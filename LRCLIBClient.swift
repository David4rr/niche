import Foundation

struct LyricLine: Identifiable, Sendable, Equatable {
    let id: Int
    let time: Double
    let endTime: Double
    let text: String
}

enum LyricsState: Sendable, Equatable {
    case idle
    case loading
    case loaded(lines: [LyricLine], isSynced: Bool)
    case notFound
}

enum LRCLIBClient {
    private static let userAgent = "Niche/0.6.9 (https://github.com/raihanadf/niche)"
    private static let exactEndpoint = "https://lrclib.net/api/get"
    private static let searchEndpoint = "https://lrclib.net/api/search"

    static func sanitize(title: String, artist: String) -> (title: String, artist: String) {
        var cleanTitle = title
        var cleanArtist = artist

        if cleanArtist.hasSuffix(" - Topic") {
            cleanArtist = String(cleanArtist.dropLast(8)).trimmingCharacters(in: .whitespaces)
        }
        if cleanArtist.hasSuffix("VEVO") {
            cleanArtist = String(cleanArtist.dropLast(4)).trimmingCharacters(in: .whitespaces)
        }

        let patterns = [
            "\\s*\\(Official\\s+(Music\\s+)?Video\\)",
            "\\s*\\[Official\\s+(Music\\s+)?Video\\]",
            "\\s*\\(Official\\s+Audio\\)",
            "\\s*\\[Official\\s+Audio\\]",
            "\\s*\\(Audio\\)",
            "\\s*\\[Audio\\]",
            "\\s*\\(Lyrics?\\s*(Video)?\\)",
            "\\s*\\[Lyrics?\\s*(Video)?\\]",
            "\\s*\\(Visualizer\\)",
            "\\s*\\[Visualizer\\]",
            "\\s*\\(Official\\s+Lyric\\s+Video\\)",
            "\\s*\\[MV\\]",
            "\\s*\\(MV\\)",
            "\\s*\\[4K\\]",
            "\\s*\\(4K\\)",
            "\\s*\\(HD\\)",
            "\\s*\\[HD\\]",
            "\\s*\\(Live.*?\\)",
            "\\s*\\[Live.*?\\]",
            "\\s*\\(feat\\..*?\\)",
            "\\s*\\[feat\\..*?\\]",
            "\\s*\\(ft\\..*?\\)",
            "\\s*\\[ft\\..*?\\]",
            "\\s*\\(prod\\..*?\\)",
            "\\s*\\[prod\\..*?\\]"
        ]

        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                cleanTitle = regex.stringByReplacingMatches(
                    in: cleanTitle,
                    range: NSRange(location: 0, length: cleanTitle.utf16.count),
                    withTemplate: ""
                )
            }
        }

        cleanTitle = cleanTitle.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”\t\n\r"))
        cleanArtist = cleanArtist.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”\t\n\r"))

        if cleanTitle.contains(" - ") {
            let parts = cleanTitle.components(separatedBy: " - ")
            if parts.count >= 2 {
                let p0 = parts[0].trimmingCharacters(in: .whitespaces)
                let p1 = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                if cleanArtist.isEmpty || cleanArtist.caseInsensitiveCompare(p0) == .orderedSame || isChannelName(cleanArtist) {
                    cleanArtist = p0
                    cleanTitle = p1
                }
            }
        }

        return (cleanTitle.isEmpty ? title : cleanTitle, cleanArtist.isEmpty ? artist : cleanArtist)
    }

    static func isChannelName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("kexp") || lower.contains("vevo") || lower.contains("records")
            || lower.contains("channel") || lower.contains("music") || lower.contains("tv")
    }

    static func baseTitle(from title: String) -> String {
        var base = title
        if let dashIdx = base.range(of: " - ") {
            base = String(base[..<dashIdx.lowerBound])
        }
        let patterns = [
            "\\s*\\(.*?Remix.*?\\)",
            "\\s*\\[.*?Remix.*?\\]",
            "\\s*\\(.*?Edit.*?\\)",
            "\\s*\\[.*?Edit.*?\\]",
            "\\s*\\(.*?Version.*?\\)",
            "\\s*\\[.*?Version.*?\\]",
            "\\s*\\(.*?Live.*?\\)",
            "\\s*\\[.*?Live.*?\\]",
            "\\s*\\(.*?Acoustic.*?\\)",
            "\\s*\\[.*?Acoustic.*?\\]",
            "\\s*\\(.*?Sped Up.*?\\)",
            "\\s*\\[.*?Sped Up.*?\\]",
            "\\s*\\(.*?Slowed.*?\\)",
            "\\s*\\[.*?Slowed.*?\\]"
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                base = regex.stringByReplacingMatches(in: base, range: NSRange(location: 0, length: base.utf16.count), withTemplate: "")
            }
        }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”\t\n\r"))
    }

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var entries: [(time: Double, text: String)] = []
        let rawLines = lrc.components(separatedBy: .newlines)

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            var lineText = trimmed
            var timestamps: [Double] = []

            while lineText.hasPrefix("[") {
                guard let closeIdx = lineText.firstIndex(of: "]") else { break }
                let tag = String(lineText[lineText.index(after: lineText.startIndex)..<closeIdx])
                lineText = String(lineText[lineText.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)

                let parts = tag.split(separator: ":")
                if parts.count >= 2, let min = Double(parts[0]), let sec = Double(parts[1]) {
                    timestamps.append(min * 60 + sec)
                }
            }

            for ts in timestamps {
                entries.append((time: ts, text: lineText))
            }
        }

        entries.sort { $0.time < $1.time }
        return entries.enumerated().map { idx, item in
            let nextTime = idx + 1 < entries.count ? entries[idx + 1].time : (item.time + 6.0)
            let gap = nextTime - item.time
            let words = item.text.split(separator: " ").count
            let estDuration = max(2.0, Double(words) * 0.45 + 1.2)
            let end = gap > (estDuration + 2.0) ? (item.time + estDuration) : nextTime
            return LyricLine(id: idx, time: item.time, endTime: max(end, item.time + 1.0), text: item.text)
        }
    }
    static func fetch(title: String, artist: String, duration: Double) async -> LyricsState {
        if let exact = await fetchExact(title: title, artist: artist, duration: duration) {
            return exact
        }
        if let search = await fetchSearch(title: title, artist: artist, duration: duration) {
            return search
        }
        let base = baseTitle(from: title)
        if base != title && !base.isEmpty {
            if let baseExact = await fetchExact(title: base, artist: artist, duration: duration) {
                return baseExact
            }
            if let baseSearch = await fetchSearch(title: base, artist: artist, duration: duration) {
                return baseSearch
            }
        }
        return .notFound
    }

    private static func createRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func fetchExact(title: String, artist: String, duration: Double) async -> LyricsState? {
        var comps = URLComponents(string: exactEndpoint)
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if duration > 1 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        comps?.queryItems = queryItems
        guard let url = comps?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(for: createRequest(url: url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parseResponse(data: data)
        } catch {
            return nil
        }
    }

    private static func fetchSearch(title: String, artist: String, duration: Double) async -> LyricsState? {
        var comps = URLComponents(string: searchEndpoint)
        let query = artist.isEmpty ? title : "\(artist) \(title)"
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(for: createRequest(url: url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

            let ranked = jsonArray.compactMap { dict -> (state: LyricsState, score: Int)? in
                guard let state = parseDict(dict) else { return nil }
                let score = scoreCandidate(dict: dict, targetTitle: title, targetArtist: artist, targetDuration: duration)
                return (state, score)
            }
            .sorted { $0.score > $1.score }

            return ranked.first?.state
        } catch {
            return nil
        }
    }

    private static func scoreCandidate(dict: [String: Any], targetTitle: String, targetArtist: String, targetDuration: Double) -> Int {
        var score = 0
        let synced = dict["syncedLyrics"] as? String ?? ""
        if !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 1000
        }

        let candDur = dict["duration"] as? Double ?? 0
        if targetDuration > 0 && candDur > 0 {
            let diff = abs(candDur - targetDuration)
            if diff <= 1.0 { score += 1200 }
            else if diff <= 2.5 { score += 800 }
            else if diff <= 5.0 { score += 400 }
            else if diff <= 10.0 { score += 100 }
            else { score -= Int(diff * 50) }
        }

        let candTitle = (dict["trackName"] as? String ?? "").lowercased()
        let tTitle = targetTitle.lowercased()
        if candTitle == tTitle { score += 500 }
        else if candTitle.contains(tTitle) || tTitle.contains(candTitle) { score += 250 }

        let candArtist = (dict["artistName"] as? String ?? "").lowercased()
        let tArtist = targetArtist.lowercased()
        if candArtist == tArtist { score += 500 }
        else if candArtist.contains(tArtist) || tArtist.contains(candArtist) { score += 250 }

        return score
    }

    private static func parseResponse(data: Data) -> LyricsState? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseDict(dict)
    }

    private static func parseDict(_ dict: [String: Any]) -> LyricsState? {
        if let synced = dict["syncedLyrics"] as? String, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty {
                return .loaded(lines: lines, isSynced: true)
            }
        }

        if let plain = dict["plainLyrics"] as? String, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = plain.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { idx, text in LyricLine(id: idx, time: Double(idx * 3), endTime: Double(idx * 3 + 3), text: text) }
            if !lines.isEmpty {
                return .loaded(lines: lines, isSynced: false)
            }
        }

        return nil
    }
}
