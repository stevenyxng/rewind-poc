import Foundation
import Testing
@testable import rewind_poc

@MainActor
struct MenuNavigationTests {
    static func track(_ title: String, artist: String = "A", album: String = "X") -> Track {
        Track(title: title, artist: artist, album: album, duration: 100, source: .local(fileName: title + ".mp3"))
    }

    var context = MenuContext()

    func navigator(_ context: MenuContext) -> MenuNavigator {
        MenuNavigator { MenuBuilder.items(for: $0, context: context) }
    }

    @Test func mainMenuShowsNowPlayingOnlyWhileLoaded() {
        var c = context
        #expect(MenuBuilder.items(for: .main, context: c).map(\.title) == ["Music", "Shuffle Songs", "Settings"])
        c.hasNowPlaying = true
        #expect(MenuBuilder.items(for: .main, context: c).map(\.title) == ["Music", "Now Playing", "Shuffle Songs", "Settings"])
    }

    @Test func musicAndSettingsMenus() {
        #expect(MenuBuilder.items(for: .music, context: context).map(\.title)
                == ["Songs", "Artists", "Albums", "Local Files", "Cloud"])
        let settings = MenuBuilder.items(for: .settings, context: context).map(\.title)
        for required in ["Appearance", "Click Sound", "Haptics", "Wall", "Haptics Lab", "Import Files", "About"] {
            #expect(settings.contains(required))
        }
    }

    @Test func appearanceCyclesAndShowsInSettings() {
        #expect(Appearance.system.next == .dark)
        #expect(Appearance.dark.next == .light)
        #expect(Appearance.light.next == .system)
        var c = context
        c.appearance = .dark
        let row = MenuBuilder.items(for: .settings, context: c).first { $0.id == "appearance" }
        #expect(row?.detail == "Dark")
        #expect(row?.action == .toggle(.appearance))
    }

    @Test func cloudNotConfigured() {
        var c = context
        c.cloudState = .notConfigured
        #expect(MenuBuilder.items(for: .cloud, context: c).map(\.title) == ["Cloud not configured"])
    }

    @Test func moveHitsWallsAndNeverWraps() {
        let nav = navigator(context)          // main: 3 rows
        #expect(!nav.canMove(.backward))
        #expect(nav.canMove(.forward))
        #expect(nav.move(.backward) == .wall)
        #expect(nav.current.selected == 0)
        #expect(nav.move(.forward) == .moved)
        #expect(nav.move(.forward) == .moved)
        #expect(nav.current.selected == 2)
        #expect(nav.move(.forward) == .wall)
        #expect(nav.current.selected == 2)
    }

    @Test func selectPushesAndMenuGoesBack() {
        let nav = navigator(context)
        #expect(nav.select() == .push(.music))
        #expect(nav.screen == .music)
        _ = nav.move(.forward)
        #expect(nav.select() == .push(.artists))
        #expect(nav.stack.count == 3)
        #expect(nav.back())
        #expect(nav.screen == .music)
        #expect(nav.current.selected == 1)       // selection is remembered per level
        #expect(nav.back())
        #expect(!nav.back())                     // root
        #expect(nav.screen == .main)
    }

    @Test func nonPushActionsAreReturned() {
        var c = context
        c.localTracks = [Self.track("B"), Self.track("A")]
        let nav = navigator(c)
        nav.push(.songs)
        let action = nav.select()
        guard case .play(let tracks, let index) = action else {
            Issue.record("expected play, got \(action)")
            return
        }
        #expect(tracks.map(\.title) == ["A", "B"])   // sorted
        #expect(index == 0)
        #expect(nav.screen == .songs)                // play doesn't push by itself
    }

    @Test func listScrollsOnlyAtEdges() {
        var c = context
        c.localTracks = (0..<20).map { Self.track(String(format: "Song %02d", $0)) }
        let nav = navigator(c)
        nav.visibleRows = 5
        nav.push(.songs)
        for _ in 0..<4 { _ = nav.move(.forward) }
        #expect(nav.current.top == 0)            // row 4 is still visible
        _ = nav.move(.forward)
        #expect(nav.current.top == 1)            // row 5 scrolls by one
        for _ in 0..<3 { _ = nav.move(.backward) }
        #expect(nav.current.top == 1)            // row 2 visible within 1...5
        _ = nav.move(.backward); _ = nav.move(.backward)
        #expect(nav.current.selected == 0)
        #expect(nav.current.top == 0)
    }

    @Test func topHelperClampsToEnd() {
        #expect(MenuNavigator.top(selected: 19, currentTop: 0, visible: 5, count: 20) == 15)
        #expect(MenuNavigator.top(selected: 2, currentTop: 10, visible: 5, count: 20) == 2)
        #expect(MenuNavigator.top(selected: 0, currentTop: 0, visible: 5, count: 3) == 0)
    }

    @Test func artistsAndAlbumsGroup() {
        var c = context
        c.localTracks = [Self.track("1", artist: "Beta", album: "B1"),
                         Self.track("2", artist: "Alpha", album: "A1"),
                         Self.track("3", artist: "Alpha", album: "A2")]
        #expect(MenuBuilder.items(for: .artists, context: c).map(\.title) == ["Alpha", "Beta"])
        #expect(MenuBuilder.items(for: .artist("Alpha"), context: c).map(\.title) == ["All Songs", "A1", "A2"])
        #expect(MenuBuilder.items(for: .albums, context: c).map(\.title) == ["A1", "A2", "B1"])
        #expect(MenuBuilder.items(for: .album("A2"), context: c).map(\.title) == ["3"])
    }

    @Test func removeScreensAndClampAfterDelete() {
        var c = context
        c.localTracks = [Self.track("A"), Self.track("B")]
        var current = c
        let nav = MenuNavigator { MenuBuilder.items(for: $0, context: current) }
        nav.push(.localFiles)
        _ = nav.move(.forward)
        let id = c.localTracks[1].id
        nav.push(.localTrack(id))
        nav.push(.confirmDelete(id))
        current.localTracks.removeLast()
        nav.removeScreens { $0 == .localTrack(id) || $0 == .confirmDelete(id) }
        #expect(nav.screen == .localFiles)
        #expect(nav.current.selected == 0)      // clamped into the shorter list
    }
}
