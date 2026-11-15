import Foundation

/// Every screen the display can show.
nonisolated enum Screen: Hashable, Sendable {
    case main
    case music, songs, artists, albums, playlists
    case spotifyArtist(String)
    case spotifyPlaylist(String)
    case spotifyAlbum(String)
    case artist(String)
    case artistSongs(String)
    case album(String)
    case localFiles
    case localTrack(Track.ID)
    case confirmDelete(Track.ID)
    case cloud
    case settings, hapticsLab, about
    case nowPlaying
}

nonisolated enum SettingToggle: Equatable, Sendable {
    case appearance, clickSound, haptics, shuffle, repeatMode
}

/// What selecting a row does. `push` is handled by the navigator; everything else by `AppModel`.
nonisolated enum MenuAction: Equatable, Sendable {
    case push(Screen)
    case play([Track], index: Int)
    case shuffleAll
    case toggle(SettingToggle)
    case importFiles
    case delete(Track.ID)
    case back
    case refreshCloud
    case startTutorial
    case connectSpotify
    case disconnectSpotify
    case refreshSpotify
    case refreshSpotifyPlaylist(String)
    case playSpotify(String)
    case none
}

nonisolated struct MenuItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var detail: String?
    let action: MenuAction

    var showsChevron: Bool {
        if case .push = action { true } else { false }
    }
}

/// Everything the menus need to know about the rest of the app, as a plain snapshot.
nonisolated struct MenuContext: Sendable {
    var localTracks: [Track] = []
    var cloudTracks: [Track] = []
    var cloudState: CloudState = .notConfigured
    var spotify = SpotifyLibrarySnapshot()
    var spotifyState = SpotifyLibraryState.disconnected
    var spotifyLinked = false
    var spotifyPlaylistContents: [String: SpotifyPlaylistContents] = [:]
    var hasNowPlaying = false
    var clickSound = true
    var haptics = true
    var shuffle = false
    var repeatMode = RepeatMode.off
    var appearance = Appearance.system
    var version = ""

    var allTracks: [Track] {
        (localTracks + cloudTracks).sorted { Track.sortKey($0.title) < Track.sortKey($1.title) }
    }
}

