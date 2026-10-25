import Foundation
import Testing
@testable import rewind_poc

struct LibraryIndexTests {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "LibraryTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func track(_ file: String, title: String? = nil) -> Track {
        Track(title: title ?? file, source: .local(fileName: file))
    }

    @Test func roundTripsThroughJSON() throws {
        let url = try tempDir().appending(path: "library.json")
        var index = LibraryIndex()
        index.upsert(Self.track("a.mp3", title: "Alpha"))
        index.upsert(Track(title: "Cloudy", artist: "C", album: "D", duration: 12, source: .cloud(path: "music/c.mp3")))
        try index.save(to: url)
        #expect(LibraryIndex.load(from: url) == index)
    }

    @Test func missingOrCorruptFileLoadsEmpty() throws {
        let dir = try tempDir()
        #expect(LibraryIndex.load(from: dir.appending(path: "nope.json")).tracks.isEmpty)
        let bad = dir.appending(path: "bad.json")
        try Data("not json".utf8).write(to: bad)
        #expect(LibraryIndex.load(from: bad).tracks.isEmpty)
    }

    @Test func upsertReplacesByID() {
        var index = LibraryIndex()
        index.upsert(Self.track("a.mp3", title: "Old"))
        index.upsert(Self.track("a.mp3", title: "New"))
        #expect(index.tracks.count == 1)
        #expect(index.tracks[0].title == "New")
    }

    @Test func removeAndPrune() {
        var index = LibraryIndex(tracks: [Self.track("a.mp3"), Self.track("b.mp3"), Self.track("c.mp3")])
        #expect(index.remove(id: "local:b.mp3")?.title == "b.mp3")
        #expect(index.remove(id: "local:zzz") == nil)
        index.prune(keepingFileNames: ["a.mp3"])
        #expect(index.tracks.map(\.id) == ["local:a.mp3"])
    }

    @Test func uniqueFileNames() {
        #expect(LibraryIndex.uniqueFileName("a.mp3", taken: []) == "a.mp3")
        #expect(LibraryIndex.uniqueFileName("a.mp3", taken: ["a.mp3"]) == "a 2.mp3")
        #expect(LibraryIndex.uniqueFileName("a.mp3", taken: ["a.mp3", "a 2.mp3"]) == "a 3.mp3")
    }

    @Test func fileNameFallbacks() {
        #expect(Track.title(fromFileName: "02_My_Song.mp3") == "02 My Song")
        let parsed = Track.artistAndTitle(fromFileName: "Daft Punk - One More Time.m4a")
        #expect(parsed?.artist == "Daft Punk")
        #expect(parsed?.title == "One More Time")
        #expect(Track.artistAndTitle(fromFileName: "NoDash.mp3") == nil)
        let t = TrackMetadata.makeTrack(info: .init(duration: 3), fileName: "Band - Tune.mp3", source: .local(fileName: "Band - Tune.mp3"))
        #expect(t.title == "Tune")
        #expect(t.artist == "Band")
        #expect(t.album == Track.unknownAlbum)
    }

    @Test func tagsWinOverFileName() {
        let t = TrackMetadata.makeTrack(info: .init(title: "Real", artist: " ", album: "LP", duration: 1),
                                        fileName: "Band - Tune.mp3", source: .local(fileName: "x.mp3"))
        #expect(t.title == "Real")
        #expect(t.artist == "Band")          // blank tag falls back to file name
        #expect(t.album == "LP")
    }

    @Test func cloudCustomMetadataOverridesTags() {
        let tags = TrackMetadata.Info(title: "Tag Title", artist: "Tag Artist", album: "Tag Album", duration: 200)
        let merged = TrackMetadata.merge(custom: ["artist": "Custom Artist", "title": " ", "duration": "241"], tags: tags)
        #expect(merged == .init(title: "Tag Title", artist: "Custom Artist", album: "Tag Album", duration: 241))
        #expect(TrackMetadata.merge(custom: [:], tags: tags) == tags)
        #expect(TrackMetadata.merge(custom: [:], tags: nil) == .init(duration: 0))
    }

    @Test func cloudTagCacheRoundTrips() throws {
        let cache = CloudTagCache(fileURL: try tempDir().appending(path: "sub/tags.json"))
        #expect(cache.load().isEmpty)
        let entries = ["music/a.mp3": CloudTagCache.Entry(stamp: "abc", info: .init(title: "A", artist: "B", album: nil, duration: 3))]
        cache.save(entries)
        #expect(cache.load() == entries)
    }

    @Test func cloudCacheRemovesStaleCopy() throws {
        let cache = CloudCache(folder: try tempDir())
        try Data("old".utf8).write(to: cache.fileURL(forPath: "music/sub/a.mp3"))
        #expect(cache.cachedFile(forPath: "music/sub/a.mp3") != nil)
        cache.remove(forPath: "music/sub/a.mp3")
        #expect(cache.cachedFile(forPath: "music/sub/a.mp3") == nil)
        cache.remove(forPath: "music/never-cached.mp3")      // no-op, no crash
    }

    @Test @MainActor func localLibraryImportAndDelete() async throws {
        let root = try tempDir()
        let source = try tempDir().appending(path: "Artist - Track.mp3")
        try Data("fake".utf8).write(to: source)

        let library = LocalLibrary(root: root)
        let result = await library.importFiles([source, source])
        #expect(result.imported == 2)
        #expect(library.tracks.count == 2)                         // second copy got a unique name
        #expect(library.tracks.map(\.title).allSatisfy { $0.hasPrefix("Track") })

        // A fresh instance reads the persisted index.
        let reopened = LocalLibrary(root: root)
        #expect(Set(reopened.tracks) == Set(library.tracks))

        let victim = try #require(reopened.tracks.first)
        // File names with spaces must resolve (URL.path() percent-encodes by default).
        #expect(FileManager.default.fileExists(atPath: try #require(reopened.fileURL(for: victim)).path(percentEncoded: false)))
        try reopened.delete(victim.id)
        #expect(reopened.tracks.count == 1)
        #expect(!FileManager.default.fileExists(atPath: try #require(reopened.fileURL(for: victim)).path(percentEncoded: false)))
    }

    @Test @MainActor func reconcilePicksUpAndDropsFiles() async throws {
        let root = try tempDir()
        let library = LocalLibrary(root: root)
        try Data("x".utf8).write(to: library.musicFolder.appending(path: "dropped.m4a"))
        try Data("x".utf8).write(to: library.musicFolder.appending(path: "notes.txt"))
        await library.reconcile()
        #expect(library.tracks.map(\.title) == ["dropped"])
        try FileManager.default.removeItem(at: library.musicFolder.appending(path: "dropped.m4a"))
        await library.reconcile()
        #expect(library.tracks.isEmpty)
    }
}

