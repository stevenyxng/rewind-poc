import SwiftUI

/// Where the tutorial overlay finds the display and the wheel.
enum TutorialAnchor: Hashable { case display, wheel }

struct TutorialAnchorKey: PreferenceKey {
    static let defaultValue: [TutorialAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TutorialAnchor: Anchor<CGRect>],
                       nextValue: () -> [TutorialAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func tutorialAnchor(_ anchor: TutorialAnchor) -> some View {
        anchorPreference(key: TutorialAnchorKey.self, value: .bounds) { [anchor: $0] }
    }
}

/// Coach marks: a pulsing highlight on the wheel plus a tip card over the display.
/// Touches pass straight through (except the Skip button), so the real UI keeps working.
struct TutorialOverlay: View {
    let step: TutorialStep
    let displayRect: CGRect
    let wheelRect: CGRect
    let onSkip: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            WheelHighlight(target: step.target, wheelRect: wheelRect)
                .allowsHitTesting(false)
            // Card sits at the bottom of the display, leaving the top rows of the menu visible.
            VStack {
                Spacer(minLength: 0)
                card.padding(.bottom, 8)
            }
            .frame(width: displayRect.width, height: displayRect.height)
            .position(x: displayRect.midX, y: displayRect.midY)
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(step.rawValue + 1) of \(TutorialStep.allCases.count)")
                    .font(Theme.monoFont)
                    .opacity(0.7)
                Spacer()
                if step != .done {
                    Button("Skip", action: onSkip)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.selectionText)
                }
            }
            Text(step.title)
                .font(.system(size: 17, weight: .semibold))
            Text(step.message)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.selectionText)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.primary))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .id(step)
        .transition(.opacity)
    }
}

/// Pulsing ring around the part of the wheel the current step is about.
private struct WheelHighlight: View {
    let target: TutorialTarget
    let wheelRect: CGRect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var spin = false

    var body: some View {
        let outer = min(wheelRect.width, wheelRect.height) / 2
        let inner = outer * WheelConfig.centerFraction
        let labelRadius = (outer + inner) / 2
        let c = CGPoint(x: wheelRect.midX, y: wheelRect.midY)
        let buttonSize = (outer - inner) * 0.7

        ZStack {
            switch target {
            case .center:
                ring(diameter: inner * 2 + 10, at: c)
            case .ring:
                // A dashed circle that rotates around the ring, hinting "spin me".
                Circle()
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10, 12]))
                    .frame(width: labelRadius * 2, height: labelRadius * 2)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .position(c)
            case .menu:
                ring(diameter: buttonSize, at: CGPoint(x: c.x, y: c.y - labelRadius))
            case .playPause:
                ring(diameter: buttonSize, at: CGPoint(x: c.x, y: c.y + labelRadius))
            case .skip:
                ring(diameter: buttonSize, at: CGPoint(x: c.x - labelRadius, y: c.y))
                ring(diameter: buttonSize, at: CGPoint(x: c.x + labelRadius, y: c.y))
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = true }
        }
    }

    private func ring(diameter: CGFloat, at point: CGPoint) -> some View {
        Circle()
            .stroke(Theme.accent, lineWidth: 3)
            .frame(width: diameter, height: diameter)
            .scaleEffect(pulse ? 1.08 : 0.96)
            .opacity(pulse ? 0.55 : 1)
            .position(point)
    }
}