/// Pure functions from (screen, context) to rows.
nonisolated enum MenuBuilder {
    static func items(for screen: Screen, context c: MenuContext) -> [MenuItem] {
        switch screen {
        case .main:
            var items = [MenuItem(id: "music", title: "Music", action: .push(.music))]
            items.append(MenuItem(id: "shuffle", title: "Shuffle Songs", action: .shuffleAll))
            items.append(MenuItem(id: "settings", title: "Settings", action: .push(.settings)))
            items.append(MenuItem(id: "nowPlaying", title: "Currently Playing", action: .push(.nowPlaying)))
            return items

        case .music:
            return [
                MenuItem(id: "songs", title: "Songs", action: .push(.songs)),
                MenuItem(id: "artists", title: "Artists", action: .push(.artists)),
                MenuItem(id: "albums", title: "Albums", action: .push(.albums)),
                MenuItem(id: "playlists", title: "Playlists", action: .push(.playlists)),
                MenuItem(id: "local", title: "Local Files", action: .push(.localFiles)),
                MenuItem(id: "cloud", title: "Cloud", action: .push(.cloud)),
            ]

        case .songs:
            let rows = (songRows(c.allTracks) + spotifySongRows(c.spotify.songs))
                .sorted { Track.sortKey($0.title) < Track.sortKey($1.title) }
            return rows + spotifyFooter(c.spotifyState, hasRows: !rows.isEmpty, empty: "No songs yet")

        case .artists:
            let artists = Set(c.allTracks.map(\.artist)).sorted { Track.sortKey($0) < Track.sortKey($1) }
            let local = artists.map { MenuItem(id: "artist:" + $0, title: $0, action: .push(.artist($0))) }
            let spotify = c.spotify.artists.map {
                MenuItem(id: $0.uri, title: $0.name, detail: "Spotify", action: .push(.spotifyArtist($0.id)))
            }
            let rows = (local + spotify).sorted { Track.sortKey($0.title) < Track.sortKey($1.title) }
            return rows + spotifyFooter(c.spotifyState, hasRows: !rows.isEmpty, empty: "No artists")

        case .playlists:
            let rows = c.spotify.playlists.map {
                MenuItem(id: $0.uri, title: $0.name, detail: "Spotify", action: .push(.spotifyPlaylist($0.id)))
            }
            return rows + spotifyFooter(c.spotifyState, hasRows: !rows.isEmpty, empty: "No Spotify playlists")

        case .spotifyPlaylist(let id):
            guard let playlist = c.spotify.playlists.first(where: { $0.id == id }) else {
                return [placeholder("Playlist no longer in library")]
            }
            let contents = c.spotifyPlaylistContents[id] ?? SpotifyPlaylistContents()
            var rows = [MenuItem(id: "playAll", title: "Play All", action: .playSpotify(playlist.uri))]
            rows += contents.songs.enumerated().map { index, song in
                MenuItem(id: "playlist:\(id):\(index)", title: song.name,
                         detail: song.canPlay ? song.artists.map(\.name).joined(separator: ", ") : "Unavailable",
                         action: song.canPlay ? .playSpotify(song.uri) : .none)
            }
            switch contents.state {
            case .loading: rows.append(placeholder("Loading playlist…"))
            case .ready:
                if contents.songs.isEmpty { rows.append(placeholder("No supported songs in playlist")) }
                rows.append(MenuItem(id: "refresh", title: "Refresh Playlist", action: .refreshSpotifyPlaylist(id)))
            case .disconnected:
                rows.append(MenuItem(id: "connect", title: "Connect to Spotify", action: .connectSpotify))
            case .failed(let message):
                rows.append(placeholder(message))
                rows.append(MenuItem(id: "retry", title: "Retry Playlist", action: .refreshSpotifyPlaylist(id)))
            }
            return rows

        case .spotifyArtist(let id):
            let albumSongIDs = Set(c.spotify.albums
                .filter { $0.artists.contains(where: { $0.id == id }) }
                .flatMap(\.songs).map(\.id))
            let songs = c.spotify.songs.filter {
                albumSongIDs.contains($0.id) || $0.artists.contains(where: { $0.id == id })
            }
            return songs.isEmpty ? [placeholder("No songs by this artist")] : spotifySongRows(songs)

        case .artist(let artist):
            let tracks = c.allTracks.filter { $0.artist == artist }
            let albums = Set(tracks.map(\.album)).sorted { Track.sortKey($0) < Track.sortKey($1) }
            return [MenuItem(id: "all", title: "All Songs", action: .push(.artistSongs(artist)))]
                + albums.map { MenuItem(id: "album:" + $0, title: $0, action: .push(.album($0))) }

        case .artistSongs(let artist):
            return songRows(c.allTracks.filter { $0.artist == artist })

        case .albums:
            let albums = Set(c.allTracks.map(\.album)).sorted { Track.sortKey($0) < Track.sortKey($1) }
            let local = albums.map { MenuItem(id: "album:" + $0, title: $0, action: .push(.album($0))) }
            let spotify = c.spotify.albums.map {
                MenuItem(id: $0.uri, title: $0.name, detail: "Spotify", action: .push(.spotifyAlbum($0.id)))
            }
            let rows = (local + spotify).sorted { Track.sortKey($0.title) < Track.sortKey($1.title) }
            return rows + spotifyFooter(c.spotifyState, hasRows: !rows.isEmpty, empty: "No albums")

        case .spotifyAlbum(let id):
            guard let album = c.spotify.albums.first(where: { $0.id == id }) else {
                return [placeholder("Album no longer in library")]
            }
            return [MenuItem(id: "playAll", title: "Play All", action: .playSpotify(album.uri))]
                + spotifySongRows(album.songs)

        case .album(let album):
            // Album order isn't in our metadata, so keep title order.
            return songRows(c.allTracks.filter { $0.album == album })

        case .localFiles:
            let tracks = c.localTracks.sorted { Track.sortKey($0.title) < Track.sortKey($1.title) }
            guard !tracks.isEmpty else {
                return [MenuItem(id: "import", title: "Import Files…", action: .importFiles)]
            }
            return tracks.map { MenuItem(id: $0.id, title: $0.title, detail: nil, action: .push(.localTrack($0.id))) }

        case .localTrack(let id):
            guard let track = c.localTracks.first(where: { $0.id == id }) else { return [] }
            let siblings = c.localTracks.sorted { Track.sortKey($0.title) < Track.sortKey($1.title) }
            let index = siblings.firstIndex(of: track) ?? 0
            return [
                MenuItem(id: "play", title: "Play", action: .play(siblings, index: index)),
                MenuItem(id: "artist", title: track.artist, action: .none),
                MenuItem(id: "album", title: track.album, action: .none),
                MenuItem(id: "delete", title: "Delete", action: .push(.confirmDelete(id))),
            ]

        case .confirmDelete(let id):
            return [
                MenuItem(id: "cancel", title: "Cancel", action: .back),
                MenuItem(id: "delete", title: "Delete Song", action: .delete(id)),
            ]

        case .cloud:
            switch c.cloudState {
            case .notConfigured:
                return [placeholder("Cloud not configured")]
            case .idle, .loading:
                return [placeholder("Loading…")]
            case .failed(let message):
                return [placeholder("Couldn't load: \(message)"),
                        MenuItem(id: "retry", title: "Try Again", action: .refreshCloud)]
            case .ready:
                let tracks = c.cloudTracks
                let refresh = MenuItem(id: "refresh", title: "Refresh", action: .refreshCloud)
                guard !tracks.isEmpty else { return [placeholder("No songs in music/"), refresh] }
                return songRows(tracks) + [refresh]
            }

        case .settings:
            return [
                MenuItem(id: "appearance", title: "Appearance", detail: c.appearance.label, action: .toggle(.appearance)),
                MenuItem(id: "click", title: "Click Sound", detail: onOff(c.clickSound), action: .toggle(.clickSound)),
                MenuItem(id: "haptics", title: "Haptics", detail: onOff(c.haptics), action: .toggle(.haptics)),
                MenuItem(id: "lab", title: "Haptics Lab", action: .push(.hapticsLab)),
                MenuItem(id: "shuffle", title: "Shuffle", detail: onOff(c.shuffle), action: .toggle(.shuffle)),
                MenuItem(id: "repeat", title: "Repeat", detail: c.repeatMode.label, action: .toggle(.repeatMode)),
                MenuItem(id: "import", title: "Import Files", action: .importFiles),
                MenuItem(id: "spotify", title: c.spotifyLinked ? "Disconnect from Spotify" : "Connect to Spotify",
                         action: c.spotifyLinked ? .disconnectSpotify : .connectSpotify),
                MenuItem(id: "tutorial", title: "Tutorial", action: .startTutorial),
                MenuItem(id: "about", title: "About", action: .push(.about)),
            ] + (c.spotifyLinked ? [MenuItem(id: "spotifyRefresh", title: "Refresh Spotify Library", action: .refreshSpotify)] : [])

        case .about:
            let cloud: String = switch c.cloudState {
            case .notConfigured: "Not configured"
            case .ready: "\(c.cloudTracks.count) songs"
            case .failed: "Error"
            case .idle, .loading: "Loading"
            }
            return [
                MenuItem(id: "version", title: "Version", detail: c.version, action: .none),
                MenuItem(id: "local", title: "Local Songs", detail: "\(c.localTracks.count)", action: .none),
                MenuItem(id: "cloud", title: "Cloud", detail: cloud, action: .none),
            ]

        case .hapticsLab, .nowPlaying:
            return []        // custom screens
        }
    }

    /// Resolve playable rows in their displayed order, including duplicate playlist entries.
    static func playbackRows(for screen: Screen, context: MenuContext) -> [(row: Int, song: ShuffleSong)] {
        let spotify = context.spotify.songs + context.spotifyPlaylistContents.values.flatMap(\.songs)
        return items(for: screen, context: context).enumerated().compactMap { row, item in
            switch item.action {
            case .play(let tracks, let index):
                guard tracks.indices.contains(index) else { return nil }
                return (row, .local(tracks[index]))
            case .playSpotify(let uri):
                guard let song = spotify.first(where: { $0.uri == uri && $0.canPlay }) else { return nil }
                return (row, .spotify(song))
            default: return nil
            }
        }
    }

    private static func spotifySongRows(_ songs: [SpotifyLibrarySong]) -> [MenuItem] {
        songs.map {
            MenuItem(id: $0.uri, title: $0.name, detail: $0.canPlay ? "Spotify" : "Unavailable",
                     action: $0.canPlay ? .playSpotify($0.uri) : .none)
        }
    }

    private static func spotifyFooter(_ state: SpotifyLibraryState, hasRows: Bool, empty: String) -> [MenuItem] {
        switch state {
        case .disconnected:
            return hasRows ? [] : [
                placeholder(empty),
                MenuItem(id: "spotifyConnect", title: "Connect to Spotify", action: .connectSpotify)
            ]
        case .loading:
            return [placeholder("Loading Spotify…")]
        case .failed(let message):
            return [placeholder(message),
                    MenuItem(id: "spotifyRetry", title: "Retry Spotify Library", action: .refreshSpotify),
                    MenuItem(id: "spotifyConnect", title: "Connect to Spotify", action: .connectSpotify)]
        case .ready:
            return (hasRows ? [] : [placeholder(empty)])
                + [MenuItem(id: "spotifyRefresh", title: "Refresh Spotify Library", action: .refreshSpotify)]
        }
    }

    private static func songRows(_ tracks: [Track]) -> [MenuItem] {
        tracks.enumerated().map { i, t in MenuItem(id: t.id, title: t.title, action: .play(tracks, index: i)) }
    }

    private static func placeholder(_ text: String) -> MenuItem {
        MenuItem(id: "placeholder:" + text, title: text, action: .none)
    }

    private static func onOff(_ on: Bool) -> String { on ? "On" : "Off" }
}
