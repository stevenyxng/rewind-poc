import SwiftUI

/// Tunables for the wheel feel.
enum WheelConfig {
    /// Angle between detents (radians). Smaller = more sensitive.
    static let detentAngle: Double = 2 * .pi / 20
    /// Black wheel variant instead of white.
    static let blackWheel = false
    /// Center button radius as a fraction of the outer radius.
    static let centerFraction: CGFloat = 0.36
    /// Max finger travel (points) that still counts as a tap.
    static let tapSlop: CGFloat = 10
    /// Max accumulated rotation (radians) that still counts as a tap.
    static let tapAngleSlop: Double = 0.12
}

struct ClickWheelView: View {
    /// Receives events; returns true if the event had an effect.
    var onEvent: (WheelEvent) -> Bool

    // Gesture state
    @State private var active = false
    @State private var startedInCenter = false
    @State private var startPoint: CGPoint = .zero
    @State private var lastAngle: Double = 0
    @State private var accumulated: Double = 0     // toward next detent
    @State private var totalRotation: Double = 0
    @State private var scrolled = false
    @State private var centerPressed = false

    private var wheelColor: Color { WheelConfig.blackWheel ? Color(white: 0.12) : Color(white: 0.93) }
    private var labelColor: Color { WheelConfig.blackWheel ? .white.opacity(0.85) : Color(white: 0.45) }
    private var buttonColor: Color { WheelConfig.blackWheel ? Color(white: 0.22) : Color(white: 0.97) }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outer = size / 2
            let inner = outer * WheelConfig.centerFraction

            ZStack {
                Circle()
                    .fill(wheelColor)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                Circle()
                    .fill(buttonColor)
                    .frame(width: inner * 2, height: inner * 2)
                    .scaleEffect(centerPressed ? 0.96 : 1)
                    .overlay(Circle().stroke(.black.opacity(0.1), lineWidth: 1).frame(width: inner * 2))

                label("MENU").position(x: center.x, y: center.y - outer * 0.68)
                Image(systemName: "forward.end.fill").font(.system(size: 17))
                    .foregroundStyle(labelColor).position(x: center.x + outer * 0.68, y: center.y)
                Image(systemName: "backward.end.fill").font(.system(size: 17))
                    .foregroundStyle(labelColor).position(x: center.x - outer * 0.68, y: center.y)
                HStack(spacing: 1) {
                    Image(systemName: "playpause.fill")
                }
                .font(.system(size: 17)).foregroundStyle(labelColor)
                .position(x: center.x, y: center.y + outer * 0.68)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleChanged(value.location, center: center, inner: inner, outer: outer)
                    }
                    .onEnded { value in
                        handleEnded(value.location, center: center, inner: inner, outer: outer)
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold).smallCaps())
            .foregroundStyle(labelColor)
    }

    // MARK: Geometry

    private func angle(of p: CGPoint, around c: CGPoint) -> Double {
        atan2(Double(p.y - c.y), Double(p.x - c.x))
    }

    private func distance(_ p: CGPoint, _ c: CGPoint) -> CGFloat {
        hypot(p.x - c.x, p.y - c.y)
    }

    // MARK: Gesture handling

    private func handleChanged(_ p: CGPoint, center: CGPoint, inner: CGFloat, outer: CGFloat) {
        if !active {
            let d = distance(p, center)
            guard d <= outer else { return }          // outside wheel: ignore
            active = true
            startPoint = p
            startedInCenter = d < inner
            lastAngle = angle(of: p, around: center)
            accumulated = 0
            totalRotation = 0
            scrolled = false
            centerPressed = startedInCenter
            HapticsManager.shared.touchDown()
            return
        }
        guard !startedInCenter else { return }

        // Ignore motion that dips into the center button or out of the wheel.
        let d = distance(p, center)
        guard d >= inner * 0.8, d <= outer * 1.15 else { return }

        let a = angle(of: p, around: center)
        var delta = a - lastAngle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        lastAngle = a

        totalRotation += delta
        if !scrolled {
            let travel = hypot(p.x - startPoint.x, p.y - startPoint.y)
            if abs(totalRotation) > WheelConfig.tapAngleSlop && travel > WheelConfig.tapSlop {
                scrolled = true
            } else {
                return                                 // still potentially a tap
            }
            // Begin counting from the moment scrolling is recognised.
            accumulated = totalRotation
        } else {
            accumulated += delta
        }

        while abs(accumulated) >= WheelConfig.detentAngle {
            let step: Double = accumulated > 0 ? 1 : -1
            accumulated -= step * WheelConfig.detentAngle
            // clockwise (positive in screen coords) = down
            if onEvent(step > 0 ? .scrollDown : .scrollUp) {
                HapticsManager.shared.tick()
            }
        }
    }

    private func handleEnded(_ p: CGPoint, center: CGPoint, inner: CGFloat, outer: CGFloat) {
        defer {
            active = false
            centerPressed = false
            scrolled = false
        }
        guard active, !scrolled else { return }
        let travel = hypot(p.x - startPoint.x, p.y - startPoint.y)
        guard travel <= WheelConfig.tapSlop * 2 else { return }

        let event: WheelEvent
        if startedInCenter {
            event = .select
        } else {
            // Quadrant of the start point: right / bottom / left / top.
            let a = angle(of: startPoint, around: center)      // 0 = right, +π/2 = down
            switch a {
            case -.pi / 4 ..< .pi / 4: event = .next
            case .pi / 4 ..< 3 * .pi / 4: event = .playPause
            case -3 * .pi / 4 ..< -.pi / 4: event = .menu
            default: event = .previous
            }
        }
        _ = onEvent(event)
        HapticsManager.shared.buttonPress()
    }
}
