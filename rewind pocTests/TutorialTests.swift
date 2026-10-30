import Foundation
import Testing
@testable import rewind_poc

@MainActor
struct TutorialTests {
    @Test func walksThroughEveryStep() {
        let t = Tutorial()
        var finished = 0
        t.onFinish = { finished += 1 }
        t.start()
        #expect(t.step == .welcome)

        #expect(t.handle(.press(.center)))            // consumed: doesn't select a menu row
        #expect(t.step == .scroll)

        for _ in 0..<Tutorial.scrollTicks { #expect(!t.handle(.tick(.forward, rate: 1))) }
        #expect(t.step == .select)

        #expect(!t.handle(.press(.center)))           // passes through so the menu opens
        #expect(t.step == .back)
        t.handle(.press(.menu))
        #expect(t.step == .playPause)
        t.handle(.press(.playPause))
        #expect(t.step == .skip)
        t.handle(.press(.previous))
        #expect(t.step == .done)

        #expect(t.handle(.press(.center)))
        #expect(t.step == nil)
        #expect(finished == 1)
    }

    @Test func ignoresUnrelatedInput() {
        let t = Tutorial()
        t.start()
        t.handle(.press(.menu))
        t.handle(.tick(.forward, rate: 1))
        #expect(t.step == .welcome)
    }

    @Test func skipFinishesOnce() {
        let t = Tutorial()
        var finished = 0
        t.onFinish = { finished += 1 }
        t.start()
        t.finish()
        t.finish()
        #expect(!t.isActive)
        #expect(finished == 1)
        #expect(!t.handle(.press(.center)))           // inactive: everything passes through
    }

    @Test func settingsHasTutorialRow() {
        let rows = MenuBuilder.items(for: .settings, context: MenuContext())
        #expect(rows.contains { $0.action == .startTutorial })
    }
}
