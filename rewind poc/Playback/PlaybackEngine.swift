import AVFoundation
import MediaPlayer
import MusicKit
import UIKit

/// Playback, independent of the UI: queue, shuffle/repeat, audio session, interruptions,
/// lock screen / Control Center. File tracks play through AVPlayer; Apple Music tracks
/// through MusicKit's `ApplicationMusicPlayer` (in-app, not the Music app's player).
@Observable
final class PlaybackEngine {
    private(set) var queue = PlaybackQueue()
    /// Play intent (what the user asked for), which is what the UI shows.
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var artwork: UIImage?
    private(set) var errorMessage: String?

    var currentTrack: Track? { queue.current }
    var hasTrack: Bool { queue.current != nil }

    /// Turns a track into a URL AVPlayer can open (local file, cache, or stream).
    @ObservationIgnored var urlResolver: ((Track) async throws -> URL)?
    /// Supplies MusicKit `Song`s for Apple Music tracks.
    @ObservationIgnored var appleMusic: AppleMusicService?

    /// Restart the current track instead of going back if we're past this point.
    static let restartThreshold: Double = 3

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var fastSeekTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    @ObservationIgnored private let musicPlayer = ApplicationMusicPlayer.shared
    /// True while `musicPlayer` holds our queue (the current track is Apple Music).
    @ObservationIgnored private var appleMusicActive = false
    @ObservationIgnored private var appleMusicPoll: Task<Void, Never>?
    @ObservationIgnored private var lastMusicStatus: MusicKit.MusicPlayer.PlaybackStatus?
    /// Set while our own load or skip is in flight, so the poll doesn't snap back to the old song.
    @ObservationIgnored private var appleMusicPending = false

    init() {
        configureSession()
        observePlayer()
        observeSession()
        configureRemoteCommands()
    }

    // MARK: Transport

    func play(_ tracks: [Track], startAt index: Int, shuffled: Bool, repeatMode: RepeatMode) {
        let previous = queue.current
        queue.load(tracks, startAt: index, shuffled: shuffled)
        queue.repeatMode = repeatMode
        guard let track = queue.current else { return }
        let sameTrack = track.id == previous?.id && errorMessage == nil
        if track.isAppleMusic {
            loadAppleMusic(autoplay: true, keepPosition: sameTrack && appleMusicActive)
            return
        }
        // Picking the song that's already loaded keeps its position (and resumes if paused);
        // only the queue around it is replaced.
        if sameTrack, player.currentItem != nil {
            if !isPlaying { play() }
            updateNowPlayingInfo()
            return
        }
        load(track, autoplay: true)
    }

