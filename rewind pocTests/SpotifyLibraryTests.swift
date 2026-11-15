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
        #expect(paths == ["/v1/me/tracks", "/v1/me/tracks", "/v1/me/albums", "/v1/me/playlists"])
    }

    @Test func groupsSavedSongsUnderEveryCreditedArtistWithoutFollowing() async throws {
        let first = SpotifyLibraryArtist(id: "a1", name: "First", uri: "spotify:artist:a1")
        let guest = SpotifyLibraryArtist(id: "a2", name: "Guest", uri: "spotify:artist:a2")
        let collaboration = #"{"id":"s1","name":"Duet","uri":"spotify:track:s1","artists":[{"id":"a1","name":"First","uri":"spotify:artist:a1"},{"id":"a2","name":"Guest","uri":"spotify:artist:a2"}]}"#
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            #expect(request.url?.path != "/v1/me/following")
            if request.url?.path == "/v1/me/tracks" {
                return try response(request, "{\"items\":[{\"track\":\(collaboration)},{\"track\":\(collaboration)}],\"next\":null}")
            }
            return try response(request, #"{"items":[],"next":null}"#)
        })
        var context = MenuContext()
        context.spotify = try await api.fetchLibrary()
        context.spotifyState = .ready
        #expect(context.spotify.artists == [first, guest])
        for artist in [first, guest] {
            let rows = MenuBuilder.items(for: .spotifyArtist(artist.id), context: context)
            #expect(rows.count == 1)
            #expect(rows.first?.title == "Duet")
            #expect(rows.first?.action == .playSpotify("spotify:track:s1"))
            #expect(!rows.contains { $0.action == .playSpotify(artist.uri) })
        }
    }

    @Test func savedAlbumsPopulateAllCategoriesAndLoadEveryTrackPage() async throws {
        let album = #"{"id":"b1","name":"Album","uri":"spotify:album:b1","artists":[{"id":"albumArtist","name":"Album Artist","uri":"spotify:artist:albumArtist"}]}"#
        let albumOnlySong = #"{"id":"s2","name":"Album Only","uri":"spotify:track:s2","artists":[{"id":"guest","name":"Guest","uri":"spotify:artist:guest"}]}"#
        var trackPages = 0
        var albumPages = 0
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            let url = try #require(request.url)
            switch url.path {
            case "/v1/me/tracks":
                return try response(request, "{\"items\":[{\"track\":\(Self.song)}],\"next\":null}")
            case "/v1/me/albums":
                albumPages += 1
                if albumPages == 1 {
                    return try response(request, "{\"items\":[{\"album\":\(album)}],\"next\":\"https://api.spotify.com/v1/me/albums?offset=50\"}")
                }
                return try response(request, #"{"items":[null,{"album":null}],"next":null}"#)
            case "/v1/albums/b1/tracks":
                trackPages += 1
                if trackPages == 1 {
                    return try response(request, "{\"items\":[\(Self.song)],\"next\":\"https://api.spotify.com/v1/albums/b1/tracks?offset=50\"}")
                }
                return try response(request, "{\"items\":[null,\(albumOnlySong)],\"next\":null}")
            default:
                return try response(request, #"{"items":[],"next":null}"#)
            }
        })
        var context = MenuContext()
        context.spotify = try await api.fetchLibrary()
        context.spotifyState = .ready
        #expect(albumPages == 2)
        #expect(trackPages == 2)
        #expect(Set(context.spotify.songs.map(\.id)) == ["s1", "s2"])
        #expect(context.spotify.songs.count == 2)
        #expect(Set(context.spotify.artists.map(\.id)) == ["a1", "guest", "albumArtist"])
        #expect(MenuBuilder.items(for: .albums, context: context).contains {
            $0.title == "Album" && $0.action == .push(.spotifyAlbum("b1"))
        })
        let rows = MenuBuilder.items(for: .spotifyAlbum("b1"), context: context)
        #expect(rows.map(\.title) == ["Play All", "Song", "Album Only"])
        #expect(rows.first?.action == .playSpotify("spotify:album:b1"))
        #expect(rows.last?.action == .playSpotify("spotify:track:s2"))
        #expect(MenuBuilder.items(for: .songs, context: context).contains { $0.title == "Album Only" })
        #expect(MenuBuilder.items(for: .spotifyArtist("guest"), context: context).first?.title == "Album Only")
        #expect(MenuBuilder.items(for: .spotifyArtist("albumArtist"), context: context).count == 2)
    }

    @Test func disconnectClearsLibraryAndIgnoresInFlightRefresh() async throws {
        var suspend = false
        var pending: CheckedContinuation<Void, Never>?
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            if suspend {
                await withCheckedContinuation { pending = $0 }
                throw URLError(.notConnectedToInternet)
            }
            switch request.url?.path {
            case "/v1/me/tracks":
                return try response(request, "{\"items\":[{\"track\":\(Self.song)}],\"next\":null}")
            case "/v1/me/playlists":
                return try response(request, "{\"items\":[\(Self.playlist)],\"next\":null}")
            case "/v1/playlists/p1/items":
                return try response(request, "{\"items\":[{\"item\":\(Self.song)}],\"next\":null}")
            default:
                return try response(request, #"{"items":[],"next":null}"#)
            }
        })
        let library = SpotifyLibrary(api: api)
        await library.refresh()
        await library.loadPlaylist(id: "p1")
        #expect(!library.snapshot.songs.isEmpty)
        #expect(!library.playlistContents.isEmpty)
        suspend = true
        let refresh = Task { await library.refresh() }
        while pending == nil { await Task.yield() }
        library.disconnect()
        pending?.resume()
        await refresh.value
        #expect(library.state == .disconnected)
        #expect(library.snapshot.songs.isEmpty)
        #expect(library.snapshot.albums.isEmpty)
        #expect(library.snapshot.artists.isEmpty)
        #expect(library.snapshot.playlists.isEmpty)
        #expect(library.playlistContents.isEmpty)
    }

    @Test func settingsSwitchesBetweenConnectAndDisconnect() {
        var context = MenuContext()
        var rows = MenuBuilder.items(for: .settings, context: context)
        #expect(rows.contains { $0.title == "Connect to Spotify" && $0.action == .connectSpotify })
        #expect(!rows.contains { $0.action == .refreshSpotify })
        context.spotifyLinked = true
        rows = MenuBuilder.items(for: .settings, context: context)
        #expect(rows.contains { $0.title == "Disconnect from Spotify" && $0.action == .disconnectSpotify })
        #expect(rows.contains { $0.action == .refreshSpotify })
        context.spotifyLinked = false
        context.localTracks = [MenuNavigationTests.track("Local")]
        for screen: Screen in [.songs, .artists, .albums, .playlists, .settings] {
            #expect(!MenuBuilder.items(for: screen, context: context).contains { $0.action == .refreshSpotify })
        }
        #expect(MenuBuilder.items(for: .songs, context: context).contains { $0.title == "Local" })
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

    @Test func playlistPagesPreserveOrderAndRepeatedSongs() async throws {
        var count = 0
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            count += 1
            #expect(request.url?.path == "/v1/playlists/p1/items")
            if count == 1 {
                return try response(request, "{\"items\":[{\"item\":\(Self.song)}, {\"item\":null}, {\"item\":{\"id\":\"e1\",\"uri\":\"spotify:episode:e1\"}}],\"next\":\"https://api.spotify.com/v1/playlists/p1/items?offset=50\"}")
            }
            return try response(request, "{\"items\":[{\"track\":\(Self.song)}],\"next\":null}")
        })
        let songs = try await api.fetchPlaylistSongs(id: "p1")
        #expect(songs.map(\.id) == ["s1", "s1"])
        #expect(count == 2)
        var context = MenuContext()
        context.spotify.playlists = [SpotifyLibraryPlaylist(id: "p1", name: "Test", uri: "spotify:playlist:p1")]
        context.spotifyPlaylistContents["p1"] = SpotifyPlaylistContents(songs: songs, state: .ready)
        let rows = MenuBuilder.items(for: .spotifyPlaylist("p1"), context: context)
        #expect(rows.map(\.title) == ["Play All", "Song", "Song", "Refresh Playlist"])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows[0].action == .playSpotify("spotify:playlist:p1"))
        #expect(rows[1].action == .playSpotify("spotify:track:s1"))
    }

    @Test func playlistFailureProvidesRetryAndKeepsOtherLibraryData() async {
        let api = SpotifyLibraryAPI(token: { _ in "test" }, transport: { request in
            try response(request, "{}", status: 403)
        })
        let library = SpotifyLibrary(api: api)
        await library.loadPlaylist(id: "p1")
        var context = MenuContext()
        context.spotify.playlists = [SpotifyLibraryPlaylist(id: "p1", name: "Test", uri: "spotify:playlist:p1")]
        context.spotifyPlaylistContents = library.playlistContents
        let rows = MenuBuilder.items(for: .spotifyPlaylist("p1"), context: context)
        #expect(rows.contains { $0.action == .refreshSpotifyPlaylist("p1") })
        #expect(rows.first?.action == .playSpotify("spotify:playlist:p1"))
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
        #expect(MenuBuilder.items(for: .playlists, context: context).first?.action == .push(.spotifyPlaylist(playlist.id)))
        let unavailableJSON = Self.song.dropLast() + #", "is_playable":false}"#
        let unavailable = try decoder.decode(SpotifyLibrarySong.self, from: Data(unavailableJSON.utf8))
        context.spotify.songs = [unavailable]
        #expect(MenuBuilder.items(for: .songs, context: context).first { $0.id == song.uri }?.action == MenuAction.none)
    }
}
