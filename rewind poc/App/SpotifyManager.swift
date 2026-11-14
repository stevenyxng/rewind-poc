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

    func connectLibraryAndPlayback() async {
        guard !isAuthorizingLibrary else { return }
        isAuthorizingLibrary = true
        defer { isAuthorizingLibrary = false }
        errorMessage = nil
        do {
            try await webAuth.authorizeIfNeeded()
            Task { await library.refresh() }
            if !(await connect()) {
                report("Library access authorized. Install Spotify on this device to connect playback.")
            }
        } catch SpotifyAuthError.cancelled {
            // Dismissing the system sheet is a normal user action.
        } catch let error as SpotifyAuthError {
            report(error.localizedDescription)
        } catch {
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
        case togglePlayPause, next, previous
    }

    /// Spotify owns audio playback; library metadata never becomes a local audio URL.
    func play(uri: String) async -> Bool {
        guard ["spotify:track:", "spotify:artist:", "spotify:playlist:"].contains(where: uri.hasPrefix) else {
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

    func perform(_ command: Command) {
        guard isConnected, appRemote.isConnected, let api = appRemote.playerAPI else {
            report("Connect to Spotify before using playback controls.")
            return
        }
        guard !commandPending else { return }
        commandPending = true
        let completion: SPTAppRemoteCallback = { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.commandPending = false
                if let error {
                    self.report("Spotify couldn't complete that control (code \((error as NSError).code)).")
                } else {
                    self.errorMessage = nil
                    self.refreshPlayerState()
                }
            }
        }
        switch command {
        case .togglePlayPause:
            if isPaused { api.resume(completion) } else { api.pause(completion) }
        case .next: api.skip(toNext: completion)
        case .previous: api.skip(toPrevious: completion)
        }
    }

    private func clearConnection() {
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
        guard isAppActive else {
            appRemote.disconnect()
            clearConnection()
            return
        }
        isConnected = true
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
        if let error, isAppActive {
            report("Spotify disconnected (code \((error as NSError).code)). Try connecting again.")
        }
        Self.logger.notice("Spotify disconnected")
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        clearConnection()
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
