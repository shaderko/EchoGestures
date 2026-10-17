import Foundation

/// Atomic, local-only storage. Original and partial examples remain available for future estimators.
struct LibraryStore {
    let directory: URL
    var libraryURL: URL { directory.appendingPathComponent("gestures.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoGestures", isDirectory: true)
    }

    func load() throws -> GestureLibrary {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return GestureLibrary() }
        let bytes = try libraryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes < 128_000_000 else { throw LibraryFailure("The gesture library is too large to load.") }
        let library = try JSONDecoder().decode(GestureLibrary.self, from: Data(contentsOf: libraryURL))
        try library.validate()
        return library
    }

    func save(_ library: GestureLibrary) throws {
        try library.validate()
        // A failed decode must never turn a corrupt or newer library into an empty overwrite.
        if FileManager.default.fileExists(atPath: libraryURL.path) { _ = try load() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: libraryURL, options: [.atomic])
    }

    func archiveLesson(gesture: LearnedGesture, examples: [GestureExample], neutral: [GestureExample], completed: Bool) throws {
        struct Recording: Encodable {
            let version = 1
            let featureVersion = EchoFeatures.version
            let date = Date()
            let gestureID: UUID
            let name: String
            let kind: GestureKind
            let completed: Bool
            let examples: [GestureExample]
            let neutral: [GestureExample]
        }
        let folder = directory.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = Recording(gestureID: gesture.id, name: gesture.name, kind: gesture.kind,
                                  completed: completed, examples: examples, neutral: neutral)
        try JSONEncoder().encode(recording).write(to: folder.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
    }

    /// Archive the complete definition before removing it from the active library.
    /// A failed write leaves the caller's in-memory library unchanged.
    func deleting(_ id: UUID, from library: GestureLibrary) throws -> GestureLibrary {
        guard let gesture = library.gestures.first(where: { $0.id == id }) else { return library }
        let folder = directory.appendingPathComponent("Deleted Gestures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).json")
        try JSONEncoder().encode(gesture).write(to: archive, options: .atomic)
        var updated = library
        updated.gestures.removeAll { $0.id == id }
        try save(updated)
        return updated
    }
}
