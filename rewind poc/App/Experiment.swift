import Foundation
import UIKit
import FirebaseAnalytics
import FirebaseAuth
import FirebaseRemoteConfig
import FirebaseStorage

/// A/B variant from Firebase Remote Config (`variant`), with each session's numbers uploaded to Storage.
///
/// A fresh install waits briefly for its variant; after that, the value fetched this launch is used
/// on the next one, so the UI never switches mid-session. Only call when Firebase is configured.
@MainActor
enum Experiment {
    static let variantKey = "variant"
    static let defaultVariant = "control"
    static let usageFolder = "usage"

    /// Where this launch's variant came from ("remote", or "default" if Remote Config wasn't reached).
    private static var configSource = "default"

    static func fetchVariant() async -> String {
        let config = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        settings.fetchTimeout = 3
        settings.minimumFetchInterval = 0         // small test group: pick up console changes on next launch
        config.configSettings = settings
        config.setDefaults([variantKey: defaultVariant as NSString])

        if config.lastFetchStatus == .noFetchYet {
            _ = try? await config.fetchAndActivate()
        } else {
            _ = try? await config.activate()
            Task { _ = try? await config.fetch() }     // for next launch; don't hold up start-up
        }

        let variant = config[variantKey].stringValue
        configSource = config[variantKey].source == .remote ? "remote" : "default"
        Analytics.setUserProperty(variant, forName: variantKey)
        return variant
    }

    static func log(_ name: String, _ parameters: [String: Any]) {
        Analytics.logEvent(name, parameters: parameters)
    }

    /// Uploads one session to `usage/<uid>/<ms since 1970>.json`, finishing even if the app is backgrounded.
    static func upload(_ summary: [String: Any], variant: String) {
        let now = Date()
        var record = summary
        record["variant"] = variant
        record["config_source"] = configSource
        record["ended_at"] = ISO8601DateFormatter().string(from: now)
        record["app_version"] = AppModel.version
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "usage-upload")
        Task {
            defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            do {
                var user = Auth.auth().currentUser
                if user == nil { user = try await Auth.auth().signInAnonymously().user }
                guard let user else { return }
                let name = "\(Int(now.timeIntervalSince1970 * 1000)).json"
                let ref = Storage.storage().reference(withPath: "\(usageFolder)/\(user.uid)/\(name)")
                let metadata = StorageMetadata()
                metadata.contentType = "application/json"
                _ = try await ref.putDataAsync(data, metadata: metadata)
            } catch {
                print("Usage upload failed: \(error)")
            }
        }
    }
}
