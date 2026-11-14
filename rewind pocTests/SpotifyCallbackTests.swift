import Foundation
import Testing
@testable import rewind_poc

struct SpotifyCallbackTests {
    @Test func acceptsRootSlashAndAuthorizationParameters() throws {
        let redirect = try #require(URL(string: "spotify-ios-quick-start://spotify-login-callback"))
        for suffix in ["", "/", "#access_token=example", "/#access_token=example", "/?error=example"] {
            let callback = try #require(URL(string: redirect.absoluteString + suffix))
            #expect(SpotifyManager.callbackMatches(callback, redirectURL: redirect))
        }
    }

    @Test func rejectsOtherRoutesAndCredentials() throws {
        let redirect = try #require(URL(string: "spotify-ios-quick-start://spotify-login-callback"))
        for text in [
            "other://spotify-login-callback/",
            "spotify-ios-quick-start://other/",
            "spotify-ios-quick-start://spotify-login-callback/other",
            "spotify-ios-quick-start://spotify-login-callback:123/",
            "spotify-ios-quick-start://user@spotify-login-callback/",
            "spotify-ios-quick-start://user:password@spotify-login-callback/"
        ] {
            let callback = try #require(URL(string: text))
            #expect(!SpotifyManager.callbackMatches(callback, redirectURL: redirect))
        }
    }

    @Test func preservesNonRootPathValidation() throws {
        let redirect = try #require(URL(string: "rewind://spotify/login"))
        let exact = try #require(URL(string: "rewind://spotify/login#access_token=example"))
        let changed = try #require(URL(string: "rewind://spotify/login/"))
        #expect(SpotifyManager.callbackMatches(exact, redirectURL: redirect))
        #expect(!SpotifyManager.callbackMatches(changed, redirectURL: redirect))
    }
}
