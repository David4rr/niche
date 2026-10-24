import Foundation

struct LyricLine: Identifiable, Sendable, Equatable {
    let id: Int, time: Double, endTime: Double, text: String
}
enum LyricsState: Sendable, Equatable {
    case idle, loading, loaded(lines: [LyricLine], isSynced: Bool), notFound
}
enum LRCLIBClient {
    private static let userAgent = "Niche/0.6.9 (https://github.com/raihanadf/niche)"
    private static let exactEndpoint = "https://lrclib.net/api/get"
    private static let searchEndpoint = "https://lrclib.net/api/search"

    private static let noiseRegex = try! NSRegularExpression(
        pattern: "\\s*(?:\\(|\\[)(?:Official\\s*(?:Music\\s*)?(?:Video|Audio|Lyric\\s*Video|Visualizer)?|Audio|Lyrics?\\s*(?:Video)?|Visualizer|MV|4K|HD|HQ|Explicit|Clean|prod\\..*?)(?:\\)|\\])",
        options: [.caseInsensitive]
    )
    private static let featRegex = try! NSRegularExpression(
        pattern: "\\s*(?:\\(|\\[)?(?:feat\\.|ft\\.|featuring)\\s+[^\\)\\]\\-]+(?:\\)|\\])?",
        options: [.caseInsensitive]
    )
    private static let editionRegex = try! NSRegularExpression(
        pattern: "\\s*(?:\\(|\\[)[^\\)\\]]*?(?:Remaster(?:ed)?|Remix|Edit|Version|Live|Acoustic|Sped\\s*Up|Slowed|Deluxe|Bonus|Mono|Stereo|Instrumental|From\\s+).*?(?:\\)|\\])|\\s+-\\s+[^-]*?(?:Remaster(?:ed)?|Version|Edit|Live|Acoustic|Mono|Stereo|Deluxe|From\\s+| Mix).*$",
        options: [.caseInsensitive]
    )
    private static let inlineWordTagRegex = try! NSRegularExpression(pattern: "<\\d{1,2}:\\d{2}(?:[.:]\\d{1,3})?>")
    private static let artistSplitRegex = try! NSRegularExpression(
        pattern: "\\s*(?:,|&|\\bx\\b|\\bwith\\b|\\bfeat\\.|\\bft\\.|\\bfeaturing\\b|/|;)\\s*",
        options: [.caseInsensitive]
    )

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String = "") -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func sanitize(title: String, artist: String) -> (title: String, artist: String) {
        var cleanTitle = replace(noiseRegex, in: title)
        var cleanArtist = artist
        for suffix in [" - Topic", "VEVO", " Official"] where cleanArtist.lowercased().hasSuffix(suffix.lowercased()) {
            cleanArtist = String(cleanArtist.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        cleanTitle = replace(featRegex, in: cleanTitle)
        let trimSet = CharacterSet(charactersIn: " \"'“”\t\n\r")
        cleanTitle = cleanTitle.trimmingCharacters(in: trimSet); cleanArtist = cleanArtist.trimmingCharacters(in: trimSet)
        if cleanTitle.contains(" - ") {
            let parts = cleanTitle.components(separatedBy: " - ")
            if parts.count >= 2 {
                let p0 = parts[0].trimmingCharacters(in: .whitespaces), p1 = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                let isEdition = editionRegex.firstMatch(in: " - " + p1, range: NSRange((" - " + p1).startIndex..., in: " - " + p1)) != nil
                if !isEdition && (cleanArtist.isEmpty || cleanArtist.caseInsensitiveCompare(p0) == .orderedSame) {
                    cleanArtist = p0; cleanTitle = p1
                }
            }
        }
        return (cleanTitle.isEmpty ? title : cleanTitle, cleanArtist.isEmpty ? artist : cleanArtist)
    }

    static func baseTitle(from title: String) -> String {
        let stripped = replace(editionRegex, in: replace(featRegex, in: title))
        return stripped.trimmingCharacters(in: CharacterSet(charactersIn: " -\"'“”\t\n\r"))
    }

    static func primaryArtist(from artist: String) -> String {
        let range = NSRange(artist.startIndex..., in: artist)
        if let match = artistSplitRegex.firstMatch(in: artist, range: range), let r = Range(match.range, in: artist) {
            let first = String(artist[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !first.isEmpty { return first }
        }
        return artist
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var entries: [(time: Double, text: String)] = []
        var offsetSeconds: Double = 0

        for rawLine in lrc.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.lowercased().hasPrefix("[offset:") && trimmed.hasSuffix("]") {
                let val = trimmed.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)
                if let ms = Double(val) { offsetSeconds = ms / 1000.0 }
                continue
            }
            var lineText = trimmed
            var timestamps: [Double] = []
            while lineText.hasPrefix("[") {
                guard let closeIdx = lineText.firstIndex(of: "]") else { break }
                let tag = String(lineText[lineText.index(after: lineText.startIndex)..<closeIdx])
                let parts = tag.split(separator: ":")
                if parts.count == 2, let min = Double(parts[0]), let sec = Double(parts[1]) {
                    timestamps.append(max(0, min * 60 + sec - offsetSeconds))
                } else if parts.count == 3, let min = Double(parts[0]), let sec = Double(parts[1]), let cs = Double(parts[2]) {
                    timestamps.append(max(0, min * 60 + sec + (cs / 100.0) - offsetSeconds))
                } else { break }
                lineText = String(lineText[lineText.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
            }
            guard !timestamps.isEmpty else { continue }
            let cleanText = replace(inlineWordTagRegex, in: lineText).trimmingCharacters(in: .whitespaces)
            for ts in timestamps { entries.append((time: ts, text: cleanText)) }
        }

        entries.sort { $0.time < $1.time }
        return entries.enumerated().map { idx, item in
            let nextTime = idx + 1 < entries.count ? entries[idx + 1].time : (item.time + 6.0)
            let gap = nextTime - item.time
            let words = max(1, item.text.split(separator: " ").count)
            let estDuration = max(2.2, Double(words) * 0.52 + 1.4)
            let end = gap > (estDuration + 3.5) ? (item.time + estDuration) : nextTime
            return LyricLine(id: idx, time: item.time, endTime: max(end, item.time + 1.0), text: item.text)
        }
    }

    static func fetch(title: String, artist: String, album: String = "", duration: Double) async -> LyricsState {
        let base = baseTitle(from: title)
        let lead = primaryArtist(from: artist)

        if let exact = await fetchExact(title: title, artist: artist, album: album, duration: duration),
           case .loaded(_, let synced) = exact, synced { return exact }
        if lead != artist, let exactLead = await fetchExact(title: base.isEmpty ? title : base, artist: lead, album: album, duration: duration),
           case .loaded(_, let synced) = exactLead, synced { return exactLead }
        var queries: [[URLQueryItem]] = [
            [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        ]
        if base != title && !base.isEmpty {
            queries.append([URLQueryItem(name: "track_name", value: base), URLQueryItem(name: "artist_name", value: lead)])
        } else if lead != artist && !lead.isEmpty {
            queries.append([URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: lead)])
        }
        queries.append([URLQueryItem(name: "q", value: "\(lead.isEmpty ? artist : lead) \(base.isEmpty ? title : base)")])

        var bestFallback: (state: LyricsState, score: Int)?
        for items in queries {
            if let match = await fetchSearch(queryItems: items, title: title, baseTitle: base, artist: artist, leadArtist: lead, album: album, duration: duration) {
                if case .loaded(_, let isSynced) = match.state, isSynced, match.score >= 2100 {
                    return match.state
                }
                if bestFallback == nil || match.score > bestFallback!.score {
                    bestFallback = match
                }
            }
        }
        return bestFallback?.state ?? .notFound
    }

    private static func request(url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func fetchExact(title: String, artist: String, album: String, duration: Double) async -> LyricsState? {
        var comps = URLComponents(string: exactEndpoint)
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 1 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        comps?.queryItems = items
        guard let url = comps?.url, let data = await request(url: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if duration > 15, let candDur = dict["duration"] as? Double, candDur > 15, abs(candDur - duration) > 6.0 {
            return nil
        }
        return parseDict(dict)
    }

    private static func fetchSearch(queryItems: [URLQueryItem], title: String, baseTitle: String, artist: String, leadArtist: String, album: String, duration: Double) async -> (state: LyricsState, score: Int)? {
        var comps = URLComponents(string: searchEndpoint)
        comps?.queryItems = queryItems
        guard let url = comps?.url, let data = await request(url: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        return arr.compactMap { dict -> (state: LyricsState, score: Int)? in
            guard let score = scoreCandidate(dict: dict, title: title, baseTitle: baseTitle, artist: artist, leadArtist: leadArtist, album: album, duration: duration),
                  let state = parseDict(dict) else { return nil }
            return (state, score)
        }.max { $0.score < $1.score }
    }

    private static func scoreCandidate(dict: [String: Any], title: String, baseTitle: String, artist: String, leadArtist: String, album: String, duration: Double) -> Int? {
        let candRawTitle = dict["trackName"] as? String ?? ""
        let candRawArtist = dict["artistName"] as? String ?? ""
        let cTitle = normalize(candRawTitle), cBase = normalize(self.baseTitle(from: candRawTitle))
        let tTitle = normalize(title), tBase = normalize(baseTitle.isEmpty ? title : baseTitle)
        guard !cTitle.isEmpty, !tTitle.isEmpty else { return nil }

        var titleScore = 0
        if cTitle == tTitle { titleScore = 700 }
        else if !cBase.isEmpty && cBase == tBase { titleScore = 580 }
        else if cTitle.contains(tBase) || tBase.contains(cBase) { titleScore = 320 }
        else { return nil }

        let cArtist = normalize(candRawArtist), cLead = normalize(primaryArtist(from: candRawArtist))
        let tArtist = normalize(artist), tLead = normalize(leadArtist.isEmpty ? artist : leadArtist)
        var artistScore = 0
        if !tArtist.isEmpty {
            if cArtist == tArtist { artistScore = 650 }
            else if !cLead.isEmpty && (cLead == tLead || cArtist.contains(tLead) || tArtist.contains(cLead)) { artistScore = 500 }
            else { return nil }
        }

        let synced = !(dict["syncedLyrics"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let candDur = dict["duration"] as? Double ?? 0
        var durScore = 0
        if duration > 15 && candDur > 15 {
            let diff = abs(candDur - duration)
            if diff > 12.0 { return nil }
            if diff <= 1.0 { durScore = 1400 }
            else if diff <= 2.2 { durScore = 1100 }
            else if diff <= 4.0 { durScore = 750 }
            else if diff <= 7.0 { durScore = 350 }
            else { durScore = -200 }
        }

        var albumScore = 0
        if !album.isEmpty, let candAlbum = dict["albumName"] as? String {
            let cAlb = normalize(candAlbum), tAlb = normalize(album)
            if !cAlb.isEmpty && (cAlb == tAlb || cAlb.contains(tAlb) || tAlb.contains(cAlb)) { albumScore = 200 }
        }
        return (synced ? 1000 : 100) + titleScore + artistScore + durScore + albumScore
    }

    private static func parseDict(_ dict: [String: Any]) -> LyricsState? {
        if let synced = dict["syncedLyrics"] as? String, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .loaded(lines: lines, isSynced: true) }
        }
        if let plain = dict["plainLyrics"] as? String, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = plain.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .enumerated()
                .map { idx, text in LyricLine(id: idx, time: Double(idx * 3), endTime: Double(idx * 3 + 3), text: text) }
            if !lines.isEmpty { return .loaded(lines: lines, isSynced: false) }
        }
        return nil
    }
}
