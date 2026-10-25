import AVFoundation
import UIKit

/// Reads tags and artwork from audio files (local or remote) with AVAsset.
nonisolated enum TrackMetadata {
    struct Info: Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double
    }

    static func read(_ url: URL) async -> Info {
        let asset = AVURLAsset(url: url)
        var info = Info(duration: 0)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            info.duration = duration.seconds
        }
        guard let items = try? await asset.load(.commonMetadata) else { return info }
        info.title = await string(items, .commonIdentifierTitle)
        info.artist = await string(items, .commonIdentifierArtist)
        info.album = await string(items, .commonIdentifierAlbumName)
        return info
    }

    static func artwork(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue) else { return nil }
        return UIImage(data: data)
    }

    /// Builds a Track from file tags, falling back to the file name ("Artist - Title.mp3" is understood).
    static func makeTrack(info: Info, fileName: String, source: Track.Source) -> Track {
        let parsed = Track.artistAndTitle(fromFileName: fileName)
        return Track(title: info.title.nonEmpty ?? parsed?.title ?? Track.title(fromFileName: fileName),
                     artist: info.artist.nonEmpty ?? parsed?.artist,
                     album: info.album,
                     duration: info.duration,
                     source: source)
    }

    private static func string(_ items: [AVMetadataItem], _ id: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
        return try? await item.load(.stringValue)
    }
}
