import Foundation

/// Physical buttons on the wheel.
nonisolated enum WheelButton: Equatable, Sendable {
    case menu, previous, next, playPause, center
}

/// Everything the click wheel reports. The wheel itself knows nothing about menus,
/// playback or haptics; `AppModel` interprets these.
nonisolated enum WheelEvent: Equatable, Sendable {
    /// Finger landed on the wheel (fires before we know if it's a tap or a spin).
    case touchDown(WheelButton)
    /// Finger started spinning the ring.
    case rotationBegan
    /// Finger position between detents, in (-1, 1). Sent after any ticks for the same touch event.
    case rotation(progress: Double)
    /// One detent crossed. `rate` is the smoothed spin speed in ticks/second.
    case tick(TickDirection, rate: Double)
    /// Finger lifted after spinning.
    case rotationEnded
    /// Short press released.
    case press(WheelButton)
    /// Press-and-hold started (previous / next only).
    case holdBegan(WheelButton)
    case holdEnded(WheelButton)
}
