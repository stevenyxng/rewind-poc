import Foundation

/// Classic iPod Now Playing: the wheel adjusts volume; center switches to scrubbing;
/// center again, or a few seconds without wheel input, switches back.
nonisolated struct NowPlayingWheelState: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case volume, scrub }

    static let scrubTimeout: TimeInterval = 3

    private(set) var mode = Mode.volume
    private(set) var lastInput: TimeInterval = 0

    mutating func pressCenter(at now: TimeInterval) {
        mode = mode == .volume ? .scrub : .volume
        lastInput = now
    }

    mutating func noteWheelInput(at now: TimeInterval) {
        lastInput = now
    }

    /// Drops back to volume mode after `scrubTimeout` without input. Returns true if it did.
    mutating func expireIfIdle(at now: TimeInterval) -> Bool {
        guard mode == .scrub, now - lastInput >= Self.scrubTimeout else { return false }
        mode = .volume
        return true
    }

    mutating func reset() {
        mode = .volume
    }
}

nonisolated enum VolumeStepper {
    /// 32 steps from silent to full (about 1⅓ turns of the wheel).
    static let step = 1.0 / 32

    enum Feedback: Equatable, Sendable {
        case step(level: Double)
        /// At 0% or 100%, whether just arrived or pushing past.
        case limit
    }

    static func apply(_ direction: TickDirection, to volume: Double) -> (volume: Double, feedback: Feedback) {
        let raw = min(max(volume + Double(direction.sign) * step, 0), 1)
        let snapped = (raw / step).rounded() * step
        if snapped <= 0 { return (0, .limit) }
        if snapped >= 1 { return (1, .limit) }
        return (snapped, .step(level: snapped))
    }
}

nonisolated enum Scrubber {
    /// Seconds moved per tick when spinning slowly...
    static let baseSecondsPerTick = 1.0
    /// ...multiplied by up to this much when spinning fast...
    static let maxAcceleration = 6.0
    /// ...reaching full acceleration at this spin speed (ticks/second).
    static let fullAccelerationRate = 20.0
    /// The stronger haptic marks every this many seconds.
    static let markInterval = 30.0

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
