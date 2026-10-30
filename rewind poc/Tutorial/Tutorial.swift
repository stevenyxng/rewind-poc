import Foundation

/// Which part of the wheel a tutorial step points at.
nonisolated enum TutorialTarget: Equatable, Sendable {
    case center, ring, menu, playPause, skip
}

/// One coach-mark step. Each one waits for the user to actually do the thing.
nonisolated enum TutorialStep: Int, CaseIterable, Sendable {
    case welcome, scroll, select, back, playPause, skip, done

    var title: String {
        switch self {
        case .welcome: "Welcome to Rewind"
        case .scroll: "Spin to scroll"
        case .select: "Press to select"
        case .back: "Go back"
        case .playPause: "Play & pause"
        case .skip: "Skip songs"
        case .done: "You're all set"
        }
    }

    var message: String {
        switch self {
        case .welcome: "Everything is controlled with the wheel. Press the center button to start."
        case .scroll: "Slide your finger around the ring to move through the menu."
        case .select: "Press the center button to open the highlighted item."
        case .back: "Press MENU to go back one level."
        case .playPause: "The bottom button plays or pauses the current song. Give it a press."
        case .skip: "Left and right skip songs. Hold one to rewind or fast-forward. Try one."
        case .done: "On Now Playing, spin the wheel to scrub through a song. Press the center button to finish."
        }
    }

    var target: TutorialTarget {
        switch self {
        case .welcome, .select, .done: .center
        case .scroll: .ring
        case .back: .menu
        case .playPause: .playPause
        case .skip: .skip
        }
    }
}

/// First-launch walkthrough. Watches wheel events and advances when the user does
/// what the current step asks. Knows nothing about views, menus or playback.
@Observable
final class Tutorial {
    /// Ticks needed to finish the scroll step.
    static let scrollTicks = 3

    private(set) var step: TutorialStep?
    var isActive: Bool { step != nil }

    /// Called once when the tutorial ends (finished or skipped).
    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored private var ticks = 0

    func start() {
        ticks = 0
        step = .welcome
    }

    func finish() {
        guard step != nil else { return }
        step = nil
        onFinish()
    }

    /// Feeds a wheel event to the tutorial. Returns true if the tutorial consumed it
    /// (the app should then ignore it); false lets it through to the app as usual.
    @discardableResult
    func handle(_ event: WheelEvent) -> Bool {
        guard let step else { return false }
        switch (step, event) {
        case (.welcome, .press(.center)):
            advance()
            return true
        case (.scroll, .tick):
            ticks += 1
            if ticks >= Self.scrollTicks { advance() }
        case (.select, .press(.center)),
             (.back, .press(.menu)),
             (.playPause, .press(.playPause)),
             (.skip, .press(.next)), (.skip, .press(.previous)),
             (.skip, .holdBegan(.next)), (.skip, .holdBegan(.previous)):
            advance()
        case (.done, .press(.center)):
            finish()
            return true
        default:
            break
        }
        return false
    }

    private func advance() {
        guard let step else { return }
        if let next = TutorialStep(rawValue: step.rawValue + 1) {
            self.step = next
        } else {
            finish()
        }
    }
}
