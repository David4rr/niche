import SwiftUI
import Observation

@MainActor
@Observable
final class NotchController {
    private(set) var isExpanded = false
    private(set) var isCollapsing = false
    private(set) var isRounded = false
    private(set) var isSharp = false
    var isLifted = false
    var isPressed = false
    var stretch: Double = 0

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var roundTask: Task<Void, Never>?

    func expand() {
        generation += 1
        let current = generation
        roundTask?.cancel()
        isCollapsing = false
        withAnimation(.spring(Spring(duration: 0.5, bounce: 0.32), blendDuration: 0)) {
            isPressed = false
            isExpanded = true
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { isSharp = true }
        roundTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.04))
            guard let self, !Task.isCancelled, self.generation == current else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { self.isRounded = true }
        }
    }

    func collapse() {
        generation += 1
        let current = generation
        roundTask?.cancel()
        isCollapsing = true
        withAnimation(.spring(response: 0.38, dampingFraction: 0.95), completionCriteria: .logicallyComplete) {
            isExpanded = false
            isRounded = false
            isSharp = false
        } completion: {
            if self.generation == current { self.isCollapsing = false }
        }
    }
}

struct NotchSquashModifier: ViewModifier {
    let controller: NotchController

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: controller.isLifted ? 1.06 : 1, y: controller.isLifted ? 1.12 : 1, anchor: .top)
            .scaleEffect(x: controller.isPressed ? 0.97 : 1, y: controller.isPressed ? 0.92 : 1, anchor: .top)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: controller.isPressed)
            .scaleEffect(x: 1, y: 1 - controller.stretch * 0.09, anchor: .top)
    }
}

struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var isIsland = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topCornerRadius, b = bottomCornerRadius
        if isIsland {
            return RoundedRectangle(cornerRadius: min(b, rect.height / 2), style: .continuous).path(in: rect.insetBy(dx: t, dy: 0))
        }
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
