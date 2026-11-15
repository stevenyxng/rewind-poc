import Foundation
import FirebaseAnalytics
import FirebaseRemoteConfig

/// Haptic A/B tests via Firebase Remote Config + A/B Testing.
///
/// `haptics_tuning` is a JSON object of `HapticParameter` raw values to override, e.g.
/// `{"detentSharpness": 0.4}`. Values fetched this launch are applied on the next one, so the
/// feel never changes mid-session. Only call when Firebase is configured.
enum HapticExperiment {
    static let variantKey = "haptic_variant"
    static let tuningKey = "haptics_tuning"

    static func apply(to haptics: HapticsEngine) async {
        let config = RemoteConfig.remoteConfig()
        config.setDefaults([variantKey: "control" as NSString, tuningKey: "{}" as NSString])
        _ = try? await config.activate()
        haptics.tuning.remote = HapticsTuning.remoteValues(json: config[tuningKey].stringValue)
        Analytics.setUserProperty(config[variantKey].stringValue, forName: variantKey)
        Analytics.setUserProperty(haptics.tuning.isCustomized ? "true" : "false", forName: "tuning_customized")
        Task { _ = try? await config.fetch() }     // for next launch; don't hold up start-up
    }

    static func log(_ name: String, _ parameters: [String: Any]) {
        Analytics.logEvent(name, parameters: parameters)
    }
}
