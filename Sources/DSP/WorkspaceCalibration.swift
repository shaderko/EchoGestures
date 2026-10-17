import Foundation

struct WorkspaceTarget: Codable, Equatable {
    let id: String
    let name: String
    let centimeters: [Double]?
    let instruction: String
    static let marks: [Self] = [
        .init(id: "center", name: "Center", centimeters: [0,20,15], instruction: "Open palm at center: 20 cm toward you from the Mac's front edge, 15 cm above the desk."),
        .init(id: "left", name: "Left", centimeters: [-15,20,15], instruction: "Move your open palm 15 cm left of center. Keep its distance, height and orientation the same."),
        .init(id: "right", name: "Right", centimeters: [15,20,15], instruction: "Move your open palm 15 cm right of center. Keep its distance, height and orientation the same."),
        .init(id: "high", name: "Higher", centimeters: [0,20,30], instruction: "Open palm above center: 30 cm above the desk, 20 cm toward you from the Mac's front edge."),
        .init(id: "near", name: "Nearer Mac", centimeters: [0,10,15], instruction: "Open palm at center, just 10 cm toward you from the Mac's front edge; height 15 cm."),
        .init(id: "far", name: "Farther from Mac", centimeters: [0,35,15], instruction: "Open palm at center, 35 cm toward you from the Mac's front edge; height 15 cm."),
        .init(id: "shoulder", name: "Shoulder only", centimeters: nil, instruction: "Rest your hand in your lap. Move only your shoulder as in the false-trigger test.")
    ]
    static let rest = Self(id: "rest", name: "Rest", centimeters: nil, instruction: "Hand in your lap. Keep your body still.")
}

/// An empirical response map uses approximate instructed hand marks, not capsule coordinates.
struct WorkspaceFeatures: Codable {
    static let bins = 16
    static let dimension = 6 * (bins * 2 + 1)
    let baseline: [SonarComplexProfile]
    let noise: [Double]
    let epoch: UUID
    let sampleRate: Double

    init?(frames: [ArrayMeasurement]) {
        guard frames.count >= 24, let first = frames.first, let timing = first.timing, timing.ready,
              frames.allSatisfy({ $0.valid && $0.timing?.epoch == timing.epoch && $0.timing?.ready == true
                  && $0.sampleRate == first.sampleRate && $0.commonProfiles.count == 6 && $0.commonProfiles.allSatisfy(\.valid) }) else { return nil }
        epoch = timing.epoch; sampleRate = first.sampleRate
        let reference = (0..<6).map { path in
            SonarComplexProfile(real: (0..<240).map { bin in frames.reduce(0) { $0 + $1.commonProfiles[path].real[bin] } / Float(frames.count) },
                                imaginary: (0..<240).map { bin in frames.reduce(0) { $0 + $1.commonProfiles[path].imaginary[bin] } / Float(frames.count) })
        }
        baseline = reference
        noise = (0..<6).map { path in
            let variance = frames.reduce(0.0) { sum, frame in
                sum + (21..<154).reduce(0.0) { value, bin in
                    let r = Double(frame.commonProfiles[path].real[bin] - reference[path].real[bin])
                    let i = Double(frame.commonProfiles[path].imaginary[bin] - reference[path].imaginary[bin])
                    return value + r*r + i*i
                }
            } / Double(frames.count * 133)
            return max(0.01, sqrt(variance))
        }
    }
    func extract(_ frame: ArrayMeasurement) -> [Double]? {
        guard frame.valid, frame.timing?.ready == true, frame.timing?.epoch == epoch,
              frame.sampleRate == sampleRate, frame.commonProfiles.count == 6,
              frame.commonProfiles.allSatisfy(\.valid) else { return nil }
        var result: [Double] = []
        for path in 0..<6 {
            var energy = 0.0
            for bin in 0..<Self.bins {
                let index = (0.12 + Double(bin) * 0.78 / Double(Self.bins - 1)) / 1.4 * 239
                let low = Int(index), fraction = index - Double(low)
                func residual(_ values: [Float], _ reference: [Float]) -> Double {
                    Double(values[low] - reference[low]) * (1-fraction)
                        + Double(values[low+1] - reference[low+1]) * fraction
                }
                let r = residual(frame.commonProfiles[path].real, baseline[path].real)
                let i = residual(frame.commonProfiles[path].imaginary, baseline[path].imaginary)
                energy += r*r + i*i
                // Compress strong echoes; never normalize a tiny residual to unit energy.
                result += [copysign(log1p(abs(r) / noise[path]), r), copysign(log1p(abs(i) / noise[path]), i)]
            }
            result.append(log1p(sqrt(energy / Double(Self.bins)) / noise[path]))
        }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}

struct WorkspacePrediction: Codable {
    let region: String
    let score: Double
    let distinct: Bool
}

struct WorkspaceResponseMap {
    let features: WorkspaceFeatures
    private var classifier: RidgeClassifier
    init?(features: WorkspaceFeatures, samples: [(String, [Double])]) {
        let allowed = Set(["rest"] + WorkspaceTarget.marks.map(\.id))
        guard samples.allSatisfy({ allowed.contains($0.0) }) else { return nil }
        let labels = samples.map { sample in
            sample.0 == "rest" ? 0 : sample.0 == "shoulder" ? 1
                : (WorkspaceTarget.marks.firstIndex { $0.id == sample.0 } ?? -2) + 2
        }
        guard (0..<8).allSatisfy({ label in labels.filter { $0 == label }.count >= 2 }) else { return nil }
        var classifier = RidgeClassifier()
        guard classifier.fit(inputs: samples.map { $0.1 }, labels: labels, classes: 8) else { return nil }
        self.features = features; self.classifier = classifier
    }
    func predict(_ frame: ArrayMeasurement) -> WorkspacePrediction? {
        guard let input = features.extract(frame), let scores = classifier.evidence(input, backgroundClasses: 2),
              let best = (2..<8).max(by: { scores.againstBackground[$0] < scores.againstBackground[$1] }) else { return nil }
        let score = scores.againstBackground[best]
        let background = scores.againstBackground.prefix(2).max() ?? 0
        if background >= score {
            return WorkspacePrediction(region: "background", score: background, distinct: background > 0.65)
        }
        return WorkspacePrediction(region: WorkspaceTarget.marks[best-2].id, score: score,
                                   distinct: score > 0.65 && scores.againstRival[best] > 0.65)
    }
}

struct WorkspaceCalibration {
    struct Trial: Codable { let target: WorkspaceTarget; let round: Int; var validation: Bool { round == 2 } }
    struct Row: Codable {
        let elapsed: Double
        let phase: String
        let trial: Int?
        let measurement: ArrayMeasurement
        let prediction: WorkspacePrediction?
    }
    static let trials: [Trial] = {
        let orders = [[0,1,2,3,4,5,6], [6,5,3,1,4,2,0], [4,2,6,0,5,1,3]]
        return orders.enumerated().flatMap { round, order in order.map { Trial(target: WorkspaceTarget.marks[$0], round: round) } }
            + [Trial(target: .rest, round: 2)]
    }()
    static let duration = 6.0 + Double(trials.count) * 4
    private(set) var rows: [Row] = []
    private(set) var elapsed = 0.0
    private var began: Double?
    private var samples: [(String, [Double])] = []
    private(set) var extractor: WorkspaceFeatures?
    private(set) var map: WorkspaceResponseMap?
    private var attemptedFit = false
    private(set) var failure: String?
    var finished: Bool { elapsed >= Self.duration }
    var trialIndex: Int? { elapsed < 6 || finished ? nil : Int((elapsed-6) / 4) }
    var phase: String { elapsed < 6 ? "baseline" : finished ? "finished" : (elapsed-6).truncatingRemainder(dividingBy: 4) < 2 ? "prepare" : "hold" }
    var countdown: Int { Int(ceil(elapsed < 6 ? 6-elapsed : 2-(elapsed-6).truncatingRemainder(dividingBy: 2))) }
    var current: Trial? { trialIndex.map { Self.trials[$0] } }

