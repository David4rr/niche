import Foundation

enum LyricsSource: String, CaseIterable, Sendable, Identifiable {
    case automatic, boidu, unison, lyricsPlus, lrclib, youtubeMusic, netease, qqMusic, kugou, deezer

    var id: String { rawValue }

    var name: String {
        switch self {
        case .automatic: "Automatic"
        case .boidu: "Boidu (Apple Music)"
        case .unison: "Unison"
        case .lyricsPlus: "LyricsPlus"
        case .lrclib: "LRCLIB"
        case .youtubeMusic: "YouTube Music"
        case .netease: "NetEase"
        case .qqMusic: "QQ Music"
        case .kugou: "Kugou"
        case .deezer: "Deezer"
        }
    }

    /// Limusic's default order: the word-timed catalogues lead, then the general LRC lookups,
    /// then the regional ones. Deezer is niche's last stop, kept after the list for coverage.
    static let defaultOrder: [LyricsSource] = [
        .boidu, .unison, .lyricsPlus, .lrclib, .youtubeMusic, .netease, .qqMusic, .kugou, .deezer
    ]
}

actor LyricsService {
    static let shared = LyricsService()
    static let agent = "Niche/\(Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String) (https://github.com/raihanadf/niche)"

    /// Providers start this far apart, like Limusic's `STAGGER`: a hit at the top usually sends
    /// one or two requests below it, while a song nobody has still costs one provider's latency.
    private static let stagger = Duration.milliseconds(300)

    func fetch(title: String, artist: String, album: String? = nil, duration: Double,
               source: LyricsSource, order: [LyricsSource] = LyricsSource.defaultOrder) async -> Lyrics.State {
        guard !Task.isCancelled,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration.isFinite, duration >= 0 else { return .missing }

        if source == .automatic {
            return await automatic(title: title, artist: artist, album: album, duration: duration, order: order)
        }
        guard !Task.isCancelled,
              let lines = await lines(from: source, title: title, artist: artist, album: album, duration: duration) else {
            return .missing
        }
        return validate(lines, duration: duration)
    }

    private func validate(_ lines: [LyricLine], duration: Double) -> Lyrics.State {
        if isValidSynced(lines, duration: duration) { return .loaded(lines, synced: true) }
        return isValidPlain(lines, duration: duration) ? .loaded(lines, synced: false) : .missing
    }

    private func lines(from source: LyricsSource, title: String, artist: String,
                       album: String?, duration: Double) async -> [LyricLine]? {
        switch source {
        case .automatic: nil
        case .boidu: await BoiduClient.fetch(title: title, artist: artist, album: album, duration: duration)
        case .unison: await UnisonClient.fetch(title: title, artist: artist, duration: duration)
        case .lyricsPlus: await LyricsPlusClient.fetch(title: title, artist: artist, album: album, duration: duration)
        case .lrclib: await LRCLIBClient.fetch(title: title, artist: artist, album: album, duration: duration)
        case .youtubeMusic: await YouTubeMusicClient.fetch(title: title, artist: artist, duration: duration)
        case .netease: await NetEaseClient.fetch(title: title, artist: artist, duration: duration)
        case .qqMusic: await QQMusicClient.fetch(title: title, artist: artist, duration: duration)
        case .kugou: await KugouClient.fetch(title: title, artist: artist, duration: duration)
        case .deezer: await DeezerClient.fetch(title: title, artist: artist, duration: duration)
        }
    }

    /// Order matters, not speed: answers are read top to bottom and the first synced one wins,
    /// exactly like Limusic reads its `lyrics_providers` list. A slower provider higher up still
    /// beats a quicker one below it, which is why the word-timed catalogues sit first.
    private func automatic(title: String, artist: String, album: String?, duration: Double,
                           order: [LyricsSource]) async -> Lyrics.State {
        let providers = order.filter { $0 != .automatic }
        guard !providers.isEmpty else { return .missing }

        var answers = [[LyricLine]?](repeating: nil, count: providers.count)
        var arrived = [Bool](repeating: false, count: providers.count)
        var next = 0
        var plain: [LyricLine]?
        var settled: Lyrics.State?

        await withTaskGroup(of: (Int, [LyricLine]?).self) { group in
            for (index, source) in providers.enumerated() {
                group.addTask { [weak self] in
                    if index > 0 { try? await Task.sleep(for: Self.stagger * index) }
                    guard !Task.isCancelled, let self else { return (index, nil) }
                    let lines = await self.lines(from: source, title: title, artist: artist,
                                                 album: album, duration: duration)
                    return (index, lines)
                }
            }
            while let (index, lines) = await group.next() {
                guard index < answers.count else { continue }
                answers[index] = lines
                arrived[index] = true
                while next < providers.count, arrived[next] {
                    if let hit = answers[next], isValidSynced(hit, duration: duration) {
                        settled = .loaded(hit, synced: true)
                        group.cancelAll()
                        return
                    }
                    if plain == nil, let hit = answers[next], isValidPlain(hit, duration: duration) {
                        plain = hit
                    }
                    next += 1
                }
            }
        }

        if let settled { return settled }
        return plain.map { .loaded($0, synced: false) } ?? .missing
    }

    private func hasRealSync(_ lines: [LyricLine]) -> Bool {
        lines.contains { $0.time.isFinite && $0.time > 0 && $0.time < 86_400 } &&
            (lines.count < 2 || Set(lines.compactMap { ($0.time.isFinite && $0.time >= 0 && $0.time < 86_400) ? Int($0.time * 10) : nil }).count > 1)
    }

    private func isValidPlain(_ lines: [LyricLine], duration: Double) -> Bool {
        guard !lines.isEmpty,
              lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LyricsWordParser.isMetadataOrJunkLine($0.text) }) else {
            return false
        }
        return !hasRealSync(lines) || LyricsWordParser.isValidDuration(lines: lines, duration: duration)
    }

    private func isValidSynced(_ lines: [LyricLine]?, duration: Double) -> Bool {
        guard let lines, LyricsWordParser.isValidDuration(lines: lines, duration: duration) else { return false }
        return hasRealSync(lines)
    }
}
