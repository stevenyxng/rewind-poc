import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

nonisolated enum SpotifyAuthError: LocalizedError {
    case cancelled, busy, invalidCallback, denied, signInRequired, missingPermissions
    case invalidResponse, storage, unavailable, server(Int)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Spotify sign-in was cancelled."
        case .busy: "Spotify sign-in is already in progress."
        case .invalidCallback: "Spotify returned an invalid sign-in response. Please reconnect."
        case .denied: "Spotify library access was declined."
        case .signInRequired: "Reconnect to Spotify to authorize library access."
        case .missingPermissions: "Reconnect and allow access to your Spotify library and playlists."
        case .invalidResponse: "Spotify returned an unexpected sign-in response."
        case .storage: "Couldn't securely save Spotify sign-in. Please try again."
        case .unavailable: "Couldn't open Spotify sign-in. Please try again."
        case .server(let status): "Spotify sign-in failed (HTTP \(status)). Please try again."
        }
    }
}

nonisolated enum SpotifyPKCE {
    static let scopes = ["user-library-read", "user-follow-read",
                         "playlist-read-private", "playlist-read-collaborative"]

    static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SpotifyAuthError.unavailable
        }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = values.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func authorizationCode(from url: URL, redirectURL: URL, state: String) throws -> String {
        guard SpotifyManager.callbackMatches(url, redirectURL: redirectURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment == nil else { throw SpotifyAuthError.invalidCallback }
        let items = components.queryItems ?? []
        func values(_ name: String) -> [String] {
            items.filter { $0.name == name }.compactMap(\.value)
        }
        guard !state.isEmpty, values("state") == [state] else { throw SpotifyAuthError.invalidCallback }
        if !values("error").isEmpty { throw SpotifyAuthError.denied }
        let codes = values("code")
        guard codes.count == 1, let code = codes.first, !code.isEmpty else {
            throw SpotifyAuthError.invalidCallback
        }
        return code
    }
}

nonisolated struct SpotifyWebCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopes: Set<String>

    var hasLibraryPermissions: Bool { Set(SpotifyPKCE.scopes).isSubset(of: scopes) }
}

nonisolated struct SpotifyTokenResponse: Decodable, Sendable {
    let access_token: String
    let token_type: String
    let expires_in: Double
    let refresh_token: String?
    let scope: String?

    func credentials(previous: SpotifyWebCredentials?, now: Date = Date()) throws -> SpotifyWebCredentials {
        guard !access_token.isEmpty, token_type.lowercased() == "bearer",
              expires_in.isFinite, expires_in > 0,
              let refresh = refresh_token ?? previous?.refreshToken, !refresh.isEmpty else {
            throw SpotifyAuthError.invalidResponse
        }
        let scopes = scope.map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? []
        let result = SpotifyWebCredentials(accessToken: access_token, refreshToken: refresh,
                                          expiresAt: now.addingTimeInterval(expires_in), scopes: scopes)
        guard result.hasLibraryPermissions else { throw SpotifyAuthError.missingPermissions }
        return result
    }
}

/// Stores credentials only on this device, accessible while it is unlocked.
nonisolated struct SpotifyCredentialStore {
    let account: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.stevenyxng.rewindpoc.spotify.web",
         kSecAttrAccount as String: account]
    }

    func load() throws -> SpotifyWebCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SpotifyAuthError.storage }
        return try JSONDecoder().decode(SpotifyWebCredentials.self, from: data)
    }

    func save(_ credentials: SpotifyWebCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SpotifyAuthError.storage }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SpotifyAuthError.storage }
    }
}

@MainActor
final class SpotifyWebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let clientID: String
    private let redirectURL: URL
    private let store: SpotifyCredentialStore
    private let network: URLSession
    private var credentials: SpotifyWebCredentials?
    private var session: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    private var refreshTask: Task<String, Error>?

    init(clientID: String, redirectURL: URL) {
        self.clientID = clientID
        self.redirectURL = redirectURL
        self.store = SpotifyCredentialStore(account: clientID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        self.network = URLSession(configuration: configuration)
        super.init()
    }

    /// Reuses a valid grant, otherwise asks the user for the required library permissions.
    func authorizeIfNeeded() async throws {
        do {
            _ = try await validAccessToken()
            return
        } catch SpotifyAuthError.signInRequired {
            // Only an absent/revoked grant triggers interactive authentication.
        } catch SpotifyAuthError.missingPermissions {
        }
        guard session == nil else { throw SpotifyAuthError.busy }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw SpotifyAuthError.unavailable
        }
        anchor = window
        defer { session = nil; anchor = nil }
        let verifier = try SpotifyPKCE.randomString()
        let state = try SpotifyPKCE.randomString()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.spotify.com"
        components.path = "/authorize"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "scope", value: SpotifyPKCE.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: SpotifyPKCE.challenge(for: verifier))
        ]
        guard let url = components.url else { throw SpotifyAuthError.unavailable }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: redirectURL.scheme) { url, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyAuthError.cancelled)
                } else if let url, error == nil {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: SpotifyAuthError.unavailable)
                }
            }
            self.session = session
            session.presentationContextProvider = self
            if !session.start() { continuation.resume(throwing: SpotifyAuthError.unavailable) }
        }
        let code = try SpotifyPKCE.authorizationCode(from: callback, redirectURL: redirectURL, state: state)
        let response = try await requestToken([
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirectURL.absoluteString, "code_verifier": verifier
        ])
        let newCredentials = try response.credentials(previous: nil)
        try store.save(newCredentials)
        credentials = newCredentials
    }

    /// Library requests use this method so concurrent requests share one token refresh.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        if let refreshTask { return try await refreshTask.value }
        if credentials == nil { credentials = try store.load() }
        guard let current = credentials else { throw SpotifyAuthError.signInRequired }
        guard current.hasLibraryPermissions else { throw SpotifyAuthError.missingPermissions }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        let task = Task { @MainActor in
            do {
                let response = try await self.requestToken([
                    "grant_type": "refresh_token", "refresh_token": current.refreshToken
                ])
                let updated = try response.credentials(previous: current)
                try self.store.save(updated)
                self.credentials = updated
                return updated.accessToken
            } catch SpotifyAuthError.signInRequired {
                self.credentials = nil
                try self.store.delete()
                throw SpotifyAuthError.signInRequired
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Set before starting the session and retained until it finishes.
        anchor ?? ASPresentationAnchor()
    }

    private func requestToken(_ fields: [String: String]) async throws -> SpotifyTokenResponse {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw SpotifyAuthError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SpotifyPKCE.form(fields.merging(["client_id": clientID]) { _, new in new })
        let (data, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SpotifyAuthError.invalidResponse }
        guard response.statusCode == 200 else {
            struct Failure: Decodable { let error: String }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data), failure.error == "invalid_grant" {
                throw SpotifyAuthError.signInRequired
            }
            // Never expose response bodies, authorization codes, or tokens in errors/logs.
            throw SpotifyAuthError.server(response.statusCode)
        }
        guard let token = try? JSONDecoder().decode(SpotifyTokenResponse.self, from: data) else {
            throw SpotifyAuthError.invalidResponse
        }
        return token
    }
}
