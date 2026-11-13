import SwiftUI

/// The automatic lookup order, played back top to bottom like Limusic's `lyrics_providers`
/// list. Swapping rows refetches the song already on screen.
struct LyricsProviderOrderView: View {
    @Binding var order: [LyricsSource]

    var body: some View {
        Section {
            ForEach(Array(order.enumerated()), id: \.element) { index, source in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .trailing)
                    Text(source.name)
                    Spacer(minLength: 0)
                    Button {
                        move(index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(source.name) up")
                    Button {
                        move(index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == order.count - 1)
                    .accessibilityLabel("Move \(source.name) down")
                }
            }
            Button("Reset order") {
                order = LyricsSource.defaultOrder
            }
            .disabled(order == LyricsSource.defaultOrder)
        } header: {
            Text("Automatic order")
        } footer: {
            Text("Automatic asks these from the top down and keeps the first timed result. Word-by-word sources sweep the closed notch; line-only ones show a still line, so karaoke follows the source instead of a separate switch.")
        }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard order.indices.contains(target) else { return }
        var moved = order
        moved.swapAt(index, target)
        order = moved
    }
}
