import CoreGraphics
import Foundation

/// Direction of one wheel detent. Clockwise = forward = down / increase.
nonisolated enum TickDirection: Equatable, Sendable {
    case forward
    case backward

    var sign: Int { self == .forward ? 1 : -1 }
}

/// Where a touch landed on the wheel.
nonisolated enum WheelZone: Equatable, Sendable {
    case center, menu, next, playPause, previous, outside
}

/// Pure geometry for the click wheel. Screen coordinates (y grows downward),
/// so an increasing angle means clockwise motion on screen.
nonisolated enum WheelGeometry {
    /// Angle of `point` around `center` in radians: 0 = right, +π/2 = down, ±π = left.
    static func angle(of point: CGPoint, around center: CGPoint) -> Double {
        atan2(Double(point.y - center.y), Double(point.x - center.x))
    }

    /// Shortest signed rotation from `from` to `to`, in (-π, π]. Positive = clockwise.
    static func delta(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d <= -.pi { d += 2 * .pi }
        return d
    }

    static func distance(_ p: CGPoint, _ c: CGPoint) -> CGFloat {
        hypot(p.x - c.x, p.y - c.y)
    }

    /// Which button a touch belongs to. The ring is split into four 90° quadrants.
    static func zone(of point: CGPoint, center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat) -> WheelZone {
        let d = distance(point, center)
        if d > outerRadius { return .outside }
        if d < innerRadius { return .center }
        let a = angle(of: point, around: center)
        switch a {
        case -.pi / 4 ..< .pi / 4: return .next
        case .pi / 4 ..< 3 * .pi / 4: return .playPause
        case -3 * .pi / 4 ..< -.pi / 4: return .menu
        default: return .previous
        }
    }
}

/// Turns a stream of angle deltas into discrete detent ticks.
///
/// Detents sit on a fixed grid relative to where scrolling started: a tick fires
/// each time the accumulated rotation crosses ±`detentAngle`, and the remainder is
/// kept, so `progress` always describes where the finger sits between detents.
nonisolated struct WheelTracker: Equatable {
    /// 15° per tick, i.e. 24 ticks per full revolution.
    static let defaultDetentAngle: Double = .pi / 12

    let detentAngle: Double
    private(set) var accumulated: Double = 0

    init(detentAngle: Double = WheelTracker.defaultDetentAngle) {
        self.detentAngle = detentAngle
    }

    /// Signed fraction of the way to the next detent, in (-1, 1).
    /// Positive = heading clockwise. Drives the haptic tension ramp.
    var progress: Double { accumulated / detentAngle }

    mutating func reset() { accumulated = 0 }

    /// Adds a rotation delta (radians, clockwise positive) and returns the ticks it produced, in order.
    mutating func add(_ delta: Double) -> [TickDirection] {
        accumulated += delta
        var ticks: [TickDirection] = []
        while abs(accumulated) >= detentAngle {
            let dir: TickDirection = accumulated > 0 ? .forward : .backward
            accumulated -= Double(dir.sign) * detentAngle
            ticks.append(dir)
        }
        return ticks
    }
}

/// How far the finger has pushed past an end (of a list, the Lab strip, or a track), in detents.
///
/// Ticks into the wall are counted rather than dropped, and turning back unwinds them before
/// anything moves, so the wall behaves like a spring. `overshoot` is continuous: whole ticks
/// pushed plus the finger's progress toward the next one.
nonisolated struct WallPush: Equatable {
    private(set) var direction: TickDirection?
    private(set) var ticks = 0

    /// Call first for every tick. True means the tick only unwound the push and should do nothing else.
    mutating func absorbs(_ tick: TickDirection) -> Bool {
        guard ticks > 0, let direction, tick != direction else { return false }
        ticks -= 1
        if ticks == 0 { self.direction = nil }
        return true
    }

    /// The tick tried to go past the end.
    mutating func hitWall(_ tick: TickDirection) {
        if direction != tick { direction = tick; ticks = 0 }
        ticks += 1
    }

    /// The tick moved something, so we're not pushing a wall.
    mutating func moved() { reset() }

    mutating func reset() {
        direction = nil
        ticks = 0
    }

    /// Detents past the endpoint for finger `progress` (-1...1, as `WheelTracker.progress`).
    /// `blocked` says whether there's an end in a direction right now; it matters only before
    /// the first tick into the wall, while the finger is still between the last item and the wall.
    func overshoot(progress: Double, blocked: (TickDirection) -> Bool) -> Double {
        if let direction, ticks > 0 {
            return max(Double(ticks) + progress * Double(direction.sign), 0)
        }
        guard progress != 0 else { return 0 }
        return blocked(progress > 0 ? .forward : .backward) ? abs(progress) : 0
    }
}

/// Smoothed spin speed in ticks per second, used to accelerate scrubbing
/// and sharpen scrub haptics.
nonisolated struct TickRateMeter: Equatable {
    /// Gaps longer than this mean the user paused; speed restarts from slow.
    static let idleGap: TimeInterval = 0.4
    static let smoothing: Double = 0.35
    static let maxRate: Double = 60

    private(set) var ticksPerSecond: Double = 0
    private var lastTick: TimeInterval?

    mutating func reset() {
        ticksPerSecond = 0
        lastTick = nil
    }

    mutating func record(at time: TimeInterval) {
        defer { lastTick = time }
        guard let lastTick else { ticksPerSecond = 0; return }
        let gap = time - lastTick
        guard gap < Self.idleGap else { ticksPerSecond = 1 / gap; return }
        let instant = min(1 / max(gap, 0.001), Self.maxRate)
        ticksPerSecond += (instant - ticksPerSecond) * Self.smoothing
    }
}
