import Foundation

nonisolated enum CloudState: Equatable, Sendable {
    case notConfigured
    case idle
    case loading
    case ready
    case failed(String)
}

/// A remote song catalog. Firebase Storage today; swap in anything that can list
/// tracks and hand back a playable URL.
protocol CloudMusicSource: AnyObject {
    var state: CloudState { get }
    var tracks: [Track] { get }
    /// Signs in if needed and re-lists the catalog.
    func refresh() async
    /// A URL AVPlayer can play: a cached file if we have one, otherwise a streaming URL.
    func playableURL(for track: Track) async throws -> URL
}

/// Used when GoogleService-Info.plist is missing: the app runs, Cloud says "not configured".
@Observable
final class UnconfiguredCloudSource: CloudMusicSource {
    let state = CloudState.notConfigured
    let tracks: [Track] = []
    func refresh() async {}
    func playableURL(for track: Track) async throws -> URL { throw URLError(.unsupportedURL) }
}

/// Disk cache for cloud tracks that have been played, in Caches/CloudMusic.
nonisolated struct CloudCache: Sendable {
    let folder: URL

    init(folder: URL = URL.cachesDirectory.appending(path: "CloudMusic", directoryHint: .isDirectory)) {
        self.folder = folder
    }

    /// Flattens "music/sub/Song.mp3" to "music_sub_Song.mp3".
    func fileURL(forPath path: String) -> URL {
        folder.appending(path: path.replacingOccurrences(of: "/", with: "_"))
    }

    func cachedFile(forPath path: String) -> URL? {
        let url = fileURL(forPath: path)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Downloads in the background; failures are ignored (we just stream next time).
    func store(remote: URL, forPath path: String) {
        let destination = fileURL(forPath: path)
        let folder = folder
        Task.detached(priority: .background) {
            guard let (temp, response) = try? await URLSession.shared.download(from: remote),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: temp, to: destination)
        }
    }
}
