import Foundation

struct GesturePrediction {
    var gestureID: UUID?
    var score: Double
    var accepted: Bool
    var neutral: Bool
    var detail: String? = nil
    var movementDuration: Double? = nil
    var waitingForMovement = false
    var rivalScore: Double? = nil
}

/// One class competition for rest, poses and movements. Sequence matching verifies
/// a movement after classification; its distance is never compared to a class score.
struct GestureRecognizer {
    private struct Motion {
        let id: UUID
        let templates: [[[Double]]]
        let radius: Double
        let minimumActivity: Double
    }
    private var classifier = RidgeClassifier()
    private var gestureIDs: [UUID] = []
    private var backgroundClasses = 1
    private var supports: [UUID: GestureSupport] = [:]
    private var motions: [UUID: Motion] = [:]
    private var negatives: [[[Double]]] = []
    private var burst = MotionBurst()
    private var completed: (prediction: GesturePrediction, frames: Int, at: Double)?
    private var history: [(Double, [Double])] = []
    private var evidenceID: UUID?
    private var evidenceFrames = 0
    private(set) var ready = false

    mutating func fit(_ library: GestureLibrary) {
        self = Self()
        guard (try? library.validate()) != nil, !library.neutral.isEmpty else { return }
        let enabled = library.gestures.filter { $0.enabled && $0.examples.count >= 2 }
        gestureIDs = enabled.map(\.id)
        let ignored = library.ignored ?? []
        let thresholds = MotionBurst.Thresholds.learned(from: library.neutral)
        burst = MotionBurst(thresholds: thresholds)
        let motionGroups = Dictionary(uniqueKeysWithValues: enabled.filter { $0.kind == .motion }.map { gesture in
            (gesture.id, gesture.examples.map { example -> [GestureExample] in
                let bursts = MotionBurst.teaching(example, thresholds: thresholds)
                return bursts == [example] ? bursts : [example] + bursts
            })
        })
        let motionExamples = motionGroups.mapValues { $0.flatMap { $0 } }
        backgroundClasses = ignored.isEmpty ? 1 : 2
        var inputs = library.neutral.flatMap(TemporalFeatures.teaching)
        var labels = Array(repeating: 0, count: inputs.count)
        let ignoredInputs = ignored.flatMap(TemporalFeatures.teaching)
        inputs += ignoredInputs
        labels += Array(repeating: 1, count: ignoredInputs.count)
        negatives = ignored.flatMap { MotionBurst.teaching($0, thresholds: thresholds) }.map { SequenceMatcher.resample($0.frames) }
        for (index, gesture) in enabled.enumerated() {
            let repetitions = motionGroups[gesture.id] ?? gesture.examples.map { [$0] }
            supports[gesture.id] = GestureSupport(repetitions: repetitions.map { $0.flatMap(GestureSupport.references) })
            let examples = (motionExamples[gesture.id] ?? gesture.examples).flatMap(TemporalFeatures.teaching)
            inputs += examples
            labels += Array(repeating: index + backgroundClasses, count: examples.count)
        }
        guard classifier.fit(inputs: inputs, labels: labels, classes: gestureIDs.count + backgroundClasses) else { return }
        for gesture in enabled where gesture.kind == .motion {
            let examples = motionExamples[gesture.id] ?? gesture.examples
            let templates = examples.map { SequenceMatcher.resample($0.frames) }
            let repetitions = (motionGroups[gesture.id] ?? []).map { examples in
                examples.map { SequenceMatcher.resample($0.frames) }
            }
            let activities = examples.flatMap { example in
                let frames = example.frames
                let start = min(TemporalFeatures.window, frames.count) - 1
                return (start..<frames.count).map { index in
                    SequenceMatcher.activity(Array(frames[max(0, index - TemporalFeatures.window + 1)...index]))
                }
            }.sorted()
            motions[gesture.id] = Motion(id: gesture.id, templates: templates,
                radius: SequenceMatcher.learnedRadius(repetitions: repetitions),
                minimumActivity: max(0.03, activities[activities.count / 2] * 0.3))
        }
        ready = !enabled.isEmpty
    }

    mutating func resetHistory() {
        history = []; evidenceID = nil; evidenceFrames = 0; completed = nil; burst.reset()
    }