    mutating func append(_ frame: ArrayMeasurement) {
        if began == nil { began = frame.time }
        let next = frame.time - began!
        guard next >= elapsed else { return }
        elapsed = next
        guard !finished, rows.count < 1600 else { return }
        if extractor == nil && elapsed >= 6 {
            extractor = WorkspaceFeatures(frames: rows.filter { $0.phase == "baseline" && $0.measurement.valid && $0.measurement.timing?.ready == true }.map(\.measurement))
            if let extractor {
                samples = rows.filter { $0.phase == "baseline" }.compactMap { row in
                    extractor.extract(row.measurement).map { ("rest", $0) }
                }
            } else { failure = "The still reference was incomplete. All measurements will be saved; restart calibration for a usable map." }
        }
        if let current, current.validation, !attemptedFit {
            attemptedFit = true
            if let extractor { map = WorkspaceResponseMap(features: extractor, samples: samples) }
            if map == nil { failure = "Training lacks usable data for every target. The check will still be recorded." }
        }
        if let extractor, frame.timing?.epoch != extractor.epoch {
            failure = "The capture clock restarted. Measurements are retained; restart calibration for a consistent map."
        }
        let prediction = current?.validation == true ? map?.predict(frame) : nil
        rows.append(Row(elapsed: elapsed, phase: phase, trial: trialIndex, measurement: frame, prediction: prediction))
        if phase == "hold", let current, !current.validation, let vector = extractor?.extract(frame) {
            samples.append((current.target.id, vector))
        }
    }

    var validationSummary: String {
        var correct = 0, missing = 0
        for index in Self.trials.indices where Self.trials[index].validation {
            let votes = rows.filter { $0.phase == "hold" && $0.trial == index }.compactMap { $0.prediction?.region }
            guard let best = Dictionary(grouping: votes, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else {
                missing += 1; continue
            }
            let target = Self.trials[index].target.id
            if best == target || (best == "background" && (target == "shoulder" || target == "rest")) { correct += 1 }
        }
        return "Separate check: \(correct)/8 leading trial responses match the prompts; \(missing) have no prediction. This is one instructed session, not independently measured accuracy."
    }
}
