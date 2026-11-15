import Foundation

/// Where the user stands with Apple Music. Pure value; `AppleMusicService` owns the live one.
nonisolated enum AppleMusicStatus: Equatable, Sendable {
    /// Never asked for access.
    case notDetermined
    /// Asking for access or checking the subscription.
    case checking
    case denied
    case restricted
    /// Access granted, but the account can't play catalog songs.
    case noSubscription
    case ready
    case failed(String)
}

/// An artist or album from a search; opening it lists its songs.
nonisolated struct AppleMusicCollection: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case artist, album }

    let kind: Kind
    let catalogID: String
    let title: String
    var subtitle: String?
    var artworkURL: URL?

    var id: String { (kind == .artist ? "artist:" : "album:") + catalogID }
}

/// The latest search.
nonisolated struct AppleMusicSearch: Equatable, Sendable {
    var term = ""
    var isLoading = false
    var error: String?
    var songs: [Track] = []
    var artists: [AppleMusicCollection] = []
    var albums: [AppleMusicCollection] = []

    var isEmpty: Bool { songs.isEmpty && artists.isEmpty && albums.isEmpty }
}

/// Songs of an opened artist (top songs) or album.
nonisolated enum AppleMusicLoad: Equatable, Sendable {
    case loading
    case loaded([Track])
    case failed(String)
}
