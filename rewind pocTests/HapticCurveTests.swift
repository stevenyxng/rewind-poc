import Foundation
import Testing
@testable import rewind_poc

struct HapticCurveTests {
    var tuning = HapticsTuning()

    @Test func rampIsFloorNearLastTickAndPeakAtNext() {
        #expect(HapticCurves.rampIntensity(progress: 0, tuning: tuning) == tuning[.rampFloor])
        #expect(abs(HapticCurves.rampIntensity(progress: 1, tuning: tuning) - tuning[.rampPeak]) < 1e-9)
    }

    @Test func rampStaysAtFloorBelowOnset() {
        let onset = tuning[.rampOnset]
        #expect(HapticCurves.rampIntensity(progress: onset * 0.9, tuning: tuning) == tuning[.rampFloor])
    }

    @Test func rampRisesMonotonically() {
        var last = -1.0
        for i in 0...100 {
            let v = HapticCurves.rampIntensity(progress: Double(i) / 100, tuning: tuning)
            #expect(v >= last)
            last = v
        }
    }

    @Test func rampIsSymmetricSoReversalIsSmooth() {
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(HapticCurves.rampIntensity(progress: p, tuning: tuning)
                    == HapticCurves.rampIntensity(progress: -p, tuning: tuning))
        }
        // Continuous through zero: a tiny step either way stays near the floor.
        #expect(HapticCurves.rampIntensity(progress: 0.01, tuning: tuning) - tuning[.rampFloor] < 0.01)
    }

    @Test func rampCurveExponentShapesTension() {
        var linear = tuning
        linear[.rampCurve] = 1
        linear[.rampOnset] = 0
        linear[.rampFloor] = 0
        #expect(abs(HapticCurves.rampIntensity(progress: 0.5, tuning: linear) - linear[.rampPeak] / 2) < 1e-9)
        var late = linear
        late[.rampCurve] = 3
        #expect(HapticCurves.rampIntensity(progress: 0.5, tuning: late) < HapticCurves.rampIntensity(progress: 0.5, tuning: linear))
    }

    @Test func rampClampsOutOfRangeProgress() {
        #expect(HapticCurves.rampIntensity(progress: 5, tuning: tuning) == HapticCurves.rampIntensity(progress: 1, tuning: tuning))
    }

    @Test func wallRampsFromStartToMaxWithDistance() {
        #expect(HapticCurves.wallIntensity(overshoot: 0, tuning: tuning) == 0)     // silent at the endpoint
        let justPast = HapticCurves.wallIntensity(overshoot: 0.01, tuning: tuning)
        #expect(abs(justPast - tuning[.wallStartIntensity]) < 0.01)
        let full = tuning[.wallFullDistance]
        #expect(abs(HapticCurves.wallIntensity(overshoot: full, tuning: tuning) - tuning[.wallMaxIntensity]) < 1e-9)
        #expect(HapticCurves.wallIntensity(overshoot: full * 3, tuning: tuning) == HapticCurves.wallIntensity(overshoot: full, tuning: tuning))
        var last = 0.0
        for i in 1...30 {
            let v = HapticCurves.wallIntensity(overshoot: full * Double(i) / 30, tuning: tuning)
            #expect(v >= last)
            last = v
        }
    }

    @Test func fasterScrubIsSharper() {
        let slow = HapticCurves.scrubSharpness(rate: 1, tuning: tuning)
        let fast = HapticCurves.scrubSharpness(rate: 100, tuning: tuning)
        #expect(fast > slow)
        #expect(fast == tuning[.scrubSharpnessMax])
    }

    @Test func tuningClampsAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "HapticCurveTests-\(UUID())"))
        var t = HapticsTuning()
        #expect(t.isDefault)
        t[.rampPeak] = 7          // out of range -> clamped to 1
        #expect(t[.rampPeak] == 1)
        t[.detentSharpness] = 0.42
        t.save(to: defaults)
        let loaded = HapticsTuning.load(from: defaults)
        #expect(loaded == t)
        #expect(loaded[.detentSharpness] == 0.42)
        var reset = loaded
        reset.reset()
        #expect(reset.isDefault)
    }

    @Test func everyParameterDefaultIsInRange() {
        for p in HapticParameter.allCases {
            #expect(p.spec.range.contains(p.spec.defaultValue), "\(p)")
        }
    }
}
