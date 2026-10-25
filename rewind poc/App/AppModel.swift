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

    private(set) var nowPlaying = NowPlayingWheelState()
    /// Playhead while scrubbing (the player's own time lags behind seeks).
    private(set) var scrubPosition: Double?
    /// Volume bar shows briefly after the wheel changes volume, then the progress bar returns.
    private(set) var volumeBarVisible = false
    /// Transient status line ("Imported 3 songs").
    private(set) var message: String?
    var showingImporter = false

    /// Haptics Lab: a strip of test detents to spin through.
    static let labDetentCount = 24
    private(set) var labDetent = 0

    @ObservationIgnored let clickSound = ClickSound()
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored private var scrubTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var volumeBarTask: Task<Void, Never>?
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
        #if DEBUG
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
        await cloud.refresh()
    }

    var menuContext: MenuContext {
        MenuContext(localTracks: library.tracks,
                    cloudTracks: cloud.tracks,
                    cloudState: cloud.state,
                    hasNowPlaying: player.hasTrack,
                    clickSound: settings.clickSound,
                    haptics: settings.haptics,
                    shuffle: settings.shuffle,
                    repeatMode: settings.repeatMode,
                    version: Self.version)
    }

    var title: String { MenuBuilder.title(for: navigator.screen, context: menuContext) }

    // MARK: Wheel events

    func handle(_ event: WheelEvent) {
        switch event {
        case .touchDown(let button):
            haptics.prepare()
            // The center button clicks on press-down (it can't become a spin). Ring buttons
            // click on release, once we know the touch wasn't the start of a spin.
            if button == .center { haptics.button(.center) }
        case .rotationBegan:
            if usesDetentRamp { haptics.beginRamp() }
        case .rotation(let progress):
            if usesDetentRamp { haptics.updateRamp(progress: progress) }
        case .rotationEnded:
            haptics.endRamp()
        case .tick(let direction, let rate):
            tick(direction, rate: rate)
        case .press(let button):
            press(button)
        case .holdBegan(let button):
            haptics.button(button)
            player.beginFastSeek(forward: button == .next)
        case .holdEnded:
            player.endFastSeek()
        }
    }

    /// Menus (and the Lab's test strip) get the tension ramp; Now Playing uses discrete clicks only.
    private var usesDetentRamp: Bool { navigator.screen != .nowPlaying }

    private func tick(_ direction: TickDirection, rate: Double) {
        switch navigator.screen {
        case .nowPlaying:
            nowPlaying.noteWheelInput(at: clock())
            switch nowPlaying.mode {
            case .volume: volumeTick(direction)
            case .scrub: scrubTick(direction, rate: rate)
            }
        case .hapticsLab:
            let target = labDetent + direction.sign
            if (0..<Self.labDetentCount).contains(target) {
                labDetent = target
                haptics.detent()
                clickSound.play()
            } else {
                haptics.wall()
            }
        default:
            switch navigator.move(direction) {
            case .moved:
                haptics.detent()
                clickSound.play()
            case .wall:
                haptics.wall()
            }
        }
    }

    private func volumeTick(_ direction: TickDirection) {
        let (volume, feedback) = VolumeStepper.apply(direction, to: player.volume)
        let changed = volume != player.volume
        player.setVolume(volume)
        switch feedback {
        case .step(let level): haptics.volumeStep(level: level)
        case .limit: haptics.volumeLimit()
        }
        if changed { clickSound.play() }
        showVolumeBar()
    }

    private func scrubTick(_ direction: TickDirection, rate: Double) {
        scheduleScrubTimeout()
        guard player.hasTrack, player.duration > 0 else {
            haptics.wall()
            return
        }
        let (position, feedback) = Scrubber.step(from: scrubPosition ?? player.currentTime, direction, rate: rate,
                                                 duration: player.duration, spacing: haptics.tuning[.scrubSpacing])
        scrubPosition = position
        player.seek(to: position)
        switch feedback {
        case .none: break
        case .tick: haptics.scrubTick(rate: rate); clickSound.play()
        case .mark: haptics.scrubMark(); clickSound.play()
        case .wall: haptics.wall()
        }
    }

    private func press(_ button: WheelButton) {
        if button != .center { haptics.button(button) }
        switch button {
        case .menu:
            if navigator.screen == .nowPlaying { leaveNowPlayingModes() }
            navigator.back()
        case .center:
            centerPressed()
        case .playPause:
            player.togglePlayPause()
        case .next:
            player.nextTrack()
        case .previous:
            player.previousTrack()
        }
    }

    private func centerPressed() {
        switch navigator.screen {
        case .nowPlaying:
            nowPlaying.pressCenter(at: clock())
            if nowPlaying.mode == .scrub {
                scrubPosition = player.currentTime
                volumeBarVisible = false
                scheduleScrubTimeout()
            } else {
                leaveNowPlayingModes()
            }
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
            if screen == .nowPlaying { leaveNowPlayingModes() }
        case .play(let tracks, let index):
            player.play(tracks, startAt: index, shuffled: settings.shuffle, repeatMode: settings.repeatMode)
            openNowPlaying()
        case .shuffleAll:
            let all = menuContext.allTracks
            guard !all.isEmpty else {
                haptics.wall()
                show("No songs yet. Import some in Settings.")
                return
            }
            player.play(all, startAt: Int.random(in: all.indices), shuffled: true, repeatMode: settings.repeatMode)
            openNowPlaying()
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
        case .none:
            break
        }
    }

    private func apply(_ toggle: SettingToggle) {
        switch toggle {
        case .clickSound:
            settings.clickSound.toggle()
            clickSound.isEnabled = settings.clickSound
        case .haptics:
            settings.haptics.toggle()
            haptics.isEnabled = settings.haptics
        case .shuffle:
            settings.shuffle.toggle()
            player.setShuffle(settings.shuffle)
        case .repeatMode:
            settings.repeatMode = settings.repeatMode.next
            player.setRepeat(settings.repeatMode)
        }
    }

    private func openNowPlaying() {
        leaveNowPlayingModes()
        navigator.removeScreens { $0 == .nowPlaying }
        navigator.push(.nowPlaying)
    }

    private func leaveNowPlayingModes() {
        nowPlaying.reset()
        scrubPosition = nil
        scrubTimeoutTask?.cancel()
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

    private func scheduleScrubTimeout() {
        scrubTimeoutTask?.cancel()
        scrubTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NowPlayingWheelState.scrubTimeout) + .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            if self.nowPlaying.expireIfIdle(at: self.clock()) { self.scrubPosition = nil }
        }
    }

    private func showVolumeBar() {
        volumeBarVisible = true
        volumeBarTask?.cancel()
        volumeBarTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.volumeBarVisible = false
        }
    }

    func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
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
