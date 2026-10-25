import Foundation

/// Every screen the display can show.
nonisolated enum Screen: Hashable, Sendable {
    case main
    case music, songs, artists, albums
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
    case clickSound, haptics, shuffle, repeatMode
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
    var hasNowPlaying = false
    var clickSound = false
    var haptics = true
    var shuffle = false
    var repeatMode = RepeatMode.off
    var version = ""

    var allTracks: [Track] {
        (localTracks + cloudTracks).sorted { Track.sortKey($0.title) < Track.sortKey($1.title) }
    }
}

/// Pure functions from (screen, context) to title and rows.
nonisolated enum MenuBuilder {
    static func title(for screen: Screen, context: MenuContext) -> String {
        switch screen {
        case .main: "PodPlayer"
        case .music: "Music"
        case .songs: "Songs"
        case .artists: "Artists"
        case .albums: "Albums"
        case .artist(let name), .artistSongs(let name): name
        case .album(let name): name
        case .localFiles: "Local Files"
        case .localTrack(let id): context.localTracks.first { $0.id == id }?.title ?? "Song"
        case .confirmDelete: "Delete?"
        case .cloud: "Cloud"
        case .settings: "Settings"
        case .hapticsLab: "Haptics Lab"
        case .about: "About"
        case .nowPlaying: "Now Playing"
        }
    }

    static func items(for screen: Screen, context c: MenuContext) -> [MenuItem] {
        switch screen {
        case .main:
            var items = [MenuItem(id: "music", title: "Music", action: .push(.music))]
            if c.hasNowPlaying {
                items.append(MenuItem(id: "nowPlaying", title: "Now Playing", action: .push(.nowPlaying)))
            }
            items.append(MenuItem(id: "shuffle", title: "Shuffle Songs", action: .shuffleAll))
            items.append(MenuItem(id: "settings", title: "Settings", action: .push(.settings)))
            return items

        case .music:
            return [
                MenuItem(id: "songs", title: "Songs", action: .push(.songs)),
                MenuItem(id: "artists", title: "Artists", action: .push(.artists)),
                MenuItem(id: "albums", title: "Albums", action: .push(.albums)),
                MenuItem(id: "local", title: "Local Files", action: .push(.localFiles)),
                MenuItem(id: "cloud", title: "Cloud", action: .push(.cloud)),
            ]

        case .songs:
            let tracks = c.allTracks
            guard !tracks.isEmpty else { return [placeholder("No songs yet")] }
            return songRows(tracks)

        case .artists:
            let artists = Set(c.allTracks.map(\.artist)).sorted { Track.sortKey($0) < Track.sortKey($1) }
            guard !artists.isEmpty else { return [placeholder("No artists")] }
            return artists.map { MenuItem(id: "artist:" + $0, title: $0, action: .push(.artist($0))) }

        case .artist(let artist):
            let tracks = c.allTracks.filter { $0.artist == artist }
            let albums = Set(tracks.map(\.album)).sorted { Track.sortKey($0) < Track.sortKey($1) }
            return [MenuItem(id: "all", title: "All Songs", action: .push(.artistSongs(artist)))]
                + albums.map { MenuItem(id: "album:" + $0, title: $0, action: .push(.album($0))) }

        case .artistSongs(let artist):
            return songRows(c.allTracks.filter { $0.artist == artist })

        case .albums:
            let albums = Set(c.allTracks.map(\.album)).sorted { Track.sortKey($0) < Track.sortKey($1) }
            guard !albums.isEmpty else { return [placeholder("No albums")] }
            return albums.map { MenuItem(id: "album:" + $0, title: $0, action: .push(.album($0))) }

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
                MenuItem(id: "click", title: "Click Sound", detail: onOff(c.clickSound), action: .toggle(.clickSound)),
                MenuItem(id: "haptics", title: "Haptics", detail: onOff(c.haptics), action: .toggle(.haptics)),
                MenuItem(id: "lab", title: "Haptics Lab", action: .push(.hapticsLab)),
                MenuItem(id: "shuffle", title: "Shuffle", detail: onOff(c.shuffle), action: .toggle(.shuffle)),
                MenuItem(id: "repeat", title: "Repeat", detail: c.repeatMode.label, action: .toggle(.repeatMode)),
                MenuItem(id: "import", title: "Import Files", action: .importFiles),
                MenuItem(id: "about", title: "About", action: .push(.about)),
            ]

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

    private static func songRows(_ tracks: [Track]) -> [MenuItem] {
        tracks.enumerated().map { i, t in MenuItem(id: t.id, title: t.title, action: .play(tracks, index: i)) }
    }

    private static func placeholder(_ text: String) -> MenuItem {
        MenuItem(id: "placeholder:" + text, title: text, action: .none)
    }

    private static func onOff(_ on: Bool) -> String { on ? "On" : "Off" }
}
