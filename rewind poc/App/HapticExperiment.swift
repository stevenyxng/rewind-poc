import Foundation
import UIKit
import FirebaseAnalytics
import FirebaseAuth
import FirebaseRemoteConfig
import FirebaseStorage

/// Haptic A/B tests via Firebase Remote Config, with each session's numbers uploaded to Storage.
///
/// `haptics_tuning` is a JSON object of `HapticParameter` raw values to override, e.g.
/// `{"detentSharpness": 0.4}`. A fresh install waits briefly for its variant; after that, values
/// fetched this launch are applied on the next one, so the feel never changes mid-session.
/// Only call when Firebase is configured.
@MainActor
enum HapticExperiment {
    static let variantKey = "haptic_variant"
    static let tuningKey = "haptics_tuning"
    static let usageFolder = "usage"

    /// What this launch is running, recorded with every session.
    private static var variant = "control"
    private static var configSource = "default"

    static func apply(to haptics: HapticsEngine) async {
        let config = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        settings.fetchTimeout = 3
        settings.minimumFetchInterval = 0         // small test group: pick up console changes on next launch
        config.configSettings = settings
        config.setDefaults([variantKey: "control" as NSString, tuningKey: "{}" as NSString])

        if config.lastFetchStatus == .noFetchYet {
            _ = try? await config.fetchAndActivate()
        } else {
            _ = try? await config.activate()
            Task { _ = try? await config.fetch() }     // for next launch; don't hold up start-up
        }

        variant = config[variantKey].stringValue
        configSource = config[variantKey].source == .remote ? "remote" : "default"
        haptics.tuning.remote = HapticsTuning.remoteValues(json: config[tuningKey].stringValue)
        Analytics.setUserProperty(variant, forName: variantKey)
        Analytics.setUserProperty(haptics.tuning.isCustomized ? "true" : "false", forName: "tuning_customized")
    }

    static func log(_ name: String, _ parameters: [String: Any]) {
        Analytics.logEvent(name, parameters: parameters)
    }

    /// Uploads one session to `usage/<uid>/<ms since 1970>.json`, finishing even if the app is backgrounded.
    static func upload(_ summary: [String: Any], tuning: HapticsTuning) {
        let now = Date()
        var record = summary
        record["variant"] = variant
        record["config_source"] = configSource
        record["tuning_customized"] = tuning.isCustomized
        record["tuning"] = Dictionary(uniqueKeysWithValues: HapticParameter.allCases.map { ($0.rawValue, tuning[$0]) })
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
