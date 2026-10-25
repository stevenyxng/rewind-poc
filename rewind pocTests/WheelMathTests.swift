import CoreGraphics
import Foundation
import Testing
@testable import rewind_poc

struct WheelMathTests {
    let center = CGPoint(x: 100, y: 100)

    @Test func angleConventions() {
        #expect(abs(WheelGeometry.angle(of: CGPoint(x: 150, y: 100), around: center)) < 1e-9)          // right = 0
        #expect(abs(WheelGeometry.angle(of: CGPoint(x: 100, y: 150), around: center) - .pi / 2) < 1e-9) // down = +π/2
    }

    @Test func deltaTakesShortestPathAcrossSeam() {
        // From just above the left seam (+179°) to just below it (-179°) is +2°, not -358°.
        let from = 179.0 * .pi / 180, to = -179.0 * .pi / 180
        #expect(abs(WheelGeometry.delta(from: from, to: to) - 2 * .pi / 180) < 1e-9)
        #expect(abs(WheelGeometry.delta(from: to, to: from) + 2 * .pi / 180) < 1e-9)
        #expect(WheelGeometry.delta(from: 0.3, to: 0.3) == 0)
    }

    @Test func zones() {
        func zone(_ x: CGFloat, _ y: CGFloat) -> WheelZone {
            WheelGeometry.zone(of: CGPoint(x: x, y: y), center: center, outerRadius: 100, innerRadius: 38)
        }
        #expect(zone(100, 100) == .center)
        #expect(zone(100, 30) == .menu)
        #expect(zone(170, 100) == .next)
        #expect(zone(100, 170) == .playPause)
        #expect(zone(30, 100) == .previous)
        #expect(zone(300, 300) == .outside)
    }

    @Test func oneTickPer15Degrees() {
        var tracker = WheelTracker()
        let deg = Double.pi / 180
        #expect(tracker.add(14 * deg).isEmpty)
        #expect(tracker.add(1.5 * deg) == [.forward])
        // 45° in one go = 3 ticks.
        #expect(tracker.add(45 * deg) == [.forward, .forward, .forward])
        #expect(abs(tracker.progress - 0.5 / 15) < 1e-9)
    }

    @Test func counterClockwiseTicksBackward() {
        var tracker = WheelTracker()
        #expect(tracker.add(-.pi / 12 - 0.001) == [.backward])
        #expect(tracker.progress < 0)
    }

    @Test func reversalNeedsAFullDetentTheOtherWay() {
        var tracker = WheelTracker()
        let deg = Double.pi / 180
        _ = tracker.add(10 * deg)                // 2/3 toward next
        #expect(tracker.add(-20 * deg).isEmpty)  // now -10°, not yet at -15°
        #expect(abs(tracker.progress + 10.0 / 15) < 1e-9)
        #expect(tracker.add(-6 * deg) == [.backward])
    }

    @Test func fullRevolutionIs24Ticks() {
        var tracker = WheelTracker()
        var ticks = 0
        for _ in 0..<360 { ticks += tracker.add(.pi / 180).count }
        #expect(ticks == 24)
    }

    @Test func rateMeterSmoothsAndResetsAfterPause() {
        var meter = TickRateMeter()
        meter.record(at: 0)
        #expect(meter.ticksPerSecond == 0)
        for i in 1...20 { meter.record(at: Double(i) * 0.1) }
        #expect(abs(meter.ticksPerSecond - 10) < 0.5)
        meter.record(at: 10)   // long pause
        #expect(meter.ticksPerSecond < 1)
    }

    @Test func wallPushGrowsContinuouslyPastTheEnd() {
        var push = WallPush()
        let atEnd: (TickDirection) -> Bool = { $0 == .forward }   // on the last row
        #expect(push.overshoot(progress: -0.5, blocked: atEnd) == 0)   // heading away: no wall
        #expect(push.overshoot(progress: 0.4, blocked: atEnd) == 0.4)  // leaning into it before any tick
        push.hitWall(.forward)
        #expect(push.overshoot(progress: 0, blocked: atEnd) == 1)      // continuous across the tick
        #expect(push.overshoot(progress: 0.5, blocked: atEnd) == 1.5)
        push.hitWall(.forward)
        #expect(push.overshoot(progress: 0.25, blocked: atEnd) == 2.25)
    }

    @Test func wallPushUnwindsBeforeAnythingMoves() {
        var push = WallPush()
        push.hitWall(.forward)
        push.hitWall(.forward)
        #expect(push.overshoot(progress: -0.5, blocked: { _ in true }) == 1.5)  // backing off
        let first = push.absorbs(.backward), second = push.absorbs(.backward), third = push.absorbs(.backward)
        #expect(first && second)                 // unwinding, not moving
        #expect(!third)                          // back at the endpoint: this tick moves
        #expect(push.ticks == 0)
        push.hitWall(.forward)
        let further = push.absorbs(.forward)
        #expect(!further)                        // pushing further in is never absorbed
        push.moved()
        #expect(push == WallPush())
    }
}
