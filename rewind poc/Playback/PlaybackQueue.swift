import Foundation

nonisolated enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off, all, one

    var label: String {
        switch self {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// Play order, shuffle and repeat. Pure value type; `PlaybackEngine` owns one.
nonisolated struct PlaybackQueue: Equatable, Sendable {
    private(set) var tracks: [Track] = []
    /// Indices into `tracks`, in play order.
    private(set) var order: [Int] = []
    /// Position within `order`.
    private(set) var position = 0
    private(set) var isShuffled = false
    var repeatMode = RepeatMode.off

    var current: Track? {
        order.indices.contains(position) ? tracks[order[position]] : nil
    }

    var isEmpty: Bool { order.isEmpty }

    /// "3 of 12"
    var positionLabel: String { isEmpty ? "" : "\(position + 1) of \(order.count)" }

    /// Replaces the queue. With shuffle on, `startIndex` plays first and the rest are shuffled.
    mutating func load<G: RandomNumberGenerator>(_ tracks: [Track], startAt startIndex: Int, shuffled: Bool,
                                                  using rng: inout G) {
        self.tracks = tracks
        isShuffled = shuffled
        position = 0
        guard !tracks.isEmpty else { order = []; return }
        let start = min(max(startIndex, 0), tracks.count - 1)
        if shuffled {
            order = [start] + tracks.indices.filter { $0 != start }.shuffled(using: &rng)
        } else {
            order = Array(tracks.indices)
            position = start
        }
    }

    mutating func load(_ tracks: [Track], startAt startIndex: Int, shuffled: Bool) {
        var rng = SystemRandomNumberGenerator()
        load(tracks, startAt: startIndex, shuffled: shuffled, using: &rng)
    }

    /// Turns shuffle on/off without interrupting the current track.
    mutating func setShuffle<G: RandomNumberGenerator>(_ on: Bool, using rng: inout G) {
        guard on != isShuffled else { return }
        isShuffled = on
        guard let currentIndex = order.indices.contains(position) ? order[position] : nil else { return }
        if on {
            order = [currentIndex] + tracks.indices.filter { $0 != currentIndex }.shuffled(using: &rng)
            position = 0
        } else {
            order = Array(tracks.indices)
            position = currentIndex
        }
    }

    mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }

    /// Advances. A user skip ignores repeat-one; a track ending naturally honours it.
    /// Returns nil at the end of the queue when repeat is off (position stays on the last track).
    mutating func advance(userInitiated: Bool) -> Track? {
        guard !isEmpty else { return nil }
        if !userInitiated && repeatMode == .one { return current }
        if position + 1 < order.count {
            position += 1
        } else if repeatMode != .off {
            position = 0
        } else {
            return nil
        }
        return current
    }

    /// Goes back one track; at the start it wraps only with repeat-all.
    mutating func retreat() -> Track? {
        guard !isEmpty else { return nil }
        if position > 0 {
            position -= 1
        } else if repeatMode == .all {
            position = order.count - 1
        }
        return current
    }

    /// Updates a track in place (e.g. a cloud track learning its duration).
    mutating func update(_ track: Track) {
        if let i = tracks.firstIndex(where: { $0.id == track.id }) { tracks[i] = track }
    }
}
