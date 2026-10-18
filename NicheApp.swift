import AppKit
import SwiftUI

@MainActor
@Observable
final class LabState {
    var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }
    var liveVisualizer: Bool {
        didSet {
            UserDefaults.standard.set(liveVisualizer, forKey: "liveVisualizer")
            player.spectrum.isEnabled = liveVisualizer
        }
    }
    var showAgents: Bool {
        didSet { UserDefaults.standard.set(showAgents, forKey: "showAgents"); applyAgentSettings() }
    }
    var showClaude: Bool {
        didSet { UserDefaults.standard.set(showClaude, forKey: "showClaude"); applyAgentSettings() }
    }
    var showOmp: Bool {
        didSet { UserDefaults.standard.set(showOmp, forKey: "showOmp"); applyAgentSettings() }
    }
    var showLockIndicator: Bool {
        didSet { UserDefaults.standard.set(showLockIndicator, forKey: "showLockIndicator") }
    }
    enum LockState { case none, locked, unlocking }
    private(set) var lockState = LockState.none
    private(set) var lockShown = false

    let controller = NotchController()
    let player = MusicPlayer()
    let agents = AgentMonitor()
    let updater = Updater()
    let liveActivities = LiveActivityCenter()
    enum Feature: CaseIterable { case music, agents }
    var selectedFeature: Feature?
    var selectedAgent: AgentKind?
    var peekFeature: Feature?
    @ObservationIgnored private var unlockTask: Task<Void, Never>?
    @ObservationIgnored private var pulseTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["showInMenuBar": true, "liveVisualizer": false, "showAgents": true,
                                     "showClaude": true, "showOmp": true, "showLockIndicator": true])
        self.showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        self.liveVisualizer = defaults.bool(forKey: "liveVisualizer")
        self.showAgents = defaults.bool(forKey: "showAgents")
        self.showClaude = defaults.bool(forKey: "showClaude")
        self.showOmp = defaults.bool(forKey: "showOmp")
        self.showLockIndicator = defaults.bool(forKey: "showLockIndicator")
        player.spectrum.isEnabled = liveVisualizer
        applyAgentSettings()
        agents.onFinished = { [weak self] session in
            guard let self, self.liveActivities.isEnabled(.agentDone), self.liveActivities.isOn else { return }
            self.liveActivities.agentFinished(session.kind)
        }

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked() }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenUnlocked() }
        }
    }

    private func applyAgentSettings() {
        var kinds: Set<AgentKind> = []
        if showAgents && showClaude { kinds.insert(.claude) }
        if showAgents && showOmp { kinds.insert(.omp) }
        agents.enabled = kinds
    }
    static let hardwareNotch: CGSize = {
        guard let screen = NSScreen.main else { fatalError("no screen available") }
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return CGSize(width: 185, height: 32)
        }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }()
    static func closedSize(hasContent: Bool) -> CGSize {
        CGSize(width: hardwareNotch.width + (hasContent ? 2 * MusicClosedView.slot : 0), height: hardwareNotch.height)
    }
    static let openSize = CGSize(width: hardwareNotch.width + 160, height: 175)

    var hasClosedContent: Bool { shownFeature != nil || lockState != .none || liveActivities.current != nil }
    var hasOpenableContent: Bool { player.track != nil || !agents.isEmpty }

    var activityRoom: CGFloat {
        controller.isExpanded && liveActivities.current != nil && shownAgent == nil ? Self.hardwareNotch.height + 4 - 18 : 0
    }

    var currentSize: CGSize {
        controller.isExpanded
            ? CGSize(width: Self.openSize.width, height: Self.openSize.height + activityRoom)
            : Self.closedSize(hasContent: hasClosedContent)
    }

    var activeFeatures: [Feature] {
        Feature.allCases.filter { $0 == .music ? player.track != nil : !agents.isEmpty }
    }

    var shownFeature: Feature? {
        if let feature = selectedFeature, activeFeatures.contains(feature) { return feature }
        return activeFeatures.first
    }

    var openFeature: Feature? {
        if let feature = peekFeature, activeFeatures.contains(feature) { return feature }
        return shownFeature
    }

    var upcomingFeatures: [Feature] {
        let live = activeFeatures
        guard let current = openFeature, let index = live.firstIndex(of: current) else { return [] }
        return (1..<live.count).map { live[(index + $0) % live.count] }
    }

    func switchFeature() {
        guard let next = upcomingFeatures.first else { return }
        peekFeature = nil
        selectedFeature = next
    }

    var shownAgent: AgentKind? {
        guard openFeature == .agents else { return nil }
        if let kind = selectedAgent, !agents.sessions(of: kind).isEmpty { return kind }
        return AgentKind.allCases.first { !agents.sessions(of: $0).isEmpty }
    }

    func showAgent(_ kind: AgentKind) {
        selectedAgent = kind
        peekFeature = .agents
        setOpen(true)
    }

    func hover(_ inside: Bool) {
        if !hasOpenableContent && lockState == .none && !controller.isExpanded {
            if inside { pulse() }
            return
        }
        setOpen(inside && lockState == .none)
    }

    private func pulse() {
        pulseTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) { controller.isLifted = true }
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.18))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 1)) { self?.controller.isLifted = false }
        }
    }

    private func screenLocked() {
        unlockTask?.cancel()
        guard showLockIndicator else { return }
        setOpen(false)
        withAnimation(.spring(Spring(duration: 0.4, bounce: 0.2), blendDuration: 0)) {
            lockState = .locked
            lockShown = true
        }
    }

    private func screenUnlocked() {
        guard lockState == .locked else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { lockState = .unlocking }
        unlockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.lockShown = false }
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 1)) { self.lockState = .none }
        }
    }

    func setOpen(_ open: Bool) {
        let c = controller
        guard open != c.isExpanded || c.isCollapsing else { return }
        if open {
            c.expand()
        } else {
            c.collapse()
            selectedAgent = nil
            peekFeature = nil
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }
}

