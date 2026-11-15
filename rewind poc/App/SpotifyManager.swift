//
//  SpotifyManager.swift
//  rewind poc
//
//  Created by Student_User on 11/13/26.
//

import Foundation
import Observation
import UIKit
import OSLog
import SpotifyiOS

@MainActor
@Observable
final class SpotifyManager: NSObject, @preconcurrency SPTAppRemoteDelegate, @preconcurrency SPTAppRemotePlayerStateDelegate {
    nonisolated private static let logger = Logger(subsystem: "com.stevenyxng.rewindpoc", category: "SpotifyDiagnostics")

    private let clientID = "d291d1a854c84ae3b623ae387e116875"
    private let redirectURL = URL(
        string: "spotify-ios-quick-start://spotify-login-callback"
    )!

    @ObservationIgnored lazy var configuration = SPTConfiguration(
        clientID: clientID,
        redirectURL: redirectURL
    )

    @ObservationIgnored private(set) lazy var webAuth = SpotifyWebAuth(clientID: clientID, redirectURL: redirectURL)
    @ObservationIgnored private(set) lazy var library = SpotifyLibrary(api: SpotifyLibraryAPI(
        token: { [webAuth] force in try await webAuth.validAccessToken(forceRefresh: force) }
    ))
    private(set) var isAuthorizingLibrary = false
    private(set) var isLinked = (try? SpotifyCredentialStore(account: "d291d1a854c84ae3b623ae387e116875").load()) != nil
    @ObservationIgnored private var accountGeneration = UUID()

    @discardableResult
    func disconnect() -> Bool {
        do { try webAuth.disconnect() }
        catch {
            report("Couldn't remove Spotify sign-in. Please try disconnecting again.")
            return false
        }
        accountGeneration = UUID()
        shouldReconnect = false
        isLinked = false
        isAuthorizingLibrary = false
        accessToken = nil
        appRemote.connectionParameters.accessToken = nil
        appRemote.disconnect()
        clearConnection()
        library.disconnect()
        trackURI = nil
        title = ""
        artist = ""
        album = ""
        artwork = nil
        duration = 0
        currentTime = 0
        isPaused = true
        isShuffling = false
        repeatMode = .off
        errorMessage = nil
        return true
    }

    func connectLibraryAndPlayback() async {
        guard !isAuthorizingLibrary else { return }
        isAuthorizingLibrary = true
        let generation = accountGeneration
        defer { if generation == accountGeneration { isAuthorizingLibrary = false } }
        errorMessage = nil
        do {
            try await webAuth.authorizeIfNeeded()
            guard generation == accountGeneration else { return }
            isLinked = true
            Task { await library.refresh() }
            if !(await connect()) {
                report("Library access authorized. Install Spotify on this device to connect playback.")
            }
        } catch SpotifyAuthError.cancelled {
            // Dismissing the system sheet is a normal user action.
        } catch let error as SpotifyAuthError {
            guard generation == accountGeneration else { return }
            report(error.localizedDescription)
        } catch {
            guard generation == accountGeneration else { return }
            report("Couldn't connect to Spotify. Check your connection and try again.")
        }
    }

    // Kept in memory for the current app session.
    @ObservationIgnored private var accessToken: String?
    private(set) var isConnected = false
    private(set) var isPaused = true
    private(set) var trackURI: String?
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var artwork: UIImage?
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var errorMessage: String?
    @ObservationIgnored var onError: ((String) -> Void)?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var artworkRequest = UUID()
    @ObservationIgnored private var commandPending = false

    private func report(_ message: String) {
        errorMessage = message
        onError?(message)
    }

    // Callback errors can contain URLs or credentials. Display only sanitized text.
    private func authorizationMessage(_ description: String) -> String {
        var text = description
        for secret in [accessToken, appRemote.connectionParameters.accessToken].compactMap({ $0 }) where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[redacted]")
        }
        for pattern in [#"(?i)\b[a-z][a-z0-9+.-]*://\S+"#,
                        #"(?i)(access_token|refresh_token|code|token)\s*[=:]\s*\S+"#,
                        #"[A-Za-z0-9_\-]{24,}"#] {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(text.prefix(400))
    }

    enum Command {
        case togglePlayPause, next, previous, seek(Double), shuffle, repeatMode
    }

