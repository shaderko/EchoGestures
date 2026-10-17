import Foundation

/// Timed instruction labels, never physical ground truth. The UI advances without capture buttons.
struct GuidedLesson {
    enum Stage { case neutral, prepare, perform, rest, finished }
    let gestureID: UUID
    private(set) var repetition = 0
    private(set) var stage: Stage = .neutral
    private(set) var startedAt: Double
    private(set) var performed: [GestureExample] = []
    private(set) var neutral: [GestureExample] = []
    private var frames: [[Double]] = []
    static let repetitions = 4

    init(gestureID: UUID, time: Double) { self.gestureID = gestureID; startedAt = time }
    var duration: Double {
        switch stage {
        case .neutral: return 3
        case .prepare: return 2
        case .perform: return 1.8
        case .rest: return 1.8
        case .finished: return 0
        }
    }
    var capturing: Bool { stage == .neutral || stage == .perform || stage == .rest }
    func remaining(at time: Double) -> Int { max(0, Int(ceil(duration - (time - startedAt)))) }
    mutating func capture(_ frame: [Double], at time: Double? = nil) {
        guard capturing, EchoFeatures.valid(frame), frames.count < 120 else { return }
        // Returning from a swipe or opening a fist is a transition, not rest.
        // Leave time to settle before assigning new frames a neutral label.
        if let time, stage == .rest, time - startedAt < 0.8 { return }
        frames.append(frame)
    }
    @discardableResult mutating func advance(at time: Double) -> Bool {
        guard time.isFinite, stage != .finished, time - startedAt >= duration else { return false }
        if !frames.isEmpty {
            let example = GestureExample(frames: frames, duration: duration)
            if stage == .perform { performed.append(example) }
            else if capturing { neutral.append(example) }
        }
        frames = []
        switch stage {
        case .neutral: stage = .prepare
        case .prepare: stage = .perform
        case .perform: stage = .rest
        case .rest:
            repetition += 1
            stage = repetition == Self.repetitions ? .finished : .prepare
        case .finished: break
        }
        startedAt = time
        return true
    }

    /// Cancellation retains the partial recording without inventing missing frames.
    mutating func retainPartial(at time: Double) {
        guard capturing, !frames.isEmpty else { return }
        let example = GestureExample(frames: frames, duration: max(0.001, min(duration, time - startedAt)))
        if stage == .perform { performed.append(example) } else { neutral.append(example) }
        frames = []
    }
}