    func play() {
        guard hasTrack else { return }
        if queue.current?.isAppleMusic == true {
            // Not loaded yet, or the player ran off the end of its queue.
            guard appleMusicActive, musicPlayer.queue.currentEntry != nil,
                  musicPlayer.state.playbackStatus != .stopped else {
                loadAppleMusic(autoplay: true, keepPosition: appleMusicActive && currentTime < duration - 1)
                return
            }
            isPlaying = true
            errorMessage = nil
            Task { [weak self] in
                do { try await self?.musicPlayer.play() } catch { self?.appleMusicFailed(error) }
            }
            return
        }
        if player.currentItem == nil, let track = queue.current {
            load(track, autoplay: true)
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        errorMessage = nil
        updateNowPlayingInfo()
    }

    func pause() {
        if appleMusicActive { musicPlayer.pause() } else { player.pause() }
        isPlaying = false
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Returns false at the end of the queue (nothing to skip to).
    @discardableResult
    func nextTrack() -> Bool {
        guard let track = queue.advance(userInitiated: true) else { return false }
        if track.isAppleMusic, appleMusicActive {
            skipAppleMusic(to: track, forward: true)
        } else if track.isAppleMusic {
            loadAppleMusic(autoplay: isPlaying, keepPosition: false)
        } else {
            load(track, autoplay: isPlaying)
        }
        return true
    }

    /// Restarts the track if past `restartThreshold`, otherwise goes to the previous one.
    func previousTrack() {
        let before = queue.current?.id
        if currentTime > Self.restartThreshold {
            seek(to: 0)
        } else if let track = queue.retreat(), track.id != before {
            if track.isAppleMusic, appleMusicActive {
                skipAppleMusic(to: track, forward: false)
            } else if track.isAppleMusic {
                loadAppleMusic(autoplay: isPlaying, keepPosition: false)
            } else {
                load(track, autoplay: isPlaying)
            }
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? duration : seconds
        let target = min(max(seconds, 0), upper)
        currentTime = target
        if appleMusicActive {
            musicPlayer.playbackTime = target
        } else {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                        toleranceBefore: CMTime(value: 1, timescale: 10), toleranceAfter: CMTime(value: 1, timescale: 10))
        }
        updateNowPlayingInfo()
    }

    /// Press-and-hold previous/next: jumps every 0.2s, accelerating after 2s (≈10x, then 25x).
    func beginFastSeek(forward: Bool) {
        guard hasTrack else { return }
        fastSeekTask?.cancel()
        fastSeekTask = Task { [weak self] in
            var elapsed: Double = 0
            while !Task.isCancelled, let self {
                let step = elapsed < 2 ? 2.0 : 5.0
                let target = self.currentTime + (forward ? step : -step)
                if forward, self.duration > 0, target >= self.duration - 0.5 { break }
                self.seek(to: target)
                if !forward, target <= 0 { break }
                try? await Task.sleep(for: .milliseconds(200))
                elapsed += 0.2
            }
        }
    }

    func endFastSeek() {
        fastSeekTask?.cancel()
        fastSeekTask = nil
    }

    func setShuffle(_ on: Bool) {
        queue.setShuffle(on)
        // The Apple Music player plays our order, so hand it the new one (same song, same spot).
        if appleMusicActive { loadAppleMusic(autoplay: isPlaying, keepPosition: true) }
        updateNowPlayingInfo()
    }

    func setRepeat(_ mode: RepeatMode) {
        queue.repeatMode = mode
        if appleMusicActive { musicPlayer.state.repeatMode = Self.musicRepeatMode(mode) }
    }

    /// Stops and clears the queue (e.g. the playing track was deleted).
    func stop() {
        stopAppleMusic()
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = PlaybackQueue()
        isPlaying = false
        currentTime = 0
        duration = 0
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Loading

    private func load(_ track: Track, autoplay: Bool) {
        stopAppleMusic()
        loadToken += 1
        let token = loadToken
        endFastSeek()
        currentTime = 0
        duration = track.duration
        artwork = nil
        errorMessage = nil
        isPlaying = autoplay
        player.pause()
        updateNowPlayingInfo()

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let resolver = self.urlResolver else { throw URLError(.fileDoesNotExist) }
                let url = try await resolver(track)
                guard token == self.loadToken else { return }
                let item = AVPlayerItem(url: url)
                self.player.replaceCurrentItem(with: item)
                if autoplay { self.play() }

                if let d = try? await item.asset.load(.duration), d.isNumeric, d.seconds > 0, token == self.loadToken {
                    self.duration = d.seconds
                    self.updateNowPlayingInfo()
                }
                let art = await Self.artwork(from: item.asset)
                guard token == self.loadToken else { return }
                self.artwork = art
                self.updateNowPlayingInfo()
            } catch {
                guard token == self.loadToken else { return }
                self.isPlaying = false
                self.errorMessage = "Can't play “\(track.title)”"
                self.updateNowPlayingInfo()
            }
        }
    }

    private static func artwork(from asset: AVAsset) async -> UIImage? {
        guard let items = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue) else { return nil }
        return UIImage(data: data)
    }

    private func itemDidEnd() {
        let before = queue.current?.id
        guard let next = queue.advance(userInitiated: false) else {
            // End of queue with repeat off: stop at the top of the last track.
            pause()
            seek(to: 0)
            return
        }
        if next.id == before {          // repeat one
            seek(to: 0)
            play()
        } else {
            load(next, autoplay: true)
        }
    }

    // MARK: Apple Music

