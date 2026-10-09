import UIKit
import CoreHaptics
import AVFoundation

/// Wheel feedback: UIKit selection haptics or Core Haptics transients,
/// plus an optional synthesized piezo-style click.
@MainActor
final class HapticsManager {
    static let shared = HapticsManager()

    enum Mode { case uikit, coreHaptics }

    // MARK: Tunables
    var mode: Mode = .uikit
    var clickSoundEnabled = false
    var coreHapticsIntensity: Float = 0.6
    var coreHapticsSharpness: Float = 1.0

    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .rigid)

    private var engine: CHHapticEngine?
    private var tickPattern: CHHapticPattern?
    private var supportsCoreHaptics: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    private let audioEngine = AVAudioEngine()
    private let clickPlayer = AVAudioPlayerNode()
    private var clickBuffer: AVAudioPCMBuffer?
    private var audioReady = false

    private init() {}

    // MARK: Touch lifecycle

    func touchDown() {
        selection.prepare()
        impact.prepare()
        if mode == .coreHaptics { startEngineIfNeeded() }
        if clickSoundEnabled { startAudioIfNeeded() }
    }

    // MARK: Feedback

    func tick() {
        switch mode {
        case .uikit:
            selection.selectionChanged()
            selection.prepare()
        case .coreHaptics:
            if supportsCoreHaptics, playCoreHapticTick() {
                break
            }
            selection.selectionChanged()   // fallback
            selection.prepare()
        }
        if clickSoundEnabled { playClick() }
    }

    func buttonPress() {
        impact.impactOccurred(intensity: 1.0)
        impact.prepare()
        if clickSoundEnabled { playClick() }
    }

    // MARK: Core Haptics

    private func startEngineIfNeeded() {
        guard supportsCoreHaptics else { return }
        if engine == nil {
            do {
                let e = try CHHapticEngine()
                e.isAutoShutdownEnabled = false
                e.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in self?.engine = nil }
                }
                e.resetHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        do { try self.engine?.start() } catch { self.engine = nil }
                    }
                }
                engine = e
            } catch {
                engine = nil
                return
            }
        }
        do { try engine?.start() } catch { engine = nil }
    }

    private func playCoreHapticTick() -> Bool {
        if engine == nil { startEngineIfNeeded() }
        guard let engine else { return false }
        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: coreHapticsIntensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: coreHapticsSharpness)
                ],
                relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            return false
        }
    }

    // MARK: Click sound (generated, no asset)

    private func startAudioIfNeeded() {
        if !audioReady {
            let sampleRate = 44_100.0
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
            let frames = AVAudioFrameCount(sampleRate * 0.004)     // 4 ms
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            let data = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                let t = Float(i) / Float(sampleRate)
                let envelope = expf(-t * 1200)                       // fast decay
                data[i] = 0.25 * envelope * sinf(2 * .pi * 3_500 * t)
            }
            clickBuffer = buffer
            audioEngine.attach(clickPlayer)
            audioEngine.connect(clickPlayer, to: audioEngine.mainMixerNode, format: format)
            audioReady = true
        }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if !audioEngine.isRunning { try? audioEngine.start() }
        if !clickPlayer.isPlaying { clickPlayer.play() }
    }

    private func playClick() {
        guard audioReady, let clickBuffer else { startAudioIfNeeded(); return }
        if !audioEngine.isRunning { startAudioIfNeeded() }
        clickPlayer.scheduleBuffer(clickBuffer, at: nil, options: .interrupts)
    }
}
