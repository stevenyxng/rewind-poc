import Foundation
import Testing
@testable import rewind_poc

struct UsageSessionTests {
    @Test func countsAndRates() {
        var s = UsageSession(startedAt: 100)
        #expect(s.isEmpty)
        s.record(.detentTick, rate: 4)
        s.record(.detentTick, rate: 8)
        s.record(.scrubTick, rate: 12)
        s.record(.scrubMark, rate: 12)
        s.record(.buttonPress)
        s.record(.spin)
        s.record(.bump)
        #expect(!s.isEmpty)
        #expect(s.detentTicks == 2 && s.scrubTicks == 1 && s.scrubMarks == 1)
        #expect(s.peakTickRate == 12)
        #expect(s.meanTickRate == 9)

        let summary = s.summary(now: 130.4)
        #expect(summary["duration_s"] as? Int == 30)
        #expect(summary["detent_ticks"] as? Int == 2)
        #expect(summary["button_presses"] as? Int == 1)
        #expect(summary["spins"] as? Int == 1)
        #expect(summary["bumps"] as? Int == 1)
        #expect(summary["mean_tick_rate"] as? Double == 9)
        #expect(summary["peak_tick_rate"] as? Double == 12)
    }
}

@MainActor
struct AppModelUsageTests {
    func makeModel() throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: "AppModelUsageTests-\(UUID())"))
        let root = FileManager.default.temporaryDirectory.appending(path: "AppModelUsageTests-\(UUID())")
        return AppModel(settings: AppSettings(defaults: defaults), haptics: HapticsEngine(defaults: defaults),
                        player: PlaybackEngine(), library: LocalLibrary(root: root), cloud: UnconfiguredCloudSource())
    }

    @Test func backgroundLogsOneWheelSession() throws {
        let model = try makeModel()
        var now = 10.0
        model.clock = { now }
        var logged: [(String, [String: Any])] = []
        model.logEvent = { logged.append(($0, $1)) }

        model.sceneBecameActive()
        model.handle(.rotationBegan)
        model.handle(.tick(.forward, rate: 5))
        #expect(model.usage.detentTicks == 1)
        #expect(model.usage.spins == 1)

        now = 25
        model.sceneEnteredBackground()
        #expect(logged.count == 1)
        #expect(logged.first?.0 == "wheel_session")
        #expect(logged.first?.1["duration_s"] as? Int == 15)
        #expect(model.usage.isEmpty)

        model.sceneEnteredBackground()     // nothing happened since: no event
        #expect(logged.count == 1)
    }

    @Test func startAppliesVariantBeforeShowingUI() async throws {
        let model = try makeModel()
        model.fetchVariant = { "B" }
        #expect(!model.variantReady)
        await model.start()
        #expect(model.variant == "B")
        #expect(model.variantReady)
    }
}