    /// Hands the whole queue (in our play order) to `ApplicationMusicPlayer`, so it moves between
    /// songs gaplessly and from the lock screen; `syncAppleMusic` mirrors where it is.
    private func loadAppleMusic(autoplay: Bool, keepPosition: Bool) {
        guard let current = queue.current, let currentID = current.appleMusicID else { return }
        loadToken += 1
        let token = loadToken
        endFastSeek()
        let resumeAt = keepPosition ? currentTime : 0
        let ordered = queue.ordered.filter(\.isAppleMusic)
        let repeatMode = Self.musicRepeatMode(queue.repeatMode)

        player.pause()
        player.replaceCurrentItem(with: nil)
        errorMessage = nil
        isPlaying = autoplay
        // ApplicationMusicPlayer publishes its own lock-screen info; drop any left from a file track.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if !keepPosition { appleMusicMoved(to: current) }
        appleMusicPending = true

        Task { [weak self] in
            guard let self else { return }
            do {
                guard let appleMusic = self.appleMusic else { throw URLError(.unsupportedURL) }
                let songs = try await appleMusic.songs(for: ordered)
                guard token == self.loadToken else { return }
                guard let start = songs.first(where: { $0.id.rawValue == currentID }) else {
                    throw URLError(.resourceUnavailable)
                }
                self.musicPlayer.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: start)
                self.musicPlayer.state.repeatMode = repeatMode
                self.musicPlayer.state.shuffleMode = .off      // shuffle is already in our order
                try await self.musicPlayer.prepareToPlay()
                guard token == self.loadToken else {
                    if self.queue.current?.isAppleMusic != true { self.musicPlayer.stop() }
                    return
                }
                self.appleMusicActive = true
                self.startAppleMusicPoll()
                if resumeAt > 0 { self.musicPlayer.playbackTime = resumeAt }
                if self.isPlaying { try await self.musicPlayer.play() }
                if token == self.loadToken { self.appleMusicPending = false }
            } catch {
                guard token == self.loadToken else { return }
                self.appleMusicPending = false
                self.appleMusicFailed(error)
            }
        }
    }

    private func stopAppleMusic() {
        guard appleMusicActive else { return }
        appleMusicActive = false
        appleMusicPoll?.cancel()
        appleMusicPoll = nil
        musicPlayer.stop()
    }

    private func skipAppleMusic(to track: Track, forward: Bool) {
        appleMusicMoved(to: track)
        appleMusicPending = true
        Task { [weak self] in
            if forward {
                try? await self?.musicPlayer.skipToNextEntry()
            } else {
                try? await self?.musicPlayer.skipToPreviousEntry()
            }
            self?.appleMusicPending = false
        }
    }

    private func appleMusicFailed(_ error: Error) {
        isPlaying = false
        let title = queue.current?.title ?? "song"
        errorMessage = "Can't play “\(title)”: \(error.localizedDescription)"
    }

    /// Resets time/duration/artwork for a new Apple Music song.
    private func appleMusicMoved(to track: Track) {
        currentTime = 0
        duration = track.duration
        artwork = nil
        guard let url = track.artworkURL else { return }
        let id = track.id
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  let self, self.queue.current?.id == id else { return }
            self.artwork = image
        }
    }

    /// `ApplicationMusicPlayer` exposes time, status and current entry as properties, not
    /// callbacks, so poll them at the same 4 Hz as the AVPlayer time observer.
    private func startAppleMusicPoll() {
        appleMusicPoll?.cancel()
        lastMusicStatus = nil
        appleMusicPoll = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.syncAppleMusic()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func syncAppleMusic() {
        guard appleMusicActive, !appleMusicPending else { return }

        // The player moved on by itself (song ended, lock screen skip): follow it.
        if let entry = musicPlayer.queue.currentEntry, let current = queue.current,
           !Self.entry(entry, matches: current),
           let match = queue.ordered.first(where: { Self.entry(entry, matches: $0) }) {
            queue.move(to: match.id)
            appleMusicMoved(to: match)
        }

        if fastSeekTask == nil { currentTime = musicPlayer.playbackTime }

        // Only react to status *changes*, so our own play/pause isn't undone before it lands.
        let status = musicPlayer.state.playbackStatus
        if status != lastMusicStatus {
            lastMusicStatus = status
            switch status {
            case .playing: isPlaying = true
            case .paused, .stopped, .interrupted: isPlaying = false
            default: break
            }
        }
    }

    private static func entry(_ entry: ApplicationMusicPlayer.Queue.Entry, matches track: Track) -> Bool {
        if case .song(let song)? = entry.item, song.id.rawValue == track.appleMusicID { return true }
        return entry.title == track.title
    }

    private static func musicRepeatMode(_ mode: RepeatMode) -> MusicKit.MusicPlayer.RepeatMode {
        switch mode {
        case .off: .none
        case .all: .all
        case .one: .one
        }
    }

    // MARK: Observers

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.fastSeekTask == nil, !self.appleMusicActive, time.isNumeric else { return }
                self.currentTime = time.seconds
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.itemDidEnd()
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.errorMessage = "Playback failed"
                self.pause()
            }
        })
    }

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                // ApplicationMusicPlayer handles its own interruptions; the poll mirrors them.
                guard let self, let type, !self.appleMusicActive else { return }
                switch type {
                case .began:
                    // The system already paused the player; reflect it.
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                case .ended:
                    if options.contains(.shouldResume) { self.play() }
                @unknown default:
                    break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                // Headphones unplugged: pause, like every music player.
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureSession()
                self?.updateNowPlayingInfo()
            }
        })
    }

    // MARK: Lock screen & Control Center

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play(); return self == nil ? .commandFailed : .success }
        }
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause(); return self == nil ? .commandFailed : .success }
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause(); return self == nil ? .commandFailed : .success }
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { (self?.nextTrack() ?? false) ? .success : .noSuchContent }
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previousTrack(); return self == nil ? .commandFailed : .success }
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            return MainActor.assumeIsolated {
                guard let self, let position else { return .commandFailed }
                self.seek(to: position)
                return .success
            }
        }
    }

    private func updateNowPlayingInfo() {
        // ApplicationMusicPlayer owns the lock screen while it plays.
        guard !appleMusicActive, queue.current?.isAppleMusic != true else { return }
        guard let track = queue.current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork {
            // @Sendable: MediaPlayer calls this on a background queue.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { @Sendable _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
