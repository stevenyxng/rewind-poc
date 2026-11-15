import Foundation

/// A snapshot of the originating menu, independent of either playback service.
nonisolated struct ListeningQueue {
    let songs: [ShuffleSong]
    private(set) var index: Int
    private var visited: Set<Int>
    private var history: [Int] = []

    init(songs: [ShuffleSong], index: Int) {
        self.songs = songs
        self.index = index
        visited = [index]
    }

    var current: ShuffleSong? { songs.indices.contains(index) ? songs[index] : nil }

    mutating func advance<G: RandomNumberGenerator>(shuffle: Bool, repeatMode: RepeatMode,
                                                    repeatAllowed: Bool, manual: Bool = false,
                                                    using rng: inout G) -> ShuffleSong? {
        guard let current else { return nil }
        if repeatMode == .one && repeatAllowed && !manual { return current }
        // A denied Repeat One explicitly falls back to sequential playback.
        let sequentialFallback = repeatMode == .one && !repeatAllowed && !manual
        var next: Int?
        if shuffle && !sequentialFallback {
            var candidates = songs.indices.filter { !visited.contains($0) && songs[$0] != current }
            if candidates.isEmpty && repeatMode == .all {
                visited = [index]
                candidates = songs.indices.filter { songs[$0] != current }
            }
            next = candidates.randomElement(using: &rng)
        } else if index + 1 < songs.count {
            next = index + 1
        } else if repeatMode == .all {
            next = 0
        }
        guard let next else { return nil }
        history.append(index)
        index = next
        visited.insert(next)
        return songs[next]
    }

    mutating func previous() -> ShuffleSong? {
        if let previous = history.popLast() { index = previous }
        else if index > 0 { index -= 1 }
        return current
    }
}