struct NicheView: View {
    let lab: LabState
    @State private var closedFeature = LabState.Feature.music

    var body: some View {
        let c = lab.controller
        let size = lab.currentSize
        let radii = c.isRounded ? (top: 16.0, bottom: 22.0) : (top: 8.0, bottom: 12.0)
        let outlineWidth = size.width + 2 * radii.top

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
                    .fill(.black)
                if c.isExpanded {
                    Group {
                        if let kind = lab.shownAgent {
                            AgentSessionList(sessions: lab.agents.sessions(of: kind)) { session in
                                lab.agents.focus(session)
                                lab.setOpen(false)
                            }
                                .frame(width: LabState.openSize.width - 2 * 18,
                                       height: LabState.openSize.height - LabState.hardwareNotch.height - 16, alignment: .top)
                                .padding(.top, LabState.hardwareNotch.height + 2)
                        } else {
                            MusicExpandedView(player: lab.player, width: LabState.openSize.width - 2 * 18)
                                .padding(.top, 18 + lab.activityRoom)
                        }
                    }
                        .frame(width: LabState.openSize.width + 2 * 16, height: size.height, alignment: .top)
                        .overlay(alignment: .top) { topRow }
                        .drawingGroup()
                        .blur(radius: c.isSharp ? 0 : 5)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                                                removal: .opacity.animation(.easeOut(duration: 0.1))))
                } else if lab.lockState != .none {
                    LockIndicator(state: lab.lockState, isShown: lab.lockShown)
                        .frame(width: LabState.closedSize(hasContent: true).width, height: LabState.hardwareNotch.height)
                        .transition(.identity)
                } else if let activity = lab.liveActivities.current {
                    LiveActivityView(activity: activity)
                        .id(activity.kind)
                        .frame(width: LabState.closedSize(hasContent: true).width, height: LabState.hardwareNotch.height)
                        .drawingGroup()
                        .modifier(ActivityFade(isShown: lab.liveActivities.isShowing))
                        .transition(Self.activityTransition)
                } else {
                    Group {
                        if closedFeature == .agents {
                            AgentClosedView(monitor: lab.agents)
                        } else {
                            MusicClosedView(player: lab.player)
                        }
                    }
                        .frame(width: LabState.closedSize(hasContent: true).width, height: LabState.hardwareNotch.height)
                        .modifier(ClosedContentFade(isShown: lab.hasClosedContent))
                        .transition(Self.closedContentTransition(afterClosing: c.isCollapsing || c.isExpanded))
                }
                NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
                    .stroke(LinearGradient(stops: [.init(color: .white.opacity(0.28), location: 0),
                                                   .init(color: .white.opacity(0.28), location: 0.25),
                                                   .init(color: .white.opacity(0), location: 0.75)],
                                           startPoint: .bottom, endPoint: .top),
                            lineWidth: 2)
                    .opacity(c.isExpanded ? 1 : 0)
                    .animation(.easeOut(duration: 0.35), value: c.isExpanded)
                    .allowsHitTesting(false)
            }
            .frame(width: outlineWidth, height: size.height, alignment: .top)
            .clipShape(NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom))
            .background {
                NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom)
                    .fill(.black)
                    .shadow(color: .black.opacity(c.isExpanded ? 0.55 : 0), radius: 14, y: 4)
                    .animation(.easeOut(duration: 0.35), value: c.isExpanded)
            }
            .modifier(NotchSquashModifier(controller: c))
            .contentShape(Rectangle())
            .onHover { lab.hover($0) }
            .onChange(of: lab.hasOpenableContent) { _, has in if !has { lab.setOpen(false) } }
            .onChange(of: lab.shownFeature, initial: true) { _, feature in
                if let feature { closedFeature = feature }
            }
            .onChange(of: lab.player.isPlaying) { _, playing in
                if playing { lab.selectedFeature = .music }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !c.isExpanded else { return }
                        c.isPressed = abs(value.translation.height) < 4
                        c.stretch = max(-1, min(1, -value.translation.height / 60))
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.35, dampingFraction: 1.0, blendDuration: 0)) {
                            c.isPressed = false
                            c.stretch = 0
                        }
                    }
            )
            Spacer(minLength: 0)
        }
        .frame(width: LabState.openSize.width + 80, height: LabState.openSize.height + 60)
        .animation(closedResize, value: lab.hasClosedContent)
    }

    private var closedResize: Animation {
        lab.hasClosedContent
            ? .spring(Spring(duration: 0.5, bounce: 0.32), blendDuration: 0)
            : .spring(response: 0.45, dampingFraction: 0.95)
    }

    private static let activityTransition = AnyTransition.asymmetric(
        insertion: AnyTransition(.blurReplace).animation(.spring(response: 0.35, dampingFraction: 0.9)),
        removal: .identity)

    private static func closedContentTransition(afterClosing: Bool) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(afterClosing ? 0.25 : 0.05)),
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    @ViewBuilder private var topRow: some View {
        if let activity = lab.liveActivities.current {
            LiveActivityView(activity: activity)
                .id(activity.kind)
                .padding(.horizontal, 16 + 4)
                .frame(height: LabState.hardwareNotch.height)
                .modifier(ActivityFade(isShown: lab.liveActivities.isShowing))
                .transition(Self.activityTransition)
        } else {
            ears
                .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.1)))
        }
    }

    private var ears: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if lab.activeFeatures.contains(.agents) {
                ForEach(AgentKind.allCases, id: \.self) { kind in
                    let sessions = lab.agents.sessions(of: kind)
                    if !sessions.isEmpty {
                        Button { lab.showAgent(kind) } label: {
                            AgentIndicator(kind: kind, sessions: sessions)
                                .frame(width: 26, height: 22)
                                .background(Capsule().fill(.white.opacity(lab.shownAgent == kind ? 0.18 : 0.06)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
            }
            let upcoming = lab.upcomingFeatures
            if !upcoming.isEmpty, let current = lab.openFeature {
                let stack = upcoming + [current]
                Button {
                    withAnimation(.spring(Spring(duration: 0.35, bounce: 0.3), blendDuration: 0)) { lab.switchFeature() }
                } label: {
                    ZStack {
                        ForEach(Array(stack.enumerated().reversed()), id: \.element) { depth, feature in
                            FeatureLogo(feature: feature)
                                .scaleEffect(1 - 0.14 * CGFloat(depth))
                                .offset(x: -14 * CGFloat(depth))
                                .opacity(1 - 0.35 * Double(depth))
                        }
                    }
                    .frame(width: 22 + 14 * CGFloat(stack.count - 1), height: 22, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16 + 10)
        .frame(height: LabState.hardwareNotch.height)
    }
}

struct ActivityFade: ViewModifier {
    let isShown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .blur(radius: isShown ? 0 : 6)
            .scaleEffect(isShown ? 1 : 0.9)
    }
}

struct ClosedContentFade: ViewModifier {
    let isShown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .scaleEffect(isShown ? 1 : 0.75)
            .blur(radius: isShown ? 0 : 4)
            .animation(isShown ? .spring(response: 0.45, dampingFraction: 0.9).delay(0.18)
                               : .spring(response: 0.45, dampingFraction: 0.95),
                       value: isShown)
    }
}

struct FeatureLogo: View {
    let feature: LabState.Feature

    var body: some View {
        let (symbol, tint): (String, Color) = switch feature {
        case .music: ("music.note", Color(red: 1, green: 0.42, blue: 0.55))
        case .agents: ("sparkles", Color(red: 0.85, green: 0.6, blue: 1))
        }
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(white: 0.16)))
            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
    }
}

struct LockIndicator: View {
    let state: LabState.LockState
    let isShown: Bool
    @State private var lift: CGFloat = 1.6
    @State private var swing: Double = 180
    @State private var squash: CGFloat = 1
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Shackle()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .frame(width: 6, height: 6)
                    .rotation3DEffect(.degrees(swing), axis: (x: 0, y: 1, z: 0), anchor: .trailing, perspective: 0)
                    .offset(y: -4.1 - lift)
                RoundedRectangle(cornerRadius: 1.9)
                    .fill(.white)
                    .frame(width: 8.8, height: 6.6)
                    .scaleEffect(x: 2 - squash, y: squash, anchor: .bottom)
            }
            .frame(width: 13, height: 12, alignment: .bottom)
            .frame(width: MusicClosedView.slot)
            Spacer(minLength: 0)
        }
        .opacity(isShown && appeared ? 1 : 0)
        .blur(radius: isShown && appeared ? 0 : 6)
        .scaleEffect(isShown && appeared ? 1 : 0.85, anchor: .leading)
        .task { await latch() }
        .onChange(of: state) { _, state in
            if state == .unlocking { Task { await unlatch() } }
        }
    }

    private func latch() async {
        withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        try? await Task.sleep(for: .seconds(0.55))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { swing = 0 }
        try? await Task.sleep(for: .seconds(0.25))
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { lift = 0 }
        try? await Task.sleep(for: .seconds(0.08))
        withAnimation(.easeOut(duration: 0.05)) { squash = 0.88 }
        try? await Task.sleep(for: .seconds(0.05))
        withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { squash = 1 }
    }

    private func unlatch() async {
        withAnimation(.easeOut(duration: 0.06)) { squash = 0.88 }
        try? await Task.sleep(for: .seconds(0.06))
        withAnimation(.spring(response: 0.28, dampingFraction: 0.4)) {
            squash = 1
            lift = 2
        }
        try? await Task.sleep(for: .seconds(0.1))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { swing = 180 }
    }
}

