import Foundation

/// The persisted list of local tracks (a JSON file). Pure value type so it's easy to test.
nonisolated struct LibraryIndex: Codable, Equatable, Sendable {
    var version = 1
    private(set) var tracks: [Track] = []

    init(tracks: [Track] = []) {
        self.tracks = tracks
    }

    /// Missing or unreadable index -> empty library (never crash on a bad file).
    static func load(from url: URL) -> LibraryIndex {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(LibraryIndex.self, from: data) else { return LibraryIndex() }
        return index
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Adds a track, or replaces the existing one with the same id.
    mutating func upsert(_ track: Track) {
        if let i = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[i] = track
        } else {
            tracks.append(track)
        }
    }

    @discardableResult
    mutating func remove(id: Track.ID) -> Track? {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return nil }
        return tracks.remove(at: i)
    }

    func track(id: Track.ID) -> Track? {
        tracks.first { $0.id == id }
    }

    /// Drops entries whose file no longer exists.
    mutating func prune(keepingFileNames existing: Set<String>) {
        tracks.removeAll { track in
            if case .local(let name) = track.source { return !existing.contains(name) }
            return false
        }
    }

    /// Picks a file name that doesn't collide with `taken`: "Song.mp3" -> "Song 2.mp3".
    static func uniqueFileName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension, ext = ns.pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}
