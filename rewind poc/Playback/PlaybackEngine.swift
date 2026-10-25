import AVFoundation
import MediaPlayer
import UIKit

/// AVPlayer-based playback, independent of the UI: queue, shuffle/repeat, audio session,
/// interruptions, lock screen / Control Center.
@Observable
final class PlaybackEngine {
    private(set) var queue = PlaybackQueue()
    /// Play intent (what the user asked for), which is what the UI shows.
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var artwork: UIImage?
    private(set) var errorMessage: String?

    /// The player's own volume, 0...1 (iOS has no public API for system volume). Persisted.
    private(set) var volume: Double

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        player.volume = Float(volume)
        defaults.set(volume, forKey: Self.volumeKey)
    }

    var currentTrack: Track? { queue.current }
    var hasTrack: Bool { queue.current != nil }

    /// Turns a track into a URL AVPlayer can open (local file, cache, or stream).
    @ObservationIgnored var urlResolver: ((Track) async throws -> URL)?

    /// Restart the current track instead of going back if we're past this point.
    static let restartThreshold: Double = 3
    private static let volumeKey = "playerVolume"

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var fastSeekTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        volume = defaults.object(forKey: Self.volumeKey) as? Double ?? 0.8
        player.volume = Float(volume)
        configureSession()
        observePlayer()
        observeSession()
        configureRemoteCommands()
    }

    // MARK: Transport

    func play(_ tracks: [Track], startAt index: Int, shuffled: Bool, repeatMode: RepeatMode) {
        queue.load(tracks, startAt: index, shuffled: shuffled)
        queue.repeatMode = repeatMode
        guard let track = queue.current else { return }
        load(track, autoplay: true)
    }

    func play() {
        guard hasTrack else { return }
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
        player.pause()
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
        load(track, autoplay: isPlaying)
        return true
    }

    /// Restarts the track if past `restartThreshold`, otherwise goes to the previous one.
    func previousTrack() {
        let before = queue.current?.id
        if currentTime > Self.restartThreshold {
            seek(to: 0)
        } else if let track = queue.retreat(), track.id != before {
            load(track, autoplay: isPlaying)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? duration : seconds
        let target = min(max(seconds, 0), upper)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(value: 1, timescale: 10), toleranceAfter: CMTime(value: 1, timescale: 10))
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
        updateNowPlayingInfo()
    }

    func setRepeat(_ mode: RepeatMode) {
        queue.repeatMode = mode
    }

    /// Stops and clears the queue (e.g. the playing track was deleted).
    func stop() {
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

    // MARK: Observers

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.fastSeekTask == nil, time.isNumeric else { return }
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
                guard let self, let type else { return }
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
