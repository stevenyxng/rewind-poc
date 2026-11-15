import Foundation
import Testing
@testable import rewind_poc

@MainActor
struct ShufflePoolTests {
    private func spotify(_ id: String, playable: Bool = true) -> SpotifyLibrarySong {
        SpotifyLibrarySong(id: id, name: id, uri: "spotify:track:" + id, artists: [],
                           is_playable: playable, is_local: false)
    }

    @Test func combinesSourcesWithoutPlaylistWeighting() {
        let local = MenuNavigationTests.track("Local")
        let first = spotify("one")
        let second = spotify("two")
        let pool = ShufflePool.songs(local: [local, local], spotify: [first, first, second, first])
        #expect(pool == [.local(local), .spotify(first), .spotify(second)])
    }

    @Test func excludesUnavailableSpotifyTracks() {
        let playable = spotify("available")
        let localSpotify = SpotifyLibrarySong(id: "local", name: "Local", uri: "spotify:local:artist:song",
                                              artists: [], is_playable: true, is_local: true)
        #expect(ShufflePool.songs(local: [], spotify: [spotify("blocked", playable: false), localSpotify, playable])
                == [.spotify(playable)])
    }

    @Test func supportsEitherSourceAloneAndEmptyLibraries() {
        var rng = SystemRandomNumberGenerator()
        let local = MenuNavigationTests.track("Local")
        let song = spotify("one")
        #expect(ShufflePool.pick(from: [], using: &rng) == nil)
        #expect(ShufflePool.pick(from: [.local(local)], using: &rng) == .local(local))
        #expect(ShufflePool.pick(from: [.spotify(song)], using: &rng) == .spotify(song))
    }

    @Test func playlistSongsJoinShuffleWithoutOpeningPlaylist() async throws {
        var requested: [String] = []
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            let url = try #require(request.url)
            requested.append(url.path)
            let body: String
            switch url.path {
            case "/v1/me/tracks": body = #"{"items":[],"next":null}"#
            case "/v1/me/following": body = #"{"artists":{"items":[],"next":null}}"#
            case "/v1/me/playlists":
                body = #"{"items":[{"id":"p1","name":"Test","uri":"spotify:playlist:p1"}],"next":null}"#
            default:
                body = #"{"items":[{"item":{"id":"s1","name":"Playlist song","uri":"spotify:track:s1","artists":[]}}],"next":null}"#
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        })
        let library = SpotifyLibrary(api: api)
        await library.refresh()
        #expect(library.playlistContents.isEmpty)
        let result = try await library.songsForShuffle()
        #expect(result.songs.map(\.id) == ["s1"])
        #expect(result.skippedPlaylists == 0)
        #expect(requested.contains("/v1/playlists/p1/items"))
    }

    @Test func reportsInaccessiblePlaylistsWithoutDroppingLikedSongs() async throws {
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            let url = try #require(request.url)
            let body: String
            var status = 200
            switch url.path {
            case "/v1/me/albums": body = #"{"items":[],"next":null}"#
            case "/v1/me/tracks":
                body = #"{"items":[{"track":{"id":"s1","name":"Liked","uri":"spotify:track:s1","artists":[]}}],"next":null}"#
            case "/v1/me/following": body = #"{"artists":{"items":[],"next":null}}"#
            case "/v1/me/playlists":
                body = #"{"items":[{"id":"p1","name":"Restricted","uri":"spotify:playlist:p1"}],"next":null}"#
            default: body = "{}"; status = 403
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        })
        let library = SpotifyLibrary(api: api)
        await library.refresh()
        let result = try await library.songsForShuffle()
        #expect(result.songs.map(\.id) == ["s1"])
        #expect(result.skippedPlaylists == 1)
    }
}
