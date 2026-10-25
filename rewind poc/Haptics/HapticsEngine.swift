import CoreHaptics
import UIKit

// MARK: - Tunable constants
//
// Every haptic in the app is shaped by the parameters in this table. The defaults
// below are the shipped feel; Settings > Haptics Lab overrides any of them at runtime
// (saved to UserDefaults), so you can tune on the phone without rebuilding.
// Intensity and sharpness are Core Haptics units (0...1).

nonisolated enum HapticParameter: String, CaseIterable, Identifiable, Sendable {
    // Menu detent ramp: continuous "tension" that builds between ticks.
    case rampPeak, rampFloor, rampCurve, rampOnset, rampSharpness
    // Menu detent click: the transient fired exactly at each tick.
    case detentIntensity, detentSharpness
    // Wall: continuous vibration while pushing past the end of a list (or the start/end of
    // a track), growing the farther the finger goes past the endpoint.
    case wallStartIntensity, wallMaxIntensity, wallFullDistance, wallCurve, wallSharpness
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
        case .rampPeak:          Spec(label: "Ramp peak",       group: "Detent ramp", defaultValue: 0.35, range: 0...1)
        case .rampFloor:         Spec(label: "Ramp floor",      group: "Detent ramp", defaultValue: 0.00, range: 0...0.3)
        case .rampCurve:         Spec(label: "Ramp curve (exp)", group: "Detent ramp", defaultValue: 2.00, range: 0.5...5)
        case .rampOnset:         Spec(label: "Ramp onset",      group: "Detent ramp", defaultValue: 0.20, range: 0...0.9)
        case .rampSharpness:     Spec(label: "Ramp sharpness",  group: "Detent ramp", defaultValue: 0.20, range: 0...1)

        case .detentIntensity:   Spec(label: "Click intensity", group: "Detent click", defaultValue: 0.85, range: 0...1)
        case .detentSharpness:   Spec(label: "Click sharpness", group: "Detent click", defaultValue: 0.90, range: 0...1)

        case .wallStartIntensity: Spec(label: "Wall start intensity", group: "Wall", defaultValue: 0.10, range: 0...1)
        case .wallMaxIntensity:  Spec(label: "Wall max intensity", group: "Wall", defaultValue: 0.90, range: 0...1)
        case .wallFullDistance:  Spec(label: "Max at (detents past end)", group: "Wall", defaultValue: 3.0, range: 0.5...8)
        case .wallCurve:         Spec(label: "Wall curve (exp)", group: "Wall", defaultValue: 1.5, range: 0.5...5)
        case .wallSharpness:     Spec(label: "Wall sharpness",  group: "Wall", defaultValue: 0.10, range: 0...1)

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
    /// Continuous ramp intensity for a finger `progress` of the way to the next detent.
    /// Sign is ignored, so reversing direction smoothly follows the new direction:
    /// tension falls as the finger backs off, then rises toward the opposite detent.
    static func rampIntensity(progress: Double, tuning: HapticsTuning) -> Double {
        let p = min(abs(progress), 1)
        let floor = tuning[.rampFloor]
        let onset = tuning[.rampOnset]
        guard p > onset else { return floor }
        let t = (p - onset) / (1 - onset)
        return floor + (tuning[.rampPeak] - floor) * pow(t, tuning[.rampCurve])
    }

    /// Wall intensity for a finger `overshoot` detents past the endpoint: silent at the endpoint,
    /// then from the start intensity up to the max at the full distance, shaped by the curve.
    static func wallIntensity(overshoot: Double, tuning: HapticsTuning) -> Double {
        guard overshoot > 0 else { return 0 }
        let t = min(overshoot / tuning[.wallFullDistance], 1)
        let start = tuning[.wallStartIntensity]
        return start + (tuning[.wallMaxIntensity] - start) * pow(t, tuning[.wallCurve])
    }

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
/// The menu detent ramp is one looping continuous pattern whose intensity is changed live
/// with dynamic parameters, so nothing restarts on every touch event.
@Observable
final class HapticsEngine {
    /// Live tuning; the Haptics Lab binds straight to this. Changes persist immediately.
    var tuning: HapticsTuning {
        didSet { if tuning != oldValue { tuning.save(to: defaults) } }
    }

    /// Master switch (Settings > Haptics).
    var isEnabled = true {
        didSet { if !isEnabled { endRamp(); endWall() } }
    }

    /// Length of the one-off `bump()`.
    private static let bumpDuration: TimeInterval = 0.06

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    @ObservationIgnored private var engine: CHHapticEngine?
    @ObservationIgnored private var engineNeedsStart = true
    @ObservationIgnored private let ramp = ContinuousHaptic()
    @ObservationIgnored private let wallHaptic = ContinuousHaptic()
    /// Whole detents of the current wall push already given a fallback bump (no Core Haptics).
    @ObservationIgnored private var fallbackWallStep = 0
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
                    Task { @MainActor in self.engineDidStop() }
                }
                e.resetHandler = { @Sendable [weak self] in
                    guard let self else { return }
                    Task { @MainActor in self.engineDidReset() }
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

    private func engineDidStop() {
        engineNeedsStart = true
        ramp.invalidate()
        wallHaptic.invalidate()
    }

    /// After a reset (e.g. the haptic server died) every player is invalid. The ramp is rebuilt
    /// now; the wall rebuilds itself on its next update.
    private func engineDidReset() {
        engineDidStop()
        if ramp.wanted { start(ramp, sharpness: tuning[.rampSharpness], intensity: tuning[.rampFloor]) }
    }

    private func stopEngine() {
        ramp.wanted = false
        wallHaptic.wanted = false
        engineDidStop()
        engine?.stop(completionHandler: nil)
    }

    private func start(_ haptic: ContinuousHaptic, sharpness: Double, intensity: Double) {
        guard let engine = startEngineIfNeeded() else { return }
        if !haptic.start(on: engine, sharpness: sharpness, intensity: intensity) { engineNeedsStart = true }
    }

    private func set(_ haptic: ContinuousHaptic, intensity: Double) {
        if !haptic.setIntensity(intensity) { engineNeedsStart = true }
    }

    // MARK: Menu detent ramp

    func beginRamp() {
        guard isEnabled else { return }
        ramp.wanted = true
        start(ramp, sharpness: tuning[.rampSharpness], intensity: tuning[.rampFloor])
    }

    /// `progress` is the signed fraction of the way to the next detent (-1...1).
    func updateRamp(progress: Double) {
        guard isEnabled, ramp.wanted else { return }
        let intensity = HapticCurves.rampIntensity(progress: progress, tuning: tuning)
        if ramp.isPlaying {
            set(ramp, intensity: intensity)
        } else {
            start(ramp, sharpness: tuning[.rampSharpness], intensity: intensity)
        }
    }

    func endRamp() {
        ramp.wanted = false
        ramp.stop()
    }

    // MARK: Wall

    /// `overshoot` is how far the finger is past the endpoint, in detents. 0 stops the wall.
    func updateWall(overshoot: Double) {
        guard isEnabled, overshoot > 0 else { endWall(); return }
        guard supportsCoreHaptics else {
            // No continuous haptics: a soft bump per whole detent pushed, stronger as it goes.
            let step = Int(overshoot)
            if step > fallbackWallStep {
                fallback.play(.soft, intensity: HapticCurves.wallIntensity(overshoot: overshoot, tuning: tuning))
            }
            fallbackWallStep = step
            return
        }
        let intensity = HapticCurves.wallIntensity(overshoot: overshoot, tuning: tuning)
        wallHaptic.wanted = true
        if wallHaptic.isPlaying {
            set(wallHaptic, intensity: intensity)
        } else {
            start(wallHaptic, sharpness: tuning[.wallSharpness], intensity: intensity)
        }
    }

    func endWall() {
        wallHaptic.wanted = false
        wallHaptic.stop()
        fallbackWallStep = 0
    }

    // MARK: Named effects

    /// The crisp click at a menu detent. Also drops the ramp straight back to its floor.
    func detent() {
        set(ramp, intensity: tuning[.rampFloor])
        transient(tuning[.detentIntensity], tuning[.detentSharpness], fallback: .rigid)
    }

    /// One-off dull bump for "can't do that" (e.g. Shuffle with no songs). Same feel as the wall at full push.
    func bump() {
        let i = Float(tuning[.wallMaxIntensity]), s = Float(tuning[.wallSharpness])
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
        ], fallback: .soft, fallbackIntensity: tuning[.wallMaxIntensity])
    }

    /// Haptics Lab preview: the wall as if pushed steadily from the endpoint to the full distance.
    func previewWall() {
        let duration = 1.2
        // Core Haptics allows at most 16 control points per curve.
        let points = (0..<16).map { i -> CHHapticParameterCurve.ControlPoint in
            let t = Double(i) / 15
            let intensity = HapticCurves.wallIntensity(overshoot: max(t, 0.001) * tuning[.wallFullDistance], tuning: tuning)
            return .init(relativeTime: t * duration, value: Float(intensity))
        }
        play(events: [
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(tuning[.wallSharpness])),
            ], relativeTime: 0, duration: duration),
        ], curves: [
            CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: points, relativeTime: 0),
        ], fallback: .soft, fallbackIntensity: tuning[.wallMaxIntensity])
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