    /// Spotify owns audio playback; library metadata never becomes a local audio URL.
    func play(uri: String) async -> Bool {
        guard ["spotify:track:", "spotify:artist:", "spotify:playlist:", "spotify:album:"].contains(where: uri.hasPrefix) else {
            report("This Spotify item can't be played.")
            return false
        }
        guard !commandPending, !isAuthorizingLibrary else { return false }
        commandPending = true
        defer { commandPending = false }
        errorMessage = nil
        shouldReconnect = true
        if !isConnected || !appRemote.isConnected {
            let opened: Bool = await withCheckedContinuation { continuation in
                appRemote.authorizeAndPlayURI(uri) { opened in
                    continuation.resume(returning: opened)
                }
            }
            if !opened { report("Install Spotify on this device to play this item.") }
            return opened
        }
        guard let api = appRemote.playerAPI else { return false }
        return await withCheckedContinuation { continuation in
            api.play(uri) { [weak self] _, error in
                MainActor.assumeIsolated {
                    if let error {
                        self?.report("Spotify couldn't play this item (code \((error as NSError).code)).")
                        continuation.resume(returning: false)
                    } else {
                        self?.refreshPlayerState()
                        continuation.resume(returning: true)
                    }
                }
            }
        }
    }

    enum ShufflePlaybackResult {
        case playing, onDemandRestricted, failed
    }

