import Foundation

/// Wires the pieces together: turns wheel events into navigation, playback and haptics.
@Observable
final class AppModel {
    let settings: AppSettings
    let haptics: HapticsEngine
    let player: PlaybackEngine
    let library: LocalLibrary
    let cloud: any CloudMusicSource
    let navigator = MenuNavigator()
    let tutorial = Tutorial()
    let spotifyManager = SpotifyManager()

    /// Playhead while scrubbing (the player's own time lags behind seeks); nil once the wheel settles.
    private(set) var scrubPosition: Double?
    /// Transient status line ("Imported 3 songs").
    private(set) var message: String?
    private(set) var isPreparingShuffle = false
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    var showingImporter = false

    /// Haptics Lab: a strip of test detents to spin through.
    static let labDetentCount = 24
    private(set) var labDetent = 0

    @ObservationIgnored let clickSound = ClickSound()
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private var scrubSettleTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    init(settings: AppSettings, haptics: HapticsEngine, player: PlaybackEngine,
         library: LocalLibrary, cloud: any CloudMusicSource) {
        self.settings = settings
        self.haptics = haptics
        self.player = player
        self.library = library
        self.cloud = cloud

        haptics.isEnabled = settings.haptics
        clickSound.isEnabled = settings.clickSound
        navigator.itemsProvider = { [unowned self] screen in
            MenuBuilder.items(for: screen, context: menuContext)
        }
        player.urlResolver = { [unowned self] track in try await playableURL(for: track) }
        spotifyManager.onError = { [weak self] message in self?.show(message) }
        spotifyManager.library.onChange = { [weak self] in self?.navigator.clampCurrent() }
        tutorial.onFinish = { [unowned self] in
            settings.tutorialSeen = true
            presentDefaultPlayback()
        }
    }

    /// Production wiring. Firebase is only touched if GoogleService-Info.plist is bundled.
    static func live() -> AppModel {
        let cloud: any CloudMusicSource = FirebaseCloudSource.configureIfPossible()
            ? FirebaseCloudSource() : UnconfiguredCloudSource()
        return AppModel(settings: AppSettings(), haptics: HapticsEngine(), player: PlaybackEngine(),
                        library: LocalLibrary(), cloud: cloud)
    }

    func start() async {
        await library.reconcile()
        navigator.clampCurrent()
        if !settings.tutorialSeen { startTutorial() }
        #if DEBUG
        // `-showTutorial YES` replays the walkthrough on every launch.
        if UserDefaults.standard.bool(forKey: "showTutorial") { startTutorial() }
        // Screenshot/debug hook: launch with `-demoNowPlaying YES` to start the first song.
        if UserDefaults.standard.bool(forKey: "demoNowPlaying"), !menuContext.allTracks.isEmpty {
            perform(.play(menuContext.allTracks, index: 0))
        }
        // `-demoHapticsLab YES` opens Settings > Haptics Lab.
        if UserDefaults.standard.bool(forKey: "demoHapticsLab") {
            navigator.push(.settings)
            navigator.push(.hapticsLab)
        }
        #endif
        async let spotifyRefresh: Void = spotifyManager.library.refresh()
        await cloud.refresh()
        await spotifyRefresh
    }

    var hasNowPlaying: Bool {
        player.hasTrack || (spotifyManager.isConnected && spotifyManager.trackURI != nil)
    }

    func presentDefaultPlayback() {
        guard !tutorial.isActive, !showingImporter else { return }
        navigator.presentPlaybackIfPreferred(hasTrack: hasNowPlaying)
    }

    func becameActive() {
        guard !tutorial.isActive, !showingImporter else { return }
        navigator.preferPlayback(hasTrack: hasNowPlaying)
    }

    var menuContext: MenuContext {
        MenuContext(localTracks: library.tracks,
                    cloudTracks: cloud.tracks,
                    cloudState: cloud.state,
                    spotify: spotifyManager.library.snapshot,
                    spotifyState: spotifyManager.library.state,
                    spotifyPlaylistContents: spotifyManager.library.playlistContents,
                    hasNowPlaying: hasNowPlaying,
                    clickSound: settings.clickSound,
                    haptics: settings.haptics,
                    shuffle: spotifyManager.isConnected ? spotifyManager.isShuffling : settings.shuffle,
                    repeatMode: spotifyManager.isConnected ? spotifyManager.repeatMode : settings.repeatMode,
                    appearance: settings.appearance,
                    version: Self.version)
    }


    // MARK: Wheel events

