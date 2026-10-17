import AppKit
import Combine
import Foundation

final class AppModel: ObservableObject {
    let audio = EchoAudioEngine()
    let arrayInspector = ArrayInspector()
    @Published private(set) var inspectingArray = false
    let commands = CommandDispatcher()
    @Published private(set) var library = GestureLibrary()
    @Published private(set) var lesson: GuidedLesson?
    @Published private(set) var countdown = 0
    @Published private(set) var fitting = false
    @Published private(set) var bestGuess = "No gesture taught yet"
    @Published private(set) var similarity = 0.0
    @Published private(set) var lastEvent = "No gesture triggered"
    @Published private(set) var lastMovement: String?
    @Published private(set) var message = "Teach a gesture. Preview it, then assign a shortcut."
    @Published private(set) var commandsEnabled = false
    @Published private(set) var eventCount = 0
    @Published private(set) var triggerStatus = "Return to rest to arm a gesture."
    @Published private(set) var inferenceSummary = ""
    @Published private(set) var recognitionReportStatus = ""
    @Published private(set) var canUndoDelete = false
    @Published private(set) var teachingIgnored = false
    private var deletedGesture: (gesture: LearnedGesture, index: Int)?

    private let store: LibraryStore
    private let modelQueue = DispatchQueue(label: "dev.echogestures.learning", qos: .userInitiated)
    private var recognizer = GestureRecognizer()
    private var lifecycle = GestureLifecycle()
    private var commandSession = CommandSession<CommandDispatcher.Target>()
    private var fitID = UUID()
    private var timer: Timer?
    private var pendingGesture: UUID?
    private var pendingIgnored = false
    private var lastFeaturesAt = 0.0
    private var hasLiveFeatures = false
    private var lastInferenceSummary = 0.0
    private var changed: AnyCancellable?
    private struct RecognitionObservation: Encodable {
        let time: Double
        let gesture: String
        let gestureID: UUID?
        let similarity: Double
        let rivalSeparation: Double?
        let accepted: Bool
        let neutral: Bool
        let waitingForMovement: Bool
        let movementSeconds: Double?
        let reason: String?
        let gate: String
        let entered: Bool
        let commandsEnabled: Bool
        let lastCommandStatus: String
    }
    private var recognitionTrace: [RecognitionObservation] = []

    init(store: LibraryStore = LibraryStore()) {
        self.store = store
        do { library = try store.load() } catch { message = error.localizedDescription }
        audio.onFrame = { [weak self] frame, time in self?.consume(frame, time: time) }
        audio.onArrayMeasurement = { [weak self] measurement in
            guard let self, self.inspectingArray else { return }
            self.arrayInspector.accept(measurement, metadata: self.audio.arrayMetadata)
        }
        audio.onDiscontinuity = { [weak self] in self?.handleDiscontinuity() }
        changed = audio.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        fit()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func addGesture(name: String, kind: GestureKind) -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, library.gestures.count < 32 else { return nil }
        let gesture = LearnedGesture(name: clean, kind: kind)
        library.gestures.append(gesture)
        save()
        return gesture.id
    }

    func teach(_ id: UUID) {
        guard !fitting, lesson == nil, library.gestures.contains(where: { $0.id == id }) else { return }
        setCommands(false)
        resetRecognition()
        pendingGesture = id
        pendingIgnored = false
        if audio.running && audio.backgroundProgress >= 1 { beginLesson(id) }
        else { audio.start(); message = "Keep your hand away while empty space is measured." }
    }

    private func beginLesson(_ id: UUID) {
        pendingGesture = nil
        teachingIgnored = pendingIgnored
        pendingIgnored = false
        lesson = GuidedLesson(gestureID: id, time: ProcessInfo.processInfo.systemUptime)
        countdown = 3
        message = "Relax in your normal resting position. The lesson advances automatically."
    }

    func teachIgnoredMovement() {
        guard !fitting, lesson == nil else { return }
        setCommands(false)
        let id = UUID()
        pendingGesture = id
        pendingIgnored = true
        if audio.running && audio.backgroundProgress >= 1 { beginLesson(id) }
        else { audio.start(); message = "Keep your hand away for the background, then demonstrate movement to ignore." }
    }