    /// Connect first so opening Spotify is not mistaken for successful on-demand playback.
    func playShuffleSelection(uri: String) async -> ShufflePlaybackResult {
        endFastSeek()
        if !isConnected || !appRemote.isConnected {
            guard await connect() else {
                report("Install Spotify on this device to play this item.")
                return .failed
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while !isConnected && ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return .failed }
            }
        }
        guard !Task.isCancelled, isConnected, appRemote.isConnected,
              let api = appRemote.playerAPI, !commandPending else {
            if !Task.isCancelled { report("Couldn't connect Spotify playback. Please try again.") }
            return .failed
        }
        commandPending = true
        let connection = connectionGeneration
        defer { if connection == connectionGeneration { commandPending = false } }
        let onDemand = await canPlayOnDemand()
        guard !Task.isCancelled, connection == connectionGeneration else { return .failed }
        // Spotify exposes availability, not a numeric allowance or reset time.
        if onDemand == false { return .onDemandRestricted }
        let error: Error? = await withCheckedContinuation { continuation in
            api.play(uri) { _, error in continuation.resume(returning: error) }
        }
        guard !Task.isCancelled, connection == connectionGeneration else { return .failed }
        if let error {
            let failure = error as NSError
            if failure.domain == SPTAppRemoteErrorDomain, failure.code == -2001 {
                let available = await canPlayOnDemand()
                guard !Task.isCancelled, connection == connectionGeneration else { return .failed }
                if available == false { return .onDemandRestricted }
            }
            report("Spotify couldn't play this item (code \(failure.code)).")
            return .failed
        }
        errorMessage = nil
        refreshPlayerState()
        return .playing
    }

    /// Release Spotify before local audio takes over, keeping controls and artwork on the same source.
    func yieldToLocalPlayback() async -> Bool {
        guard !commandPending, !isAuthorizingLibrary else { return false }
        if appRemote.isConnected, let api = appRemote.playerAPI {
            commandPending = true
            let paused: Bool = await withCheckedContinuation { continuation in
                api.pause { _, error in continuation.resume(returning: error == nil) }
            }
            commandPending = false
            guard paused else {
                report("Couldn't pause Spotify before starting local music.")
                return false
            }
        }
        shouldReconnect = false
        appRemote.disconnect()
        clearConnection()
        return true
    }

    private(set) var isShuffling = false
    private(set) var repeatMode: RepeatMode = .off
    @ObservationIgnored private var fastSeekTask: Task<Void, Never>?

    func perform(_ command: Command) {
        endFastSeek()
        Task { await execute(command) }
    }

    func beginFastSeek(forward: Bool) {
        endFastSeek()
        let uri = trackURI
        let started = ProcessInfo.processInfo.systemUptime
        fastSeekTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected, self.trackURI == uri else { return }
                let step = ProcessInfo.processInfo.systemUptime - started < 2 ? 2.0 : 5.0
                guard await self.execute(.seek(forward ? step : -step)), !Task.isCancelled else { return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    func endFastSeek() {
        fastSeekTask?.cancel()
        fastSeekTask = nil
    }

    private func fetchState() async -> (any SPTAppRemotePlayerState)? {
        guard let api = appRemote.playerAPI else { return nil }
        return await withCheckedContinuation { continuation in
            api.getPlayerState { result, error in
                continuation.resume(returning: error == nil ? result as? SPTAppRemotePlayerState : nil)
            }
        }
    }

    private func canPlayOnDemand() async -> Bool? {
        guard let api = appRemote.userAPI else { return nil }
        return await withCheckedContinuation { continuation in
            api.fetchCapabilities(callback: { result, error in
                continuation.resume(returning: error == nil
                    ? (result as? SPTAppRemoteUserCapabilities)?.canPlayOnDemand : nil)
            })
        }
    }

    private func isAllowed(_ command: Command, state: any SPTAppRemotePlayerState) -> Bool {
        let restrictions = state.playbackRestrictions
        switch command {
        case .togglePlayPause: return true
        case .next: return restrictions.canSkipNext
        case .previous: return restrictions.canSkipPrevious
        case .seek: return restrictions.canSeek
        case .shuffle: return restrictions.canToggleShuffle
        case .repeatMode:
            switch state.playbackOptions.repeatMode {
            case .off: return restrictions.canRepeatContext
            case .context: return restrictions.canRepeatTrack
            default: return true // Turning repeat off adds no repeat restriction.
            }
        }
    }

    private func restrictionMessage(_ command: Command, free: Bool, state: any SPTAppRemotePlayerState) -> String {
        let freeSong = free && !state.track.isAdvertisement && !state.track.isEpisode
        let premium = " This action requires a Spotify Premium account."
        switch command {
        case .previous:
            return freeSong ? "Going back to the previous song is unavailable." + premium
                : "Spotify doesn’t allow going back to the previous song right now."
        case .seek:
            return freeSong ? "Seeking in this song is unavailable." + premium
                : "Spotify doesn’t allow seeking in this song right now."
        case .repeatMode:
            return freeSong ? "This repeat mode is unavailable." + premium
                : "Spotify doesn’t allow this repeat mode right now."
        case .shuffle:
            return freeSong ? "Changing shuffle is unavailable." + premium
                : "Spotify doesn’t allow changing shuffle right now."
        case .next:
            return freeSong ? "You have run out of Spotify skips as a Spotify Free member."
                : "Spotify doesn’t allow skipping this song right now."
        case .togglePlayPause:
            return "Spotify couldn’t change playback right now."
        }
    }

    @discardableResult
    private func execute(_ command: Command) async -> Bool {
        guard isConnected, appRemote.isConnected, let api = appRemote.playerAPI else {
            report("Connect to Spotify before using playback controls.")
            return false
        }
        guard !commandPending, !Task.isCancelled else { return false }
        commandPending = true
        let connection = connectionGeneration
        defer { if connection == connectionGeneration { commandPending = false } }
        guard let state = await fetchState() else {
            if !Task.isCancelled, connection == connectionGeneration {
                report("Couldn’t check Spotify playback controls. Please try again.")
            }
            return false
        }
        guard !Task.isCancelled, isConnected, connection == connectionGeneration else { return false }
        if !isAllowed(command, state: state) {
            let free = await canPlayOnDemand() == false
            guard !Task.isCancelled, connection == connectionGeneration else { return false }
            report(restrictionMessage(command, free: free, state: state))
            return false
        }
        // A held seek must never jump into a new track or keep issuing requests at an endpoint.
        if case .seek(let offset) = command {
            guard state.track.uri == trackURI else { return false }
            let end = max(Double(state.track.duration) - 500, 0)
            if offset < 0 && state.playbackPosition <= 0 { return false }
            if offset > 0 && Double(state.playbackPosition) >= end { return false }
        }
        let error: Error? = await withCheckedContinuation { continuation in
            let completion: SPTAppRemoteCallback = { _, error in continuation.resume(returning: error) }
            switch command {
            case .togglePlayPause:
                if state.isPaused { api.resume(completion) } else { api.pause(completion) }
            case .next: api.skip(toNext: completion)
            case .previous: api.skip(toPrevious: completion)
            case .seek(let offset):
                let position = min(max(Double(state.playbackPosition) + offset * 1000, 0),
                                   max(Double(state.track.duration) - 500, 0))
                api.seek(toPosition: Int(position), callback: completion)
            case .shuffle:
                api.setShuffle(!state.playbackOptions.isShuffling, callback: completion)
            case .repeatMode:
                let next: SPTAppRemotePlaybackOptionsRepeatMode
                switch state.playbackOptions.repeatMode {
                case .off: next = .context
                case .context: next = .track
                default: next = .off
                }
                api.setRepeatMode(next, callback: completion)
            }
        }
        guard !Task.isCancelled, isConnected, connection == connectionGeneration else { return false }
        if let error {
            // Restrictions can change between checking the state and sending the command.
            if let latest = await fetchState(), !isAllowed(command, state: latest) {
                let free = await canPlayOnDemand() == false
                guard !Task.isCancelled, connection == connectionGeneration else { return false }
                report(restrictionMessage(command, free: free, state: latest))
            } else if !Task.isCancelled, connection == connectionGeneration {
                report("Spotify couldn't complete that control (code \((error as NSError).code)).")
            }
            return false
        }
        errorMessage = nil
        refreshPlayerState()
        return true
    }

    @ObservationIgnored private var connectionGeneration = UUID()

    private func clearConnection() {
        endFastSeek()
        connectionGeneration = UUID()
        isConnected = false
        isConnecting = false
        commandPending = false
        progressTask?.cancel()
        progressTask = nil
        artworkRequest = UUID()
    }

    private var shouldReconnect = true
    private var isAppActive = false
    private var isConnecting = false

    @ObservationIgnored lazy var appRemote: SPTAppRemote = {
        let remote = SPTAppRemote(configuration: configuration, logLevel: .debug)
        remote.connectionParameters.accessToken = accessToken
        remote.delegate = self
        return remote
    }()

    // An empty URI lets Spotify resume the user's last track or choose a track.
    private let playURI = ""

    /// Returns whether Spotify could open, not whether authorization succeeded.
    func connect() async -> Bool {
        shouldReconnect = true
        errorMessage = nil
        Self.logger.notice("Starting Spotify authorization")
        return await withCheckedContinuation { continuation in
            appRemote.authorizeAndPlayURI(playURI) { opened in
                Self.logger.notice("Spotify launch accepted: \(opened)")
                continuation.resume(returning: opened)
            }
        }
    }

    func setAppActive(_ isActive: Bool) {
        Self.logger.notice("App active: \(isActive)")
        isAppActive = isActive
        if isActive {
            connectIfReady()
        } else if appRemote.isConnected || isConnecting {
            Self.logger.notice("Disconnect requested because app is inactive")
            appRemote.disconnect()
            clearConnection()
        }
    }

    private func connectIfReady() {
        Self.logger.notice("Connection readiness: active=\(self.isAppActive), tokenPresent=\(self.accessToken != nil), connected=\(self.appRemote.isConnected), connecting=\(self.isConnecting)")
        guard isAppActive, shouldReconnect,
              appRemote.connectionParameters.accessToken != nil,
              !appRemote.isConnected,
              !isConnecting else {
            return
        }
        isConnecting = true
        Self.logger.notice("Requesting App Remote connection")
        appRemote.connect()
    }

    nonisolated static func callbackMatches(_ url: URL, redirectURL: URL) -> Bool {
        // Spotify may add a root slash to a redirect URI with no path.
        guard let incoming = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        let expectedPath = expected.percentEncodedPath
        let incomingPath = incoming.percentEncodedPath
        let pathMatches = incomingPath == expectedPath
            || (expectedPath.isEmpty && incomingPath == "/")
        return url.scheme == redirectURL.scheme
            && url.host == redirectURL.host
            && pathMatches
            && url.port == redirectURL.port
            && url.user == nil
            && url.password == nil
    }

    func handleCallback(_ url: URL) {
        guard shouldReconnect else { return }
        // Web authorization callbacks belong exclusively to ASWebAuthenticationSession.
        // Never interpret a code/state callback as an App Remote access-token response.
        let queryNames = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        guard queryNames.isDisjoint(with: ["code", "state"]) else { return }
        // Log only routing components. Never log the full URL, query, fragment, or credentials.
        let scheme = url.scheme ?? "<nil>"
        let host = url.host ?? "<nil>"
        let path = url.path
        let expectedScheme = redirectURL.scheme ?? "<nil>"
        let expectedHost = redirectURL.host ?? "<nil>"
        let expectedPath = redirectURL.path
        Self.logger.notice("Callback routing: scheme=\(scheme, privacy: .public), host=\(host, privacy: .public), path=[\(path, privacy: .public)]")
        Self.logger.notice("Expected routing: scheme=\(expectedScheme, privacy: .public), host=\(expectedHost, privacy: .public), path=[\(expectedPath, privacy: .public)]")
        Self.logger.notice("Callback checks: scheme=\(url.scheme == self.redirectURL.scheme), host=\(url.host == self.redirectURL.host), path=\(url.path == self.redirectURL.path || (self.redirectURL.path.isEmpty && url.path == "/")), port=\(url.port == self.redirectURL.port), noUser=\(url.user == nil), noPassword=\(url.password == nil)")
        // Only process URLs addressed to our Spotify authentication callback.
        guard Self.callbackMatches(url, redirectURL: redirectURL) else {
            Self.logger.notice("Callback rejected: redirect components do not match")
            report("Spotify callback does not match the configured redirect URI.")
            return
        }

        guard let parameters = appRemote.authorizationParameters(from: url) else {
            Self.logger.notice("Callback contains no authorization parameters")
            report("Spotify returned no authorization details. Try connecting again.")
            return
        }

        if let token = parameters[SPTAppRemoteAccessTokenKey], !token.isEmpty {
            Self.logger.notice("Callback accepted with nonempty token; token omitted")
            accessToken = token
            appRemote.connectionParameters.accessToken = token
            // The callback may arrive before or after the active scene transition.
            connectIfReady()
        } else if let description = parameters[SPTAppRemoteErrorDescriptionKey] {
            report("Spotify authorization: " + authorizationMessage(description))
            Self.logger.error("Spotify authorization returned an error; response contents omitted")
        } else {
            Self.logger.notice("Callback contains no access token")
            report("Spotify returned no access token. Try connecting again.")
        }
    }


    // Spotify documents that its delegate and API callbacks run on the main thread.
    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        isConnecting = false
        guard isAppActive, shouldReconnect else {
            appRemote.disconnect()
            clearConnection()
            return
        }
        isConnected = true
        isLinked = true
        errorMessage = nil
        Self.logger.notice("Spotify connected; subscribing to player state")
        guard let api = appRemote.playerAPI else { return }
        api.delegate = self
        api.subscribe(toPlayerState: { [weak self] _, error in
            MainActor.assumeIsolated {
                if let error {
                    self?.report("Spotify player updates failed (code \((error as NSError).code)).")
                }
            }
        })
        refreshPlayerState()
    }

    private func refreshPlayerState() {
        appRemote.playerAPI?.getPlayerState { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self, self.isConnected else { return }
                if let state = result as? SPTAppRemotePlayerState {
                    self.playerStateDidChange(state)
                } else if let error {
                    self.report("Couldn't read Spotify playback (code \((error as NSError).code)).")
                }
            }
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        clearConnection()
        if let error, isAppActive, shouldReconnect {
            report("Spotify disconnected (code \((error as NSError).code)). Try connecting again.")
        }
        Self.logger.notice("Spotify disconnected")
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        clearConnection()
        guard shouldReconnect else { return }
        report("Spotify connection failed (code \((error as NSError?)?.code ?? 0)). Try connecting again.")
    }

    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        guard isConnected else { return }
        let track = playerState.track
        let changed = trackURI != track.uri
        trackURI = track.uri
        title = track.name
        artist = track.artist.name
        album = track.album.name
        duration = Double(track.duration) / 1000
        currentTime = min(max(Double(playerState.playbackPosition) / 1000, 0), duration)
        isShuffling = playerState.playbackOptions.isShuffling
        switch playerState.playbackOptions.repeatMode {
        case .context: repeatMode = .all
        case .track: repeatMode = .one
        default: repeatMode = .off
        }
        if changed { endFastSeek() }
        isPaused = playerState.isPaused
        progressTask?.cancel()
        if !isPaused {
            let position = currentTime
            let started = ProcessInfo.processInfo.systemUptime
            let speed = Double(playerState.playbackSpeed)
            progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard let self, isConnected, !isPaused else { return }
                    currentTime = min(duration, position + (ProcessInfo.processInfo.systemUptime - started) * speed)
                }
            }
        }
        if changed { artwork = nil }
        if changed || artwork == nil {
            let request = UUID()
            artworkRequest = request
            appRemote.imageAPI?.fetchImage(forItem: track, with: CGSize(width: 600, height: 600)) { [weak self] result, _ in
                MainActor.assumeIsolated {
                    guard let self, self.isConnected, self.artworkRequest == request else { return }
                    self.artwork = result as? UIImage
                }
            }
        }
        Self.logger.notice("Player state: paused=\(self.isPaused), positionMs=\(playerState.playbackPosition)")
    }
}
