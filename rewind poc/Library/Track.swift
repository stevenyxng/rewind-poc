import Foundation

/// One song, from any source.
nonisolated struct Track: Identifiable, Codable, Hashable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        /// File name inside Documents/Music.
        case local(fileName: String)
        /// Full path in Firebase Storage, e.g. "music/song.mp3".
        case cloud(path: String)
    }

    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"

    let id: String
    var title: String
    var artist: String
    var album: String
    /// Seconds; 0 if unknown (cloud tracks without metadata learn it when played).
    var duration: Double
    let source: Source

    init(title: String, artist: String? = nil, album: String? = nil, duration: Double = 0, source: Source) {
        switch source {
        case .local(let name): id = "local:" + name
        case .cloud(let path): id = "cloud:" + path
        }
        self.title = title
        self.artist = artist.nonEmpty ?? Self.unknownArtist
        self.album = album.nonEmpty ?? Self.unknownAlbum
        self.duration = duration
        self.source = source
    }

    var isLocal: Bool { if case .local = source { true } else { false } }

    /// Human title derived from a file name: "02_My_Song.mp3" -> "02 My Song".
    static func title(fromFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let cleaned = base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? name : cleaned
    }

    /// Splits "Artist - Title" file names. Returns nil if there's no " - ".
    static func artistAndTitle(fromFileName name: String) -> (artist: String, title: String)? {
        let title = title(fromFileName: name)
        let parts = title.components(separatedBy: " - ")
        guard parts.count >= 2 else { return nil }
        let artist = parts[0].trimmingCharacters(in: .whitespaces)
        let rest = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !rest.isEmpty else { return nil }
        return (artist, rest)
    }

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf", "mp4"]

    static func isAudioFile(_ name: String) -> Bool {
        audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

nonisolated extension Optional where Wrapped == String {
    /// The trimmed string, or nil if missing/blank.
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

nonisolated extension Track {
    static func sortKey(_ s: String) -> String {
        let lower = s.lowercased()
        return lower.hasPrefix("the ") ? String(lower.dropFirst(4)) : lower
    }
}