    mutating func predict(_ frame: [Double], time: Double) -> GesturePrediction? {
        guard ready, EchoFeatures.valid(frame), time.isFinite else { resetHistory(); return nil }
        if let prior = history.last, time <= prior.0 { return nil }
        if let prior = history.last, time - prior.0 > 0.35 { resetHistory() }
        if let segment = burst.consume(frame, time: time) {
            completed = (match(segment), 2, time)
            evidenceID = nil; evidenceFrames = 0
        }
        history.append((time, frame))
        history.removeAll { time - $0.0 > 2.4 }
        if let held = completed, held.frames > 0, time - held.at <= 0.25 {
            completed = held.frames > 1 ? (held.prediction, held.frames - 1, held.at) : nil
            return held.prediction
        }
        completed = nil
        guard let input = TemporalFeatures.extract(history.map { $0.1 }),
              let evidence = classifier.evidence(input, backgroundClasses: backgroundClasses),
              let best = gestureIDs.indices.max(by: { evidence.againstBackground[$0 + backgroundClasses] < evidence.againstBackground[$1 + backgroundClasses] }) else { return nil }
        let scores = evidence.againstBackground
        let id = gestureIDs[best]
        let score = scores[best + backgroundClasses]
        var detail: String?
        var accepted = history.count >= TemporalFeatures.window && score > 0.65 && evidence.againstRival[best + backgroundClasses] > 0.65
        if history.count < TemporalFeatures.window { detail = "Gathering fresh echo history…" }
        else if !accepted { detail = "Class match is not distinct enough yet." }
        if accepted && supports[id]?.supports(input) != true {
            accepted = false
            detail = "Unknown echo pattern · not supported by the taught examples."
        }
        if burst.moving || motions[id] != nil {
            accepted = false
            detail = burst.moving ? "Movement underway · waiting for its end…" : "Ready · make a short movement."
        }
        if accepted {
            if evidenceID == id { evidenceFrames += 1 } else { evidenceID = id; evidenceFrames = 1 }
        } else { evidenceID = nil; evidenceFrames = 0 }
        if accepted, evidenceFrames < 4 { detail = "Confirming gesture · \(evidenceFrames)/4 frames" }
        return GesturePrediction(gestureID: id, score: score, accepted: accepted && evidenceFrames >= 4,
                                 neutral: scores[0] > 0.6, detail: detail,
                                 waitingForMovement: motions[id] != nil && !burst.moving,
                                 rivalScore: evidence.againstRival[best + backgroundClasses])
    }

    private func match(_ segment: MotionBurst.Segment) -> GesturePrediction {
        // Most of the burst must have nearby recorded support and pass both
        // classifier comparisons. One isolated score peak cannot authorize it.
        var peaks: [UUID: (score: Double, support: Double, rival: Double)] = [:]
        var matching: [UUID: Int] = [:]
        var nearby: [UUID: Int] = [:]
        let windows = TemporalFeatures.teaching(segment.example)
        for input in windows {
            guard let evidence = classifier.evidence(input, backgroundClasses: backgroundClasses) else { continue }
            for (index, id) in gestureIDs.enumerated() where motions[id] != nil {
                let score = evidence.againstBackground[index + backgroundClasses]
                let support = min(score, evidence.againstRival[index + backgroundClasses])
                if supports[id]?.supports(input) == true { nearby[id, default: 0] += 1 }
                if support > 0.65 { matching[id, default: 0] += 1 }
                if support > (peaks[id]?.support ?? 0) {
                    peaks[id] = (score, support, evidence.againstRival[index + backgroundClasses])
                }
            }
        }
        guard let best = peaks.max(by: {
            let first = matching[$0.key] ?? 0, second = matching[$1.key] ?? 0
            return first == second ? $0.value.support < $1.value.support : first < second
        }),
              let motion = motions[best.key] else {
            return GesturePrediction(gestureID: nil, score: 0, accepted: false, neutral: false,
                                     detail: "Movement ended · no distinct gesture match.", movementDuration: segment.duration)
        }
        let block = motionBlock(motion, frames: segment.frames)
        let sustained = (nearby[best.key] ?? 0) >= max(1, Int(ceil(Double(windows.count) * 0.6)))
            && (matching[best.key] ?? 0) >= min(2, windows.count)
        let accepted = best.value.support > 0.65 && sustained && block == nil
        return GesturePrediction(gestureID: best.key, score: best.value.score, accepted: accepted, neutral: false,
            detail: accepted ? String(format: "Movement complete · %.0f ms", segment.duration * 1000)
                : !sustained ? "Unknown movement · the whole burst does not match the taught examples." : block,
            movementDuration: segment.duration, rivalScore: best.value.rival)
    }