    func finishLesson(cancelled: Bool = false) {
        guard var current = lesson else { return }
        if cancelled { current.retainPartial(at: ProcessInfo.processInfo.systemUptime) }
        lesson = nil
        let ignoring = teachingIgnored
        teachingIgnored = false
        let gesture: LearnedGesture
        if ignoring {
            library.ignored = Array(((library.ignored ?? []) + current.performed).suffix(128))
            gesture = LearnedGesture(id: current.gestureID, name: "Ignored movement", kind: .motion)
        } else {
            guard let index = library.gestures.firstIndex(where: { $0.id == current.gestureID }) else { return }
            library.gestures[index].examples += current.performed
            library.gestures[index].examples = Array(library.gestures[index].examples.suffix(32))
            gesture = library.gestures[index]
        }
        library.neutral += current.neutral
        library.neutral = Array(library.neutral.suffix(256))
        var archived = true
        do {
            try store.archiveLesson(gesture: gesture, examples: current.performed,
                                    neutral: current.neutral, completed: !cancelled)
        } catch { archived = false; message = "Recording could not be saved: \(error.localizedDescription)" }
        let saved = save()
        fit()
        guard archived, saved else { return }
        if current.performed.count < 2 {
            message = "Partial lesson saved. Teach again to collect at least two repetitions."
        } else { message = ignoring ? "Ignored movements saved and included in learning. Commands remain paused."
            : "Examples saved. Try the gesture in preview; commands remain paused." }
    }

    func bind(_ id: UUID, shortcut: Shortcut?, exitShortcut: Shortcut? = nil) {
        guard lesson == nil, let index = library.gestures.firstIndex(where: { $0.id == id }),
              shortcut?.valid ?? true, exitShortcut?.valid ?? true else { return }
        setCommands(false)
        library.gestures[index].shortcut = shortcut
        library.gestures[index].exitShortcut = shortcut == nil ? nil : exitShortcut
        save()
    }

    func toggleGesture(_ id: UUID) {
        guard lesson == nil, let index = library.gestures.firstIndex(where: { $0.id == id }) else { return }
        setCommands(false)
        library.gestures[index].enabled.toggle()
        save()
        fit()
    }

    func deleteGesture(_ id: UUID) {
        guard lesson == nil, !fitting, let index = library.gestures.firstIndex(where: { $0.id == id }) else { return }
        setCommands(false)
        let gesture = library.gestures[index]
        do {
            let updated = try store.deleting(id, from: library)
            deletedGesture = (gesture, index)
            canUndoDelete = true
            library = updated
            lastEvent = "No gesture triggered"
            fit()
            message = "Deleted \(gesture.name). Saved recordings retained."
        } catch { message = "Delete failed: \(error.localizedDescription)" }
    }

    func undoDelete() {
        guard lesson == nil, !fitting, let deletedGesture else { return }
        setCommands(false)
        var restored = library
        restored.gestures.insert(deletedGesture.gesture, at: min(deletedGesture.index, restored.gestures.count))
        do {
            try store.save(restored)
            library = restored
            self.deletedGesture = nil
            canUndoDelete = false
            fit()
            message = "Restored \(deletedGesture.gesture.name). Commands remain paused."
        } catch { message = "Restore failed: \(error.localizedDescription)" }
    }

    func setCommands(_ enabled: Bool) {
        resetRecognition()
        commandsEnabled = false
        guard enabled else {
            commandsEnabled = false
            message = "Commands paused · recognition stays in preview."
            return
        }
        guard !inspectingArray else { message = "Commands stay paused during array inspection."; return }
        guard commands.permitted else { message = "Enable Accessibility for EchoGestures, then enable commands."; return }
        guard recognizer.ready, audio.running, audio.backgroundProgress >= 1, !fitting, lesson == nil,
              library.gestures.contains(where: { $0.enabled && $0.examples.count >= 2 && $0.shortcut != nil }) else {
            message = "Start listening and teach a gesture with a shortcut first."
            return
        }
        commandsEnabled = true
        lifecycle.arm()
        triggerStatus = lifecycle.status
        message = "Commands enabled for the foreground app. Release to repeat; different gestures can follow directly."
    }

    func beginArrayInspection() {
        guard lesson == nil else { return }
        setCommands(false)
        inspectingArray = true
        audio.inspectArray = true
    }
    func endArrayInspection() {
        arrayInspector.finish(metadata: audio.arrayMetadata)
        inspectingArray = false
        audio.inspectArray = false
    }

