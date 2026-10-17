import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps
import SwiftUI

@MainActor
@Observable
final class LiveActivityCenter {
    enum Kind: String, CaseIterable, Identifiable {
        case capsLock, focus, volume, brightness, lowBattery, charging, fullyCharged, agentDone
        var id: Self { self }
        var title: String {
            switch self {
            case .capsLock: "Caps Lock"
            case .focus: "Focus"
            case .volume: "Volume"
            case .brightness: "Brightness"
            case .lowBattery: "Low battery"
            case .charging: "Charging"
            case .fullyCharged: "Fully charged"
            case .agentDone: "Agent finished"
            }
        }
    }

    struct Activity: Equatable {
        let kind: Kind
        var level: Double = 0
        var isOn = false
        var symbol: String?
        var agent: AgentKind?
    }

    private(set) var current: Activity?

    var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: "liveActivities"); restart() }
    }
    private(set) var enabled: Set<Kind>
    var replacesSystemHUD: Bool {
        didSet { UserDefaults.standard.set(replacesSystemHUD, forKey: "replacesSystemHUD"); restart() }
    }
    private(set) var isKeyTapActive = false

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var capsTimer: Timer?
    @ObservationIgnored private var lastCaps: Bool?
    @ObservationIgnored private var brightnessRegistered = false
    @ObservationIgnored private var lastBrightness: Double?
    @ObservationIgnored private var focusProcess: Process?
    @ObservationIgnored private var lastFocus: Bool?
    @ObservationIgnored private var focusSymbol = "moon.fill"
    @ObservationIgnored private var batterySource: CFRunLoopSource?
    @ObservationIgnored private var lastBattery: (level: Int, onAC: Bool, full: Bool)?
    @ObservationIgnored private var volumeDevice = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var lastVolume: (Float, Bool)?
    @ObservationIgnored private var audioListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private let registerBrightness: @convention(c) (UInt32, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    @ObservationIgnored private let unregisterBrightness: @convention(c) (UInt32, UnsafeRawPointer?) -> Int32
    @ObservationIgnored private let getBrightness: @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    @ObservationIgnored private let setBrightness: @convention(c) (UInt32, Float) -> Int32
    @ObservationIgnored private var keyTap: CFMachPort?
    @ObservationIgnored private var keyTapSource: CFRunLoopSource?

    nonisolated(unsafe) private static weak var shared: LiveActivityCenter?
    private static let lowBatteryThreshold = 20

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: Kind.allCases.map { ("liveActivity.\($0.rawValue)", true) })
            .merging(["liveActivities": true, "replacesSystemHUD": true]) { a, _ in a })
        isOn = defaults.bool(forKey: "liveActivities")
        replacesSystemHUD = defaults.bool(forKey: "replacesSystemHUD")
        enabled = Set(Kind.allCases.filter { defaults.bool(forKey: "liveActivity.\($0.rawValue)") })
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let register = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications"),
              let unregister = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications"),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else {
            fatalError("DisplayServices brightness symbols not found")
        }
        registerBrightness = unsafeBitCast(register, to: (@convention(c) (UInt32, UnsafeRawPointer?, CFNotificationCallback) -> Int32).self)
        unregisterBrightness = unsafeBitCast(unregister, to: (@convention(c) (UInt32, UnsafeRawPointer?) -> Int32).self)
        getBrightness = unsafeBitCast(get, to: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
        setBrightness = unsafeBitCast(set, to: (@convention(c) (UInt32, Float) -> Int32).self)
        Self.shared = self
    }

    func isEnabled(_ kind: Kind) -> Bool { enabled.contains(kind) }

    func setEnabled(_ kind: Kind, _ on: Bool) {
        if on { enabled.insert(kind) } else { enabled.remove(kind) }
        UserDefaults.standard.set(on, forKey: "liveActivity.\(kind.rawValue)")
        restart()
    }

    func start() {
        if replacesSystemHUD && !UserDefaults.standard.bool(forKey: "askedAccessibility") {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            requestAccessibility()
        }
        restart()
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    func stop() {
        focusProcess?.terminationHandler = nil
        focusProcess?.terminate()
        focusProcess = nil
    }

    func agentFinished(_ kind: AgentKind) {
        guard watching(.agentDone) else { return }
        show(Activity(kind: .agentDone, agent: kind), for: 2.5)
    }

    private func watching(_ kind: Kind) -> Bool { isOn && enabled.contains(kind) }

    private func restart() {
        capsTimer?.invalidate()
        capsTimer = nil
        if brightnessRegistered {
            _ = unregisterBrightness(CGMainDisplayID(), nil)
            brightnessRegistered = false
        }
        focusProcess?.terminationHandler = nil
        focusProcess?.terminate()
        focusProcess = nil
        if let batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), batterySource, .defaultMode)
            self.batterySource = nil
        }
        for (object, address, block) in audioListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        audioListeners = []
        lastCaps = nil
        lastBrightness = nil
        lastFocus = nil
        lastBattery = nil
        lastVolume = nil
        if let keyTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyTapSource, .commonModes)
            self.keyTapSource = nil
        }
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: false)
            CFMachPortInvalidate(keyTap)
            self.keyTap = nil
        }
        isKeyTapActive = false
        if let current, !watching(current.kind) { hide() }

        if replacesSystemHUD && (watching(.volume) || watching(.brightness)) { startKeyTap() }

        if watching(.capsLock) {
            readCaps()
            capsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readCaps() }
            }
        }
        if watching(.brightness) {
            brightnessRegistered = registerBrightness(CGMainDisplayID(), nil) { _, _, _, _, info in
                guard let value = (info as NSDictionary?)?["value"] as? NSNumber else { return }
                let level = value.doubleValue
                Task { @MainActor in LiveActivityCenter.shared?.brightnessChanged(level) }
            } == 0
            if !brightnessRegistered { NSLog("Niche could not register for brightness changes") }
        }
        if watching(.focus) { watchFocus() }
        if watching(.lowBattery) || watching(.charging) || watching(.fullyCharged) { watchBattery() }
        if watching(.volume) { watchVolume() }
    }

    private enum MediaKey { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    private func startKeyTap() {
        guard AXIsProcessTrusted() else {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.keyTap == nil, self.replacesSystemHUD else { return }
                self.startKeyTap()
            }
            return
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << 14)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            MainActor.assumeIsolated {
                guard let center = LiveActivityCenter.shared else { return Unmanaged.passUnretained(event) }
                return center.handleTap(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            }
        }, userInfo: nil) else {
            NSLog("Niche could not create the media key tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyTap = tap
        keyTapSource = source
        isKeyTapActive = true
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            return false
        }
        let key: MediaKey
        let isDown: Bool
        if type.rawValue == 14 {
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
            let data = ns.data1
            isDown = (data & 0xFF00) >> 8 == 0xA
            switch (data & 0xFFFF0000) >> 16 {
            case 0: key = .volumeUp
            case 1: key = .volumeDown
            case 7: key = .mute
            case 2: key = .brightnessUp
            case 3: key = .brightnessDown
            default: return false
            }
        } else {
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: key = .brightnessUp
            case 145: key = .brightnessDown
            default: return false
            }
            isDown = type == .keyDown
        }
        let isVolume = key == .volumeUp || key == .volumeDown || key == .mute
        guard watching(isVolume ? .volume : .brightness) else { return false }
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        guard isDown else { return true }
        return isVolume ? changeVolume(key, step: step) : changeBrightness(up: key == .brightnessUp, step: step)
    }

    private func changeVolume(_ key: MediaKey, step: Float) -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var volume = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var mute = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &volume), AudioObjectIsPropertySettable(device, &volume, &settable) == noErr,
              settable.boolValue else { return false }
        let hasMute = AudioObjectHasProperty(device, &mute)
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if hasMute { AudioObjectGetPropertyData(device, &mute, 0, nil, &size, &muted) }
        if key == .mute {
            guard hasMute else { return false }
            muted = muted == 0 ? 1 : 0
            return AudioObjectSetPropertyData(device, &mute, 0, nil, size, &muted) == noErr
        }
        var level = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volume, 0, nil, &size, &level) == noErr else { return false }
        level = min(max(((level + (key == .volumeUp ? step : -step)) / step).rounded() * step, 0), 1)
        if hasMute && muted != 0 && key == .volumeUp {
            muted = 0
            AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
        }
        return AudioObjectSetPropertyData(device, &volume, 0, nil, size, &level) == noErr
    }

    private func changeBrightness(up: Bool, step: Float) -> Bool {
        let display = CGMainDisplayID()
        var level: Float = 0
        guard getBrightness(display, &level) == 0 else { return false }
        level = min(max(((level + (up ? step : -step)) / step).rounded() * step, 0), 1)
        return setBrightness(display, level) == 0
    }

    private func readCaps() {
        let caps = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        if let lastCaps, lastCaps != caps { show(Activity(kind: .capsLock, isOn: caps), for: 1.4) }
        lastCaps = caps
    }

    private func brightnessChanged(_ level: Double) {
        if lastBrightness.map({ abs($0 - level) > 0.001 }) != false {
            show(Activity(kind: .brightness, level: level), for: 1.4)
        }
        lastBrightness = level
    }

    private func watchFocus() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate",
                             "process == \"donotdisturbd\" AND eventMessage BEGINSWITH \"Delivering active mode update\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        readLines(from: pipe.fileHandleForReading, label: "niche.focus") { [weak self] line in
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = json["eventMessage"] as? String,
                  let match = message.firstMatch(of: #/activeModeIdentifier=([A-Za-z0-9._-]+|\(null\))/#) else { return }
            let mode = String(match.1)
            let active = mode != "(null)"
            Task { @MainActor in self?.focusChanged(active: active, mode: mode) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.focusProcess === process else { return }
                self.watchFocus()
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("Niche could not start the focus log stream: %@", String(describing: error))
            return
        }
        focusProcess = process
    }

    private func focusChanged(active: Bool, mode: String?) {
        if active, let mode { focusSymbol = Self.focusSymbol(for: mode) }
        if lastFocus != active { show(Activity(kind: .focus, isOn: active, symbol: focusSymbol), for: 1.6) }
        lastFocus = active
    }

    private static func focusSymbol(for mode: String) -> String {
        switch mode {
        case let m where m.hasSuffix("mode.driving"): "car.fill"
        case let m where m.hasSuffix("mode.workout") || m.hasSuffix("fitness"): "figure.run"
        case let m where m.hasSuffix(".work"): "briefcase.fill"
        case let m where m.hasSuffix("personal-time"): "person.fill"
        case let m where m.hasSuffix("reading"): "book.fill"
        case let m where m.hasSuffix("gaming"): "gamecontroller.fill"
        case let m where m.hasSuffix("mindfulness"): "brain.head.profile"
        case let m where m.contains("sleep"): "bed.double.fill"
        default: "moon.fill"
        }
    }

    private func watchBattery() {
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in LiveActivityCenter.shared?.readBattery() }
        }, nil)?.takeRetainedValue() else {
            NSLog("Niche could not watch the power source")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        batterySource = source
        readBattery()
    }

    private func readBattery() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let battery = sources.lazy
                .compactMap({ IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] })
                .first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }),
              let capacity = battery[kIOPSCurrentCapacityKey] as? Int,
              let maximum = battery[kIOPSMaxCapacityKey] as? Int, maximum > 0,
              let state = battery[kIOPSPowerSourceStateKey] as? String else { return }
        let level = capacity * 100 / maximum
        let onAC = state == kIOPSACPowerValue
        let full = onAC && (level >= 100 || battery[kIOPSIsChargedKey] as? Bool == true)
        let now = (level: level, onAC: onAC, full: full)
        if let last = lastBattery {
            let fraction = Double(level) / 100
            if full && !last.full && watching(.fullyCharged) {
                show(Activity(kind: .fullyCharged, level: fraction), for: 2.5)
            } else if onAC && !last.onAC && watching(.charging) {
                show(Activity(kind: .charging, level: fraction), for: 2)
            } else if !onAC && level <= Self.lowBatteryThreshold
                        && (last.onAC || last.level > Self.lowBatteryThreshold || (level <= 10 && last.level > 10))
                        && watching(.lowBattery) {
                show(Activity(kind: .lowBattery, level: fraction), for: 3)
            }
        }
        lastBattery = now
    }

    private func watchVolume() {
        var defaultOutput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        let deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.restart() }
        }
        AudioObjectAddPropertyListenerBlock(system, &defaultOutput, .main, deviceChanged)
        audioListeners.append((system, defaultOutput, deviceChanged))

        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &defaultOutput, 0, nil, &size, &volumeDevice) == noErr else {
            NSLog("Niche cannot read the default output device")
            return
        }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(volumeDevice, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.readVolume() }
            }
            AudioObjectAddPropertyListenerBlock(volumeDevice, &address, .main, block)
            audioListeners.append((volumeDevice, address, block))
        }
        readVolume()
    }

    private func readVolume() {
        var level = Float32(0)
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(volumeDevice, &address, 0, nil, &size, &level) == noErr else { return }
        address.mSelector = kAudioDevicePropertyMute
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(volumeDevice, &address) {
            AudioObjectGetPropertyData(volumeDevice, &address, 0, nil, &size, &muted)
        }
        let now = (level, muted != 0)
        if let lastVolume, lastVolume != now {
            show(Activity(kind: .volume, level: Double(level), isOn: muted == 0), for: 1.4)
        }
        lastVolume = now
    }

    private func show(_ activity: Activity, for seconds: Double) {
        withAnimation(.spring(Spring(duration: 0.4, bounce: 0.25), blendDuration: 0)) { current = activity }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.95)) { current = nil }
    }
}

