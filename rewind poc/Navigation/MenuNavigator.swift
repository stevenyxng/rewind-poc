import Foundation

/// Menu stack and selection. Knows nothing about haptics or playback: it reports
/// whether a move hit a wall and hands non-navigation actions back to the caller.
@Observable
final class MenuNavigator {
    struct Frame: Equatable {
        var screen: Screen
        var selected = 0
        /// First visible row, iPod style: the list only scrolls when the selection hits an edge.
        var top = 0
    }

    enum MoveResult: Equatable { case moved, wall }

    private(set) var stack: [Frame] = [Frame(screen: .main)]

    /// Rows that fit on the display; set by the view from its height.
    var visibleRows = 6 {
        didSet { if visibleRows != oldValue { clampCurrent() } }
    }

    /// Supplies the rows for a screen (usually `MenuBuilder` over the live library).
    @ObservationIgnored var itemsProvider: (Screen) -> [MenuItem]

    init(items: @escaping (Screen) -> [MenuItem] = { _ in [] }) {
        itemsProvider = items
    }

    var current: Frame { stack[stack.count - 1] }
    var screen: Screen { current.screen }
    var items: [MenuItem] { itemsProvider(current.screen) }
    var selectedItem: MenuItem? {
        let items = items
        return items.indices.contains(current.selected) ? items[current.selected] : nil
    }

    /// Moves the selection one row. Never wraps: at either end it reports `.wall`.
    func move(_ direction: TickDirection) -> MoveResult {
        let count = items.count
        let target = current.selected + direction.sign
        guard target >= 0, target < count else { return .wall }
        var frame = current
        frame.selected = target
        frame.top = Self.top(selected: target, currentTop: frame.top, visible: visibleRows, count: count)
        stack[stack.count - 1] = frame
        return .moved
    }

    /// Selects the highlighted row. Pushes for `.push`, returns every other action for the caller.
    @discardableResult
    func select() -> MenuAction {
        guard let item = selectedItem else { return .none }
        if case .push(let screen) = item.action {
            push(screen)
        }
        return item.action
    }

    func push(_ screen: Screen) {
        stack.append(Frame(screen: screen))
    }

    /// MENU: up one level. Returns false at the root.
    @discardableResult
    func back() -> Bool {
        guard stack.count > 1 else { return false }
        stack.removeLast()
        clampCurrent()
        return true
    }

    /// Pops until `screen` is on top; returns false (and leaves the stack alone) if it isn't in it.
    @discardableResult
    func pop(to screen: Screen) -> Bool {
        guard let i = stack.lastIndex(where: { $0.screen == screen }) else { return false }
        stack.removeSubrange((i + 1)...)
        clampCurrent()
        return true
    }

    /// Removes every frame for which `shouldRemove` is true (never the root), e.g. screens
    /// for a deleted song or a Now Playing that no longer exists.
    func removeScreens(where shouldRemove: (Screen) -> Bool) {
        stack = [stack[0]] + stack.dropFirst().filter { !shouldRemove($0.screen) }
        clampCurrent()
    }

    /// Keeps selection and scroll valid after the list's contents change.
    func clampCurrent() {
        let count = items.count
        var frame = current
        frame.selected = min(max(frame.selected, 0), max(count - 1, 0))
        frame.top = Self.top(selected: frame.selected, currentTop: frame.top, visible: visibleRows, count: count)
        if frame != current { stack[stack.count - 1] = frame }
    }

    /// Scroll position that keeps `selected` visible, moving as little as possible.
    static func top(selected: Int, currentTop: Int, visible: Int, count: Int) -> Int {
        let visible = max(visible, 1)
        var top = currentTop
        if selected < top { top = selected }
        if selected >= top + visible { top = selected - visible + 1 }
        return min(max(top, 0), max(count - visible, 0))
    }
}
