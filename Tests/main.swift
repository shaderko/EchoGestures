import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAILED: " + message) }
    checks += 1
}
func frame(_ index: Int, _ amount: Double = 1) -> [Double] {
    var result = Array(repeating: 0.0, count: EchoFeatures.dimension)
    result[index] = amount
    return result
}
func withRestTail(_ frames: [[Double]]) -> [[Double]] {
    frames + Array(repeating: frames.last!, count: 3)
}
func example(_ index: Int) -> GestureExample {
    GestureExample(frames: (0..<20).map { frame(index, 1 + Double($0 % 3) * 0.001) }, duration: 1.8)
}

let paths = (0..<6).map { path in (0..<240).map { Float($0 + 1) * Float(path + 1) / 240 } }
let features = EchoFeatures.extract(paths)!
check(features.count == 402, "All six paths produce 402 features")
check(abs(features.reduce(0) { $0 + $1 * $1 } - 1) < 1e-10, "Microphone pairs have balanced total energy")
let amplified = EchoFeatures.extract(paths.map { $0.map { $0 * 4 } })!
check(zip(features, amplified).allSatisfy { abs($0 - $1) < 1e-7 }, "Common gain does not change features")
let swapped = EchoFeatures.extract([paths[1], paths[0]] + Array(paths.dropFirst(2)))!
check(features != swapped, "Speaker identity is preserved")
check(EchoFeatures.extract(Array(paths.prefix(4))) == nil, "Four paths cannot impersonate six")
var invalidPaths = paths
invalidPaths[0][20] = .nan
check(EchoFeatures.extract(invalidPaths) == nil, "Nonfinite input is rejected explicitly")
var background = EchoBackground()
for _ in 0..<36 { check(background.consume(paths) == nil, "Background frames are not training frames") }
check(background.ready && background.progress == 1, "Background ends after 36 complete frames")
check(background.consume(paths)!.allSatisfy { abs($0) < 1e-5 }, "Static baseline is subtracted independently on all paths")
check(background.count == 36, "Background stays frozen while a hand is present")

let id = UUID()
var lesson = GuidedLesson(gestureID: id, time: 0)
var time = 0.0
var stages = 0
while lesson.stage != .finished {
    if lesson.capturing { lesson.capture(frame(1)) }
    time = lesson.startedAt + lesson.duration + 1e-6
    check(lesson.advance(at: time), "Automatic lesson advances")
    stages += 1
}
check(stages == 13 && lesson.performed.count == 4 && lesson.neutral.count == 5, "One lesson captures four repetitions and five rest examples")
check(abs(time - 25.4) < 1e-3, "Lesson has a bounded 25.4 second protocol")
var partial = GuidedLesson(gestureID: id, time: 0)
partial.capture(frame(0))
partial.retainPartial(at: 1)
check(partial.neutral.count == 1 && partial.performed.isEmpty, "Cancellation retains partial neutral data")
var emptyLesson = GuidedLesson(gestureID: id, time: 0)
_ = emptyLesson.advance(at: 3)
check(emptyLesson.neutral.isEmpty, "Missing audio never creates fake examples")

var library = GestureLibrary()
library.neutral = [example(0), example(0)]
library.gestures = [
    LearnedGesture(name: "My first shape", kind: .pose, examples: [example(1), example(1)]),
    LearnedGesture(name: "A different shape", kind: .pose, examples: [example(2), example(2)])
]
try library.validate()
var recognizer = GestureRecognizer()
recognizer.fit(library)
check(recognizer.ready, "User-defined poses fit without built-in semantics")
let rest = recognizer.predict(frame(0), time: 1)!
check(rest.neutral && !rest.accepted, "Learned rest is distinct from both gestures")
var first = rest
for index in 1...12 { first = recognizer.predict(frame(1), time: 1 + Double(index) * 0.085)! }
check(first.gestureID == library.gestures[0].id && first.accepted, "First user pose is recognized")
var second = first
for index in 13...24 { second = recognizer.predict(frame(2), time: 1 + Double(index) * 0.085)! }
check(second.gestureID == library.gestures[1].id && second.accepted, "Second user pose is recognized")
check(recognizer.predict(frame(1), time: 1.16) == nil, "Out-of-order frames cannot change live predictions")
check(recognizer.predict([.nan], time: 4) == nil, "Malformed feature frames do not reach a classifier")
library.gestures[0].enabled = false
recognizer.fit(library)
check(recognizer.predict(frame(1), time: 3)?.gestureID != library.gestures[0].id, "Disabled gestures cannot be predicted or dispatched")

let prediction = GesturePrediction(gestureID: id, score: 0.9, accepted: true, neutral: false)
let neutral = GesturePrediction(gestureID: nil, score: 0, accepted: false, neutral: true)
var gate = GestureEventGate()
check(gate.update(prediction, time: 0) == nil && gate.update(prediction, time: 0.085) == nil, "Starting inside a gesture never fires a command")
for step in 2..<5 { _ = gate.update(neutral, time: Double(step) * 0.085) }
check(gate.update(prediction, time: 0.425) == nil, "One matching frame cannot trigger")
check(gate.update(prediction, time: 0.51) == id, "Rest followed by persistent gesture triggers once")
for step in 7..<25 { check(gate.update(prediction, time: Double(step) * 0.085) == nil, "A held gesture does not repeat commands") }
for step in 25..<28 { _ = gate.update(neutral, time: Double(step) * 0.085) }
_ = gate.update(prediction, time: 2.38)
check(gate.update(prediction, time: 2.465) == id, "Returning to rest re-arms a deliberate repeat")
gate.reset()
for step in 0..<3 { _ = gate.update(neutral, time: 4 + Double(step) * 0.085) }
check(gate.update(prediction, time: 5) == nil && gate.update(prediction, time: 5.085) == nil, "An audio gap disarms even a previously armed command")
var badPrediction = prediction
badPrediction.score = .nan
check(gate.update(badPrediction, time: 5.17) == nil, "Nonfinite scores cannot dispatch commands")

let forward = (0..<20).map { index -> [Double] in
    var result = frame(1, 1 - Double(index) / 20)
    result[2] = Double(index) / 20
    return result
}
let reverse = Array(forward.reversed())
let template = SequenceMatcher.resample(forward)
check(template.count == 12, "Motion resampling has bounded dimensions")
check(SequenceMatcher.distance(template, template) == 0, "Identical motion has zero DTW distance")
check(SequenceMatcher.distance(template, SequenceMatcher.resample(reverse)) > 0.3, "Motion direction survives time warping")
check(SequenceMatcher.activity([frame(0), frame(0)]) == 0, "Stillness is not movement")
check(SequenceMatcher.distance([], template).isInfinite, "Missing sequences cannot match")
let pooled = SequenceMatcher.pooled((0..<21).map { frame(1, Double($0)) })
check(pooled.count == 4 && pooled.last![1] == 17.5, "All finite frames contribute to pooled teaching, including remainder frames")
var movingLibrary = GestureLibrary()
movingLibrary.neutral = [example(0)]
movingLibrary.gestures = [LearnedGesture(name: "My sweep", kind: .motion,
                                      examples: [.init(frames: forward, duration: 1.8), .init(frames: forward, duration: 1.8)])]
