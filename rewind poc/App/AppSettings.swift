import Foundation

/// User settings, persisted in UserDefaults.
@Observable
final class AppSettings {
    var clickSound: Bool { didSet { defaults.set(clickSound, forKey: "clickSound") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    var shuffle: Bool { didSet { defaults.set(shuffle, forKey: "shuffle") } }
    var repeatMode: RepeatMode { didSet { defaults.set(repeatMode.rawValue, forKey: "repeatMode") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clickSound = defaults.object(forKey: "clickSound") as? Bool ?? false
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        shuffle = defaults.object(forKey: "shuffle") as? Bool ?? false
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: "repeatMode") ?? "") ?? .off
    }
}