    private func motionBlock(_ motion: Motion, frames: [[Double]]) -> String? {
        guard SequenceMatcher.activity(frames) >= motion.minimumActivity else {
            return "Movement ended · too little change for this gesture."
        }
        var fitsRadius = false
        var closestBlock: (margin: Double, ignored: Bool)?
        // Onset is sampled, not exact. Compare the same small boundary shifts
        // against every class; never favor a positive with a different rival window.
        for offset in 0...min(2, max(0, frames.count - 4)) {
            let sequence = SequenceMatcher.resample(Array(frames.dropFirst(offset)))
            let closest = motion.templates.map { SequenceMatcher.distance(sequence, $0) }.min() ?? .infinity
            guard closest < motion.radius else { continue }
            fitsRadius = true
            let ignored = negatives.map { SequenceMatcher.distance(sequence, $0) }.min() ?? .infinity
            var rival = Double.infinity
            for other in motions.values where other.id != motion.id {
                rival = min(rival, other.templates.map { SequenceMatcher.distance(sequence, $0) }.min() ?? .infinity)
            }
            let competitor = min(ignored, rival)
            if !competitor.isFinite || closest + 0.03 < competitor * 0.92 { return nil }
            let margin = competitor * 0.92 - closest - 0.03
            if closestBlock == nil || margin > closestBlock!.margin { closestBlock = (margin, ignored <= rival) }
        }
        return fitsRadius ? (closestBlock?.ignored == true ? "Movement too similar to an ignored example." : "Movement too similar to another taught gesture.")
            : "Movement ended · sequence has not matched."
    }

}

/// Recognition is continuous; commands are edge-triggered and require a neutral release.
struct GestureEventGate {
    private var armed = false
    private var neutralFrames = 0
    private var candidate: UUID?
    private var candidateFrames = 0
    private var lastTime: Double?
    private var lastEvent = -Double.infinity
    private var lastGesture: UUID?
    private var releaseFrames = 0
    private var releaseAt: Double?
    var waitingForRest: Bool { !armed }
    private(set) var status = "Return to rest briefly to arm a gesture."

    mutating func reset() {
        armed = false; neutralFrames = 0; candidate = nil; candidateFrames = 0; lastTime = nil
        releaseFrames = 0; lastGesture = nil; releaseAt = nil
        status = "Return to rest briefly to arm a gesture."
    }

    /// Explicitly enabling commands is intent to accept the next settled gesture.
    mutating func arm() { armed = true; status = "Ready · show a gesture." }

    mutating func update(_ prediction: GesturePrediction, time: Double, canTrigger: Bool = true) -> UUID? {
        guard time.isFinite, prediction.score.isFinite else { reset(); return nil }
        if let prior = lastTime, time <= prior { return nil }
        if let prior = lastTime, time - prior > 0.35 { reset() }
        lastTime = time
        if prediction.neutral {
            neutralFrames += 1
            if neutralFrames >= 3 { arm() }
            candidate = nil; candidateFrames = 0
            releaseFrames = 0
            releaseAt = nil
            return nil
        }
        neutralFrames = 0
        guard prediction.accepted, let id = prediction.gestureID else {
            candidate = nil; candidateFrames = 0
            releaseFrames += 1
            if releaseAt == nil { releaseAt = time }
            // A completed motion can release even if its class score stays high.
            if lastGesture != nil, releaseFrames >= 8, time - (releaseAt ?? time) >= 0.5 { arm() }
            return nil
        }
        releaseFrames = 0
        releaseAt = nil
        // Stable different actions can follow without a rest-class interlude.
        if let lastGesture, id != lastGesture { armed = true }
        if candidate == id { candidateFrames += 1 } else { candidate = id; candidateFrames = 1 }
        guard armed else { status = "Already triggered · release before repeating."; return nil }
        guard candidateFrames >= 2 else { status = "Gesture settling before trigger…"; return nil }
        guard time - lastEvent >= 0.8 else { status = "Brief cooldown before the next command."; return nil }
        guard canTrigger else { return nil }
        armed = false; lastEvent = time; lastGesture = id
        status = "Triggered · release before repeating."
        return id
    }
}
