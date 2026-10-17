import AppKit
import SwiftUI

struct Track: Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let artwork: NSImage?
    let artworkKey: String

    func isSameSong(as other: Track) -> Bool {
        title == other.title && artist == other.artist && album == other.album
    }

    static func == (a: Track, b: Track) -> Bool { a.isSameSong(as: b) && a.artworkKey == b.artworkKey }
}

@MainActor
@Observable
final class MusicPlayer {
    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var isShuffled = false
    private(set) var repeatMode = 1
    private(set) var position: Double = 0
    private(set) var songChangeToken = 0
    let spectrum = AudioSpectrum()

    @ObservationIgnored private var elapsedAtTimestamp: Double = 0
    @ObservationIgnored private var timestamp = Date()
    @ObservationIgnored private var rate: Double = 1
    @ObservationIgnored private var pendingSong: Track?
    @ObservationIgnored private var pendingDeadline: Task<Void, Never>?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private let send: @convention(c) (Int, AnyObject?) -> Bool
    @ObservationIgnored private let setElapsed: @convention(c) (Double) -> Void
    @ObservationIgnored private let setShuffle: @convention(c) (Int) -> Void
    @ObservationIgnored private let setRepeat: @convention(c) (Int) -> Void

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let send = dlsym(handle, "MRMediaRemoteSendCommand"),
              let setElapsed = dlsym(handle, "MRMediaRemoteSetElapsedTime"),
              let setShuffle = dlsym(handle, "MRMediaRemoteSetShuffleMode"),
              let setRepeat = dlsym(handle, "MRMediaRemoteSetRepeatMode") else {
            fatalError("MediaRemote.framework symbols not found")
        }
        self.send = unsafeBitCast(send, to: (@convention(c) (Int, AnyObject?) -> Bool).self)
        self.setElapsed = unsafeBitCast(setElapsed, to: (@convention(c) (Double) -> Void).self)
        self.setShuffle = unsafeBitCast(setShuffle, to: (@convention(c) (Int) -> Void).self)
        self.setRepeat = unsafeBitCast(setRepeat, to: (@convention(c) (Int) -> Void).self)
    }

    func start() {
        guard let resources = Bundle.main.resourceURL else { fatalError("app bundle has no resources") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.appendingPathComponent("mediaremote-adapter.pl").path,
                             resources.appendingPathComponent("MediaRemoteAdapter.framework").path,
                             "stream", "--no-diff", "--debounce=50"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let output = pipe.fileHandleForReading
        Task.detached { [weak self] in
            for try await line in output.bytes.lines {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = json["payload"] as? [String: Any] else { continue }
                let snapshot = NowPlayingSnapshot(payload)
                await self?.apply(snapshot)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.start()
            }
        }
        do { try process.run() } catch { fatalError("could not launch mediaremote-adapter: \(error)") }
        self.process = process
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        spectrum.stop()
    }

    private func apply(_ snapshot: NowPlayingSnapshot) {
        guard let next = snapshot.track else {
            pendingSong = nil
            pendingDeadline?.cancel()
            track = nil
            isPlaying = false
            spectrum.follow(pid: nil)
            return
        }
        isPlaying = snapshot.isPlaying
        if let shuffle = snapshot.shuffleMode { isShuffled = shuffle != 1 }
        if let mode = snapshot.repeatMode { repeatMode = mode }
        elapsedAtTimestamp = snapshot.elapsed
        timestamp = snapshot.timestamp
        rate = snapshot.rate
        spectrum.follow(pid: snapshot.isPlaying ? snapshot.pid : nil)

        let isNewSong = track.map { !$0.isSameSong(as: next) } ?? false
        if isNewSong && next.artwork == nil {
            if pendingSong.map({ !$0.isSameSong(as: next) }) ?? true {
                pendingDeadline?.cancel()
                pendingDeadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(0.8))
                    guard !Task.isCancelled, let self, let held = self.pendingSong else { return }
                    self.commit(held)
                }
            }
            pendingSong = next
            return
        }
        commit(next)
    }

    private func commit(_ next: Track) {
        pendingSong = nil
        pendingDeadline?.cancel()
        if let current = track, !current.isSameSong(as: next) {
            songChangeToken += 1
        }
        track = next
        tick()
    }

    func tick() {
        guard let track else { return }
        let live = isPlaying ? Date().timeIntervalSince(timestamp) * rate : 0
        position = min(max(elapsedAtTimestamp + live, 0), track.duration)
    }

    func togglePlay() { _ = send(2, nil) }
    func skip(forward: Bool) { _ = send(forward ? 4 : 5, nil) }

    func seek(to fraction: Double) {
        guard let track else { return }
        let target = track.duration * min(max(fraction, 0), 1)
        setElapsed(target)
        elapsedAtTimestamp = target
        timestamp = Date()
        tick()
    }

    func toggleShuffle() {
        setShuffle(isShuffled ? 1 : 3)
        isShuffled.toggle()
    }

    func cycleRepeat() {
        let next = repeatMode == 1 ? 3 : repeatMode - 1
        setRepeat(next)
        repeatMode = next
    }
}

