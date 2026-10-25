import Foundation
import Testing
@testable import rewind_poc

struct NowPlayingWheelTests {
    @Test func centerTogglesVolumeAndScrub() {
        var s = NowPlayingWheelState()
        #expect(s.mode == .volume)
        s.pressCenter(at: 0)
        #expect(s.mode == .scrub)
        s.pressCenter(at: 1)
        #expect(s.mode == .volume)
    }

    @Test func scrubTimesOutAfterThreeIdleSeconds() {
        var s = NowPlayingWheelState()
        s.pressCenter(at: 10)
        var expired = s.expireIfIdle(at: 12.9)
        #expect(!expired)
        s.noteWheelInput(at: 12.5)              // input pushes the timeout out
        expired = s.expireIfIdle(at: 15.4)
        #expect(!expired)
        #expect(s.mode == .scrub)
        expired = s.expireIfIdle(at: 15.5)
        #expect(expired)
        #expect(s.mode == .volume)
        expired = s.expireIfIdle(at: 100)       // nothing to expire in volume mode
        #expect(!expired)
    }

    @Test func volumeStepsAndLimits() {
        var v = 0.5
        let (up, fb) = VolumeStepper.apply(.forward, to: v)
        #expect(up == 0.5 + VolumeStepper.step)
        #expect(fb == .step(level: up))
        v = VolumeStepper.step
        #expect(VolumeStepper.apply(.backward, to: v) == (0, .limit))
        #expect(VolumeStepper.apply(.backward, to: 0) == (0, .limit))     // pushing past
        #expect(VolumeStepper.apply(.forward, to: 1 - VolumeStepper.step) == (1, .limit))
        #expect(VolumeStepper.apply(.forward, to: 1) == (1, .limit))
    }

    @Test func volumeSnapsToGrid() {
        let (v, _) = VolumeStepper.apply(.forward, to: 0.51)
        #expect(abs((v / VolumeStepper.step).rounded() - v / VolumeStepper.step) < 1e-9)
    }

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
