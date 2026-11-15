# Rewind (Native iOS / Swift)

## Orchestration & Token Rules
- **Role:** You are the Lead Architect. Never dump raw `.swift` files or verbose `xcodebuild` logs into the main context window; delegate via the `Task` tool (`model: "haiku"` or `model: "sonnet"`).
- **Routing:**
  - `model: "haiku"`: Explore the repo (`grep`/`glob`), read specific file line ranges to extract signatures/constants, and run `swift test` or `xcodebuild` (returning **only** compiler errors or test failures).
  - `model: "sonnet"`: Implement Swift features, views, audio/haptics engines, and XCTest / Swift Testing suites.
  - **Main Session (Opus / Fable):** Plan architecture, dispatch parallel `Task` calls, review `git diff --stat`, and pause at device verification gates.
- **Subagent Prompt Caps:** Pass file paths and line ranges—never paste code blocks into prompts. Require every subagent to return `<150 words` with changed file paths, exact symbols/constants, or failure logs only.
- **Strict YAGNI:** Implement only what was explicitly requested. No speculative protocols, extra abstractions, unrequested settings, comments, or refactors of untouched lines. Keep responses terse.

## Architecture & Technical Guardrails
- **Platform:** Native iOS (Swift / SwiftUI), targeting physical iPhone hardware (Simulator cannot verify Core Haptics or background audio interruptions).
- **Core Modules & Boundaries:**
  - **Pure Logic (Zero UIKit/SwiftUI imports):** `WheelMath`, `MenuNavigator`, `Menu`, `PlaybackQueue`, `NowPlayingWheel`, `LibraryIndex` — keep decoupled so all logic runs fast in unit tests.
  - **Hardware & Media:** `ClickWheelView` (gesture recognizer + 15° detent grid), `CoreHaptics` engine (`CHHapticEngine` with graceful fallback), `AVFoundation` / `AVPlayer` background audio + `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`.
  - **Storage & Cloud:** Firebase iOS SDK (Anonymous Auth + Storage under `music/`) and local `FileManager` document directory + JSON `LibraryIndex`.
- **Dependencies:** Do not add third-party Swift packages unless explicitly approved.

## Verification & Device Gates
- **Logic Changes:** Require `swift test` (or `xcodebuild test`) to pass before reporting completion.
- **Hardware Feel Changes:** Whenever touching `CHHapticEngine` patterns, `ClickWheelView` gesture thresholds, or `AVAudioSession` background playback, **stop and prompt for physical iPhone testing** (haptic sharpness/intensity and lock-screen audio cannot be verified in CI/Simulator).