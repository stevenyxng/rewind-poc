import Foundation
import Observation

nonisolated struct SpotifyLibraryArtist: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
}

nonisolated struct SpotifyLibrarySong: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artists: [SpotifyLibraryArtist]
    let is_playable: Bool?
    let is_local: Bool?

    var canPlay: Bool { is_playable != false && is_local != true && uri.hasPrefix("spotify:track:") }
}

nonisolated struct SpotifyLibraryPlaylist: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
}

nonisolated struct SpotifyLibraryAlbum: Decodable, Sendable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artists: [SpotifyLibraryArtist]
    var songs: [SpotifyLibrarySong] = []

    private enum CodingKeys: String, CodingKey { case id, name, uri, artists }
}

nonisolated struct SpotifySavedAlbum: Decodable, Sendable {
    let album: SpotifyLibraryAlbum?
}

nonisolated enum SpotifyLibraryState: Equatable, Sendable {
    case disconnected, loading, ready, failed(String)
}

nonisolated struct SpotifyLibrarySnapshot: Sendable {
    var songs: [SpotifyLibrarySong] = []
    var artists: [SpotifyLibraryArtist] = []
    var playlists: [SpotifyLibraryPlaylist] = []
    var albums: [SpotifyLibraryAlbum] = []
}

nonisolated enum SpotifyLibraryError: LocalizedError {
    case invalidResponse, forbidden, rateLimited(Int), server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Spotify returned an unexpected library response."
        case .forbidden: "Spotify denied library access. Check your app's Spotify access settings."
        case .rateLimited(let seconds): "Spotify is busy. Try again in \(seconds) seconds."
        case .server(let status): "Couldn't load Spotify library (HTTP \(status))."
        }
    }
}

nonisolated struct SpotifyPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item?]
    let next: String?
}

nonisolated struct SpotifySavedSong: Decodable, Sendable {
    let track: SpotifyLibrarySong?

    private enum CodingKeys: String, CodingKey { case track }
    private enum TrackKeys: String, CodingKey { case id, uri }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.track), try !container.decodeNil(forKey: .track) else {
            track = nil
            return
        }
        let item = try container.nestedContainer(keyedBy: TrackKeys.self, forKey: .track)
        // Removed and Spotify-local files may have no catalog ID and cannot play by track URI.
        guard let id = try item.decodeIfPresent(String.self, forKey: .id), !id.isEmpty,
              let uri = try item.decodeIfPresent(String.self, forKey: .uri), uri.hasPrefix("spotify:track:") else {
            track = nil
            return
        }
        track = try container.decode(SpotifyLibrarySong.self, forKey: .track)
    }
}

nonisolated struct SpotifyPlaylistItem: Decodable, Sendable {
    let song: SpotifyLibrarySong?
    private enum CodingKeys: String, CodingKey { case item, track, is_local }
    private enum ItemKeys: String, CodingKey { case id, uri }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key: CodingKeys = container.contains(.item) ? .item : .track
        guard try container.decodeIfPresent(Bool.self, forKey: .is_local) != true,
              container.contains(key), try !container.decodeNil(forKey: key) else {
            song = nil
            return
        }
        let item = try container.nestedContainer(keyedBy: ItemKeys.self, forKey: key)
        guard let id = try item.decodeIfPresent(String.self, forKey: .id), !id.isEmpty,
              let uri = try item.decodeIfPresent(String.self, forKey: .uri),
              uri.hasPrefix("spotify:track:") else {
            song = nil
            return
        }
        song = try container.decode(SpotifyLibrarySong.self, forKey: key)
    }
}

nonisolated struct SpotifyPlaylistContents: Sendable {
    var songs: [SpotifyLibrarySong] = []
    var state: SpotifyLibraryState = .loading
}

nonisolated struct SpotifyArtistPage: Decodable, Sendable {
    let artists: SpotifyPage<SpotifyLibraryArtist>
}

