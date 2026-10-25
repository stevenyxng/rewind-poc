import Foundation

/// Songs imported into Documents/Music, indexed in a JSON file.
@Observable
final class LocalLibrary {
    private(set) var tracks: [Track] = []

    let musicFolder: URL
    private let indexURL: URL
    private var index: LibraryIndex {
        didSet { tracks = index.tracks }
    }

    /// `root` defaults to the app's Documents folder; tests pass a temp directory.
    init(root: URL = URL.documentsDirectory) {
        musicFolder = root.appending(path: "Music", directoryHint: .isDirectory)
        indexURL = root.appending(path: "library.json")
        try? FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)
        index = LibraryIndex.load(from: indexURL)
        tracks = index.tracks
    }

    func fileURL(for track: Track) -> URL? {
        guard case .local(let name) = track.source else { return nil }
        return musicFolder.appending(path: name)
    }

    /// Syncs the index with the folder: drops entries whose file is gone and indexes
    /// audio files that appeared on their own (e.g. dropped in via Finder file sharing).
    func reconcile() async {
        let files = Set(fileNames())
        index.prune(keepingFileNames: files)
        let indexed = Set(index.tracks.compactMap { track -> String? in
            if case .local(let name) = track.source { return name }
            return nil
        })
        for name in files.subtracting(indexed).sorted() where Track.isAudioFile(name) {
            await indexFile(named: name)
        }
        save()
    }

    struct ImportResult: Equatable {
        var imported = 0
        var failed: [String] = []
    }

    /// Copies picked files into Documents/Music and indexes them.
    func importFiles(_ urls: [URL]) async -> ImportResult {
        var result = ImportResult()
        var taken = Set(fileNames())
        for url in urls {
            let name = LibraryIndex.uniqueFileName(url.lastPathComponent, taken: taken)
            do {
                try await Self.copy(url, to: musicFolder.appending(path: name))
                taken.insert(name)
                await indexFile(named: name)
                result.imported += 1
            } catch {
                result.failed.append(url.lastPathComponent)
            }
        }
        save()
        return result
    }

    func delete(_ id: Track.ID) throws {
        guard let track = index.track(id: id), let url = fileURL(for: track) else { return }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
        index.remove(id: id)
        save()
    }

    // MARK: Private

    private func indexFile(named name: String) async {
        let info = await TrackMetadata.read(musicFolder.appending(path: name))
        index.upsert(TrackMetadata.makeTrack(info: info, fileName: name, source: .local(fileName: name)))
    }

    private func fileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: musicFolder.path(percentEncoded: false))) ?? []
    }

    private func save() {
        try? index.save(to: indexURL)
    }

    /// File copy off the main actor; handles security-scoped URLs from the document picker.
    @concurrent
    private nonisolated static func copy(_ source: URL, to destination: URL) async throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