private struct NowPlayingSnapshot: @unchecked Sendable {
    let track: Track?
    let isPlaying: Bool
    let elapsed: Double
    let timestamp: Date
    let rate: Double
    let shuffleMode: Int?
    let repeatMode: Int?
    let pid: pid_t?

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    init(_ p: [String: Any]) {
        if let title = p["title"] as? String, !title.isEmpty {
            let art = p["artworkData"] as? String
            track = Track(title: title,
                          artist: p["artist"] as? String ?? "",
                          album: p["album"] as? String ?? "",
                          duration: p["duration"] as? Double ?? 0,
                          artwork: art.flatMap { Data(base64Encoded: $0) }.flatMap { NSImage(data: $0) },
                          artworkKey: art.map { "\($0.count):\($0.suffix(32))" } ?? "")
        } else {
            track = nil
        }
        isPlaying = p["playing"] as? Bool ?? false
        elapsed = p["elapsedTime"] as? Double ?? 0
        timestamp = (p["timestamp"] as? String).flatMap { Self.iso.date(from: $0) } ?? Date()
        rate = p["playbackRate"] as? Double ?? 1
        shuffleMode = p["shuffleMode"] as? Int
        repeatMode = p["repeatMode"] as? Int
        pid = (p["processIdentifier"] as? Int).map { pid_t($0) }
    }
}

struct ArtworkTile: View {
    let track: Track

