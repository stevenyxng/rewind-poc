import SwiftUI

/// Now Playing: large artwork, title and artist, then a progress bar that becomes a
/// scrubber while the wheel is turning.
struct NowPlayingView: View {
    let model: AppModel

    private var player: PlaybackEngine { model.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Takes whatever height is left over, so the artwork is as large as fits.
            Artwork(image: player.artwork)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.title ?? "Not Playing")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.primary)
                    Text(player.currentTrack?.artist ?? "")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if player.queue.isShuffled { Image(systemName: "shuffle") }
                    switch player.queue.repeatMode {
                    case .off: EmptyView()
                    case .all: Image(systemName: "repeat")
                    case .one: Image(systemName: "repeat.1")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let error = player.errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
                bottomBar
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var bottomBar: some View {
        if let scrub = model.scrubPosition {
            TimeBar(position: scrub, duration: player.duration, scrubbing: true)
        } else {
            TimeBar(position: player.currentTime, duration: player.duration, scrubbing: false)
        }
    }
}

/// Square cover art, sized to fit the space it's given and centered in it.
private struct Artwork: View {
    let image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.track)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Progress bar, or a scrubber with a diamond playhead in scrub mode.
private struct TimeBar: View {
    let position: Double
    let duration: Double
    let scrubbing: Bool

    var body: some View {
        let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
        VStack(spacing: 6) {
            GeometryReader { geo in
                let x = geo.size.width * fraction
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track).frame(height: 4)
                    Capsule().fill(scrubbing ? Theme.secondary : Theme.accent).frame(width: x, height: 4)
                    if scrubbing {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(width: 11, height: 11)
                            .rotationEffect(.degrees(45))
                            .position(x: x, y: geo.size.height / 2)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            HStack {
                Text(Self.format(position))
                Spacer()
                if scrubbing {
                    Text("SCRUB").tracking(1).foregroundStyle(Theme.accent)
                    Spacer()
                }
                Text("-" + Self.format(max(duration - position, 0)))
            }
            .font(Theme.monoFont)
            .foregroundStyle(Theme.secondary)
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
