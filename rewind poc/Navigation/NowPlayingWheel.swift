import Foundation

/// Now Playing: spinning the wheel scrubs through the track.
nonisolated enum Scrubber {
    /// Seconds moved per tick when spinning slowly...
    static let baseSecondsPerTick = 1.0
    /// ...multiplied by up to this much when spinning fast...
    static let maxAcceleration = 6.0
    /// ...reaching full acceleration at this spin speed (ticks/second).
    static let fullAccelerationRate = 20.0
    /// The stronger haptic marks every this many seconds.
    static let markInterval = 30.0
    /// The scrub playhead hands back to the player's own time this long after the wheel stops.
    static let settleDelay = 1.0

    enum Feedback: Equatable, Sendable {
        case none
        /// Crossed a haptic spacing boundary.
        case tick
        /// Crossed a 30-second mark.
        case mark
        /// Hit the start or end of the track.
        case wall
    }

    static func secondsPerTick(rate: Double) -> Double {
        let t = min(max(rate / fullAccelerationRate, 0), 1)
        return baseSecondsPerTick * (1 + (maxAcceleration - 1) * t)
    }

    /// Moves the playhead one tick. `spacing` is seconds between haptic ticks.
    static func step(from position: Double, _ direction: TickDirection, rate: Double,
                     duration: Double, spacing: Double) -> (position: Double, feedback: Feedback) {
        guard duration > 0 else { return (0, .wall) }
        let target = position + Double(direction.sign) * secondsPerTick(rate: rate)
        let clamped = min(max(target, 0), duration)
        if clamped != target { return (clamped, .wall) }
        if crossed(position, clamped, every: markInterval) { return (clamped, .mark) }
        if crossed(position, clamped, every: max(spacing, 0.1)) { return (clamped, .tick) }
        return (clamped, .none)
    }

    private static func crossed(_ a: Double, _ b: Double, every interval: Double) -> Bool {
        (a / interval).rounded(.down) != (b / interval).rounded(.down)
    }
}
