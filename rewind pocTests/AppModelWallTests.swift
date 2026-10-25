import Foundation
import Testing
@testable import rewind_poc

/// Drives a real AppModel with wheel events to check the wall end to end
/// (the haptic itself can't be felt in tests, but the overshoot it's driven by can be read).
@MainActor
struct AppModelWallTests {
    func makeModel(wall: Bool = true) throws -> AppModel {
        let defaults = try #require(UserDefaults(suiteName: "AppModelWallTests-\(UUID())"))
        defaults.set(false, forKey: "clickSound")
        defaults.set(wall, forKey: "wallHaptic")
        let root = FileManager.default.temporaryDirectory.appending(path: "AppModelWallTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppModel(settings: AppSettings(defaults: defaults), haptics: HapticsEngine(defaults: defaults),
                        player: PlaybackEngine(), library: LocalLibrary(root: root), cloud: UnconfiguredCloudSource())
    }

    @Test func pushingPastTheLastRowDrivesTheWall() throws {
        let model = try makeModel()
        let rows = model.navigator.items.count            // main menu: Music, Shuffle Songs, Settings
        model.handle(.touchDown(.next))
        model.handle(.rotationBegan)
        for _ in 1..<rows { model.handle(.tick(.forward, rate: 2)) }
        model.handle(.rotation(progress: 0.5))           // on the last row, leaning toward the end
        #expect(model.navigator.current.selected == rows - 1)
        #expect(model.haptics.wallOvershoot == 0.5)

        model.handle(.tick(.forward, rate: 2))           // one detent past the end
        model.handle(.rotation(progress: 0.25))
        #expect(model.haptics.wallOvershoot == 1.25)
        #expect(model.navigator.current.selected == rows - 1)

        model.handle(.tick(.backward, rate: 2))          // backing off unwinds the push...
        model.handle(.rotation(progress: 0))
        #expect(model.haptics.wallOvershoot == 0)
        #expect(model.navigator.current.selected == rows - 1)
        model.handle(.tick(.backward, rate: 2))          // ...then the selection moves
        #expect(model.navigator.current.selected == rows - 2)

        model.handle(.tick(.forward, rate: 2))
        model.handle(.tick(.forward, rate: 2))
        model.handle(.rotation(progress: 0.1))
        #expect(model.haptics.wallOvershoot > 1)
        model.handle(.rotationEnded)                     // lifting the finger stops it
        #expect(model.haptics.wallOvershoot == 0)
    }

    @Test func wallIsOffByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "AppModelWallTests-\(UUID())"))
        #expect(AppSettings(defaults: defaults).wall == false)
    }

    @Test func withTheWallOffTheEndIsAPlainStop() throws {
        let model = try makeModel(wall: false)
        let rows = model.navigator.items.count
        model.handle(.touchDown(.next))
        model.handle(.rotationBegan)
        for _ in 1..<rows { model.handle(.tick(.forward, rate: 2)) }
        model.handle(.tick(.forward, rate: 2))           // past the end
        model.handle(.tick(.forward, rate: 2))
        model.handle(.rotation(progress: 0.5))
        #expect(model.haptics.wallOvershoot == 0)        // no wall
        model.handle(.tick(.backward, rate: 2))          // nothing to unwind: moves right away
        #expect(model.navigator.current.selected == rows - 2)
    }

    @Test func topOfTheListIsAWallToo() throws {
        let model = try makeModel()
        model.handle(.touchDown(.next))
        model.handle(.rotationBegan)
        model.handle(.rotation(progress: -0.6))
        #expect(model.haptics.wallOvershoot == 0.6)
        model.handle(.rotation(progress: 0.3))           // heading back down: no wall
        #expect(model.haptics.wallOvershoot == 0)
    }
}
