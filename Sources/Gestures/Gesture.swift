import Foundation

enum GestureKind: String, Codable, CaseIterable {
    case pose = "Hold a pose"
    case motion = "Make a movement"
}

struct GestureExample: Codable, Equatable {
    var frames: [[Double]]
    var duration: Double
    var valid: Bool {
        !frames.isEmpty && frames.count <= 120 && frames.allSatisfy(EchoFeatures.valid)
            && duration.isFinite && duration > 0 && duration <= 10
    }
}

struct LearnedGesture: Identifiable, Codable {
    var id = UUID()
    var name: String
    var kind: GestureKind
    var examples: [GestureExample] = []
    var shortcut: Shortcut?
    var exitShortcut: Shortcut? = nil
    var enabled = true
}

struct GestureLibrary: Codable {
    var version = 1
    var featureVersion = EchoFeatures.version
    var gestures: [LearnedGesture] = []
    var neutral: [GestureExample] = []
    var ignored: [GestureExample]? = nil

    func validate() throws {
        guard version == 1, featureVersion == EchoFeatures.version,
              gestures.count <= 32, Set(gestures.map(\.id)).count == gestures.count,
              neutral.count <= 256, neutral.allSatisfy(\.valid),
              (ignored ?? []).count <= 128, (ignored ?? []).allSatisfy(\.valid),
              gestures.allSatisfy({
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 60
                      && $0.examples.count <= 32 && $0.examples.allSatisfy(\.valid)
                      && ($0.shortcut?.valid ?? true)
                      && ($0.exitShortcut?.valid ?? true)
                      && ($0.exitShortcut == nil || $0.shortcut != nil)
              }) else { throw LibraryFailure("The saved gesture library has an unsupported format or invalid measurements.") }
    }
}

struct LibraryFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
