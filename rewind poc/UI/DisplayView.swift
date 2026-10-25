import SwiftUI

/// The "screen": title bar plus whatever the current menu level shows.
struct DisplayView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: model.title, isPlaying: model.player.isPlaying, hasTrack: model.player.hasTrack)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.display)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay(alignment: .bottom) {
            if let message = model.message {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.selectionText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.primary))
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.message)
    }

    @ViewBuilder private var content: some View {
        switch model.navigator.screen {
        case .nowPlaying:
            NowPlayingView(model: model)
        case .hapticsLab:
            HapticsLabView(model: model)
        default:
            MenuListView(navigator: model.navigator, playingID: model.player.currentTrack?.id)
        }
    }
}

private struct TitleBar: View {
    let title: String
    let isPlaying: Bool
    let hasTrack: Bool

    var body: some View {
        ZStack {
            Text(title)
                .font(Theme.titleFont)
                .lineLimit(1)
                .padding(.horizontal, 44)
            HStack {
                if hasTrack {
                    Image(systemName: isPlaying ? "play.fill" : "pause.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(isPlaying ? Theme.accent : Theme.secondary)
                }
                Spacer()
                BatteryGlyph()
            }
            .padding(.horizontal, 12)
        }
        .foregroundStyle(Theme.primary)
        .frame(height: 28)
    }
}

private struct BatteryGlyph: View {
    var body: some View {
        let level = Self.level
        if level >= 0 {
            Image(systemName: Self.symbol(for: level))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
    }

    private static var level: Float {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return UIDevice.current.batteryLevel
    }

    private static func symbol(for level: Float) -> String {
        switch level {
        case ..<0.13: "battery.0percent"
        case ..<0.38: "battery.25percent"
        case ..<0.63: "battery.50percent"
        case ..<0.88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
