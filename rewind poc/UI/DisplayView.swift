import SwiftUI

/// The area above the wheel: whatever the current menu level shows, plus transient messages.
struct DisplayView: View {
    let model: AppModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