/// A looping continuous haptic whose intensity is changed live (the detent ramp, the wall).
/// Wraps one `CHHapticAdvancedPatternPlayer`; invalidated whenever the engine stops or resets.
private final class ContinuousHaptic {
    /// 30 s is the longest continuous event Core Haptics allows; the pattern loops.
    private static let patternDuration: TimeInterval = 30
    /// Intensity updates smaller than this are skipped...
    private static let epsilon = 0.01
    /// ...unless this long has passed, which also recovers from the pattern's loop restart.
    private static let refreshInterval: TimeInterval = 0.25

    /// Whether the owner currently wants it running.
    var wanted = false
    private(set) var isPlaying = false
    private var player: CHHapticAdvancedPatternPlayer?
    private var lastIntensity: Double = -1
    private var lastSend: TimeInterval = 0

    /// Returns false if the player couldn't start; the engine likely needs restarting.
    func start(on engine: CHHapticEngine, sharpness: Double, intensity: Double) -> Bool {
        do {
            if player == nil {
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                    ],
                    relativeTime: 0,
                    duration: Self.patternDuration)
                // Start silent so there's no blip before the first update.
                let silent = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)
                let pattern = try CHHapticPattern(events: [event], parameters: [silent])
                let newPlayer = try engine.makeAdvancedPlayer(with: pattern)
                newPlayer.loopEnabled = true
                player = newPlayer
            }
            try player?.start(atTime: CHHapticTimeImmediate)
            isPlaying = true
            lastIntensity = -1
            // Sharpness is additive around the pattern's 0.5 base.
            try player?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Float(sharpness - 0.5), relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
            return setIntensity(intensity)
        } catch {
            invalidate()
            return false
        }
    }

    /// Returns false if sending failed (the engine stopped underneath us).
    @discardableResult
    func setIntensity(_ value: Double) -> Bool {
        guard isPlaying, let player else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        guard abs(value - lastIntensity) >= Self.epsilon || now - lastSend >= Self.refreshInterval else { return true }
        do {
            try player.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: Float(value), relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
            lastIntensity = value
            lastSend = now
            return true
        } catch {
            invalidate()
            return false
        }
    }

    func stop() {
        guard isPlaying else { return }
        try? player?.stop(atTime: CHHapticTimeImmediate)
        isPlaying = false
    }

    func invalidate() {
        player = nil
        isPlaying = false
    }
}

/// UIKit fallback for devices without Core Haptics (or if the engine fails).
/// It can't do the continuous ramp, only the discrete clicks.
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
