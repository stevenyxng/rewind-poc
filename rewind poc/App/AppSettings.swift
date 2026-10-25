import Foundation

/// Light/dark: follow the phone, or force one.
nonisolated enum Appearance: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var next: Appearance {
        switch self {
        case .system: .dark
        case .dark: .light
        case .light: .system
        }
    }
}

/// User settings, persisted in UserDefaults.
@Observable
final class AppSettings {
    var clickSound: Bool { didSet { defaults.set(clickSound, forKey: "clickSound") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    var shuffle: Bool { didSet { defaults.set(shuffle, forKey: "shuffle") } }
    var repeatMode: RepeatMode { didSet { defaults.set(repeatMode.rawValue, forKey: "repeatMode") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clickSound = defaults.object(forKey: "clickSound") as? Bool ?? false
        haptics = defaults.object(forKey: "haptics") as? Bool ?? true
        shuffle = defaults.object(forKey: "shuffle") as? Bool ?? false
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: "repeatMode") ?? "") ?? .off
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    }
}
