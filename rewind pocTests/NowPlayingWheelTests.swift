import Foundation
import Testing
@testable import rewind_poc

struct NowPlayingWheelTests {
    @Test func scrubWallsAtStartAndEnd() {
        #expect(Scrubber.step(from: 0.5, .backward, rate: 0, duration: 200, spacing: 3) == (0, .wall))
        #expect(Scrubber.step(from: 199.5, .forward, rate: 0, duration: 200, spacing: 3) == (200, .wall))
        #expect(Scrubber.step(from: 10, .forward, rate: 0, duration: 0, spacing: 3).feedback == .wall)
    }

    @Test func scrubMarksEvery30Seconds() {
        #expect(Scrubber.step(from: 29.5, .forward, rate: 0, duration: 200, spacing: 3).feedback == .mark)
        #expect(Scrubber.step(from: 60.5, .backward, rate: 0, duration: 200, spacing: 3).feedback == .mark)
    }

    @Test func scrubTicksSpacedByTime() {
        // 1s per tick when slow, haptic every 3s: ticks at 3, 6, 9...
        var pos = 0.0
        var feedback: [Scrubber.Feedback] = []
        for _ in 0..<9 {
            let r = Scrubber.step(from: pos, .forward, rate: 0, duration: 200, spacing: 3)
            pos = r.position
            feedback.append(r.feedback)
        }
        #expect(feedback == [.none, .none, .tick, .none, .none, .tick, .none, .none, .tick])
    }

    @Test func fastSpinScrubsFurther() {
        #expect(Scrubber.secondsPerTick(rate: 100) == Scrubber.baseSecondsPerTick * Scrubber.maxAcceleration)
        #expect(Scrubber.secondsPerTick(rate: 0) == Scrubber.baseSecondsPerTick)
    }
}
