import SwiftUI

/// Now Playing: track info, then a progress bar, a volume bar (while spinning in volume
/// mode) or a scrubber (scrub mode).
struct NowPlayingView: View {
    let model: AppModel

    private var player: PlaybackEngine { model.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(player.queue.positionLabel)
                Spacer()
                if player.queue.isShuffled { Image(systemName: "shuffle") }
                switch player.queue.repeatMode {
                case .off: EmptyView()
                case .all: Image(systemName: "repeat")
                case .one: Image(systemName: "repeat.1")
                }
            }
            .font(Theme.monoFont)
            .foregroundStyle(Theme.secondary)
            .padding(.bottom, 10)

            HStack(alignment: .top, spacing: 14) {
                Artwork(image: player.artwork)
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.currentTrack?.title ?? "Not Playing")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(2)
                    Text(player.currentTrack?.artist ?? "")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Text(player.currentTrack?.album ?? "")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 8)

            if let error = player.errorMessage {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .padding(.bottom, 6)
            }
            bottomBar
        }
        .padding(14)
    }

    @ViewBuilder private var bottomBar: some View {
        if model.nowPlaying.mode == .scrub {
            TimeBar(position: model.scrubPosition ?? player.currentTime, duration: player.duration, scrubbing: true)
        } else if model.volumeBarVisible {
            VolumeBar(volume: player.volume)
        } else {
            TimeBar(position: player.currentTime, duration: player.duration, scrubbing: false)
        }
    }
}

private struct Artwork: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.track)
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

private struct VolumeBar: View {
    let volume: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(Theme.accent).frame(width: geo.size.width * volume)
                    }
                }
                .frame(height: 6)
                Image(systemName: "speaker.wave.3.fill")
            }
            .frame(height: 14)
            Text("\(Int((volume * 100).rounded()))%")
                .font(Theme.monoFont)
                .frame(maxWidth: .infinity)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
    }
}
