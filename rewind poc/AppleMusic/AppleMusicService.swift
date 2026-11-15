import Foundation
import MusicKit

/// Apple Music access, subscription state, catalog search and song lookup (MusicKit).
/// Playback itself lives in `PlaybackEngine`, which asks this for `Song`s.
@Observable
final class AppleMusicService {
    private(set) var status: AppleMusicStatus
    private(set) var results = AppleMusicSearch()
    /// Keyed by `AppleMusicCollection.id`.
    private(set) var collections: [String: AppleMusicLoad] = [:]

    /// Catalog songs seen so far, by catalog ID, so playback doesn't refetch them.
    @ObservationIgnored private var songs: [String: Song] = [:]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?

    /// MusicKit caps catalog search at 25 per type.
    static let searchLimit = 25
    static let rowArtworkSize = 120
    static let nowPlayingArtworkSize = 600

    init() {
        status = Self.status(for: MusicAuthorization.currentStatus)
    }

    /// At launch: if access was granted earlier, check the subscription without prompting.
    func start() {
        if MusicAuthorization.currentStatus == .authorized { watchSubscription() }
    }

    /// Shows the system permission prompt (first time only), then checks the subscription.
    func connect() async {
        status = .checking
        let auth = await MusicAuthorization.request()
        if auth == .authorized {
            watchSubscription()
        } else {
            status = Self.status(for: auth)
        }
    }

    func search(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, status == .ready else { return }
        searchTask?.cancel()
        results = AppleMusicSearch(term: term, isLoading: true)
        searchTask = Task { [weak self] in
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Artist.self, Album.self])
            request.limit = Self.searchLimit
            do {
                let response = try await request.response()
                guard let self, !Task.isCancelled else { return }
                self.remember(response.songs)
                self.results = AppleMusicSearch(
                    term: term,
                    songs: response.songs.map(Self.track),
                    artists: response.artists.map {
                        AppleMusicCollection(kind: .artist, catalogID: $0.id.rawValue, title: $0.name,
                                             artworkURL: Self.artworkURL($0.artwork, size: Self.rowArtworkSize))
                    },
                    albums: response.albums.map {
                        AppleMusicCollection(kind: .album, catalogID: $0.id.rawValue, title: $0.title,
                                             subtitle: $0.artistName,
                                             artworkURL: Self.artworkURL($0.artwork, size: Self.rowArtworkSize))
                    })
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.results = AppleMusicSearch(term: term, error: "Search failed: \(error.localizedDescription)")
            }
        }
    }

    /// Loads an artist's top songs or an album's tracks into `collections`.
    func loadCollection(_ collection: AppleMusicCollection) {
        switch collections[collection.id] {
        case .loading?, .loaded?: return
        case .failed?, nil: break
        }
        collections[collection.id] = .loading
        Task { [weak self] in
            do {
                let found = try await Self.fetchSongs(of: collection)
                guard let self else { return }
                self.remember(found)
                self.collections[collection.id] = .loaded(found.map(Self.track))
            } catch {
                self?.collections[collection.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// `Song`s for Apple Music tracks, in the same order. Unknown IDs are fetched in one request.
    func songs(for tracks: [Track]) async throws -> [Song] {
        let ids = tracks.compactMap(\.appleMusicID)
        let missing = Array(Set(ids.filter { songs[$0] == nil }))
        if !missing.isEmpty {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: missing.map { MusicItemID($0) })
            let response = try await request.response()
            remember(response.items)
        }
        return ids.compactMap { songs[$0] }
    }

    // MARK: Private

    private func watchSubscription() {
        subscriptionTask?.cancel()
        status = .checking
        subscriptionTask = Task { [weak self] in
            do {
                let current = try await MusicSubscription.current
                self?.apply(current)
            } catch {
                self?.status = .failed(error.localizedDescription)
                return
            }
            // Keeps up if the user subscribes or cancels while the app is open.
            for await subscription in MusicSubscription.subscriptionUpdates {
                guard let self, !Task.isCancelled else { return }
                self.apply(subscription)
            }
        }
    }

    private func apply(_ subscription: MusicSubscription) {
        status = subscription.canPlayCatalogContent ? .ready : .noSubscription
    }

    private func remember<S: Sequence>(_ found: S) where S.Element == Song {
        for song in found { songs[song.id.rawValue] = song }
    }

    private static func fetchSongs(of collection: AppleMusicCollection) async throws -> [Song] {
        let id = MusicItemID(collection.catalogID)
        switch collection.kind {
        case .album:
            let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: id)
            guard let album = try await request.response().items.first else { return [] }
            let tracks = try await album.with([.tracks]).tracks ?? []
            return tracks.compactMap { (item: MusicKit.Track) -> Song? in
                if case .song(let song) = item { song } else { nil }
            }
        case .artist:
            let request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: id)
            guard let artist = try await request.response().items.first else { return [] }
            let detailed = try await artist.with([.topSongs])
            return Array(detailed.topSongs ?? [])
        }
    }

    private static func track(_ song: Song) -> Track {
        Track(title: song.title, artist: song.artistName, album: song.albumTitle, duration: song.duration ?? 0,
              source: .appleMusic(id: song.id.rawValue),
              artworkURL: artworkURL(song.artwork, size: nowPlayingArtworkSize))
    }

    private static func artworkURL(_ artwork: Artwork?, size: Int) -> URL? {
        artwork?.url(width: size, height: size)
    }

    private static func status(for auth: MusicAuthorization.Status) -> AppleMusicStatus {
        switch auth {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .checking
        @unknown default: .denied
        }
    }
}
