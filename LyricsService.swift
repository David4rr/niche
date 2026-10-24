import Foundation
import AppKit
import SwiftUI
@MainActor
@Observable
final class LyricsService {
    private(set) var state: LyricsState = .idle
    private(set) var activeIndex: Int? = nil
    private(set) var isLineSinging: Bool = true
    private(set) var activeLineText: String = ""
    private(set) var activeLineWidth: CGFloat = 0
    private(set) var rowHeights: [CGFloat] = []

    private static let closedFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded)!, size: 11.5)!
    }()

    private static let expandedAttributes: [NSAttributedString.Key: Any] = {
        let base = NSFont.systemFont(ofSize: 13.5, weight: .bold)
        let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded)!, size: 13.5)!
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1.5
        return [.font: font, .paragraphStyle: style]
    }()
    @ObservationIgnored private var cache: [String: LyricsState] = [:]
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var currentKey: String = ""

    func update(track: Track?, position: Double, isEnabled: Bool) {
        guard isEnabled, let track else {
            if state != .idle {
                state = .idle
                activeIndex = nil
                isLineSinging = true
                activeLineText = ""
                activeLineWidth = 0
                rowHeights = []
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

        let newIndex: Int?
        let newSinging: Bool
        if case .loaded(let lines, let isSynced) = state, isSynced {
            newIndex = Self.binarySearchActiveIndex(for: position, in: lines)
            if let active = newIndex, lines.indices.contains(active) {
                newSinging = (position + Self.vocalLeadOffset) <= lines[active].endTime
            } else {
                newSinging = true
            }
        } else {
            newIndex = nil
            newSinging = true
        }
        if activeIndex != newIndex || isLineSinging != newSinging {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82, blendDuration: 0)) {
                if activeIndex != newIndex { activeIndex = newIndex }
                if isLineSinging != newSinging { isLineSinging = newSinging }
                refreshActiveLine()
            }
        }
    }

    private func cacheKey(for track: Track) -> String {
        "\(track.artist.trimmingCharacters(in: .whitespaces).lowercased())|\(track.title.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    private func loadLyrics(for track: Track, key: String) {
        fetchTask?.cancel()
        fetchTask = nil

        if let cached = cache[key] {
            applyState(cached)
            return
        }

        applyState(.loading)
        let (cleanTitle, cleanArtist) = LRCLIBClient.sanitize(title: track.title, artist: track.artist)
        let album = track.album
        let duration = track.duration

        fetchTask = Task { [weak self] in
            let result = await LRCLIBClient.fetch(title: cleanTitle, artist: cleanArtist, album: album, duration: duration)
            guard !Task.isCancelled, let self, self.currentKey == key else { return }
            if self.cache.count > 50 {
                self.cache.removeAll(keepingCapacity: true)
            }
            self.cache[key] = result
            self.applyState(result)
        }
    }

    private func applyState(_ newState: LyricsState) {
        state = newState
        if case .loaded(let lines, _) = newState {
            let textWidth = LabState.lyricsWidth - 17 - 16 - 4
            rowHeights = lines.map { line in
                let raw = line.text.trimmingCharacters(in: .whitespaces)
                let str = (raw.isEmpty ? "♪" : raw) as NSString
                let bounds = str.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: Self.expandedAttributes)
                return max(30, ceil(bounds.height) + 10)
            }
        } else {
            rowHeights = []
        }
        refreshActiveLine()
    }

    private func refreshActiveLine() {
        let nextText: String
        if case .loaded(let lines, let isSynced) = state {
            if let active = activeIndex, lines.indices.contains(active) {
                let t = lines[active].text.trimmingCharacters(in: .whitespaces)
                nextText = (!isLineSinging && isSynced) ? "♪" : (t.isEmpty ? "♪" : t)
            } else {
                nextText = isSynced ? "♪" : (lines.first?.text ?? "")
            }
        } else {
            nextText = ""
        }
        if activeLineText != nextText { activeLineText = nextText }
        let nextWidth: CGFloat
        if nextText.isEmpty {
            nextWidth = 0
        } else {
            let w = ceil((nextText as NSString).size(withAttributes: [.font: Self.closedFont]).width) + 10
            nextWidth = min(max(w, 24), LabState.maxClosedLyricsWidth)
        }
        if activeLineWidth != nextWidth { activeLineWidth = nextWidth }
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
