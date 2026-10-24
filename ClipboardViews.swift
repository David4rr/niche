import AppKit
import SwiftUI

struct ClipboardDropZone: View {
    static let height: CGFloat = 52
    let preview: ClipboardHistory.DragPreview?
    @State private var isArmed = false

    var body: some View {
        let count = preview?.count ?? 1
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.1)).frame(width: 30, height: 30)
                    .overlay {
                        if let icon = preview?.icon {
                            Image(nsImage: icon).resizable().scaledToFit().padding(4)
                        } else {
                            Image(systemName: preview?.symbol ?? "tray.and.arrow.down.fill")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                if count > 1 {
                    Text("\(count)").font(.system(size: 8.5, weight: .bold).monospacedDigit()).foregroundStyle(.black)
                        .frame(minWidth: 14, minHeight: 14).background(Circle().fill(.white)).offset(x: 4, y: -4)
                }
            }
            .scaleEffect(isArmed ? 1 : 0.84)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(preview?.title ?? "Drop to copy").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92)).lineLimit(1).truncationMode(.middle)
                Text(preview?.subtitle ?? "Add to Clipboard").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "plus.circle.fill").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(isArmed ? 0.85 : 0.4)).scaleEffect(isArmed ? 1.05 : 0.88)
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(isArmed ? 0.08 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(isArmed ? 0.3 : 0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        )
        .padding(.horizontal, 12)
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { isArmed = true } }
    }
}

struct ClipboardView: View {
    let history: ClipboardHistory
    let onPick: (ClipboardHistory.Item) -> Void
    let onPickSelected: () -> Void
    @State private var hovered: UUID?
    private let columns = 5, spacing: CGFloat = 6

    var body: some View {
        let items = history.items
        let focus = items.first { $0.id == hovered }
            ?? (history.isKeyboard && items.indices.contains(history.selection) ? items[history.selection] : items.first)
        let side = (LabState.openSize.width - 36 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns), spacing: spacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let selOrder = history.selectedIDs.firstIndex(of: item.id).map { $0 + 1 }
                    ClipTile(item: item, number: history.isKeyboard && index < 9 ? index + 1 : nil, selectedOrder: selOrder,
                             isFocused: history.isKeyboard && index == history.selection, isHovered: hovered == item.id,
                             onToggleSelect: { history.toggleSelect(item) }, onDelete: { history.remove(item) })
                        .frame(width: side, height: 48)
                        .onHover { if $0 { hovered = item.id } else if hovered == item.id { hovered = nil } }
                        .onTapGesture {
                            let flags = NSEvent.modifierFlags
                            if flags.contains(.command) || flags.contains(.shift) || !history.selectedIDs.isEmpty {
                                history.toggleSelect(item)
                            } else { onPick(item) }
                        }
                        .onDrag { history.itemProvider(for: item) }
                }
            }
            .frame(height: 48 * 2 + spacing)
            if let focus {
                ClipCaption(item: focus, isKeyboard: history.isKeyboard, selectedCount: history.selectedIDs.count,
                            pastesOnPick: history.pastesOnPick, onCopySelected: onPickSelected,
                            onClearSelection: { history.clearSelection() }, onClear: { history.clear() })
                    .id(focus.id)
            }
        }
        .animation(.easeOut(duration: 0.15), value: focus?.id)
    }
}

private struct ClipTile: View {
    let item: ClipboardHistory.Item, number: Int?, selectedOrder: Int?
    let isFocused: Bool, isHovered: Bool
    let onToggleSelect: () -> Void, onDelete: () -> Void

    var body: some View {
        let active = selectedOrder != nil || isFocused
        Color.clear
            .overlay { content }
            .clipped()
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(selectedOrder != nil ? 0.14 : 0.07)))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(active ? 0.88 : isHovered ? 0.32 : 0), lineWidth: active ? 1.5 : 1))
            .overlay(alignment: .topLeading) {
                if let selectedOrder {
                    Button(action: onToggleSelect) {
                        Text("\(selectedOrder)").font(.system(size: 8.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(.black).frame(width: 14, height: 14).background(Circle().fill(.white))
                    }.buttonStyle(.plain).padding(3)
                } else if isHovered {
                    Button(action: onToggleSelect) {
                        Image(systemName: "checkmark").font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85)).frame(width: 14, height: 14).background(Circle().fill(Color(white: 0.25)))
                    }.buttonStyle(.plain).padding(3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let number, selectedOrder == nil {
                    Text("\(number)").font(.system(size: 8.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.black).frame(width: 13, height: 13).background(Circle().fill(.white.opacity(0.9))).padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white).frame(width: 14, height: 14).background(Circle().fill(Color(white: 0.25)))
                    }.buttonStyle(.plain).padding(3)
                }
            }
            .scaleEffect(isHovered || active ? 1.04 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovered)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: active)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image: if let image = item.image { Image(nsImage: image).resizable().scaledToFill() }
        case .color: (ClipboardHistory.color(from: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .clear)
        case .files: if let icon = item.image { Image(nsImage: icon).resizable().scaledToFit().padding(7) }
        case .link:
            VStack(spacing: 4) {
                Image(systemName: "link").font(.system(size: 11, weight: .semibold))
                Text(ClipboardHistory.domain(item.text)).font(.system(size: 9, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 6).padding(.bottom, number == nil ? 0 : 8)
        case .text:
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(number == nil ? 3 : 2).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 7).padding(.vertical, 6)
        }
    }
}

private struct ClipCaption: View {
    let item: ClipboardHistory.Item, isKeyboard: Bool, selectedCount: Int, pastesOnPick: Bool
    let onCopySelected: () -> Void, onClearSelection: () -> Void, onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if selectedCount > 0 {
                Text("\(selectedCount) selected").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 4)
                Button(action: onCopySelected) {
                    Text(pastesOnPick ? "Paste \(selectedCount) ⏎" : "Copy \(selectedCount)")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(.white.opacity(0.92)))
                }.buttonStyle(.plain)
                Button("Reset", action: onClearSelection).buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            } else {
                if let app = item.app { Image(nsImage: app).resizable().frame(width: 13, height: 13) }
                Text(item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.text)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Self.age(of: item.date, now: Date()))
                    .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                if isKeyboard {
                    Text("␣ multi · ⏎ paste").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                } else {
                    Button("Clear", action: onClear).buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(height: 16)
    }

    static func age(of date: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(date))
        return s < 60 ? "now" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
    }
}
