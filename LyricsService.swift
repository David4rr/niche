import Foundation
import AppKit

@MainActor
@Observable
final class LyricsService {
    private(set) var state: LyricsState = .idle
    private(set) var activeIndex: Int? = nil
    private(set) var isLineSinging: Bool = true

    var activeLineText: String {
        if case .loaded(let lines, let isSynced) = state {
            if let active = activeIndex, lines.indices.contains(active) {
                let t = lines[active].text.trimmingCharacters(in: .whitespaces)
                return (!isLineSinging && isSynced) ? "♪" : (t.isEmpty ? "♪" : t)
            }
            return isSynced ? "♪" : (lines.first?.text ?? "")
        }
        return ""
    }

    var activeLineWidth: CGFloat {
        let text = activeLineText
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return min(max(w, 20), 280)
    }

    @ObservationIgnored private var cache: [String: LyricsState] = [:]
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var currentKey: String = ""

    func update(track: Track?, position: Double, isEnabled: Bool) {
        guard isEnabled, let track else {
            if state != .idle {
                state = .idle
                activeIndex = nil
                currentKey = ""
                fetchTask?.cancel()
                fetchTask = nil
            }
            return
        }

        let key = cacheKey(for: track)
        if key != currentKey {
            currentKey = key
            activeIndex = nil
            loadLyrics(for: track, key: key)
        }

        if case .loaded(let lines, let isSynced) = state, isSynced {
            activeIndex = Self.binarySearchActiveIndex(for: position, in: lines)
            if let active = activeIndex, lines.indices.contains(active) {
                let effPos = position + Self.vocalLeadOffset
                isLineSinging = effPos <= lines[active].endTime
            } else {
                isLineSinging = true
            }
        } else {
            activeIndex = nil
            isLineSinging = true
        }
    }

    private func cacheKey(for track: Track) -> String {
        "\(track.artist.trimmingCharacters(in: .whitespaces).lowercased())|\(track.title.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    private func loadLyrics(for track: Track, key: String) {
        fetchTask?.cancel()
        fetchTask = nil

        if let cached = cache[key] {
            state = cached
            return
        }

        state = .loading
        let (cleanTitle, cleanArtist) = LRCLIBClient.sanitize(title: track.title, artist: track.artist)
        let duration = track.duration

        fetchTask = Task { [weak self] in
            let result = await LRCLIBClient.fetch(title: cleanTitle, artist: cleanArtist, duration: duration)
            guard !Task.isCancelled, let self, self.currentKey == key else { return }
            if self.cache.count > 50 {
                self.cache.removeAll(keepingCapacity: true)
            }
            self.cache[key] = result
            self.state = result
        }
    }

    nonisolated static let vocalLeadOffset: Double = 0.28

    nonisolated static func binarySearchActiveIndex(for position: Double, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        let effectivePos = position + vocalLeadOffset
        var low = 0
        var high = lines.count - 1
        var best: Int? = nil

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= effectivePos {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}
