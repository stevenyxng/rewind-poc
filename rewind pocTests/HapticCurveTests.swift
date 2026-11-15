import Foundation
import Testing
@testable import rewind_poc

struct HapticCurveTests {
    var tuning = HapticsTuning()

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
        t[.detentIntensity] = 7   // out of range -> clamped to 1
        #expect(t[.detentIntensity] == 1)
        t[.detentSharpness] = 0.42
        t.save(to: defaults)
        let loaded = HapticsTuning.load(from: defaults)
        #expect(loaded == t)
        #expect(loaded[.detentSharpness] == 0.42)
        var reset = loaded
        reset.reset()
        #expect(reset.isDefault)
    }

    @Test func remoteTuningSitsBetweenDefaultsAndOverrides() throws {
        let defaults = try #require(UserDefaults(suiteName: "HapticCurveTests-\(UUID())"))
        var t = HapticsTuning()
        t.remote = HapticsTuning.remoteValues(json: #"{"detentSharpness": 0.4, "bumpIntensity": 0.5}"#)
        #expect(t[.detentSharpness] == 0.4)
        #expect(!t.isCustomized)
        t[.detentSharpness] = 0.7
        #expect(t[.detentSharpness] == 0.7)
        #expect(t.isCustomized)
        t.save(to: defaults)
        #expect(HapticsTuning.load(from: defaults)[.bumpIntensity] == HapticParameter.bumpIntensity.spec.defaultValue)
        t.reset()
        #expect(t[.detentSharpness] == 0.4)
    }

    @Test func remoteValuesParsing() {
        let v = HapticsTuning.remoteValues(json: #"{"detentIntensity": 3, "nope": 0.5, "bumpSharpness": "x"}"#)
        #expect(v == [.detentIntensity: 1])
        #expect(HapticsTuning.remoteValues(json: "not json").isEmpty)
        #expect(HapticsTuning.remoteValues(json: "{}").isEmpty)
    }

    @Test func everyParameterDefaultIsInRange() {
        for p in HapticParameter.allCases {
            #expect(p.spec.range.contains(p.spec.defaultValue), "\(p)")
        }
    }
}