var movingModel = GestureRecognizer()
movingModel.fit(movingLibrary)
var movingPrediction: GesturePrediction?
for (index, value) in withRestTail(forward).enumerated() { movingPrediction = movingModel.predict(value, time: Double(index) * 0.085) }
check(movingPrediction?.gestureID == movingLibrary.gestures[0].id && movingPrediction?.accepted == true, "A user-defined ordered motion can match without a neural network")
movingModel.resetHistory()
var idleAccepted = false
for index in 0..<30 { idleAccepted = idleAccepted || (movingModel.predict(frame(0), time: 5 + Double(index) * 0.085)?.accepted ?? false) }
check(!idleAccepted, "An idle hand cannot satisfy a learned motion's activity requirement")

// Regression: a moving trajectory passes through the exact held-pose morphology.
// Movement examples must be negatives for that pose and share its class competition.
var mixedLibrary = movingLibrary
var middle = frame(1, 0.5)
middle[2] = 0.5
let heldMiddle = GestureExample(frames: Array(repeating: middle, count: 22), duration: 1.8)
let heldGesture = LearnedGesture(name: "Held shape", kind: .pose, examples: [heldMiddle, heldMiddle])
mixedLibrary.gestures += [heldGesture, LearnedGesture(name: "Another pose", kind: .pose, examples: [example(3), example(3)])]
var mixed = GestureRecognizer()
mixed.fit(mixedLibrary)
var posePrediction: GesturePrediction?
for index in 0..<20 { posePrediction = mixed.predict(middle, time: Double(index) * 0.085) }
check(posePrediction?.gestureID == heldGesture.id && posePrediction?.accepted == true,
      "A settled pose is distinct from a movement that passes through it")
mixed.resetHistory()
var correctMotion = 0, wrongHeld = 0
for (index, value) in withRestTail(forward).enumerated() {
    if let prediction = mixed.predict(value, time: Double(index) * 0.085), prediction.accepted {
        if prediction.gestureID == movingLibrary.gestures[0].id { correctMotion += 1 }
        if prediction.gestureID == heldGesture.id { wrongHeld += 1 }
    }
}
check(correctMotion > 0 && wrongHeld == 0, "Adding multiple poses does not turn a learned movement into a pose command")
var lateMotion = false
for index in 23..<55 {
    if let prediction = mixed.predict(middle, time: Double(index) * 0.085), index >= 33 {
        lateMotion = lateMotion || (prediction.accepted && prediction.gestureID == movingLibrary.gestures[0].id)
    }
}
check(!lateMotion, "An old movement in history cannot trigger while the recent echo is stationary")
mixed.resetHistory()
var earlyAccepted = false
for index in 0..<6 { earlyAccepted = earlyAccepted || (mixed.predict(middle, time: 8 + Double(index) * 0.085)?.accepted ?? false) }
check(!earlyAccepted, "A fresh or interrupted stream must establish consistent temporal evidence")
var manyNeutral = mixedLibrary
manyNeutral.neutral = Array(repeating: example(0), count: 100)
mixed.fit(manyNeutral)
for index in 0..<20 { posePrediction = mixed.predict(middle, time: 10 + Double(index) * 0.085) }
check(posePrediction?.gestureID == heldGesture.id && posePrediction?.accepted == true,
      "Many rest examples do not overwhelm a less frequently taught gesture")
let temporalStill = TemporalFeatures.extract(Array(repeating: middle, count: 6))!
let temporalMoving = TemporalFeatures.extract(Array(forward.prefix(6)))!
check(temporalStill.count == TemporalFeatures.dimension && temporalStill.suffix(18).allSatisfy { $0 == 0 },
      "Stillness has an explicit zero temporal descriptor")
