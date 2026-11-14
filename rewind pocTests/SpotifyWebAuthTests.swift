import Foundation
import Testing
@testable import rewind_poc

struct SpotifyWebAuthTests {
    @Test func pkceMatchesRFC7636Vector() throws {
        #expect(SpotifyPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
                "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = try SpotifyPKCE.randomString()
        #expect(verifier.count == 43)
        #expect(verifier.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        #expect(try verifier != SpotifyPKCE.randomString())
    }

    @Test func validatesStateAndRejectsAmbiguousCallbacks() throws {
        let redirect = try #require(URL(string: "spotify-ios-quick-start://spotify-login-callback"))
        let good = try #require(URL(string: redirect.absoluteString + "/?code=sample&state=expected"))
        #expect(try SpotifyPKCE.authorizationCode(from: good, redirectURL: redirect, state: "expected") == "sample")
        for suffix in [
            "?code=sample", "?code=sample&state=wrong",
            "?code=sample&state=expected&state=other",
            "?code=a&code=b&state=expected", "?code=&state=expected",
            "?error=access_denied&state=expected",
            "?code=sample&state=expected#access_token=example",
            "/other?code=sample&state=expected"
        ] {
            let url = try #require(URL(string: redirect.absoluteString + suffix))
            #expect(throws: SpotifyAuthError.self) {
                try SpotifyPKCE.authorizationCode(from: url, redirectURL: redirect, state: "expected")
            }
        }
    }

    @Test func encodesTokenFormWithoutChangingReservedCharacters() {
        let encoded = String(decoding: SpotifyPKCE.form(["code": "a+b&= /", "client_id": "test"]), as: UTF8.self)
        #expect(encoded == "client_id=test&code=a%2Bb%26%3D%20%2F")
    }

    @Test func refreshPreservesOrRotatesRefreshToken() throws {
        let now = Date(timeIntervalSince1970: 100)
        let previous = SpotifyWebCredentials(accessToken: "old", refreshToken: "original",
                                            expiresAt: now, scopes: Set(SpotifyPKCE.scopes))
        let withoutRotation = SpotifyTokenResponse(access_token: "new", token_type: "Bearer", expires_in: 3600,
                                                  refresh_token: nil, scope: nil)
        let updated = try withoutRotation.credentials(previous: previous, now: now)
        #expect(updated.refreshToken == "original")
        #expect(updated.accessToken == "new")
        #expect(updated.expiresAt == Date(timeIntervalSince1970: 3700))
        #expect(updated.scopes == previous.scopes)
        let rotated = SpotifyTokenResponse(access_token: "new", token_type: "Bearer", expires_in: 3600,
                                           refresh_token: "rotated", scope: SpotifyPKCE.scopes.joined(separator: " "))
        #expect(try rotated.credentials(previous: previous).refreshToken == "rotated")
    }

    @Test func rejectsIncompleteGrants() {
        for token in [
            SpotifyTokenResponse(access_token: "", token_type: "Bearer", expires_in: 3600, refresh_token: "test", scope: SpotifyPKCE.scopes.joined(separator: " ")),
            SpotifyTokenResponse(access_token: "test", token_type: "Bearer", expires_in: 0, refresh_token: "test", scope: SpotifyPKCE.scopes.joined(separator: " ")),
            SpotifyTokenResponse(access_token: "test", token_type: "Bearer", expires_in: 3600, refresh_token: nil, scope: SpotifyPKCE.scopes.joined(separator: " ")),
            SpotifyTokenResponse(access_token: "test", token_type: "Bearer", expires_in: 3600, refresh_token: "test", scope: "user-library-read")
        ] {
            #expect(throws: SpotifyAuthError.self) { try token.credentials(previous: nil) }
        }
    }

    @Test func keychainRoundTripAndReplacement() throws {
        let store = SpotifyCredentialStore(account: "test-" + UUID().uuidString)
        defer { try? store.delete() }
        #expect(try store.load() == nil)
        let first = SpotifyWebCredentials(accessToken: "test", refreshToken: "refresh",
                                         expiresAt: Date(), scopes: Set(SpotifyPKCE.scopes))
        try store.save(first)
        #expect(try store.load()?.refreshToken == "refresh")
        let second = SpotifyWebCredentials(accessToken: "replacement", refreshToken: "rotated",
                                          expiresAt: Date(), scopes: first.scopes)
        try store.save(second)
        #expect(try store.load()?.accessToken == "replacement")
        try store.delete()
        #expect(try store.load() == nil)
    }
}
