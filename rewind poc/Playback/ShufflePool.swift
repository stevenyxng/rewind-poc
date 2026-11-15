import Foundation

nonisolated enum ShuffleSong: Equatable, Sendable {
    case local(Track)
    case spotify(SpotifyLibrarySong)
}

/// One entry per local file or Spotify track, regardless of how many playlists contain it.
nonisolated enum ShufflePool {
    static func songs(local: [Track], spotify: [SpotifyLibrarySong]) -> [ShuffleSong] {
        var localIDs = Set<Track.ID>()
        var spotifyURIs = Set<String>()
        let localSongs = local.filter { localIDs.insert($0.id).inserted }.map(ShuffleSong.local)
        let spotifySongs = spotify.filter { $0.canPlay && spotifyURIs.insert($0.uri).inserted }
            .map(ShuffleSong.spotify)
        return localSongs + spotifySongs
    }

    static func pick<G: RandomNumberGenerator>(from songs: [ShuffleSong], using rng: inout G) -> ShuffleSong? {
        songs.randomElement(using: &rng)
    }
}