/// Injectable transport keeps paging, authorization recovery and rate limiting testable.
@MainActor
final class SpotifyLibraryAPI {
    typealias TokenProvider = @MainActor (Bool) async throws -> String
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let token: TokenProvider
    private let transport: Transport
    private var retryAfter: Date?

    init(token: @escaping TokenProvider, transport: Transport? = nil) {
        self.token = token
        if let transport {
            self.transport = transport
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: configuration)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw SpotifyLibraryError.invalidResponse }
                return (data, response)
            }
        }
    }

    func fetchLibrary() async throws -> SpotifyLibrarySnapshot {
        let saved: [SpotifySavedSong] = try await pages(path: "/v1/me/tracks?limit=50") { data in
            try JSONDecoder().decode(SpotifyPage<SpotifySavedSong>.self, from: data)
        }
        let savedAlbums: [SpotifySavedAlbum] = try await pages(path: "/v1/me/albums?limit=50") {
            try JSONDecoder().decode(SpotifyPage<SpotifySavedAlbum>.self, from: $0)
        }
        var albums = unique(savedAlbums.compactMap(\.album))
        for index in albums.indices {
            let id = albums[index].id
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw SpotifyLibraryError.invalidResponse
            }
            // Fetch every page rather than relying on the album's embedded track preview.
            albums[index].songs = try await pages(path: "/v1/albums/\(id)/tracks?limit=50") {
                try JSONDecoder().decode(SpotifyPage<SpotifyLibrarySong>.self, from: $0)
            }
        }
        let songs = unique(saved.compactMap(\.track) + albums.flatMap(\.songs))
        let artists = songs.flatMap(\.artists) + albums.flatMap(\.artists)
        let playlists: [SpotifyLibraryPlaylist] = try await pages(path: "/v1/me/playlists?limit=50") { data in
            try JSONDecoder().decode(SpotifyPage<SpotifyLibraryPlaylist>.self, from: data)
        }
        return SpotifyLibrarySnapshot(
            songs: songs.sorted { Track.sortKey($0.name) < Track.sortKey($1.name) },
            artists: unique(artists).sorted { Track.sortKey($0.name) < Track.sortKey($1.name) },
            playlists: unique(playlists).sorted { Track.sortKey($0.name) < Track.sortKey($1.name) },
            albums: albums.sorted { Track.sortKey($0.name) < Track.sortKey($1.name) }
        )
    }

    func fetchPlaylistSongs(id: String) async throws -> [SpotifyLibrarySong] {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw SpotifyLibraryError.invalidResponse
        }
        let items: [SpotifyPlaylistItem] = try await pages(path: "/v1/playlists/\(id)/items?limit=50") {
            try JSONDecoder().decode(SpotifyPage<SpotifyPlaylistItem>.self, from: $0)
        }
        // Preserve playlist order and repeated songs.
        return items.compactMap(\.song)
    }

    private func unique<T: Identifiable>(_ items: [T]) -> [T] {
        var ids = Set<T.ID>()
        return items.filter { ids.insert($0.id).inserted }
    }

    private func pages<T: Decodable & Sendable>(
        path: String, decode: (Data) throws -> SpotifyPage<T>
    ) async throws -> [T] {
        var next: String? = "https://api.spotify.com" + path
        var visited = Set<String>()
        var results: [T] = []
        let expectedPath = URLComponents(string: path)?.path
        while let address = next {
            try Task.checkCancellation()
            guard visited.insert(address).inserted,
                  let url = URL(string: address),
                  url.scheme == "https", url.host == "api.spotify.com",
                  url.port == nil || url.port == 443,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.path == expectedPath else { throw SpotifyLibraryError.invalidResponse }
            let data = try await get(url)
            let page: SpotifyPage<T>
            do { page = try decode(data) }
            catch { throw SpotifyLibraryError.invalidResponse }
            results.append(contentsOf: page.items.compactMap { $0 })
            next = page.next
        }
        return results
    }

    private func get(_ url: URL) async throws -> Data {
        if let retryAfter, retryAfter > Date() {
            throw SpotifyLibraryError.rateLimited(Int(ceil(retryAfter.timeIntervalSinceNow)))
        }
        for attempt in 0...1 {
            var request = URLRequest(url: url)
            request.setValue("Bearer " + (try await token(attempt == 1)), forHTTPHeaderField: "Authorization")
            let (data, response) = try await transport(request)
            switch response.statusCode {
            case 200: return data
            case 401:
                if attempt == 1 { throw SpotifyAuthError.signInRequired }
            case 403: throw SpotifyLibraryError.forbidden
            case 429:
                let delay = max(1, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30)
                retryAfter = Date().addingTimeInterval(Double(delay))
                throw SpotifyLibraryError.rateLimited(delay)
            default: throw SpotifyLibraryError.server(response.statusCode)
            }
        }
        throw SpotifyAuthError.signInRequired
    }
}

