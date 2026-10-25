import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseStorage

/// Streams songs stored under `music/` in Firebase Storage.
///
/// Per-file metadata comes from Storage custom metadata keys `title`, `artist`, `album`
/// and `duration` (seconds) when present, otherwise from the file name.
@Observable
final class FirebaseCloudSource: CloudMusicSource {
    static let rootFolder = "music"

    private(set) var state = CloudState.idle
    private(set) var tracks: [Track] = []

    @ObservationIgnored private let cache = CloudCache()

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
            let loaded = await Self.loadTracks(paths: paths)
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

    @concurrent
    private nonisolated static func loadTracks(paths: [String]) async -> [Track] {
        await withTaskGroup(of: Track.self) { group in
            for path in paths {
                group.addTask { await track(forPath: path) }
            }
            var tracks: [Track] = []
            for await track in group { tracks.append(track) }
            return tracks
        }
    }

    private nonisolated static func track(forPath path: String) async -> Track {
        let fileName = (path as NSString).lastPathComponent
        let custom = (try? await Storage.storage().reference(withPath: path).getMetadata())?.customMetadata ?? [:]
        let info = TrackMetadata.Info(title: custom["title"],
                                      artist: custom["artist"],
                                      album: custom["album"],
                                      duration: Double(custom["duration"] ?? "") ?? 0)
        return TrackMetadata.makeTrack(info: info, fileName: fileName, source: .cloud(path: path))
    }

    @concurrent
    private nonisolated static func downloadURL(path: String) async throws -> URL {
        try await Storage.storage().reference(withPath: path).downloadURL()
    }
}
