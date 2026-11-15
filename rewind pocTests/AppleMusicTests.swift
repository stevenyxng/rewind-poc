import Foundation
import Testing
@testable import rewind_poc

struct AppleMusicMenuTests {
    static func song(_ id: String, _ title: String, duration: Double = 187) -> Track {
        Track(title: title, artist: "Artist", album: "Album", duration: duration, source: .appleMusic(id: id),
              artworkURL: URL(string: "https://example.com/\(id).jpg"))
    }

    func rows(_ screen: Screen, _ configure: (inout MenuContext) -> Void) -> [MenuItem] {
        var c = MenuContext()
        configure(&c)
        return MenuBuilder.items(for: screen, context: c)
    }

    @Test func appleMusicTrackIDs() {
        let t = Self.song("123", "Song")
        #expect(t.id == "apple:123")
        #expect(t.appleMusicID == "123")
        #expect(t.isAppleMusic && !t.isLocal)
    }

    @Test func accessStates() {
        #expect(rows(.appleMusic) { $0.appleMusicStatus = .notDetermined }.map(\.action) == [.connectAppleMusic])
        #expect(rows(.appleMusic) { $0.appleMusicStatus = .denied }.last?.action == .openAppleMusicSettings)
        #expect(rows(.appleMusic) { $0.appleMusicStatus = .noSubscription }.map(\.title)
                == ["No Apple Music subscription", "Check Again"])
        #expect(rows(.appleMusic) { $0.appleMusicStatus = .ready }.map(\.title) == ["Search…"])
    }

    @Test func searchResults() {
        let songs = [Self.song("1", "One"), Self.song("2", "Two")]
        let album = AppleMusicCollection(kind: .album, catalogID: "9", title: "LP", subtitle: "Artist")
        let items = rows(.appleMusic) {
            $0.appleMusicStatus = .ready
            $0.appleMusicSearch = AppleMusicSearch(term: "abc", songs: songs, albums: [album])
        }
        #expect(items.map(\.title) == ["Search…", "Songs", "Albums"])
        #expect(items.first?.detail == "abc")

        let songRows = rows(.appleMusicSongs) { $0.appleMusicSearch = AppleMusicSearch(term: "abc", songs: songs) }
        #expect(songRows.map(\.detail) == ["3:07", "3:07"])
        #expect(songRows.map(\.subtitle) == ["Artist", "Artist"])
        #expect(songRows[1].action == .play(songs, index: 1))
        #expect(songRows[0].artworkURL != nil)

        #expect(rows(.appleMusic) {
            $0.appleMusicStatus = .ready
            $0.appleMusicSearch = AppleMusicSearch(term: "zzz")
        }.map(\.title) == ["Search…", "No results"])
    }

    @Test func collectionLoads() {
        let album = AppleMusicCollection(kind: .album, catalogID: "9", title: "LP")
        #expect(rows(.appleMusicCollection(album)) { _ in }.map(\.title) == ["Loading…"])
        #expect(rows(.appleMusicCollection(album)) {
            $0.appleMusicCollections[album.id] = .loaded([Self.song("1", "One")])
        }.map(\.title) == ["One"])
        #expect(rows(.appleMusicCollection(album)) {
            $0.appleMusicCollections[album.id] = .failed("offline")
        }.last?.action == .openAppleMusicCollection(album))
    }

    @Test func queueFollowsExternalPlayer() {
        let tracks = [Self.song("1", "One"), Self.song("2", "Two"), Self.song("3", "Three")]
        var q = PlaybackQueue()
        q.load(tracks, startAt: 0, shuffled: false)
        #expect(q.move(to: "apple:3"))
        #expect(q.current?.title == "Three")
        #expect(!q.move(to: "apple:404"))
        #expect(q.current?.title == "Three")
        #expect(q.ordered.map(\.title) == ["One", "Two", "Three"])
    }
}
