import SwiftUI

/// Tunables for wheel gesture recognition (not haptics; see HapticsEngine.swift for feel).
enum WheelConfig {
    /// Center button radius as a fraction of the outer radius.
    static let centerFraction: CGFloat = 0.38
    /// Max finger travel (points) that still counts as a tap.
    static let tapSlop: CGFloat = 10
    /// Rotation (radians) needed before a touch counts as a spin rather than a press.
    static let spinSlop: Double = 0.12
    /// How long previous/next must be held to start rewind / fast-forward.
    static let holdDelay: Duration = .milliseconds(450)
    /// Rotation is tracked while the finger stays within this band of the ring
    /// (fractions of the outer radius), so sloppy circles still count.
    static let ringBand: ClosedRange<CGFloat> = 0.30...1.25
}

/// The on-screen click wheel. Reports raw `WheelEvent`s; it has no knowledge of menus or playback.
struct ClickWheelView: View {
    var onEvent: (WheelEvent) -> Void

    @State private var active = false
    @State private var startZone: WheelZone = .outside
    @State private var startPoint: CGPoint = .zero
    @State private var lastAngle: Double = 0
    @State private var totalRotation: Double = 0
    @State private var spinning = false
    @State private var holding = false
    @State private var tracker = WheelTracker()
    @State private var rateMeter = TickRateMeter()
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let outer = size / 2
            let inner = outer * WheelConfig.centerFraction
            let labelRadius = (outer + inner) / 2

            ZStack {
                Circle()
                    .fill(Theme.wheel)
                Circle()
                    .fill(pressed(.center) ? Theme.wheelPressed : Theme.background)
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                    .frame(width: inner * 2, height: inner * 2)

                Text("MENU")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(labelColor(.menu))
                    .position(x: center.x, y: center.y - labelRadius)
                symbol("backward.end.fill", zone: .previous)
                    .position(x: center.x - labelRadius, y: center.y)
                symbol("forward.end.fill", zone: .next)
                    .position(x: center.x + labelRadius, y: center.y)
                symbol("playpause.fill", zone: .playPause)
                    .position(x: center.x, y: center.y + labelRadius)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Circle().size(width: size, height: size)
                .offset(x: (geo.size.width - size) / 2, y: (geo.size.height - size) / 2))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { changed($0.location, center: center, inner: inner, outer: outer) }
                    .onEnded { ended($0.location) }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Click wheel")
        .accessibilityAdjustableAction { direction in
            onEvent(.tick(direction == .increment ? .forward : .backward, rate: 0))
        }
        .accessibilityAction(named: "Select") { onEvent(.press(.center)) }
        .accessibilityAction(named: "Menu") { onEvent(.press(.menu)) }
        .accessibilityAction(named: "Play or pause") { onEvent(.press(.playPause)) }
        .accessibilityAction(named: "Next") { onEvent(.press(.next)) }
        .accessibilityAction(named: "Previous") { onEvent(.press(.previous)) }
    }

    // MARK: Drawing

    private func pressed(_ zone: WheelZone) -> Bool {
        active && !spinning && startZone == zone
    }

    private func labelColor(_ zone: WheelZone) -> Color {
        pressed(zone) ? Theme.primary : Theme.secondary
    }

    private func symbol(_ name: String, zone: WheelZone) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(labelColor(zone))
    }

    // MARK: Gesture handling

    private func button(for zone: WheelZone) -> WheelButton? {
        switch zone {
        case .center: .center
        case .menu: .menu
        case .next: .next
        case .previous: .previous
        case .playPause: .playPause
        case .outside: nil
        }
    }

    private func changed(_ p: CGPoint, center: CGPoint, inner: CGFloat, outer: CGFloat) {
        if !active {
            let zone = WheelGeometry.zone(of: p, center: center, outerRadius: outer, innerRadius: inner)
            guard let button = button(for: zone) else { return }
            active = true
            startZone = zone
            startPoint = p
            lastAngle = WheelGeometry.angle(of: p, around: center)
            totalRotation = 0
            spinning = false
            holding = false
            tracker.reset()
            rateMeter.reset()
            onEvent(.touchDown(button))
            if zone == .next || zone == .previous { scheduleHold(button) }
            return
        }
        // Rotation is ignored for touches that began on the center button, and during a hold.
        guard startZone != .center, !holding else { return }

        let a = WheelGeometry.angle(of: p, around: center)
        let d = WheelGeometry.distance(p, center) / outer
        guard WheelConfig.ringBand.contains(d) else {
            lastAngle = a          // re-anchor so re-entering the ring doesn't jump
            return
        }
        let delta = WheelGeometry.delta(from: lastAngle, to: a)
        lastAngle = a
        totalRotation += delta

        let ticks: [TickDirection]
        if spinning {
            ticks = tracker.add(delta)
        } else {
            let travel = WheelGeometry.distance(p, startPoint)
            guard abs(totalRotation) > WheelConfig.spinSlop, travel > WheelConfig.tapSlop else { return }
            spinning = true
            holdTask?.cancel()
            onEvent(.rotationBegan)
            ticks = tracker.add(totalRotation)    // the slop counts toward the first detent
        }

        let now = ProcessInfo.processInfo.systemUptime
        for tick in ticks {
            rateMeter.record(at: now)
            onEvent(.tick(tick, rate: rateMeter.ticksPerSecond))
        }
        onEvent(.rotation(progress: tracker.progress))
    }

    private func ended(_ p: CGPoint) {
        defer {
            active = false
            spinning = false
            holding = false
            holdTask?.cancel()
            holdTask = nil
        }
        guard active, let button = button(for: startZone) else { return }
        if holding {
            onEvent(.holdEnded(button))
        } else if spinning {
            onEvent(.rotationEnded)
        } else if WheelGeometry.distance(p, startPoint) <= WheelConfig.tapSlop * 2 {
            onEvent(.press(button))
        }
    }

    private func scheduleHold(_ button: WheelButton) {
        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(for: WheelConfig.holdDelay)
            guard !Task.isCancelled, active, !spinning, !holding else { return }
            holding = true
            onEvent(.holdBegan(button))
        }
    }
}