struct PlaybackQueueTests {
    let tracks = (0..<5).map { Track(title: "T\($0)", source: .local(fileName: "\($0).mp3")) }

    @Test func linearNextAndEnd() {
        var q = PlaybackQueue()
        q.load(tracks, startAt: 3, shuffled: false)
        #expect(q.current?.title == "T3")
        #expect(q.positionLabel == "4 of 5")
        #expect(q.advance(userInitiated: true)?.title == "T4")
        #expect(q.advance(userInitiated: true) == nil)            // repeat off: end
        #expect(q.current?.title == "T4")
    }

    @Test func repeatAllWrapsBothWays() {
        var q = PlaybackQueue()
        q.load(tracks, startAt: 4, shuffled: false)
        q.repeatMode = .all
        #expect(q.advance(userInitiated: false)?.title == "T0")
        #expect(q.retreat()?.title == "T4")
    }

    @Test func repeatOneOnlyForNaturalEnd() {
        var q = PlaybackQueue()
        q.load(tracks, startAt: 1, shuffled: false)
        q.repeatMode = .one
        #expect(q.advance(userInitiated: false)?.title == "T1")
        #expect(q.advance(userInitiated: true)?.title == "T2")
    }

    @Test func shuffleStartsWithChosenTrackAndCoversAll() {
        var q = PlaybackQueue()
        var rng = SeededRNG(seed: 42)
        q.load(tracks, startAt: 2, shuffled: true, using: &rng)
        #expect(q.current?.title == "T2")
        #expect(Set(q.order) == Set(0..<5))
        #expect(q.order.count == 5)
    }

    @Test func toggleShuffleKeepsCurrentTrack() {
        var q = PlaybackQueue()
        var rng = SeededRNG(seed: 7)
        q.load(tracks, startAt: 3, shuffled: false)
        q.setShuffle(true, using: &rng)
        #expect(q.current?.title == "T3")
        #expect(q.order.first == 3)
        q.setShuffle(false, using: &rng)
        #expect(q.current?.title == "T3")
        #expect(q.order == Array(0..<5))
    }

    @Test func retreatAtStartStays() {
        var q = PlaybackQueue()
        q.load(tracks, startAt: 0, shuffled: false)
        #expect(q.retreat()?.title == "T0")
    }
}

/// Deterministic RNG for shuffle tests (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
