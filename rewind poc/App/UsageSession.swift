import Foundation

/// Wheel engagement for one foreground session, reported as the `wheel_session` analytics event.
nonisolated struct UsageSession: Equatable, Sendable {
    enum Kind: Sendable { case detentTick, scrubTick, scrubMark, buttonPress, spin, bump }

    let startedAt: TimeInterval
    private(set) var detentTicks = 0
    private(set) var scrubTicks = 0
    private(set) var scrubMarks = 0
    private(set) var buttonPresses = 0
    private(set) var spins = 0
    private(set) var bumps = 0
    private(set) var peakTickRate = 0.0
    private var tickRateSum = 0.0
    private var rateSamples = 0

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    var isEmpty: Bool { detentTicks + scrubTicks + scrubMarks + buttonPresses + spins + bumps == 0 }

    var meanTickRate: Double { rateSamples == 0 ? 0 : tickRateSum / Double(rateSamples) }

    /// `rate` is the wheel speed in ticks/second, for detent and scrub ticks.
    mutating func record(_ kind: Kind, rate: Double? = nil) {
        switch kind {
        case .detentTick: detentTicks += 1
        case .scrubTick: scrubTicks += 1
        case .scrubMark: scrubMarks += 1
        case .buttonPress: buttonPresses += 1
        case .spin: spins += 1
        case .bump: bumps += 1
        }
        if let rate {
            tickRateSum += rate
            rateSamples += 1
            peakTickRate = max(peakTickRate, rate)
        }
    }

    func summary(now: TimeInterval) -> [String: Any] {
        [
            "duration_s": Int((now - startedAt).rounded()),
            "detent_ticks": detentTicks,
            "scrub_ticks": scrubTicks,
            "scrub_marks": scrubMarks,
            "button_presses": buttonPresses,
            "spins": spins,
            "bumps": bumps,
            "mean_tick_rate": (meanTickRate * 10).rounded() / 10,
            "peak_tick_rate": (peakTickRate * 10).rounded() / 10,
        ]
    }
}
