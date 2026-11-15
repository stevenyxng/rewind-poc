import CoreHaptics
import UIKit

// MARK: - Tunable constants
//
// Every haptic in the app is shaped by the parameters in this table. The defaults
// below are the shipped feel; Settings > Haptics Lab overrides any of them at runtime
// (saved to UserDefaults), so you can tune on the phone without rebuilding.
// Intensity and sharpness are Core Haptics units (0...1).

nonisolated enum HapticParameter: String, CaseIterable, Identifiable, Sendable {
    // Menu detent click: the transient fired at each tick.
    case detentIntensity, detentSharpness
    // Bump: short dull thud for "can't do that" (e.g. Shuffle Songs with no songs).
    case bumpIntensity, bumpSharpness
    // Buttons.
    case buttonIntensity, buttonSharpness, centerIntensity, centerSharpness
    // Scrubbing in Now Playing.
    case scrubSpacing, scrubIntensity, scrubSharpnessMin, scrubSharpnessMax, scrubFastRate,
         scrubMarkIntensity, scrubMarkSharpness

    var id: String { rawValue }

    struct Spec: Sendable {
        let label: String
        let group: String
        let defaultValue: Double
        let range: ClosedRange<Double>
    }

    var spec: Spec {
        switch self {
        //                           label                     group      default  range
        case .detentIntensity:   Spec(label: "Click intensity", group: "Detent click", defaultValue: 0.85, range: 0...1)
        case .detentSharpness:   Spec(label: "Click sharpness", group: "Detent click", defaultValue: 0.90, range: 0...1)

        case .bumpIntensity:     Spec(label: "Bump intensity",  group: "Bump", defaultValue: 0.90, range: 0...1)
        case .bumpSharpness:     Spec(label: "Bump sharpness",  group: "Bump", defaultValue: 0.30, range: 0...1)

        case .buttonIntensity:   Spec(label: "Button intensity", group: "Buttons", defaultValue: 0.60, range: 0...1)
        case .buttonSharpness:   Spec(label: "Button sharpness", group: "Buttons", defaultValue: 0.85, range: 0...1)
        case .centerIntensity:   Spec(label: "Center intensity", group: "Buttons", defaultValue: 0.80, range: 0...1)
        case .centerSharpness:   Spec(label: "Center sharpness", group: "Buttons", defaultValue: 0.70, range: 0...1)

        case .scrubSpacing:       Spec(label: "Tick every (s)",  group: "Scrub", defaultValue: 3.0, range: 0.5...15)
        case .scrubIntensity:     Spec(label: "Tick intensity",  group: "Scrub", defaultValue: 0.45, range: 0...1)
        case .scrubSharpnessMin:  Spec(label: "Sharpness slow",  group: "Scrub", defaultValue: 0.15, range: 0...1)
        case .scrubSharpnessMax:  Spec(label: "Sharpness fast",  group: "Scrub", defaultValue: 0.95, range: 0...1)
        case .scrubFastRate:      Spec(label: "Fast = ticks/s",  group: "Scrub", defaultValue: 15, range: 2...40)
        case .scrubMarkIntensity: Spec(label: "30s mark intensity", group: "Scrub", defaultValue: 0.90, range: 0...1)
        case .scrubMarkSharpness: Spec(label: "30s mark sharpness", group: "Scrub", defaultValue: 0.60, range: 0...1)
        }
    }
}

/// Current values for every `HapticParameter`: defaults plus any Haptics Lab overrides.
nonisolated struct HapticsTuning: Equatable, Sendable {
    static let storageKey = "hapticsTuning.v1"

    private var overrides: [HapticParameter: Double] = [:]

    subscript(_ p: HapticParameter) -> Double {
        get { overrides[p] ?? p.spec.defaultValue }
        set { overrides[p] = min(max(newValue, p.spec.range.lowerBound), p.spec.range.upperBound) }
    }

    var isDefault: Bool { HapticParameter.allCases.allSatisfy { self[$0] == $0.spec.defaultValue } }

    mutating func reset() { overrides = [:] }

    static func load(from defaults: UserDefaults) -> HapticsTuning {
        var tuning = HapticsTuning()
        let stored = defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
        for (key, value) in stored {
            if let p = HapticParameter(rawValue: key) { tuning[p] = value }
        }
        return tuning
    }

    func save(to defaults: UserDefaults) {
        let dict = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        defaults.set(dict, forKey: Self.storageKey)
    }
}

/// Pure curve math, separated from Core Haptics so it can be unit tested.
nonisolated enum HapticCurves {
    /// Scrub tick sharpness: crisper as the spin gets faster.
    static func scrubSharpness(rate: Double, tuning: HapticsTuning) -> Double {
        let t = min(max(rate / tuning[.scrubFastRate], 0), 1)
        return tuning[.scrubSharpnessMin] + (tuning[.scrubSharpnessMax] - tuning[.scrubSharpnessMin]) * t
    }
}

// MARK: - Engine

/// The single place the app produces haptics.
///
/// Keeps one `CHHapticEngine` alive for the app's lifetime, restarts it after a stop or
/// reset, and falls back to `UIFeedbackGenerator` when Core Haptics is unavailable.
@Observable
final class HapticsEngine {
    /// Live tuning; the Haptics Lab binds straight to this. Changes persist immediately.
    var tuning: HapticsTuning {
        didSet { if tuning != oldValue { tuning.save(to: defaults) } }
    }