    func handle(_ event: WheelEvent) {
        if tutorial.handle(event) { return }
        switch event {
        case .touchDown(let button):
            haptics.prepare()
            // The center button clicks on press-down (it can't become a spin). Ring buttons
            // click on release, once we know the touch wasn't the start of a spin.
            if button == .center { buttonClick(.center) }
        case .rotationBegan, .rotation, .rotationEnded:
            break                       // only whole detents (ticks) matter
        case .tick(let direction, let rate):
            tick(direction, rate: rate)
        case .press(let button):
            press(button)
        case .holdBegan(let button):
            buttonClick(button)
            if spotifyManager.isConnected {
                spotifyManager.beginFastSeek(forward: button == .next)
            } else {
                player.beginFastSeek(forward: button == .next)
            }
        case .holdEnded:
            spotifyManager.endFastSeek()
            player.endFastSeek()
        }
    }

    private func tick(_ direction: TickDirection, rate: Double) {
        switch navigator.screen {
        case .nowPlaying:
            endScrub()
            navigator.revealMainMenu()
            haptics.detent()
            clickSound.play()
        case .hapticsLab:
            let target = labDetent + direction.sign
            if (0..<Self.labDetentCount).contains(target) {
                labDetent = target
                haptics.detent()
                clickSound.play()
            }
        default:
            // At either end of a list the wheel just stops: no haptic, no wrap-around.
            if navigator.move(direction) == .moved {
                haptics.detent()
                clickSound.play()
            }
        }
    }

    private func scrubTick(_ direction: TickDirection, rate: Double) {
        guard !spotifyManager.isConnected else { return }
        scheduleScrubSettle()
        guard player.hasTrack, player.duration > 0 else { return }
        let from = scrubPosition ?? player.currentTime
        let (position, feedback) = Scrubber.step(from: from, direction, rate: rate,
                                                 duration: player.duration, spacing: haptics.tuning[.scrubSpacing])
        guard position != from else { return }      // already at the start or end
        scrubPosition = position
        player.seek(to: position)
        switch feedback {
        case .none: break
        case .tick: haptics.scrubTick(rate: rate); clickSound.play()
        case .mark: haptics.scrubMark(); clickSound.play()
        case .wall: break               // arrived at the start or end
        }
    }

    /// Button feedback: haptic plus the click sound (when it's on).
    private func buttonClick(_ button: WheelButton) {
        haptics.button(button)
        clickSound.play()
    }

    private func press(_ button: WheelButton) {
        if button != .center { buttonClick(button) }
        switch button {
        case .menu:
            if navigator.screen == .nowPlaying {
                endScrub()
                navigator.revealMainMenu()
            } else if navigator.screen == .main, hasNowPlaying {
                openNowPlaying()
            } else {
                navigator.back()
            }
        case .center:
            centerPressed()
        case .playPause:
            if spotifyManager.isConnected { spotifyManager.perform(.togglePlayPause) }
            else { player.togglePlayPause() }
        case .next:
            if spotifyManager.isConnected { spotifyManager.perform(.next) }
            else { player.nextTrack() }
        case .previous:
            if spotifyManager.isConnected { spotifyManager.perform(.previous) }
            else { player.previousTrack() }
        }
    }

    private func centerPressed() {
        switch navigator.screen {
        case .nowPlaying:
            if spotifyManager.isConnected { spotifyManager.perform(.togglePlayPause) }
            else { player.togglePlayPause() }
        case .hapticsLab:
            break
        default:
            perform(navigator.select())
        }
    }

    // MARK: Actions

    func perform(_ action: MenuAction) {
        switch action {
        case .push(let screen):
            if screen == .nowPlaying { endScrub() }
            if case .spotifyPlaylist(let id) = screen {
                Task { await spotifyManager.library.loadPlaylist(id: id) }
            }
        case .play(let tracks, let index):
            selectionTask?.cancel()
            selectionTask = Task {
                guard await spotifyManager.yieldToLocalPlayback(), !Task.isCancelled else { return }
                player.play(tracks, startAt: index, shuffled: settings.shuffle, repeatMode: settings.repeatMode)
                openNowPlaying()
            }
        case .shuffleAll:
            guard !isPreparingShuffle else { return }
            selectionTask?.cancel()
            selectionTask = Task { await shuffleFromAllSources() }
        case .toggle(let toggle):
            apply(toggle)
        case .importFiles:
            showingImporter = true
        case .delete(let id):
            delete(id)
        case .back:
            navigator.back()
        case .refreshCloud:
            Task { await cloud.refresh() }
        case .playSpotify(let uri):
            selectionTask?.cancel()
            selectionTask = Task {
                player.stop()
                if await spotifyManager.play(uri: uri), !Task.isCancelled { openNowPlaying() }
            }
        case .refreshSpotifyPlaylist(let id):
            Task { await spotifyManager.library.loadPlaylist(id: id) }
        case .refreshSpotify:
            Task { await spotifyManager.library.refresh() }
        case .connectSpotify:
            Task {
                await spotifyManager.connectLibraryAndPlayback()
            }
        case .startTutorial:
            startTutorial()
        case .none:
            break
        }
    }

