import Foundation

enum GestureLifecycleEvent: Equatable {
    case entered(UUID)
    case exited(UUID)
}

/// A held action has one entry and one exit. Short uncertainty never repeats either.
struct GestureLifecycle {
    private var entry = GestureEventGate()
    private(set) var held: UUID?
    private var lastConfirmed = 0.0
    private var releaseFrames = 0
    private var lastTime: Double?
    var waitingForRest: Bool { entry.waitingForRest }
    var status: String { entry.status }
    mutating func arm() { entry.arm() }

    mutating func cancel() -> [GestureLifecycleEvent] {
        let events = held.map { [GestureLifecycleEvent.exited($0)] } ?? []
        held = nil
        releaseFrames = 0
        lastTime = nil
        entry.reset()
        return events
    }

    mutating func update(_ prediction: GesturePrediction, time: Double, heldGestures: Set<UUID>) -> [GestureLifecycleEvent] {
        guard time.isFinite, prediction.score.isFinite else { return cancel() }
        if let lastTime, time <= lastTime { return [] }
        var events: [GestureLifecycleEvent] = []
        if let lastTime, time - lastTime > 0.35 { events += cancel() }
        lastTime = time

        if let held {
            if prediction.accepted && prediction.gestureID == held && !prediction.neutral {
                lastConfirmed = time
                releaseFrames = 0
            } else {
                if prediction.neutral || prediction.accepted { releaseFrames += 1 }
                else { releaseFrames = 0 }
                if releaseFrames >= 3 || time - lastConfirmed >= 0.65 || !heldGestures.contains(held) {
                    events.append(.exited(held))
                    self.held = nil
                    releaseFrames = 0
                }
            }
        }
        // Track release while held, but never consume a competing entry early.
        if let id = entry.update(prediction, time: time, canTrigger: held == nil) {
            events.append(.entered(id))
            if heldGestures.contains(id) { held = id; lastConfirmed = time }
        }
        return events
    }
}