check(temporalMoving.suffix(18).contains { $0 > 0 }, "Movement has temporal evidence beyond current hand shape")
var settlingLesson = GuidedLesson(gestureID: id, time: 0)
_ = settlingLesson.advance(at: 3.01)
_ = settlingLesson.advance(at: 5.02)
_ = settlingLesson.advance(at: 6.83)
settlingLesson.capture(frame(1), at: 7.03)
settlingLesson.capture(frame(0), at: 7.73)
_ = settlingLesson.advance(at: 8.64)
check(settlingLesson.neutral.count == 1 && settlingLesson.neutral[0].frames == [frame(0)],
      "Returning from a gesture is not mislabeled as stationary rest in new lessons")

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("EchoGestures-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: temporary) }
let store = LibraryStore(directory: temporary)
let emptyLibrary = try store.load()
check(emptyLibrary.gestures.isEmpty, "First launch starts with an empty user library")
library.gestures[1].shortcut = Shortcut(key: "Right", command: true, shift: true)
try store.save(library)
let restored = try store.load()
check(restored.gestures.map(\.id) == library.gestures.map(\.id), "Gesture identities persist across launches")
check(restored.gestures[1].shortcut?.label == "⇧⌘Right", "Shortcut modifiers and key survive storage")
check(restored.gestures[0].examples == library.gestures[0].examples, "Captured examples survive exact round trip")
var restoredModel = GestureRecognizer()
restoredModel.fit(restored)
check(restoredModel.ready, "Saved examples rebuild a ready model")
try store.archiveLesson(gesture: library.gestures[1], examples: [example(2)], neutral: [example(0)], completed: false)
let recordings = try FileManager.default.contentsOfDirectory(at: temporary.appendingPathComponent("Recordings"), includingPropertiesForKeys: nil)
check(recordings.count == 1, "Partial lessons have independent local archives")
check(!Shortcut(key: "Unknown").valid && Shortcut(key: "Space", command: false).valid, "Only supported keys can be configured")
var invalidLibrary = library
invalidLibrary.gestures[1].examples[0].frames[0][0] = .infinity
do { try store.save(invalidLibrary); fatalError("Invalid library was saved") } catch { checks += 1 }
let afterFailedSave = try store.load()
check(afterFailedSave.gestures[1].examples == restored.gestures[1].examples, "A failed save preserves the previous library")
invalidLibrary = library
invalidLibrary.version = 2
do { try invalidLibrary.validate(); fatalError("Unsupported schema accepted") } catch { checks += 1 }
let gestureToDelete = library.gestures[1]
let deletedLibrary = try store.deleting(gestureToDelete.id, from: library)
check(!deletedLibrary.gestures.contains { $0.id == gestureToDelete.id }, "Deleting removes only the selected gesture from recognition and bindings")
check(deletedLibrary.neutral == library.neutral && deletedLibrary.gestures[0].id == library.gestures[0].id,
      "Deleting preserves rest data and other gestures")
let deletedArchives = try FileManager.default.contentsOfDirectory(at: temporary.appendingPathComponent("Deleted Gestures"), includingPropertiesForKeys: nil)
let archivedGesture = try JSONDecoder().decode(LearnedGesture.self, from: Data(contentsOf: deletedArchives[0]))
check(archivedGesture.id == gestureToDelete.id && archivedGesture.examples == gestureToDelete.examples && archivedGesture.shortcut == gestureToDelete.shortcut,
      "Deleted gesture definitions, samples and bindings remain recoverable")
check(FileManager.default.fileExists(atPath: recordings[0].path), "Deleting a gesture retains its lesson archives")
try store.save(library)
let restoredDeletion = try store.load()
check(restoredDeletion.gestures.map(\.id) == library.gestures.map(\.id), "Undo restores the original gesture and ordering")
let damaged = Data("unreadable existing library".utf8)
try damaged.write(to: store.libraryURL)
do { try store.save(library); fatalError("Damaged library was overwritten") } catch { checks += 1 }
check(try! Data(contentsOf: store.libraryURL) == damaged, "An unreadable saved library is preserved for recovery")

// Enter/exit regression: user-held poses produce a lifecycle, not repeated toggles.
var lifecycle = GestureLifecycle()
let heldIDs: Set<UUID> = [id]
for index in 0..<3 { check(lifecycle.update(neutral, time: Double(index) * 0.085, heldGestures: heldIDs).isEmpty, "Rest arms without entering a held command") }
check(lifecycle.update(prediction, time: 0.255, heldGestures: heldIDs).isEmpty, "Held entry requires persistent acceptance")
check(lifecycle.update(prediction, time: 0.34, heldGestures: heldIDs) == [.entered(id)], "Held gesture enters once")
for index in 5..<18 { check(lifecycle.update(prediction, time: Double(index) * 0.085, heldGestures: heldIDs).isEmpty, "Holding never repeats the enter shortcut") }
var ambiguous = prediction
ambiguous.accepted = false
check(lifecycle.update(ambiguous, time: 1.53, heldGestures: heldIDs).isEmpty, "One uncertain frame does not release a held gesture")
check(lifecycle.update(prediction, time: 1.615, heldGestures: heldIDs).isEmpty && lifecycle.held == id, "A brief recognition wobble retains the held action")
check(lifecycle.update(neutral, time: 1.7, heldGestures: heldIDs).isEmpty, "One neutral frame is not release")
check(lifecycle.update(neutral, time: 1.785, heldGestures: heldIDs).isEmpty, "Two neutral frames are not release")
check(lifecycle.update(neutral, time: 1.87, heldGestures: heldIDs) == [.exited(id)], "Stable rest runs one exit shortcut")
check(lifecycle.update(neutral, time: 1.955, heldGestures: heldIDs).isEmpty, "Rest cannot repeat an exit shortcut")
_ = lifecycle.update(prediction, time: 2.04, heldGestures: heldIDs)
check(lifecycle.update(prediction, time: 2.125, heldGestures: heldIDs) == [.entered(id)], "A new held cycle can enter after release")
check(lifecycle.cancel() == [.exited(id)] && lifecycle.cancel().isEmpty, "Stopping or pausing releases a held action exactly once")
_ = lifecycle.update(prediction, time: 3, heldGestures: heldIDs)
check(lifecycle.update(prediction, time: 3.085, heldGestures: heldIDs).isEmpty, "Starting inside a fist still requires rest before entry")
for index in 0..<3 { _ = lifecycle.update(neutral, time: 4 + Double(index) * 0.085, heldGestures: heldIDs) }
_ = lifecycle.update(prediction, time: 4.255, heldGestures: heldIDs)
_ = lifecycle.update(prediction, time: 4.34, heldGestures: heldIDs)
check(lifecycle.update(prediction, time: 5, heldGestures: heldIDs) == [.exited(id)], "A capture gap cleans up the held action without re-entering")
check(lifecycle.update(prediction, time: 4.9, heldGestures: heldIDs).isEmpty, "A late frame cannot create another lifecycle event")
for index in 0..<3 { _ = lifecycle.update(neutral, time: 6 + Double(index) * 0.085, heldGestures: heldIDs) }
_ = lifecycle.update(prediction, time: 6.255, heldGestures: heldIDs)
_ = lifecycle.update(prediction, time: 6.34, heldGestures: heldIDs)
var uncertainRelease: [GestureLifecycleEvent] = []
for index in 5..<14 { uncertainRelease += lifecycle.update(ambiguous, time: 6 + Double(index) * 0.085, heldGestures: heldIDs) }
check(uncertainRelease == [.exited(id)], "Sustained uncertainty releases once instead of leaving an action stuck")

var commandSession = CommandSession<Int>()
check(commandSession.release(id) == nil, "A preview or failed entry cannot send an exit command")
let exitKey = Shortcut(key: "Space", command: false)
commandSession.remember(id, target: 42, exit: exitKey)
let releaseCommand = commandSession.release(id)
check(releaseCommand?.target == 42 && releaseCommand?.shortcut == exitKey, "Exit remembers the entry app even after the foreground app changes")
check(commandSession.release(id) == nil, "A successful entry has at most one exit dispatch")
commandSession.remember(id, target: 100, exit: nil)
check(commandSession.release(id) == nil, "A one-shot shortcut never schedules an exit")

// Existing schema-1 files decode missing exit bindings as nil; samples are untouched.
var pairedLibrary = library
pairedLibrary.gestures[1].exitShortcut = exitKey
let pairedRoundTrip = try JSONDecoder().decode(GestureLibrary.self, from: JSONEncoder().encode(pairedLibrary))
check(pairedRoundTrip.gestures[1].exitShortcut == exitKey, "An exit binding survives exact library round trip")
var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as! [String: Any]
var legacyGestures = legacyObject["gestures"] as! [[String: Any]]
for index in legacyGestures.indices { legacyGestures[index].removeValue(forKey: "exitShortcut") }
legacyObject["gestures"] = legacyGestures
let legacyLibrary = try JSONDecoder().decode(GestureLibrary.self, from: JSONSerialization.data(withJSONObject: legacyObject))
check(legacyLibrary.gestures.allSatisfy { $0.exitShortcut == nil }, "Earlier teaching files load without migration or invented exit commands")
pairedLibrary.gestures[1].shortcut = nil
do { try pairedLibrary.validate(); fatalError("Exit without entry accepted") } catch { checks += 1 }

// A strong accepted class must not remain blocked solely because rest never wins.
var readyGate = GestureEventGate()
readyGate.arm()
check(readyGate.update(prediction, time: 0) == nil && readyGate.update(prediction, time: 0.085) == id,
      "Explicit command enable arms the first settled gesture without a rest-class prerequisite")
let nextID = UUID()
let nextPrediction = GesturePrediction(gestureID: nextID, score: 0.99, accepted: true, neutral: false)
for index in 2..<12 { _ = readyGate.update(prediction, time: Double(index) * 0.085) }
check(readyGate.update(nextPrediction, time: 1.02) == nil && readyGate.update(nextPrediction, time: 1.105) == nextID,
      "A distinct stable gesture triggers directly without a neutral interlude")
var highScoreUnmatched = nextPrediction
highScoreUnmatched.accepted = false
for index in 14..<21 { _ = readyGate.update(highScoreUnmatched, time: Double(index) * 0.085) }
check(readyGate.waitingForRest, "A brief rejection burst does not re-arm a held action")
_ = readyGate.update(highScoreUnmatched, time: 1.785)
check(!readyGate.waitingForRest, "A completed movement releases even when its class similarity stays high")
_ = readyGate.update(nextPrediction, time: 1.87)
check(readyGate.update(nextPrediction, time: 1.955) == nextID,
      "A deliberate repeat fires after release without requiring a winning rest label")
for index in 24..<44 { check(readyGate.update(nextPrediction, time: Double(index) * 0.085) == nil,
      "A continuously accepted gesture cannot repeatedly trigger despite a full similarity bar") }
readyGate.reset()
readyGate.arm()
_ = readyGate.update(prediction, time: 5)
check(readyGate.update(prediction, time: 5.085) == id, "Re-arming after fresh recovery accepts a new stable gesture")

var switchLifecycle = GestureLifecycle()
switchLifecycle.arm()
_ = switchLifecycle.update(prediction, time: 0, heldGestures: [id])
check(switchLifecycle.update(prediction, time: 0.085, heldGestures: [id]) == [.entered(id)], "Explicitly armed held lifecycle enters without an extra rest cycle")
for index in 2..<12 { _ = switchLifecycle.update(prediction, time: Double(index) * 0.085, heldGestures: [id]) }
_ = switchLifecycle.update(nextPrediction, time: 1.02, heldGestures: [id])
_ = switchLifecycle.update(nextPrediction, time: 1.105, heldGestures: [id])
check(switchLifecycle.update(nextPrediction, time: 1.19, heldGestures: [id]) == [.exited(id), .entered(nextID)],
      "A different gesture exits the held action before consuming and dispatching the new entry")

var freshness = CaptureFreshness()
check(freshness.accept(captured: 100, now: 100.08), "A fresh capture timestamp reaches recognition")
check(!freshness.accept(captured: 100.085, now: 101), "A queued old frame cannot become a new gesture command")
check(freshness.accept(captured: 101, now: 101.06), "A stale frame does not poison later fresh captures")
check(!freshness.accept(captured: 100.9, now: 101.07), "Late capture order is rejected before recognition")
check(!freshness.accept(captured: nil, now: 102), "Missing capture clocks cannot masquerade as current audio")
check(!freshness.accept(captured: .nan, now: 102), "Nonfinite capture clocks cannot trigger")
check(!freshness.accept(captured: 103, now: 102), "A future clock mismatch is explicit instead of silently accepted")
check(freshness.rejected == 5, "All capture clock rejects are counted")
var health = CaptureHealth()
for index in 0..<2000 {
    health.append(.init(elapsed: Double(index), captureAgeMilliseconds: 30, linkDB: [], directSamples: [],
                        backgroundProgress: 1, residualEnergy: [], accepted: index % 2 == 0, reason: "synthetic"))
}
check(health.first.count == 120 && health.recent.count == 720 && health.total == 2000,
      "Long-running diagnostics retain a bounded first and recent window")
check(health.orderedRecent.first?.elapsed == 1280 && health.orderedRecent.last?.elapsed == 1999,
      "Circular diagnostic windows retain chronological order")
check(health.rejected == 1000, "Skipped frames remain counted after diagnostic rotation")
let diagnosticJSON = try JSONEncoder().encode(health.orderedRecent)
let decodedDiagnostics = try JSONDecoder().decode([CaptureHealthRow].self, from: diagnosticJSON)
check(decodedDiagnostics.count == 720,
      "Numeric timing reports can be inspected after capture")

// Opposite trajectories can share activity but must retain opposite signed change.
let directionForward = TemporalFeatures.extract(Array(forward.prefix(6)))!
let directionReverse = TemporalFeatures.extract(Array(forward.prefix(6).reversed()))!
let signedRange = EchoFeatures.dimension..<(EchoFeatures.dimension * 2)
check(signedRange.allSatisfy { abs(directionForward[$0] + directionReverse[$0]) < 1e-12 },
      "Reversing a trajectory reverses its signed temporal descriptor")
check(directionForward.suffix(18).enumerated().allSatisfy { abs($0.element - directionReverse.suffix(18)[directionReverse.count - 18 + $0.offset]) < 1e-12 },
      "Opposite directions retain equal energy, requiring signed features to distinguish them")

var directionalLibrary = movingLibrary
let reverseGesture = LearnedGesture(name: "Reverse sweep", kind: .motion,
    examples: [.init(frames: reverse, duration: 1.8), .init(frames: reverse, duration: 1.8)])
directionalLibrary.gestures.append(reverseGesture)
var directionalModel = GestureRecognizer()
directionalModel.fit(directionalLibrary)
for (trajectory, expectedID) in [(forward, directionalLibrary.gestures[0].id), (reverse, reverseGesture.id)] {
    directionalModel.resetHistory()
    var acceptedIDs: [UUID] = []
    for (index, value) in withRestTail(trajectory).enumerated() {
        if let p = directionalModel.predict(value, time: Double(index) * 0.085), p.accepted, let id = p.gestureID {
            acceptedIDs.append(id)
        }
    }
    check(!acceptedIDs.isEmpty && acceptedIDs.allSatisfy { $0 == expectedID },
          "Opposite synthetic sweeps select their own gesture without accepting the other direction")
}

// Unwanted movement is learned as no-command evidence, not silently discarded.
var ignoredLibrary = movingLibrary
ignoredLibrary.ignored = [.init(frames: reverse, duration: 1.8), .init(frames: reverse, duration: 1.8)]
var ignoredModel = GestureRecognizer()
ignoredModel.fit(ignoredLibrary)
var ignoredAccepted = false
for (index, value) in withRestTail(reverse).enumerated() {
    let p = ignoredModel.predict(value, time: Double(index) * 0.085)
    ignoredAccepted = ignoredAccepted || (p?.accepted ?? false)
}
check(!ignoredAccepted, "A taught ignored trajectory cannot trigger the opposing motion in this synthetic fixture")
ignoredModel.resetHistory()
var wantedAccepted = false
for (index, value) in withRestTail(forward).enumerated() {
    let p = ignoredModel.predict(value, time: Double(index) * 0.085)
    wantedAccepted = wantedAccepted || (p?.accepted ?? false)
}
check(wantedAccepted, "Ignored examples do not disable the distinct wanted synthetic trajectory")
let ignoredRoundTrip = try JSONDecoder().decode(GestureLibrary.self, from: JSONEncoder().encode(ignoredLibrary))
check(ignoredRoundTrip.ignored == ignoredLibrary.ignored && ignoredRoundTrip.gestures[0].examples == movingLibrary.gestures[0].examples,
      "Ignored teaching persists exactly without changing gesture examples")
check(legacyLibrary.ignored == nil, "Old libraries without ignored teaching load unchanged")
var invalidIgnored = ignoredLibrary
invalidIgnored.ignored![0].frames[0][0] = .nan
do { try invalidIgnored.validate(); fatalError("Malformed ignored example accepted") } catch { checks += 1 }
var duplicateLibrary = movingLibrary
duplicateLibrary.gestures.append(LearnedGesture(name: "Indistinguishable sweep", kind: .motion,
                                                examples: movingLibrary.gestures[0].examples))
var duplicateModel = GestureRecognizer()
duplicateModel.fit(duplicateLibrary)
var duplicateAccepted = false
for (index, value) in withRestTail(forward).enumerated() {
    duplicateAccepted = (duplicateModel.predict(value, time: Double(index) * 0.085)?.accepted ?? false) || duplicateAccepted
}
check(!duplicateAccepted, "Indistinguishable taught gestures cannot arbitrarily dispatch one command")

// Adding distinct gestures must not spend the confidence of an unchanged old pose.
var growingLibrary = GestureLibrary()
growingLibrary.neutral = [example(0), example(0)]
growingLibrary.gestures = [LearnedGesture(name: "First learned pose", kind: .pose, examples: [example(1), example(1)])]
var growingModel = GestureRecognizer()
growingModel.fit(growingLibrary)
var beforeAddition: GesturePrediction?
for index in 0..<20 { beforeAddition = growingModel.predict(frame(1), time: Double(index) * 0.085) }
check(beforeAddition?.accepted == true, "The original synthetic pose triggers before library growth")
for index in 2...32 {
    growingLibrary.gestures.append(LearnedGesture(name: "Distinct pose \(index)", kind: .pose,
                                                examples: [example(index), example(index)]))
}
growingModel.fit(growingLibrary)
var afterAddition: GesturePrediction?
for index in 0..<20 { afterAddition = growingModel.predict(frame(1), time: Double(index) * 0.085) }
check(afterAddition?.accepted == true && afterAddition?.gestureID == growingLibrary.gestures[0].id,
      "Adding 31 distinct gestures does not suppress the existing pose")
check(abs(beforeAddition!.score - afterAddition!.score) < 0.02,
      "An old pose's evidence remains stable across distinct library growth in this fixture")
growingModel.resetHistory()
var grownRest: GesturePrediction?
for index in 0..<20 { grownRest = growingModel.predict(frame(0), time: Double(index) * 0.085) }
check(grownRest?.neutral == true && grownRest?.accepted == false,
      "Library-growth scoring keeps rest distinct from every gesture")
growingModel.resetHistory()
var newestPose: GesturePrediction?
for index in 0..<20 { newestPose = growingModel.predict(frame(32), time: Double(index) * 0.085) }
check(newestPose?.accepted == true && newestPose?.gestureID == growingLibrary.gestures.last?.id,
      "The newly added synthetic pose remains usable alongside the first")
var overlappingLibrary = library
overlappingLibrary.gestures = [LearnedGesture(name: "A", kind: .pose, examples: [example(1), example(1)]),
                              LearnedGesture(name: "B", kind: .pose, examples: [example(1), example(1)])]
var overlappingModel = GestureRecognizer(); overlappingModel.fit(overlappingLibrary)
var overlapping: GesturePrediction?
for index in 0..<20 { overlapping = overlappingModel.predict(frame(1), time: Double(index) * 0.085) }
check(overlapping?.accepted == false && overlapping?.neutral == false,
      "Overlapping poses remain ambiguous instead of arbitrarily triggering after the scoring fix")

// A quick motion surrounded by waiting is one event, not a long fixed window.
let quick = [frame(1), frame(1, 0.7), frame(1, 0.3), frame(2)]
func paddedQuick(_ wait: Int) -> [[Double]] {
    Array(repeating: quick[0], count: wait) + quick + Array(repeating: quick.last!, count: 12)
}
let padded = GestureExample(frames: paddedQuick(8), duration: Double(paddedQuick(8).count - 1) * 0.085)
let trimmed = MotionBurst.teaching(padded, thresholds: .quiet)
let shiftedFrames = paddedQuick(2)
let shifted = MotionBurst.teaching(.init(frames: shiftedFrames, duration: Double(shiftedFrames.count - 1) * 0.085), thresholds: .quiet)
check(trimmed.count == 1 && trimmed[0].frames.count < padded.frames.count,
      "Teaching isolates the active burst from long leading and trailing waits")
check(trimmed[0].frames == shifted[0].frames,
      "Moving the same burst within the teaching window preserves its derived template")
check(padded.frames == paddedQuick(8), "Burst extraction leaves all original recorded frames intact")
var streamBurst = MotionBurst()
var detected: [MotionBurst.Segment] = []
for (index, frame) in padded.frames.enumerated() {
    if let segment = streamBurst.consume(frame, time: Double(index) * 0.085) { detected.append(segment) }
}
check(detected.count == 1 && detected[0].frames == trimmed[0].frames,
      "Live and teaching use identical burst boundaries on the same timed signal")
var interruptedBurst = MotionBurst()
_ = interruptedBurst.consume(frame(1), time: 0)
_ = interruptedBurst.consume(frame(2), time: 0.085)
_ = interruptedBurst.consume(frame(1), time: 0.17)
check(interruptedBurst.moving, "Two changing frames establish movement onset")
check(interruptedBurst.consume(frame(0), time: 1) == nil && !interruptedBurst.moving,
      "A capture gap clears the unfinished burst instead of joining unrelated movement")
check(interruptedBurst.consume(frame(2), time: 0.5) == nil && !interruptedBurst.moving,
      "An out-of-order frame cannot start or finish a burst")
var continuousBurst = MotionBurst()
var continuousEvents = 0
for index in 0..<100 {
    if continuousBurst.consume(frame(index % 2 + 1), time: Double(index) * 0.085) != nil { continuousEvents += 1 }
}
check(continuousEvents == 1, "Continuous movement has a bounded burst and requires settling before another")

var quickLibrary = GestureLibrary()
quickLibrary.neutral = [example(0), example(0)]
quickLibrary.gestures = [LearnedGesture(name: "Quick flick", kind: .motion, examples: [padded, padded])]
var quickModel = GestureRecognizer(); quickModel.fit(quickLibrary)
var quickGate = GestureEventGate(); quickGate.arm()
var quickEvents: [Double] = []
var earlyQuick = false
let actualEnd = Double(8 + quick.count - 1) * 0.085
for (index, frame) in padded.frames.enumerated() {
    let time = Double(index) * 0.085
    if let p = quickModel.predict(frame, time: time) {
        if time <= actualEnd { earlyQuick = earlyQuick || p.accepted }
        if quickGate.update(p, time: time) != nil { quickEvents.append(time) }
    }
}
check(!earlyQuick, "A quick shortcut is verified at movement completion, not a partial trajectory")
check(quickEvents.count == 1, "A completed quick flick produces exactly one command event")
check(quickEvents[0] - actualEnd <= 0.3,
      "Synthetic burst completion triggers within three capture intervals of its endpoint")
check(quickLibrary.gestures[0].examples == [padded, padded],
      "Learning from derived bursts preserves all saved original examples")
var stationaryMotion: GesturePrediction?
for index in 0..<8 {
    stationaryMotion = quickModel.predict(padded.frames.last!, time: Double(padded.frames.count + index) * 0.085)
}
check(stationaryMotion?.waitingForMovement == true && stationaryMotion?.accepted == false,
      "A stationary echo resembling a movement is explicitly waiting, never an accepted shortcut")
check(stationaryMotion?.rivalScore?.isFinite == true,
      "Diagnostics retain competing-class evidence separately from gesture-versus-rest similarity")

let radiusBeforeVariants = SequenceMatcher.learnedRadius(repetitions: [[template], [SequenceMatcher.resample(reverse)]])
let radiusAfterVariants = SequenceMatcher.learnedRadius(repetitions: [[template, template], [SequenceMatcher.resample(reverse), SequenceMatcher.resample(reverse)]])
check(abs(radiusBeforeVariants - radiusAfterVariants) < 1e-12 && radiusAfterVariants > 0.3,
      "Adding variants of the same recording cannot collapse learned cross-repetition tolerance")

let shortCapture = GestureExample(frames: [frame(1), frame(2)], duration: 0.085)
check(MotionBurst.teaching(shortCapture, thresholds: .quiet) == [shortCapture],
      "A short lesson capture is retained even when no complete burst can be isolated")
var quietDetector = MotionBurst()
var noiseBursts = 0
for index in 0..<100 {
    if quietDetector.consume(frame(0, 1 + Double(index % 2) * 0.001), time: Double(index) * 0.085) != nil { noiseBursts += 1 }
}
check(noiseBursts == 0, "Small stationary feature jitter does not become repeated movement bursts")
var repeatedQuick = GestureRecognizer(); repeatedQuick.fit(quickLibrary)
var repeatedGate = GestureEventGate(); repeatedGate.arm()
var repeatedCount = 0
let doubleQuick = padded.frames + padded.frames
for (index, frame) in doubleQuick.enumerated() {
    let time = Double(index) * 0.085
    if let p = repeatedQuick.predict(frame, time: time), repeatedGate.update(p, time: time) != nil { repeatedCount += 1 }
}
check(repeatedCount == 2, "Two separated quick flicks trigger twice without reusing the old burst")
var spikeModel = GestureRecognizer(); spikeModel.fit(quickLibrary)
var spikeAccepted = false
let spike = Array(repeating: frame(0), count: 8) + [frame(3)] + Array(repeating: frame(0), count: 12)
for (index, frame) in spike.enumerated() {
    spikeAccepted = (spikeModel.predict(frame, time: Double(index) * 0.085)?.accepted ?? false) || spikeAccepted
}
check(!spikeAccepted, "An unrelated single-frame excursion does not satisfy the taught quick-flick sequence")

// Open-set rejection: high linear evidence is not proof of a taught pattern.
var openLibrary = GestureLibrary()
openLibrary.neutral = [example(0), example(0)]
openLibrary.gestures = [LearnedGesture(name: "Known shape", kind: .pose, examples: [example(1), example(1)])]
var openModel = GestureRecognizer(); openModel.fit(openLibrary)
var extrapolated: GesturePrediction?
for index in 0..<25 { extrapolated = openModel.predict(frame(1, 4), time: Double(index) * 0.085) }
check(extrapolated?.score ?? 0 > 0.9, "The extrapolation fixture has a high discriminative score")
check(extrapolated?.accepted == false && extrapolated?.detail?.contains("Unknown echo") == true,
      "A high classifier score far from all taught shapes is explicitly rejected as unknown")
openModel.resetHistory()
var knownAgain: GesturePrediction?
for index in 0..<25 { knownAgain = openModel.predict(frame(1), time: Double(index) * 0.085) }
check(knownAgain?.accepted == true, "Unknown rejection preserves the exact taught pose")
openModel.resetHistory()
var unitUnknown = frame(1, 0.8)
unitUnknown[3] = 0.6
var unitPrediction: GesturePrediction?
for index in 0..<25 { unitPrediction = openModel.predict(unitUnknown, time: Double(index) * 0.085) }
check(abs(unitUnknown.reduce(0) { $0 + $1 * $1 } - 1) < 1e-12 && (unitPrediction?.score ?? 0) > 0.9,
      "An unfamiliar unit-norm echo can also receive high discriminative evidence")
check(unitPrediction?.accepted == false,
      "Unknown rejection applies within normalized feature space, not only to impossible gains")
openModel.resetHistory()
var nearbyPrediction: GesturePrediction?
for index in 0..<25 { nearbyPrediction = openModel.predict(frame(1, 1.01), time: Double(index) * 0.085) }
check(nearbyPrediction?.accepted == true,
      "Small changes around a taught echo remain usable with the unknown-pattern guard")
let knownInput = TemporalFeatures.extract(Array(repeating: frame(1), count: 6))!
let unknownInput = TemporalFeatures.extract(Array(repeating: frame(1, 4), count: 6))!
let recordedSupport = GestureSupport(repetitions: [[knownInput], [knownInput]])
check(recordedSupport.supports(knownInput) && !recordedSupport.supports(unknownInput),
      "Local example support bounds an otherwise unbounded linear class")
var ignoredPoseLibrary = openLibrary
ignoredPoseLibrary.ignored = [example(1), example(1)]
ignoredPoseLibrary.neutral = Array(repeating: example(0), count: 100)
var ignoredPoseModel = GestureRecognizer(); ignoredPoseModel.fit(ignoredPoseLibrary)
var ignoredPose: GesturePrediction?
for index in 0..<25 { ignoredPose = ignoredPoseModel.predict(frame(1), time: Double(index) * 0.085) }
check(ignoredPose?.accepted == false,
      "Conflicting ignored evidence blocks a known pose through class competition")
var openMotion = quickLibrary
let unknownQuickFrames = padded.frames.map { $0.map { $0 * 4 } }
var openMotionModel = GestureRecognizer(); openMotionModel.fit(openMotion)
var unknownQuickEvents = 0
var unknownQuickGate = GestureEventGate(); unknownQuickGate.arm()
for (index, frame) in unknownQuickFrames.enumerated() {
    let time = Double(index) * 0.085
    if let prediction = openMotionModel.predict(frame, time: time), unknownQuickGate.update(prediction, time: time) != nil {
        unknownQuickEvents += 1
    }
}
check(unknownQuickEvents == 0, "Matching movement timing alone cannot trigger a far-away echo trajectory")

// Array measurements preserve inter-microphone phase instead of re-zeroing it.
let arrayRate = 48_000.0, arrayCarrier = 21_500.0, arrayOrigin = 120
let arrayReal = (0..<4096).map { Float(cos(2 * Double.pi * arrayCarrier / arrayRate * Double($0))) }
let arrayImaginary = (0..<4096).map { Float(sin(2 * Double.pi * arrayCarrier / arrayRate * Double($0))) }
let turnedReal = arrayImaginary.map { -$0 }
let turnedImaginary = arrayReal
let commonPhase = SonarComplexProfile.commonReferenced(real: turnedReal, imaginary: turnedImaginary,
    referenceReal: arrayReal, referenceImaginary: arrayImaginary,
    direct: arrayOrigin, rate: arrayRate, carrier: arrayCarrier, normalization: 1)
let independentPhase = SonarComplexProfile.referenced(real: turnedReal, imaginary: turnedImaginary,
    direct: arrayOrigin, rate: arrayRate, carrier: arrayCarrier, normalization: 1)
check(abs(commonPhase.real[0]) < 1e-5 && abs(commonPhase.imaginary[0] - 1) < 1e-5,
      "A common reference preserves a 90-degree difference between microphones")
check(abs(independentPhase.real[0] - 1) < 1e-5 && abs(independentPhase.imaginary[0]) < 1e-5,
      "The original independent reference removes that phase difference as expected")
let doubledPhase = SonarComplexProfile.commonReferenced(real: arrayReal.map { $0 * 2 }, imaginary: arrayImaginary.map { $0 * 2 },
    referenceReal: arrayReal, referenceImaginary: arrayImaginary,
    direct: arrayOrigin, rate: arrayRate, carrier: arrayCarrier, normalization: 1)
check(abs(doubledPhase.real[0] - 2) < 1e-5,
      "Shared amplitude scaling retains channel gain differences")
let rawProbe = (0..<512).map { Float(sin(Double($0) * 0.21)) }
let duplicateMetrics = ArrayInputMetrics.measure([rawProbe, rawProbe, rawProbe.map { -$0 }])
check(abs(duplicateMetrics.pairs[0].correlation! - 1) < 1e-10 && duplicateMetrics.pairs[0].relativeDifference == 0,
      "Array diagnostics expose exact duplicated raw input streams")
check(duplicateMetrics.pairs[1].correlation! < -0.99 && duplicateMetrics.pairs[1].relativeDifference! > 1,
      "Distinct inverted inputs are not mistaken for duplicates")
let silentMetrics = ArrayInputMetrics.measure(Array(repeating: Array(repeating: Float(0), count: 512), count: 3))
check(silentMetrics.pairs.allSatisfy { $0.correlation == nil && $0.relativeDifference == nil },
      "Silent inputs report undefined similarity instead of claiming distinct microphones")
func arrayEcho(_ time: Double) -> SonarEcho {
    SonarEcho(captureTime: time, left: Array(repeating: 0, count: 240), right: Array(repeating: 0, count: 240),
        timingLeader: "left", leftEnvelope: [], rightEnvelope: [], leftDirectSample: arrayOrigin, rightDirectSample: arrayOrigin,
        leftLinkDB: 30, rightLinkDB: 30, clipping: false, bands: [], receivedFrames: 4096, inputGap: false,
        sampleRate: arrayRate, leftRawReal: arrayReal, leftRawImaginary: arrayImaginary,
        rightRawReal: arrayReal, rightRawImaginary: arrayImaginary)
}
let arrayFrame = ArrayMeasurement.make([arrayEcho(1), arrayEcho(1), arrayEcho(1)], input: duplicateMetrics)!
check(arrayFrame.commonProfiles.count == 6 && arrayFrame.valid && arrayFrame.relativeDirectSamples.allSatisfy { $0 == 0 },
      "One synchronized capture retains six profiles and their common timing origin")
check(ArrayMeasurement.make([arrayEcho(1), arrayEcho(1.01), arrayEcho(1)], input: duplicateMetrics) == nil,
      "Different channel timestamps cannot masquerade as a synchronized array measurement")
var measurementStudy = ArrayStudy()
measurementStudy.append(arrayFrame, now: 100)
check(measurementStudy.rows.count == 1 && measurementStudy.rows[0].stage == "rest",
      "Array comparison begins with recorded stillness, independent of gesture training")
measurementStudy.append(arrayFrame, now: 106)
check(measurementStudy.rows.last?.stage == "hand-left-right", "Timed array comparison labels hand-only movement")
measurementStudy.append(arrayFrame, now: 118)
check(measurementStudy.rows.last?.stage == "shoulder-only", "Timed array comparison labels shoulder-only movement separately")
measurementStudy.append(arrayFrame, now: 130)
check(measurementStudy.finished && measurementStudy.rows.count == 3, "Array comparison stops at 30 seconds without inventing frames")
let arrayJSON = try JSONEncoder().encode(arrayFrame)
let restoredArray = try JSONDecoder().decode(ArrayMeasurement.self, from: arrayJSON)
check(restoredArray.commonProfiles[0].real == arrayFrame.commonProfiles[0].real,
      "Numerical common-phase probe responses survive exact local persistence")

// Rigid-array timing cannot follow independent microphone peak wander.
let rigidOrigins = [100,104,97,105,98,105]
var rigidClock = RigidArrayClock()
var rigidState: RigidArrayClock.State?
for index in 0..<36 { rigidState = rigidClock.update(anchors: rigidOrigins, time: Double(index)*0.085, qualified: true) }
check(rigidState?.ready == true && rigidState?.anchors == rigidOrigins, "Still calibration fixes all six receiver/probe offsets")
let initialEpoch = rigidState!.epoch
rigidState = rigidClock.update(anchors: [107,111,97,105,102,109], time: 36*0.085, qualified: true)
check(rigidState?.heldForDisagreement == true && rigidState?.anchors == rigidOrigins,
      "Independent moving peaks cannot move the rigid array's timing reference")
rigidState = rigidClock.update(anchors: rigidOrigins.map { $0+1 }, time: 37*0.085, qualified: true)
check(rigidState?.shift == 1 && rigidState?.anchors == rigidOrigins.map { $0+1 }, "A unanimous one-sample clock drift moves every receiver together")
check(rigidClock.update(anchors: rigidOrigins, time: 1, qualified: true) == nil, "Late observations cannot rewind the shared clock")
rigidState = rigidClock.update(anchors: rigidOrigins, time: 10, qualified: true)
check(rigidState?.ready == false && rigidState?.epoch != initialEpoch, "A gap establishes a fresh timing epoch and requires still calibration")
var weakClock = RigidArrayClock()
for index in 0..<40 { rigidState = weakClock.update(anchors: rigidOrigins, time: Double(index)*0.085, qualified: false) }
check(rigidState?.ready == false && rigidState?.calibrationFrames == 0, "Weak or stale frames cannot establish fixed receiver geometry")

let workspaceEpoch = UUID()
func workspaceFrame(_ region: Int, time: Double, epoch: UUID = workspaceEpoch) -> ArrayMeasurement {
    var profiles = Array(repeating: SonarComplexProfile(real: Array(repeating: 0, count: 240), imaginary: Array(repeating: 0, count: 240)), count: 6)
    if region >= 0 {
        let center = Int((0.12 + Double(region+2)*0.78/15)/1.4*239)
        var real = Array(repeating: Float(0), count: 240)
        for index in max(0,center-5)...min(239,center+5) { real[index] = Float(0.2 * exp(-pow(Double(index-center)/3,2))) }
        profiles[region] = SonarComplexProfile(real: real, imaginary: real.map { $0*0.3 })
    } else if region == -2 {
        profiles = profiles.map { _ in SonarComplexProfile(real: Array(repeating: 0.02, count: 240), imaginary: Array(repeating: -0.02, count: 240)) }
    }
    return ArrayMeasurement(time: time, sampleRate: 48000, input: duplicateMetrics, directSamples: rigidOrigins,
        relativeDirectSamples: [0,0,-3,1,-2,1], directAmplitude: Array(repeating: 1, count: 6), linkDB: Array(repeating: 30, count: 6),
        commonProfiles: profiles, independentEnvelopes: profiles.map(\.magnitude), valid: true,
        timing: RigidArrayClock.State(epoch: epoch, calibrationFrames: 36, anchors: rigidOrigins, shift: 0, heldForDisagreement: false))
}
let workspaceFeatures = WorkspaceFeatures(frames: (0..<24).map { workspaceFrame(-1, time: Double($0)*0.085) })!
check(workspaceFeatures.extract(workspaceFrame(-1,time:3))!.allSatisfy { $0 == 0 }, "A still complex reference subtracts to zero without unit-energy amplification")
check(workspaceFeatures.extract(workspaceFrame(0,time:3))!.count == 198, "Workspace features preserve signed complex changes and six path strengths")
check(workspaceFeatures.extract(workspaceFrame(0,time:3,epoch:UUID())) == nil, "A calibration cannot silently apply to a restarted clock")
check(WorkspaceCalibration.duration == 94 && WorkspaceCalibration.trials.filter(\.validation).count == 8,
      "The guided protocol has two teaching rounds and eight separate check trials")
var calibratedWorkspace = WorkspaceCalibration()
var mapBeforeCheck: WorkspaceResponseMap?
for index in 0...376 {
    let time = Double(index)*0.25
    let trial = time >= 6 && time < 94 ? WorkspaceCalibration.trials[Int((time-6)/4)] : nil
    let region = trial.map { $0.target.id == "rest" ? -1 : $0.target.id == "shoulder" ? -2 : WorkspaceTarget.marks.firstIndex(of: $0.target)! } ?? -1
    calibratedWorkspace.append(workspaceFrame(region,time:time))
    if time == 62 { mapBeforeCheck = calibratedWorkspace.map }
}
check(calibratedWorkspace.finished && calibratedWorkspace.map != nil, "Synthetic marked regions create one response map before the check round")
check(calibratedWorkspace.validationSummary.contains("8/8"), "The synthetic check distinguishes six regions and two background cases")
check(calibratedWorkspace.rows.filter { $0.phase == "hold" && $0.trial.map { WorkspaceCalibration.trials[$0].validation } == false }.allSatisfy { $0.prediction == nil },
      "Teaching rows are not reported as independent validation predictions")
let preCheckLeft = mapBeforeCheck!.predict(workspaceFrame(1,time:95))!
let postCheckLeft = calibratedWorkspace.map!.predict(workspaceFrame(1,time:95))!
check(preCheckLeft.region == "left" && postCheckLeft.region == preCheckLeft.region && abs(postCheckLeft.score-preCheckLeft.score)<1e-12,
      "The separate check cannot update the map's weights")
var hostileCheck = WorkspaceCalibration()
for index in 0...376 {
    let time = Double(index)*0.25
    let trial = time >= 6 && time < 94 ? WorkspaceCalibration.trials[Int((time-6)/4)] : nil
    let intended = trial.map { $0.target.id == "rest" ? -1 : $0.target.id == "shoulder" ? -2 : WorkspaceTarget.marks.firstIndex(of: $0.target)! } ?? -1
    hostileCheck.append(workspaceFrame(time >= 62 ? 0 : intended,time:time))
}
check(hostileCheck.validationSummary.contains("1/8"), "Incorrect check movements are recorded as failures, not learned to manufacture a passing result")
check(hostileCheck.map?.predict(workspaceFrame(1,time:95))?.region == "left", "Contradictory check data cannot overwrite the taught left response")
let encodedCalibrationRows = try JSONEncoder().encode(calibratedWorkspace.rows)
let decodedCalibrationRows = try JSONDecoder().decode([WorkspaceCalibration.Row].self,from:encodedCalibrationRows)
check(decodedCalibrationRows.count == calibratedWorkspace.rows.count && decodedCalibrationRows.last?.measurement.timing?.epoch == workspaceEpoch,
      "Full numeric calibration measurements and timing provenance remain inspectable")

print("Passed \(checks) feature, lesson, pose, motion, lifecycle, capture freshness and persistence checks. Synthetic recognition is not physical accuracy.")
