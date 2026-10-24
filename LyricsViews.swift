import SwiftUI

struct LyricsExpandedView: View {
    let player: MusicPlayer
    let track: Track
    var body: some View {
        Group {
            switch player.lyrics.state {
            case .idle, .loading:
                LyricsLoadingSkeletonView()
                    .transition(.opacity)
            case .notFound:
                notFoundView
                    .transition(.opacity)
            case .loaded(let lines, let isSynced):
                lyricsContent(lines: lines, isSynced: isSynced)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: player.lyrics.state)
        .frame(height: 140)
        .task(id: track) {
            if player.allowsLyrics {
                player.lyrics.update(track: track, position: player.position, isEnabled: true)
            }
        }
    }

    static let verticalMask = LinearGradient(
        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                .init(color: .black, location: 0.84), .init(color: .clear, location: 1.0)],
        startPoint: .top, endPoint: .bottom
    )

    private var notFoundView: some View {
        VStack(spacing: 7) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
            Text("Lyrics Unavailable")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.40))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricsContent(lines: [LyricLine], isSynced: Bool) -> some View {
        let active = player.lyrics.activeIndex ?? 0
        let containerHeight: CGFloat = 140
        let rowHeight: CGFloat = 36
        let rowSpacing: CGFloat = 6
        let step = rowHeight + rowSpacing
        let targetY = (containerHeight * 0.38) - (rowHeight / 2) - CGFloat(active) * step

        return GeometryReader { _ in
            VStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    LyricLineRow(
                        line: line,
                        isActive: isSynced && index == active,
                        isSinging: player.lyrics.isLineSinging,
                        distance: isSynced ? abs(index - active) : 0,
                        isSynced: isSynced,
                        rowHeight: rowHeight,
                        onSeek: {
                            guard isSynced, track.duration > 0 else { return }
                            withAnimation(.spring(response: 0.50, dampingFraction: 0.75)) { player.seek(to: line.time / track.duration) }
                        }
                    )
                }
            }
            .offset(y: targetY)
            .animation(.spring(response: 0.50, dampingFraction: 0.75, blendDuration: 0), value: player.lyrics.activeIndex)
        }
        .frame(height: containerHeight)
        .clipped()
        .mask(Self.verticalMask)
    }
}

private struct LyricsLoadingSkeletonView: View {
    @State private var isShimmering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            capsule(width: 135, height: 13, isActive: false)
            capsule(width: 185, height: 16, isActive: true)
            capsule(width: 115, height: 13, isActive: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .mask(LyricsExpandedView.verticalMask)
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { isShimmering = true } }
    }

    private func capsule(width: CGFloat, height: CGFloat, isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(.white)
            .opacity(isActive ? (isShimmering ? 0.32 : 0.14) : (isShimmering ? 0.14 : 0.05))
            .scaleEffect(x: isActive ? (isShimmering ? 1.02 : 0.98) : 1.0, anchor: .leading)
            .blur(radius: isActive ? 0 : 0.8).frame(width: width, height: height)
    }
}

private struct LyricLineRow: View {
    let line: LyricLine
    let isActive: Bool
    let isSinging: Bool
    let distance: Int
    let isSynced: Bool
    let rowHeight: CGFloat
    let onSeek: () -> Void

    @State private var isHovered = false

    var body: some View {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        let displayText = text.isEmpty ? "♪" : text

        Button(action: onSeek) {
            Text(displayText)
                .font(.system(size: (isActive && isSinging) ? 15 : 13.5, weight: (isActive && isSinging) ? .bold : (isHovered ? .semibold : .medium), design: .rounded))
                .foregroundStyle(.white.opacity(rowOpacity))
                .scaleEffect(rowScale, anchor: .leading)
                .blur(radius: rowBlur)
                .shadow(color: (isActive && isSinging) ? .white.opacity(0.35) : .clear, radius: 10, x: 0, y: 0)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(isHovered && !isActive ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.45, dampingFraction: 0.75, blendDuration: 0), value: isActive)
        .animation(.spring(response: 0.45, dampingFraction: 0.75, blendDuration: 0), value: distance)
        .onHover { inside in withAnimation(.easeOut(duration: 0.16)) { isHovered = inside } }
    }

    private var rowOpacity: Double {
        if isActive { return isSinging ? 1.0 : 0.55 }; if isHovered { return 0.85 }; if !isSynced { return 0.65 }
        return distance == 1 ? 0.42 : (distance == 2 ? 0.20 : 0.08)
    }
    private var rowScale: CGFloat {
        if isActive { return isSinging ? 1.04 : 1.0 }; if isHovered { return 0.98 }; if !isSynced { return 0.96 }
        return distance == 1 ? 0.94 : (distance == 2 ? 0.88 : 0.82)
    }
    private var rowBlur: CGFloat {
        if isActive || isHovered || !isSynced { return 0 }
        return distance == 1 ? 0.8 : (distance == 2 ? 1.8 : 3.0)
    }
}