    func startListening() { resetRecognition(); lifecycle.arm(); triggerStatus = lifecycle.status; audio.start() }
    func stopListening() {
        pendingGesture = nil
        pendingIgnored = false
        if lesson != nil { finishLesson(cancelled: true) }
        setCommands(false)
        arrayInspector.finish(metadata: audio.arrayMetadata)
        audio.stop()
        bestGuess = "Listening stopped"
        message = "Sound off · commands paused."
    }

    func revealData() { NSWorkspace.shared.selectFile(store.libraryURL.path, inFileViewerRootedAtPath: store.directory.path) }

    func saveDiagnostics() {
        audio.saveDiagnostics()
        struct Report: Encodable {
            let version = 1
            let featureVersion = EchoFeatures.version
            let observations: [RecognitionObservation]
            let note = "Most recent 360 predictions. Similarity and rival scores are model evidence, not probabilities. Acceptance, lifecycle entry and command status are distinct. No raw audio or echo feature vectors."
        }
        let report = Report(observations: recognitionTrace)
        let url = store.directory.appendingPathComponent("RecognitionDiagnostics/recognition-\(UUID().uuidString).json")
        recognitionReportStatus = "Saving recognition check…"
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(report).write(to: url, options: .atomic)
                DispatchQueue.main.async { self.recognitionReportStatus = "Saved signal + recognition check locally" }
            } catch {
                let detail = error.localizedDescription
                DispatchQueue.main.async { self.recognitionReportStatus = "Recognition save failed: " + detail }
            }
        }
    }

    private func consume(_ frame: [Double], time: Double) {
        lastFeaturesAt = ProcessInfo.processInfo.systemUptime
        hasLiveFeatures = true
        if let id = pendingGesture { beginLesson(id) }
        if lesson != nil { lesson?.capture(frame, at: ProcessInfo.processInfo.systemUptime); return }
        guard !inspectingArray else { return }
        let began = ProcessInfo.processInfo.systemUptime
        guard !fitting, let prediction = recognizer.predict(frame, time: time) else { return }
        if began - lastInferenceSummary > 1 {
            lastInferenceSummary = began
            inferenceSummary = String(format: "Recognition %.1f ms · %d saved rest holds",
                (ProcessInfo.processInfo.systemUptime - began) * 1000, library.neutral.count)
        }
        let name = library.gestures.first { $0.id == prediction.gestureID }?.name ?? "Unknown"
        if prediction.movementDuration != nil {
            lastMovement = "Last movement · \(name): \(prediction.detail ?? (prediction.accepted ? "matched" : "not matched"))"
        }
        similarity = prediction.neutral ? 0 : prediction.score
        let heldGestures = Set(library.gestures.filter { $0.enabled && $0.exitShortcut != nil }.map(\.id))
        let wasWaitingForRest = lifecycle.waitingForRest
        let events = lifecycle.update(prediction, time: time, heldGestures: heldGestures)
        process(events)
        if let duration = prediction.movementDuration,
           events.contains(where: { if case .entered = $0 { return true }; return false }) {
            lastEvent += String(format: " · %.0f ms movement", duration * 1000)
        }
        if prediction.neutral { bestGuess = "Resting" }
        else if prediction.waitingForMovement { bestGuess = "Closest echo: " + name }
        else if !prediction.accepted, prediction.detail?.hasPrefix("Unknown") == true {
            bestGuess = "Unknown movement · closest: " + name
        }
        else if !prediction.accepted { bestGuess = name + " · uncertain" }
        else if lifecycle.held == prediction.gestureID { bestGuess = name + " · held" }
        else if events.contains(where: { if case .entered = $0 { return true }; return false }) { bestGuess = name + " · triggered" }
        else { bestGuess = name + (wasWaitingForRest ? " · return to rest" : " · settling") }
        if let held = lifecycle.held, let name = library.gestures.first(where: { $0.id == held })?.name {
            triggerStatus = commandSession.contains(held) ? "\(name) active · release to run the exit shortcut."
                : commandsEnabled ? "\(name) held · entry command was not sent." : "\(name) held · commands paused."
        } else {
            triggerStatus = !prediction.neutral && !prediction.accepted ? prediction.detail ?? lifecycle.status : lifecycle.status
        }
        recognitionTrace.append(RecognitionObservation(time: time, gesture: name, gestureID: prediction.gestureID,
            similarity: prediction.score, rivalSeparation: prediction.rivalScore, accepted: prediction.accepted,
            neutral: prediction.neutral, waitingForMovement: prediction.waitingForMovement,
            movementSeconds: prediction.movementDuration, reason: prediction.detail, gate: triggerStatus,
            entered: events.contains { if case .entered = $0 { return true }; return false },
            commandsEnabled: commandsEnabled, lastCommandStatus: lastEvent))
        if recognitionTrace.count > 360 { recognitionTrace.removeFirst(recognitionTrace.count - 360) }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if hasLiveFeatures, now - lastFeaturesAt > 0.35 {
            resetRecognition(force: false)
            bestGuess = audio.running ? "Waiting for fresh echoes" : "Listening stopped"
        }
        guard var current = lesson else {
            if pendingGesture != nil, !audio.running, !audio.starting {
                pendingGesture = nil
                pendingIgnored = false
                message = "Could not start teaching. \(audio.status)"
            }
            return
        }
        countdown = current.remaining(at: now)
        if current.advance(at: now) {
            lesson = current
            if current.stage == .finished { finishLesson() }
        }
    }

    private func resetRecognition(force: Bool = true) {
        guard force || hasLiveFeatures else { return }
        hasLiveFeatures = false
        process(lifecycle.cancel())
        recognizer.resetHistory()
        similarity = 0
        if force { lastMovement = nil }
        triggerStatus = "Return to rest briefly to arm the next gesture."
        if !force && commandsEnabled {
            lifecycle.arm()
            triggerStatus = "Waiting for fresh echoes before the next command."
        }
    }

    private func handleDiscontinuity() {
        // Skip a bad frame; the timeout below handles sustained loss. One weak
        // probe must not silently lock an enabled command session indefinitely.
        if audio.running, hasLiveFeatures, ProcessInfo.processInfo.systemUptime - lastFeaturesAt <= 0.35 { return }
        resetRecognition(force: false)
    }

    private func process(_ events: [GestureLifecycleEvent]) {
        for event in events {
            switch event {
            case .entered(let id):
                guard let gesture = library.gestures.first(where: { $0.id == id && $0.enabled }) else { continue }
                eventCount += 1
                let phase = gesture.exitShortcut == nil ? "trigger" : "enter"
                guard commandsEnabled else { lastEvent = "\(gesture.name) · \(phase) preview (commands paused)"; continue }
                guard let shortcut = gesture.shortcut else { lastEvent = "\(gesture.name) · no shortcut assigned"; continue }
                switch commands.send(shortcut) {
                case .posted(let target):
                    commandSession.remember(id, target: target, exit: gesture.exitShortcut)
                    lastEvent = "\(gesture.name) · \(phase): \(shortcut.label) posted to \(target.name)"
                case .blocked(let reason): lastEvent = "\(gesture.name) · not sent: \(reason)"
                }
            case .exited(let id):
                let name = library.gestures.first(where: { $0.id == id })?.name ?? "Gesture"
                if let active = commandSession.release(id) {
                    switch commands.send(active.shortcut, to: active.target) {
                    case .posted(let target): lastEvent = "\(name) · exit: \(active.shortcut.label) posted to \(target.name)"
                    case .blocked(let reason): lastEvent = "\(name) · exit not sent: \(reason)"
                    }
                } else { lastEvent = "\(name) · exit preview (no entry command was sent)" }
            }
        }
    }

    private func fit() {
        fitting = true
        resetRecognition()
        let snapshot = library
        let id = UUID()
        fitID = id
        modelQueue.async { [weak self] in
            var model = GestureRecognizer()
            model.fit(snapshot)
            DispatchQueue.main.async {
                guard let self, self.fitID == id else { return }
                self.recognizer = model
                self.fitting = false
                self.bestGuess = model.ready ? "Waiting for gesture" : "Teach at least two repetitions"
            }
        }
    }

    @discardableResult private func save() -> Bool {
        do { try store.save(library); return true }
        catch { message = "Save failed: \(error.localizedDescription)"; commandsEnabled = false; return false }
    }
}
