import SwiftUI

/// Now Playing: large artwork, title and artist, then a progress bar that becomes a
/// scrubber while the wheel is turning.
struct NowPlayingView: View {
    let model: AppModel

    private var player: PlaybackEngine { model.player }
    private var spotify: SpotifyManager { model.spotifyManager }
    private var usesSpotify: Bool { spotify.isConnected }
    private var title: String {
        usesSpotify ? (spotify.title.isEmpty ? "Waiting for Spotify…" : spotify.title)
            : (player.currentTrack?.title ?? "Not Playing")
    }
    private var artist: String {
        usesSpotify ? spotify.artist : (player.currentTrack?.artist ?? "")
    }
    private var playbackError: String? {
        usesSpotify || !player.hasTrack ? spotify.errorMessage : player.errorMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Takes whatever height is left over, so the artwork is as large as fits.
            Artwork(image: usesSpotify ? spotify.artwork : player.artwork)
                .accessibilityLabel("Cover art")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.primary)
                    Text(verbatim: artist)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if usesSpotify {
                        Image(systemName: spotify.isPaused ? "play.fill" : "pause.fill")
                            .accessibilityLabel(spotify.isPaused ? "Paused" : "Playing")
                    } else {
                    if player.queue.isShuffled { Image(systemName: "shuffle") }
                    switch player.queue.repeatMode {
                    case .off: EmptyView()
                    case .all: Image(systemName: "repeat")
                    case .one: Image(systemName: "repeat.1")
                    }
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let error = playbackError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
                if usesSpotify {
                    Text("Spotify")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                } else if !player.hasTrack {
                    Text("Connect to Spotify in Settings or choose a song from Music.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                bottomBar
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var bottomBar: some View {
        if usesSpotify {
            SpotifyTimeBar(spotify: spotify)
        } else if let scrub = model.scrubPosition {
            TimeBar(position: scrub, duration: player.duration, scrubbing: true)
        } else {
            TimeBar(position: player.currentTime, duration: player.duration, scrubbing: false)
        }
    }
}

// Keep frequent progress updates separate from the artwork and metadata.
private struct SpotifyTimeBar: View {
    let spotify: SpotifyManager

    var body: some View {
        TimeBar(position: spotify.currentTime, duration: spotify.duration, scrubbing: false)
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

/// Progress bar, or a scrubber with a round playhead while scrubbing.
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
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 12, height: 12)
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
