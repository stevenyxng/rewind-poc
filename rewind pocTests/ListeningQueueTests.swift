import Foundation
import Testing
@testable import rewind_poc

struct ListeningQueueTests {
    private func local(_ name: String) -> ShuffleSong {
        .local(MenuNavigationTests.track(name))
    }

    @Test func sequentialUsesCapturedOrderAndStops() {
        let songs = [local("Zulu"), local("Alpha"), local("Middle")]
        var queue = ListeningQueue(songs: songs, index: 1)
        var rng = SystemRandomNumberGenerator()
        #expect(queue.advance(shuffle: false, repeatMode: .off, repeatAllowed: true, using: &rng) == songs[2])
        #expect(queue.advance(shuffle: false, repeatMode: .off, repeatAllowed: true, using: &rng) == nil)
        #expect(queue.current == songs[2])
    }

    @Test func repeatAllWrapsToFirstRow() {
        let songs = [local("First"), local("Last")]
        var queue = ListeningQueue(songs: songs, index: 1)
        var rng = SystemRandomNumberGenerator()
        #expect(queue.advance(shuffle: false, repeatMode: .all, repeatAllowed: true, using: &rng) == songs[0])
    }

    @Test func repeatOneRespectsPermissionAndSequentialFallback() {
        let songs = [local("First"), local("Second")]
        var queue = ListeningQueue(songs: songs, index: 0)
        var rng = SystemRandomNumberGenerator()
        #expect(queue.advance(shuffle: true, repeatMode: .one, repeatAllowed: true, using: &rng) == songs[0])
        #expect(queue.advance(shuffle: true, repeatMode: .one, repeatAllowed: false, using: &rng) == songs[1])
        #expect(queue.advance(shuffle: true, repeatMode: .one, repeatAllowed: false, using: &rng) == nil)
    }

    @Test func shuffleVisitsListThenStopsWithoutImmediateRepeats() {
        let songs = [local("A"), local("B"), local("C")]
        var queue = ListeningQueue(songs: songs, index: 1)
        var rng = SystemRandomNumberGenerator()
        var played = [songs[1]]
        while let next = queue.advance(shuffle: true, repeatMode: .off, repeatAllowed: true, using: &rng) {
            #expect(next != played.last)
            played.append(next)
        }
        #expect(played.count == 3)
        #expect(songs.allSatisfy { played.contains($0) })
        let last = queue.current
        #expect(queue.advance(shuffle: true, repeatMode: .all, repeatAllowed: true, using: &rng) != last)
    }

    @Test func singleSongShuffleStopsUnlessRepeatOne() {
        var queue = ListeningQueue(songs: [local("Only")], index: 0)
        var rng = SystemRandomNumberGenerator()
        #expect(queue.advance(shuffle: true, repeatMode: .all, repeatAllowed: true, using: &rng) == nil)
        #expect(queue.advance(shuffle: true, repeatMode: .one, repeatAllowed: true, using: &rng) == queue.current)
    }

    @Test func previousFollowsActualShuffleHistory() {
        var queue = ListeningQueue(songs: [local("A"), local("B"), local("C")], index: 0)
        let first = queue.current
        var rng = SystemRandomNumberGenerator()
        _ = queue.advance(shuffle: true, repeatMode: .off, repeatAllowed: true, using: &rng)
        #expect(queue.previous() == first)
    }

    @Test func songsMenuQueueIncludesBothSourcesInDisplayedOrder() {
        let spotify = SpotifyLibrarySong(id: "s", name: "Middle", uri: "spotify:track:s",
                                         artists: [], is_playable: true, is_local: false)
        var context = MenuContext()
        context.localTracks = [MenuNavigationTests.track("Zulu"), MenuNavigationTests.track("Alpha")]
        context.spotify.songs = [spotify]
        let rows = MenuBuilder.playbackRows(for: .songs, context: context)
        #expect(rows.map(\.row) == [0, 1, 2])
        #expect(rows[1].song == .spotify(spotify))
        var queue = ListeningQueue(songs: rows.map(\.song), index: 0)
        var rng = SystemRandomNumberGenerator()
        #expect(queue.advance(shuffle: false, repeatMode: .off, repeatAllowed: true, using: &rng) == .spotify(spotify))
        #expect(queue.advance(shuffle: false, repeatMode: .off, repeatAllowed: true, using: &rng) == rows[2].song)
    }

    @Test func playlistPreservesDuplicatesAndExcludesPlayAllRow() {
        let song = SpotifyLibrarySong(id: "s", name: "Song", uri: "spotify:track:s",
                                      artists: [], is_playable: true, is_local: false)
        var context = MenuContext()
        context.spotify.playlists = [SpotifyLibraryPlaylist(id: "p", name: "Playlist", uri: "spotify:playlist:p")]
        context.spotifyPlaylistContents["p"] = SpotifyPlaylistContents(songs: [song, song], state: .ready)
        let rows = MenuBuilder.playbackRows(for: .spotifyPlaylist("p"), context: context)
        #expect(rows.map(\.row) == [1, 2])
        #expect(rows.map(\.song) == [.spotify(song), .spotify(song)])
    }
}