@MainActor
@Observable
final class SpotifyLibrary {
    private(set) var playlistContents: [String: SpotifyPlaylistContents] = [:]
    private(set) var snapshot = SpotifyLibrarySnapshot()
    private(set) var state = SpotifyLibraryState.disconnected
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let api: SpotifyLibraryAPI

    init(api: SpotifyLibraryAPI) { self.api = api }

    /// Loads playlist tracks even if their song lists have never been opened.
    /// A playlist denied by Spotify is excluded; network/auth failures abort rather than bias the pool.
    func songsForShuffle() async throws -> (songs: [SpotifyLibrarySong], skippedPlaylists: Int) {
        guard state != .loading else { throw SpotifyAuthError.busy }
        if state == .disconnected { return ([], 0) }
        if case .failed = state { throw SpotifyLibraryError.invalidResponse }
        var songs = snapshot.songs
        var skipped = 0
        for playlist in snapshot.playlists {
            try Task.checkCancellation()
            do {
                let tracks = try await api.fetchPlaylistSongs(id: playlist.id)
                playlistContents[playlist.id] = SpotifyPlaylistContents(songs: tracks, state: .ready)
                songs += tracks
            } catch SpotifyLibraryError.forbidden {
                skipped += 1
            }
        }
        onChange?()
        return (songs, skipped)
    }

    func loadPlaylist(id: String) async {
        guard playlistContents[id]?.state != .loading else { return }
        var contents = playlistContents[id] ?? SpotifyPlaylistContents()
        contents.state = .loading
        playlistContents[id] = contents
        defer { onChange?() }
        do {
            contents.songs = try await api.fetchPlaylistSongs(id: id)
            contents.state = .ready
        } catch SpotifyAuthError.signInRequired {
            contents = SpotifyPlaylistContents(state: .disconnected)
        } catch let error as SpotifyLibraryError {
            contents.state = .failed(error.localizedDescription)
        } catch {
            contents.state = .failed("Couldn't load playlist. Please try again.")
        }
        playlistContents[id] = contents
    }

    func refresh() async {
        guard state != .loading else { return }
        state = .loading
        defer { onChange?() }
        do {
            let updated = try await api.fetchLibrary()
            try Task.checkCancellation()
            snapshot = updated
            state = .ready
        } catch SpotifyAuthError.signInRequired {
            playlistContents = [:]
            snapshot = SpotifyLibrarySnapshot()
            state = .disconnected
        } catch SpotifyAuthError.missingPermissions {
            playlistContents = [:]
            snapshot = SpotifyLibrarySnapshot()
            state = .disconnected
        } catch is CancellationError {
            state = .failed("Spotify library refresh was cancelled.")
        } catch let error as SpotifyLibraryError {
            state = .failed(error.localizedDescription)
        } catch {
            state = .failed("Couldn't load Spotify. Check your connection and try again.")
        }
    }
}
