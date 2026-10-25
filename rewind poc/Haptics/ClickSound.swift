import AVFoundation

/// A tiny synthesized "tick" (no audio asset), played on wheel detents when
/// Settings > Click Sound is on. Uses the app's shared `.playback` audio session.
final class ClickSound {
    var isEnabled = false {
        didSet { if !isEnabled { stop() } }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    func play() {
        guard isEnabled else { return }
        guard startIfNeeded(), let buffer else { return }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    private func startIfNeeded() -> Bool {
        if buffer == nil {
            let sampleRate = 44_100.0
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 0.004)),
                  let samples = b.floatChannelData?[0] else { return false }
            b.frameLength = b.frameCapacity
            for i in 0..<Int(b.frameLength) {
                let t = Float(i) / Float(sampleRate)
                samples[i] = 0.2 * expf(-t * 1200) * sinf(2 * .pi * 3_500 * t)   // 4 ms decaying ping
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            buffer = b
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        if !node.isPlaying { node.play() }
        return true
    }

    private func stop() {
        node.stop()
        engine.stop()
    }
}
