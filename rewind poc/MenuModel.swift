import SwiftUI
import Observation

/// Single source of truth for what the screen shows.
/// Step 1: just a placeholder list of 30 numbered items.
@Observable
final class MenuModel {
    var title = "iPod"
    var items: [String] = (1...30).map { "Item \($0)" }
    var selectedIndex = 0
    var isPlaying = false

    /// Handles a wheel event. Returns true if the event changed something
    /// (used to decide whether a scroll tick should produce haptics).
    @discardableResult
    func handle(_ event: WheelEvent) -> Bool {
        switch event {
        case .scrollDown:
            guard selectedIndex < items.count - 1 else { return false }
            selectedIndex += 1
            return true
        case .scrollUp:
            guard selectedIndex > 0 else { return false }
            selectedIndex -= 1
            return true
        case .playPause:
            isPlaying.toggle()
            return true
        case .select, .menu, .next, .previous:
            return true
        }
    }
}