    var body: some View {
        if let artwork = track.artwork {
            Image(nsImage: artwork).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            Color(white: 0.22).overlay {
                Image(systemName: "music.note").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

struct ArtworkSwap: ViewModifier, Animatable {
    var progress: Double
    let incoming: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        content
            .scaleEffect(incoming ? 0.86 + 0.14 * p : 1 - 0.1 * p)
            .blur(radius: incoming ? 6 * (1 - p) : 4 * p)
            .opacity(incoming ? p : 1 - p)
    }
}

struct ArtworkView: View {
    let track: Track
    let token: Int
    let isPlaying: Bool
    let cornerRadius: CGFloat

    @State private var current: Track?
    @State private var outgoing: Track?
    @State private var incomingProgress = 1.0
    @State private var outgoingProgress = 0.0

    var body: some View {
        ZStack {
            if let outgoing {
                ArtworkTile(track: outgoing).modifier(ArtworkSwap(progress: outgoingProgress, incoming: false))
            }
            ArtworkTile(track: current ?? track).modifier(ArtworkSwap(progress: incomingProgress, incoming: true))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .scaleEffect(isPlaying ? 1 : 0.82)
        .animation(.spring(Spring(duration: 0.5, bounce: 0.3), blendDuration: 0), value: isPlaying)
        .onAppear { current = track }
        .onChange(of: track) {
            guard let current, current.isSameSong(as: track), outgoing == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.current = track }
        }
        .onChange(of: token) {
            outgoing = current
            current = track
            outgoingProgress = 0
            incomingProgress = 0
            withAnimation(.easeIn(duration: 0.18)) {
                outgoingProgress = 1
            } completion: {
                outgoing = nil
                withAnimation(.spring(Spring(duration: 0.38, bounce: 0.25), blendDuration: 0)) {
                    incomingProgress = 1
                }
            }
        }
    }
}

struct WaveformView: View {
    let track: Track
    let levels: [Float]
    let isLive: Bool
    let isPlaying: Bool
    let barWidth: CGFloat
    let maxHeight: CGFloat

    static let tick = 0.28

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.tick, paused: isLive || !isPlaying)) { context in
            let step = UInt64(context.date.timeIntervalSinceReferenceDate / Self.tick)
            let minHeight: CGFloat = 2.5
            let heights = levels.indices.map { bar -> CGFloat in
                let level = isLive ? levels[bar] : simulatedLevel(bar: bar, step: step)
                let raw = isPlaying ? minHeight + CGFloat(level) * (maxHeight - minHeight) : minHeight
                return (raw * displayScale).rounded() / displayScale
            }
            ArtworkTile(track: track)
                .blur(radius: 5)
                .saturation(1.5)
                .brightness(0.12)
                .mask {
                    HStack(alignment: .center, spacing: barWidth * 0.75) {
                        ForEach(heights.indices, id: \.self) { bar in
                            Capsule().frame(width: barWidth, height: heights[bar])
                        }
                    }
                    .animation(isLive ? .easeOut(duration: 1.0 / 24) : .spring(duration: Self.tick), value: heights)
                    .animation(.easeOut(duration: 0.3), value: isPlaying)
                }
                .frame(width: CGFloat(levels.count) * barWidth * 1.75, height: maxHeight)
        }
    }

    private func simulatedLevel(bar: Int, step: UInt64) -> Float {
        let seed = UInt64(bitPattern: Int64(track.title.hashValue ^ track.artist.hashValue))
        var x = (step &* 0xbf58476d1ce4e5b9) ^ (UInt64(bar) &* 0x94d049bb133111eb) ^ seed
        x = x &+ 0x9e3779b97f4a7c15
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        x ^= x >> 31
        return 0.25 + 0.75 * Float(x % 1000) / 1000
    }
}

struct MarqueeText: View {
    let text: String
    let font: Font
    let width: CGFloat

    @State private var textWidth: CGFloat = 0

    var body: some View {
        let gap: CGFloat = 28
        let hold = 1.5
        let speed: CGFloat = 28
        let travel = textWidth + gap
        let cycle = Double(travel / speed) + hold
        TimelineView(.animation(minimumInterval: 1.0 / 120, paused: textWidth <= width)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: max(cycle, 0.001))
            let offset = textWidth > width ? -CGFloat(max(0, t - hold)) * speed : 0
            HStack(spacing: gap) {
                label
                if textWidth > width { label }
            }
            .offset(x: offset)
            .frame(width: width, alignment: .leading)
            .clipped()
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                       .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .opacity(textWidth > width ? 1 : 0)
                    .overlay(Color.black.opacity(textWidth > width ? 0 : 1))
            )
        }
    }

    private var label: some View {
        Text(text).font(font).fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.onAppear { textWidth = proxy.size.width }
                    .onChange(of: text) { textWidth = proxy.size.width }
            })
    }
}

struct ProgressBar: View {
    let fraction: Double
    let isSeeking: Bool
    let songToken: Int
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.85))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    .animation(.spring(response: 0.3, dampingFraction: 1.0, blendDuration: 0), value: songToken)
                    .animation(isSeeking ? .spring(response: 0.3, dampingFraction: 1.0, blendDuration: 0) : .linear(duration: 1),
                               value: fraction)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in onSeek(location.x / proxy.size.width) }
        }
        .frame(height: 5)
    }
}