struct LiveActivityView: View {
    let activity: LiveActivityCenter.Activity

    var body: some View {
        HStack(spacing: 0) {
            icon
                .frame(width: MusicClosedView.slot)
            Spacer(minLength: 0)
            trailing
                .frame(width: MusicClosedView.slot)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private var icon: some View {
        switch activity.kind {
        case .capsLock:
            symbol(activity.isOn ? "capslock.fill" : "capslock", tint: activity.isOn ? .green : .white)
        case .focus:
            symbol(activity.symbol ?? "moon.fill", tint: activity.isOn ? Color(red: 0.58, green: 0.5, blue: 1) : .white.opacity(0.5))
        case .volume:
            symbol(volumeSymbol, tint: .white)
        case .brightness:
            symbol(activity.level < 0.35 ? "sun.min.fill" : "sun.max.fill", tint: .yellow)
        case .lowBattery:
            symbol(activity.level <= 0.1 ? "battery.0percent" : "battery.25percent", tint: .red)
        case .charging:
            symbol("battery.100percent.bolt", tint: .green)
        case .fullyCharged:
            symbol("battery.100percent", tint: .green)
        case .agentDone:
            if let agent = activity.agent { AgentGlyph(kind: agent, size: 13) }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch activity.kind {
        case .capsLock, .focus:
            label(activity.isOn ? "On" : "Off")
        case .volume, .brightness:
            LevelBar(level: activity.kind == .volume && !activity.isOn ? 0 : activity.level)
        case .lowBattery, .charging, .fullyCharged:
            label("\(Int((activity.level * 100).rounded()))%")
                .foregroundStyle(activity.kind == .lowBattery ? Color.red : .white.opacity(0.85))
        case .agentDone:
            symbol("checkmark.circle.fill", tint: .green)
        }
    }

    private var volumeSymbol: String {
        if !activity.isOn || activity.level == 0 { return "speaker.slash.fill" }
        return activity.level < 0.34 ? "speaker.wave.1.fill" : activity.level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct LevelBar: View {
    let level: Double

    var body: some View {
        Capsule().fill(.white.opacity(0.2))
            .overlay(alignment: .leading) {
                Capsule().fill(.white)
                    .frame(width: 26 * min(max(level, 0), 1))
            }
            .frame(width: 26, height: 5)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: level)
    }
}