    private func shuffleFromAllSources() async {
        isPreparingShuffle = true
        defer { isPreparingShuffle = false }
        show("Preparing shuffle…")
        do {
            let spotify = try await spotifyManager.library.songsForShuffle()
            try Task.checkCancellation()
            let local = menuContext.allTracks
            let pool = ShufflePool.songs(local: local, spotify: spotify.songs)
            var rng = SystemRandomNumberGenerator()
            guard let selected = ShufflePool.pick(from: pool, using: &rng) else {
                show("No playable songs. Add music or connect Spotify.")
                return
            }
            switch selected {
            case .local(let track):
                guard let index = local.firstIndex(where: { $0.id == track.id }),
                      await spotifyManager.yieldToLocalPlayback(), !Task.isCancelled else { return }
                player.play(local, startAt: index, shuffled: true, repeatMode: settings.repeatMode)
                openNowPlaying()
            case .spotify(let song):
                player.stop()
                let result = await spotifyManager.playShuffleSelection(uri: song.uri)
                guard !Task.isCancelled else { return }
                switch result {
                case .playing:
                    openNowPlaying()
                case .onDemandRestricted:
                    let restriction = "You have run out of on-demand track selection as a Spotify Free member"
                    // Fallback uses imported local files, not another Spotify request or cloud stream.
                    let fallback = library.tracks.filter {
                        if case .local = $0.source { return true }
                        return false
                    }
                    guard let track = fallback.randomElement(),
                          let index = fallback.firstIndex(where: { $0.id == track.id }) else {
                        show(restriction + "\nNo local songs are available. Add local music to continue.", duration: 8)
                        return
                    }
                    guard await spotifyManager.yieldToLocalPlayback(), !Task.isCancelled else { return }
                    player.play(fallback, startAt: index, shuffled: true, repeatMode: settings.repeatMode)
                    openNowPlaying()
                    show(restriction, duration: 6)
                    return // Keep the explanation visible after starting local playback.
                case .failed:
                    return
                }
            }
            if spotify.skippedPlaylists > 0 {
                show("Shuffled available songs; Spotify denied access to \(spotify.skippedPlaylists) playlists.")
            } else {
                message = nil
            }
        } catch is CancellationError {
            // A newer song selection supersedes this request.
        } catch SpotifyAuthError.busy {
            show("Spotify library is still loading. Try Shuffle Songs again shortly.")
        } catch let error as SpotifyAuthError {
            show(error.localizedDescription)
        } catch let error as SpotifyLibraryError {
            show(error.localizedDescription)
        } catch {
            show("Couldn't prepare shuffle. Check your connection and try again.")
        }
    }

    private func apply(_ toggle: SettingToggle) {
        switch toggle {
        case .appearance:
            settings.appearance = settings.appearance.next
        case .clickSound:
            settings.clickSound.toggle()
            clickSound.isEnabled = settings.clickSound
        case .haptics:
            settings.haptics.toggle()
            haptics.isEnabled = settings.haptics
        case .shuffle:
            if spotifyManager.isConnected {
                spotifyManager.perform(.shuffle)
            } else {
                settings.shuffle.toggle()
                player.setShuffle(settings.shuffle)
            }
        case .repeatMode:
            if spotifyManager.isConnected {
                spotifyManager.perform(.repeatMode)
            } else {
                settings.repeatMode = settings.repeatMode.next
                player.setRepeat(settings.repeatMode)
            }
        }
    }

    /// Starts the walkthrough from the main menu, where every step makes sense.
    func startTutorial() {
        navigator.pop(to: .main)
        tutorial.start()
    }

    private func openNowPlaying() {
        endScrub()
        navigator.showNowPlaying()
    }

    private func endScrub() {
        scrubPosition = nil
        scrubSettleTask?.cancel()
    }

    private func delete(_ id: Track.ID) {
        if player.currentTrack?.id == id {
            player.stop()
            navigator.removeScreens { $0 == .nowPlaying }
        }
        do {
            try library.delete(id)
            show("Deleted")
        } catch {
            show("Couldn't delete: \(error.localizedDescription)")
        }
        navigator.removeScreens { $0 == .localTrack(id) || $0 == .confirmDelete(id) }
    }

    func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            Task {
                let r = await library.importFiles(urls)
                navigator.clampCurrent()
                var text = "Imported \(r.imported) song\(r.imported == 1 ? "" : "s")"
                if !r.failed.isEmpty { text += ", \(r.failed.count) failed" }
                show(text)
            }
        case .failure(let error):
            show("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private func playableURL(for track: Track) async throws -> URL {
        switch track.source {
        case .local:
            guard let url = library.fileURL(for: track), FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw URLError(.fileDoesNotExist)
            }
            return url
        case .cloud:
            return try await cloud.playableURL(for: track)
        }
    }

    private func scheduleScrubSettle() {
        scrubSettleTask?.cancel()
        scrubSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Scrubber.settleDelay))
            guard !Task.isCancelled else { return }
            self?.scrubPosition = nil
        }
    }

    func show(_ text: String, duration: Double = 2.5) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }()
}