struct MusicExpandedView: View {
    let player: MusicPlayer
    let width: CGFloat
    @State private var isSeeking = false

    var body: some View {
        if let track = player.track {
            playing(track)
        } else {
            Text("Nothing playing").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                .frame(width: width, height: 97)
        }
    }

    private func playing(_ track: Track) -> some View {
        let art: CGFloat = 48
        let waveWidth: CGFloat = 4 * 3 + 3 * 2.25
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                ArtworkView(track: track, token: player.songChangeToken, isPlaying: player.isPlaying, cornerRadius: 11)
                    .frame(width: art, height: art)
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .leading) {
                        MarqueeText(text: track.title, font: .system(size: 13, weight: .semibold),
                                    width: width - art - waveWidth - 24)
                            .id(player.songChangeToken)
                            .transition(.blurReplace(.downUp))
                    }
                    .frame(height: 16)
                    ZStack(alignment: .leading) {
                        Text(track.artist).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .id(player.songChangeToken)
                            .transition(.blurReplace(.downUp))
                    }
                    .frame(height: 15)
                }
                .animation(.spring(Spring(duration: 0.38, bounce: 0.25), blendDuration: 0), value: player.songChangeToken)
                Spacer(minLength: 0)
                WaveformView(track: track, levels: player.spectrum.levels, isLive: player.spectrum.isEnabled, isPlaying: player.isPlaying, barWidth: 3, maxHeight: 16)
            }
            .frame(height: art)
            .padding(.bottom, 6)
            HStack(spacing: 8) {
                timeLabel(player.position)
                ProgressBar(fraction: player.position / track.duration, isSeeking: isSeeking, songToken: player.songChangeToken) { fraction in
                    isSeeking = true
                    player.seek(to: fraction)
                    Task { try? await Task.sleep(for: .seconds(0.35)); isSeeking = false }
                }
                timeLabel(track.duration - player.position, negative: true)
            }
            .frame(height: 12)
            .padding(.bottom, 2)
            HStack(spacing: 0) {
                controlButton("shuffle", size: 18) { player.toggleShuffle() }
                    .opacity(player.isShuffled ? 1 : 0.45)
                controlButton("backward.fill", size: 19) { player.skip(forward: false) }
                controlButton(player.isPlaying ? "pause.fill" : "play.fill", size: 19) { player.togglePlay() }
                    .contentTransition(.symbolEffect(.replace))
                controlButton("forward.fill", size: 19) { player.skip(forward: true) }
                controlButton(player.repeatMode == 2 ? "repeat.1" : "repeat", size: 18) { player.cycleRepeat() }
                    .opacity(player.repeatMode == 1 ? 0.45 : 1)
            }
            .frame(height: 30)
        }
        .frame(width: width)
        .foregroundStyle(.white)
    }

    private func timeLabel(_ seconds: Double, negative: Bool = false) -> some View {
        let s = Int(max(seconds, 0))
        return Text("\(negative ? "-" : "")\(s / 60):\(String(format: "%02d", s % 60))")
            .font(.system(size: 10.5, weight: .semibold)).kerning(0.1)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: negative))
            .animation(.smooth(duration: 0.25), value: s)
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 36, alignment: negative ? .trailing : .leading)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .frame(width: 20, height: 20)
                .frame(width: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MusicClosedView: View {
    let player: MusicPlayer
    static let slot: CGFloat = 42

    var body: some View {
        if let track = player.track {
            HStack(spacing: 0) {
                ArtworkView(track: track, token: player.songChangeToken, isPlaying: player.isPlaying, cornerRadius: 7)
                    .frame(width: 26, height: 26)
                    .frame(width: Self.slot)
                Spacer(minLength: 0)
                WaveformView(track: track, levels: player.spectrum.levels, isLive: player.spectrum.isEnabled, isPlaying: player.isPlaying, barWidth: 3.5, maxHeight: 16)
                    .frame(width: Self.slot)
            }
        }
    }
}
