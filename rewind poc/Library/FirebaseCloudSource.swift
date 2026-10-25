import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseStorage

/// Streams songs stored under `music/` in Firebase Storage.
///
/// Title, artist, album and duration come from the file's own tags (read over the network
/// once, then kept in `CloudTagCache`). Storage custom metadata keys `title`, `artist`,
/// `album` and `duration` override the tags; the file name is the last resort.
@Observable
final class FirebaseCloudSource: CloudMusicSource {
    static let rootFolder = "music"

    private(set) var state = CloudState.idle
    private(set) var tracks: [Track] = []

    @ObservationIgnored private let cache = CloudCache()
    @ObservationIgnored private let tagCache = CloudTagCache()

    /// How many files have their tags read at once on a refresh.
    private nonisolated static let tagReadConcurrency = 6

    /// Configures Firebase if GoogleService-Info.plist is bundled. Returns false if it isn't,
    /// in which case Firebase must not be touched at all.
    static func configureIfPossible() -> Bool {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return false }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        return true
    }

    func refresh() async {
        guard state != .loading else { return }
        state = .loading
        do {
            if Auth.auth().currentUser == nil {
                _ = try await Auth.auth().signInAnonymously()
            }
            let paths = try await Self.listAudioPaths(under: Self.rootFolder)
            let loaded = await Self.loadTracks(paths: paths, cache: cache, tagCache: tagCache)
            tracks = loaded.sorted { Track.sortKey($0.title) < Track.sortKey($1.title) }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func playableURL(for track: Track) async throws -> URL {
        guard case .cloud(let path) = track.source else { throw URLError(.unsupportedURL) }
        if let cached = cache.cachedFile(forPath: path) { return cached }
        if Auth.auth().currentUser == nil {
            _ = try await Auth.auth().signInAnonymously()
        }
        let url = try await Self.downloadURL(path: path)
        cache.store(remote: url, forPath: path)
        return url
    }

    // MARK: Storage calls (off the main actor)

    @concurrent
    private nonisolated static func listAudioPaths(under folder: String) async throws -> [String] {
        let result = try await Storage.storage().reference(withPath: folder).listAll()
        var paths = result.items.map(\.fullPath).filter { Track.isAudioFile($0) }
        for prefix in result.prefixes {               // one level of sub-folders, e.g. music/Album/
            let sub = try await Storage.storage().reference(withPath: prefix.fullPath).listAll()
            paths += sub.items.map(\.fullPath).filter { Track.isAudioFile($0) }
        }
        return paths
    }

    private struct Loaded: Sendable {
        var path: String
        var track: Track
        var entry: CloudTagCache.Entry?
    }

    @concurrent
    private nonisolated static func loadTracks(paths: [String], cache: CloudCache, tagCache: CloudTagCache) async -> [Track] {
        let known = tagCache.load()
        var entries: [String: CloudTagCache.Entry] = [:]
        var tracks: [Track] = []
        await withTaskGroup(of: Loaded.self) { group in
            var remaining = paths[...]
            func addNext() {
                guard let path = remaining.popFirst() else { return }
                group.addTask { await load(path: path, known: known[path], cache: cache) }
            }
            for _ in 0..<tagReadConcurrency { addNext() }
            for await loaded in group {
                tracks.append(loaded.track)
                entries[loaded.path] = loaded.entry
                addNext()
            }
        }
        tagCache.save(entries)   // also drops entries for files that are gone
        return tracks
    }

    private nonisolated static func load(path: String, known: CloudTagCache.Entry?, cache: CloudCache) async -> Loaded {
        let fileName = (path as NSString).lastPathComponent
        let ref = Storage.storage().reference(withPath: path)
        let meta = try? await ref.getMetadata()
        let stamp = meta.flatMap { $0.md5Hash ?? $0.updated.map { "\($0.timeIntervalSince1970)" } }

        var entry: CloudTagCache.Entry?
        if let known, known.stamp == stamp {
            entry = known
        } else if let stamp {
            // New or replaced in Storage: any copy we cached when it was played is stale.
            cache.remove(forPath: path)
            // AVAsset fetches just the tag bytes it needs, not the whole song.
            var tags: TrackMetadata.Info?
            if let remote = try? await ref.downloadURL() {
                tags = await TrackMetadata.read(remote)
            }
            // A failed read comes back empty; don't cache that, so the next refresh retries.
            if let tags, tags.title != nil || tags.artist != nil || tags.duration > 0 {
                entry = CloudTagCache.Entry(stamp: stamp, info: tags)
            }
        }

        let info = TrackMetadata.merge(custom: meta?.customMetadata ?? [:], tags: entry?.info)
        return Loaded(path: path,
                      track: TrackMetadata.makeTrack(info: info, fileName: fileName, source: .cloud(path: path)),
                      entry: entry)
    }

    @concurrent
    private nonisolated static func downloadURL(path: String) async throws -> URL {
        try await Storage.storage().reference(withPath: path).downloadURL()
    }
}
