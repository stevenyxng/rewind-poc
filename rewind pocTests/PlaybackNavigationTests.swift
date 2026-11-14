import Testing
@testable import rewind_poc

@MainActor
struct PlaybackNavigationTests {
    private func navigator() -> MenuNavigator {
        MenuNavigator { MenuBuilder.items(for: $0, context: MenuContext()) }
    }

    @Test func availableTrackAppearsWithoutSelectingMenuItem() {
        let nav = navigator()
        nav.presentPlaybackIfPreferred(hasTrack: false)
        #expect(nav.screen == .main)
        nav.presentPlaybackIfPreferred(hasTrack: true)
        #expect(nav.screen == .nowPlaying)
        nav.presentPlaybackIfPreferred(hasTrack: true)
        #expect(nav.stack.count == 2)
    }

    @Test func revealingMenuKeepsSelectionAndAllowsScrolling() {
        let nav = navigator()
        nav.showNowPlaying()
        nav.revealMainMenu()
        #expect(nav.screen == .main)
        #expect(nav.current.selected == 0)
        #expect(nav.move(.forward) == .moved)
        #expect(nav.selectedItem?.title == "Shuffle Songs")
    }

    @Test func playbackUpdatesDoNotInterruptBrowsing() {
        let nav = navigator()
        nav.showNowPlaying()
        nav.revealMainMenu()
        nav.select()
        #expect(nav.screen == .music)
        nav.presentPlaybackIfPreferred(hasTrack: false)
        nav.presentPlaybackIfPreferred(hasTrack: true)
        #expect(nav.screen == .music)
    }

    @Test func returningToAppPrefersPlaybackAgain() {
        let nav = navigator()
        nav.showNowPlaying()
        nav.revealMainMenu()
        nav.push(.settings)
        nav.preferPlayback(hasTrack: true)
        #expect(nav.screen == .nowPlaying)
        nav.revealMainMenu()
        #expect(nav.screen == .main)
        nav.preferPlayback(hasTrack: false)
        #expect(nav.screen == .main)
        nav.presentPlaybackIfPreferred(hasTrack: true)
        #expect(nav.screen == .nowPlaying)
    }
}
