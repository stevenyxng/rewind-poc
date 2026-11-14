import Foundation
import Testing
@testable import rewind_poc

@MainActor
struct SpotifyLibraryTests {
    private static let song = #"{"id":"s1","name":"Song","uri":"spotify:track:s1","artists":[{"id":"a1","name":"Artist","uri":"spotify:artist:a1"}]}"#
    private static let artist = #"{"id":"a1","name":"Artist","uri":"spotify:artist:a1"}"#
    private static let playlist = #"{"id":"p1","name":"Playlist","uri":"spotify:playlist:p1"}"#

    private func response(_ request: URLRequest, _ body: String, status: Int = 200,
                          headers: [String: String] = [:]) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status,
                                                           httpVersion: nil, headerFields: headers)))
    }

    private func emptyPage(for request: URLRequest) -> String {
        request.url?.path == "/v1/me/following"
            ? #"{"artists":{"items":[],"next":null}}"# : #"{"items":[],"next":null}"#
    }

    @Test func loadsAllPagesAndDeduplicatesWithoutLosingCategories() async throws {
        var paths: [String] = []
        let api = SpotifyLibraryAPI(token: { _ in "test-token" }, transport: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let url = try #require(request.url)
            paths.append(url.path)
            switch url.path {
            case "/v1/me/tracks":
                if url.query?.contains("offset=50") == true {
                    return try response(request, "{\"items\":[{\"track\":\(Self.song)},null,{\"track\":null},{\"track\":{\"id\":null,\"uri\":\"spotify:local:x\"}}],\"next\":null}")
                }
                return try response(request, "{\"items\":[{\"track\":\(Self.song)}],\"next\":\"https://api.spotify.com/v1/me/tracks?offset=50&limit=50\"}")
            case "/v1/me/following":
                if url.query?.contains("after=a1") == true {
                    return try response(request, #"{"artists":{"items":[],"next":null}}"#)
                }
                return try response(request, "{\"artists\":{\"items\":[\(Self.artist)],\"next\":\"https://api.spotify.com/v1/me/following?type=artist&after=a1\"}}")
            default:
                return try response(request, "{\"items\":[\(Self.playlist)],\"next\":null}")
            }
        })
        let result = try await api.fetchLibrary()
        #expect(result.songs.map(\.id) == ["s1"])
        #expect(result.artists.map(\.id) == ["a1"])
        #expect(result.playlists.map(\.id) == ["p1"])
        #expect(paths == ["/v1/me/tracks", "/v1/me/tracks", "/v1/me/following", "/v1/me/following", "/v1/me/playlists"])
    }

    @Test func refreshesTokenOnceAfterUnauthorized() async throws {
        var requests = 0
        var forcedRefreshes = 0
        let api = SpotifyLibraryAPI(token: { force in
            if force { forcedRefreshes += 1 }
            return force ? "fresh" : "cached"
        }, transport: { request in
            requests += 1
            if requests == 1 { return try response(request, "{}", status: 401) }
            if requests == 2 { #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh") }
            return try response(request, emptyPage(for: request))
        })
        _ = try await api.fetchLibrary()
        #expect(requests == 4)
        #expect(forcedRefreshes == 1)
    }

    @Test func doesNotRetryUnauthorizedForever() async {
        var count = 0
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            count += 1
            return try response(request, "{}", status: 401)
        })
        await #expect(throws: SpotifyAuthError.self) { try await api.fetchLibrary() }
        #expect(count == 2)
    }

    @Test func honorsRateLimitAcrossRefreshAttempts() async {
        var count = 0
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            count += 1
            return try response(request, "{}", status: 429, headers: ["Retry-After": "60"])
        })
        await #expect(throws: SpotifyLibraryError.self) { try await api.fetchLibrary() }
        await #expect(throws: SpotifyLibraryError.self) { try await api.fetchLibrary() }
        #expect(count == 1)
    }

    @Test func rejectsUntrustedAndRepeatedNextPages() async {
        for next in ["https://example.com/steal", "https://api.spotify.com/v1/me/tracks?limit=50",
                     "http://api.spotify.com/v1/me/tracks?offset=50",
                     "https://api.spotify.com/v1/other"] {
            var count = 0
            let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
                count += 1
                return try response(request, "{\"items\":[],\"next\":\"\(next)\"}")
            })
            await #expect(throws: SpotifyLibraryError.self) { try await api.fetchLibrary() }
            #expect(count == 1)
        }
    }

    @Test func keepsLoadedLibraryOnNetworkFailureAndClearsRevokedAccess() async {
        var status = 200
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            if status != 200 { return try response(request, "{}", status: status) }
            if request.url?.path == "/v1/me/tracks" {
                return try response(request, "{\"items\":[{\"track\":\(Self.song)}],\"next\":null}")
            }
            return try response(request, emptyPage(for: request))
        })
        let library = SpotifyLibrary(api: api)
        await library.refresh()
        #expect(library.state == .ready)
        #expect(library.snapshot.songs.count == 1)
        status = 500
        await library.refresh()
        #expect(library.snapshot.songs.count == 1)
        if case .failed = library.state {} else { Issue.record("Expected failed state") }
        status = 401
        await library.refresh()
        #expect(library.snapshot.songs.isEmpty)
        #expect(library.state == .disconnected)
    }

    @Test func categoryRowsRouteToSpotifyAndKeepLocalSongs() throws {
        let decoder = JSONDecoder()
        let song = try decoder.decode(SpotifyLibrarySong.self, from: Data(Self.song.utf8))
        let artist = try decoder.decode(SpotifyLibraryArtist.self, from: Data(Self.artist.utf8))
        let playlist = try decoder.decode(SpotifyLibraryPlaylist.self, from: Data(Self.playlist.utf8))
        var context = MenuContext()
        context.localTracks = [MenuNavigationTests.track("Local")]
        context.spotify = SpotifyLibrarySnapshot(songs: [song], artists: [artist], playlists: [playlist])
        context.spotifyState = .ready
        let songs = MenuBuilder.items(for: .songs, context: context)
        #expect(songs.contains { $0.title == "Local" })
        #expect(songs.first { $0.id == song.uri }?.action == .playSpotify(song.uri))
        #expect(MenuBuilder.items(for: .artists, context: context).contains { $0.action == .push(.spotifyArtist("a1")) })
        #expect(MenuBuilder.items(for: .spotifyArtist("a1"), context: context).contains { $0.action == .playSpotify(song.uri) })
        #expect(MenuBuilder.items(for: .playlists, context: context).first?.action == .playSpotify(playlist.uri))
        let unavailableJSON = Self.song.dropLast() + #", "is_playable":false}"#
        let unavailable = try decoder.decode(SpotifyLibrarySong.self, from: Data(unavailableJSON.utf8))
        context.spotify.songs = [unavailable]
        #expect(MenuBuilder.items(for: .songs, context: context).first { $0.id == song.uri }?.action == MenuAction.none)
    }
}
