import Foundation

/// Shared offline/live boundaries. Raw lesson examples are never modified.
struct MotionBurst {
    struct Thresholds {
        var onset: Double
        var release: Double
        static let quiet = Thresholds(onset: 0.025, release: 0.015)

        static func learned(from rest: [GestureExample]) -> Self {
            let levels = rest.compactMap { example -> Double? in
                let changes = zip(example.frames, example.frames.dropFirst()).map { MotionBurst.change($0, $1) }.sorted()
                return changes.isEmpty ? nil : changes[changes.count / 2]
            }.sorted()
            let floor = levels.isEmpty ? 0 : levels[levels.count / 2]
            let onset = max(0.025, floor * 1.8)
            return Self(onset: onset, release: onset * 0.6)
        }
    }
    struct Sample {
        let frame: [Double]
        let time: Double
    }
    struct Segment {
        let samples: [Sample]
        let endedAt: Double
        var frames: [[Double]] { samples.map(\.frame) }
        var duration: Double { max(0.001, endedAt - samples[0].time) }
        var example: GestureExample { GestureExample(frames: frames, duration: duration) }
    }
    let thresholds: Thresholds
    private var previous: Sample?
    private var idle: [Sample] = []
    private var current: [Sample] = []
    private var highFrames = 0
    private var quietFrames = 0
    private var waitingForQuiet = false
    var moving: Bool { !current.isEmpty || highFrames > 0 || waitingForQuiet }

    init(thresholds: Thresholds = .quiet) { self.thresholds = thresholds }
    mutating func reset() { self = Self(thresholds: thresholds) }

    mutating func consume(_ frame: [Double], time: Double) -> Segment? {
        guard EchoFeatures.valid(frame), time.isFinite else { reset(); return nil }
        if let previous, time <= previous.time { return nil }
        if let previous, time - previous.time > 0.35 { reset() }
        let sample = Sample(frame: frame, time: time)
        let step = previous.map { Self.change($0.frame, frame) } ?? 0
        previous = sample
        if waitingForQuiet {
            quietFrames = step < thresholds.release ? quietFrames + 1 : 0
            idle = Array((idle + [sample]).suffix(4))
            if quietFrames >= 2 { waitingForQuiet = false; quietFrames = 0 }
            return nil
        }
        if current.isEmpty {
            idle = Array((idle + [sample]).suffix(4))
            highFrames = step >= thresholds.onset ? highFrames + 1 : 0
            if highFrames >= 2 {
                current = idle
                idle = []
                highFrames = 0
                quietFrames = 0
            }
            return nil
        }
        current.append(sample)
        quietFrames = step < thresholds.release ? quietFrames + 1 : 0
        if quietFrames >= 2 {
            let endedAt = current[max(0, current.count - quietFrames - 1)].time
            let samples = Array(current.dropLast()) // One settled frame preserves the endpoint.
            idle = Array(current.suffix(3))
            current = []; quietFrames = 0
            return samples.count >= 4 ? Segment(samples: samples, endedAt: endedAt) : nil
        }
        if time - current[0].time >= 2 || current.count >= 30 {
            let result = finish()
            waitingForQuiet = true
            return result
        }
        return nil
    }

    /// A lesson boundary retains the unfinished burst instead of dropping a capture.
    mutating func finish() -> Segment? {
        let samples = current
        current = []; highFrames = 0; quietFrames = 0
        guard samples.count >= 4, let last = samples.last else { return nil }
        return Segment(samples: samples, endedAt: last.time)
    }

    static func teaching(_ example: GestureExample, thresholds: Thresholds) -> [GestureExample] {
        guard example.valid else { return [] }
        var detector = Self(thresholds: thresholds)
        var result: [GestureExample] = []
        let interval = example.duration / Double(max(1, example.frames.count - 1))
        for (index, frame) in example.frames.enumerated() {
            if let segment = detector.consume(frame, time: Double(index) * interval) { result.append(segment.example) }
        }
        if let segment = detector.finish() { result.append(segment.example) }
        // Short or weak demonstrations remain available to the model and archive.
        return result.isEmpty ? [example] : result
    }

    private static func change(_ first: [Double], _ second: [Double]) -> Double {
        sqrt(zip(first, second).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
    }
}