private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.width / 2
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.midX, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

@_silgen_name("_CGSDefaultConnection") private func CGSDefaultConnection() -> UInt
@_silgen_name("CGSSpaceCreate") private func CGSSpaceCreate(_ cid: UInt, _ flag: Int, _ options: NSDictionary?) -> UInt64
@_silgen_name("CGSSpaceSetAbsoluteLevel") private func CGSSpaceSetAbsoluteLevel(_ cid: UInt, _ space: UInt64, _ level: Int)
@_silgen_name("CGSShowSpaces") private func CGSShowSpaces(_ cid: UInt, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces") private func CGSHideSpaces(_ cid: UInt, _ spaces: NSArray)
@_silgen_name("CGSSpaceDestroy") private func CGSSpaceDestroy(_ cid: UInt, _ space: UInt64)
@_silgen_name("CGSAddWindowsToSpaces") private func CGSAddWindowsToSpaces(_ cid: UInt, _ windows: NSArray, _ spaces: NSArray)

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let lab = LabState()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var notchSpace: UInt64 = 0
    private var monitors: [Any] = []
    private var playbackTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { fatalError("no screen available") }
        let size = CGSize(width: LabState.openSize.width + 80, height: LabState.openSize.height + 60)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.canBecomeVisibleWithoutLogin = true
        panel.contentView = NSHostingView(rootView: NicheView(lab: lab))
        panel.orderFrontRegardless()

        let cid = CGSDefaultConnection()
        notchSpace = CGSSpaceCreate(cid, 0x1, nil)
        CGSSpaceSetAbsoluteLevel(cid, notchSpace, 400)
        CGSShowSpaces(cid, [notchSpace] as NSArray)
        CGSAddWindowsToSpaces(cid, [panel.windowNumber] as NSArray, [notchSpace] as NSArray)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.isVisible = lab.showInMenuBar
        trackSettings()

        lab.player.start()
        lab.agents.start()
        lab.updater.start()
        lab.liveActivities.start()
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.lab.player.tick() }
        }

        let update: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            let notch = self.lab.currentSize
            let hit = NSRect(x: frame.midX - notch.width / 2 - 8, y: frame.maxY - notch.height - 8,
                             width: notch.width + 16, height: notch.height + 8)
            self.panel.ignoresMouseEvents = !hit.contains(NSEvent.mouseLocation)
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: update) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { update($0); return $0 } as Any)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.panel, let view = self.panel.contentView else { return event }
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings", action: #selector(self.openSettings), keyEquivalent: "").target = self
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil
        } as Any)

        if !UserDefaults.standard.bool(forKey: "onboarded") { openOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lab.player.stop()
        lab.liveActivities.stop()
        let cid = CGSDefaultConnection()
        CGSHideSpaces(cid, [notchSpace] as NSArray)
        CGSSpaceDestroy(cid, notchSpace)
    }

    private func trackSettings() {
        withObservationTracking {
            _ = lab.showInMenuBar
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem.isVisible = self.lab.showInMenuBar
                self.trackSettings()
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(lab: lab)))
            window.title = "Niche Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 420))
            settingsWindow = window
            monitors.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.settingsWindow = nil }
            })
        }
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openOnboarding() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(lab: lab) { [weak window] in window?.close() })
        window.setContentSize(window.contentView!.fittingSize)
        monitors.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            UserDefaults.standard.set(true, forKey: "onboarded")
            Task { @MainActor in self?.onboardingWindow = nil }
        })
        onboardingWindow = window
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            let x0: CGFloat = 2, x1: CGFloat = 18, y0: CGFloat = 2.5, y1: CGFloat = 13.5
            let nl: CGFloat = 10 - 3.4, nr: CGFloat = 10 + 3.4, depth: CGFloat = 2.6
            let corners: [(CGPoint, CGFloat)] = [
                (CGPoint(x: x0, y: y1), 3.6), (CGPoint(x: nl, y: y1), 0.8), (CGPoint(x: nl, y: y1 - depth), 1.2),
                (CGPoint(x: nr, y: y1 - depth), 1.2), (CGPoint(x: nr, y: y1), 0.8), (CGPoint(x: x1, y: y1), 3.6),
                (CGPoint(x: x1, y: y0), 3.6), (CGPoint(x: x0, y: y0), 3.6),
            ]
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x0, y: 8))
            for i in corners.indices {
                path.addArc(tangent1End: corners[i].0, tangent2End: corners[(i + 1) % corners.count].0, radius: corners[i].1)
            }
            path.closeSubpath()
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path)
            ctx.setLineWidth(1.6)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