    /// Master switch (Settings > Haptics).
    var isEnabled = true

    /// Length of the one-off `bump()`.
    private static let bumpDuration: TimeInterval = 0.06

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    @ObservationIgnored private var engine: CHHapticEngine?
    @ObservationIgnored private var engineNeedsStart = true
    @ObservationIgnored private let fallback = FallbackHaptics()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.tuning = HapticsTuning.load(from: defaults)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopEngine() }
        })
    }

    // MARK: Lifecycle

    /// Call on touch-down so the first haptic of a gesture has no start-up latency.
    func prepare() {
        guard isEnabled else { return }
        if startEngineIfNeeded() == nil { fallback.prepare() }
    }

    @discardableResult
    private func startEngineIfNeeded() -> CHHapticEngine? {
        guard supportsCoreHaptics else { return nil }
        if engine == nil {
            do {
                let e = try CHHapticEngine()
                e.playsHapticsOnly = true
                e.isAutoShutdownEnabled = false
                // Handlers run on a Core Haptics queue; hop to the main actor.
                e.stoppedHandler = { @Sendable [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in self.engineNeedsStart = true }
                }
                e.resetHandler = { @Sendable [weak self] in
                    guard let self else { return }
                    Task { @MainActor in self.engineNeedsStart = true }
                }
                engine = e
                engineNeedsStart = true
            } catch {
                return nil
            }
        }
        if engineNeedsStart {
            do {
                try engine?.start()
                engineNeedsStart = false
            } catch {
                return nil
            }
        }
        return engine
    }

    private func stopEngine() {
        engine?.stop(completionHandler: nil)
        engineNeedsStart = true
    }

    // MARK: Named effects

    /// The crisp click at a menu detent.
    func detent() {
        transient(tuning[.detentIntensity], tuning[.detentSharpness], fallback: .rigid)
    }

    /// Short dull thud for "can't do that" (e.g. Shuffle Songs with no songs).
    func bump() {
        let i = Float(tuning[.bumpIntensity]), s = Float(tuning[.bumpSharpness])
        let duration = Self.bumpDuration
        play(events: [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: i * 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: s),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: s),
            ], relativeTime: 0, duration: duration),
        ], curves: [
            // Decay to nothing over the bump so it thuds rather than buzzes.
            CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 1),
                .init(relativeTime: duration, value: 0),
            ], relativeTime: 0),
        ], fallback: .soft, fallbackIntensity: tuning[.bumpIntensity])
    }

    func button(_ button: WheelButton) {
        if button == .center {
            transient(tuning[.centerIntensity], tuning[.centerSharpness], fallback: .medium)
        } else {
            transient(tuning[.buttonIntensity], tuning[.buttonSharpness], fallback: .light)
        }
    }

    /// Scrub tick; sharper the faster the wheel is spinning.
    func scrubTick(rate: Double) {
        transient(tuning[.scrubIntensity], HapticCurves.scrubSharpness(rate: rate, tuning: tuning), fallback: .rigid)
    }

    /// Stronger bump each time the playhead crosses a 30-second mark.
    func scrubMark() {
        transient(tuning[.scrubMarkIntensity], tuning[.scrubMarkSharpness], fallback: .heavy)
    }

    // MARK: Playback helpers

    private func transient(_ intensity: Double, _ sharpness: Double, fallback style: FallbackHaptics.Style) {
        play(events: [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness)),
            ], relativeTime: 0),
        ], fallback: style, fallbackIntensity: intensity)
    }

    private func play(events: [CHHapticEvent], curves: [CHHapticParameterCurve] = [],
                      fallback style: FallbackHaptics.Style, fallbackIntensity: Double) {
        guard isEnabled else { return }
        if let engine = startEngineIfNeeded() {
            if (try? playPattern(events, curves, on: engine)) != nil { return }
            // The engine may have stopped without us hearing about it yet: restart once and retry.
            engineNeedsStart = true
            if let engine = startEngineIfNeeded(), (try? playPattern(events, curves, on: engine)) != nil { return }
        }
        fallback.play(style, intensity: fallbackIntensity)
    }

    private func playPattern(_ events: [CHHapticEvent], _ curves: [CHHapticParameterCurve], on engine: CHHapticEngine) throws {
        let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
        try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
    }
}

/// UIKit fallback for devices without Core Haptics (or if the engine fails).
private final class FallbackHaptics {
    enum Style { case light, medium, heavy, rigid, soft }

    private lazy var generators: [Style: UIImpactFeedbackGenerator] = [
        .light: UIImpactFeedbackGenerator(style: .light),
        .medium: UIImpactFeedbackGenerator(style: .medium),
        .heavy: UIImpactFeedbackGenerator(style: .heavy),
        .rigid: UIImpactFeedbackGenerator(style: .rigid),
        .soft: UIImpactFeedbackGenerator(style: .soft),
    ]

    func prepare() {
        generators[.rigid]?.prepare()
        generators[.light]?.prepare()
    }

    func play(_ style: Style, intensity: Double) {
        guard let g = generators[style] else { return }
        g.impactOccurred(intensity: CGFloat(min(max(intensity, 0), 1)))
        g.prepare()
    }
}
