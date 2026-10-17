import Foundation

struct ArrayInputMetrics: Codable {
    struct Pair: Codable {
        let first: Int
        let second: Int
        let correlation: Double?
        let relativeDifference: Double?
    }
    let rms: [Double]
    let pairs: [Pair]
    static let empty = Self(rms: [], pairs: [])

    static func measure(_ channels: [[Float]]) -> Self {
        guard channels.count == 3, let count = channels.map(\.count).min(), count > 1,
              channels.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { return .empty }
        let countUsed = min(count, 1024)
        let means = channels.map { $0.prefix(countUsed).reduce(0.0) { $0 + Double($1) } / Double(countUsed) }
        let rms = channels.map { sqrt($0.prefix(countUsed).reduce(0.0) { $0 + Double($1) * Double($1) } / Double(countUsed)) }
        var pairs: [Pair] = []
        for (a, b) in [(0,1), (0,2), (1,2)] {
            var cross = 0.0, aa = 0.0, bb = 0.0, difference = 0.0, energy = 0.0
            for index in 0..<countUsed {
                let x = Double(channels[a][index]), y = Double(channels[b][index])
                cross += (x - means[a]) * (y - means[b])
                aa += (x - means[a]) * (x - means[a]); bb += (y - means[b]) * (y - means[b])
                difference += (x - y) * (x - y); energy += x * x + y * y
            }
            pairs.append(Pair(first: a, second: b, correlation: aa * bb > 1e-24 ? cross / sqrt(aa * bb) : nil,
                              relativeDifference: energy > 1e-24 ? sqrt(difference / energy) : nil))
        }
        return Self(rms: rms, pairs: pairs)
    }
}

/// The same origin, phase rotation and scale are applied to all microphones for
/// each speaker. Channel IDs remain HAL IDs, not guessed physical locations.
struct ArrayMeasurement: Codable {
    let time: Double
    let sampleRate: Double
    let input: ArrayInputMetrics
    let directSamples: [Int]
    let relativeDirectSamples: [Int]
    let directAmplitude: [Double]
    let linkDB: [Double]
    let commonProfiles: [SonarComplexProfile]
    let independentEnvelopes: [[Float]]
    let valid: Bool
    var timing: RigidArrayClock.State? = nil

    static func make(_ echoes: [SonarEcho], input: ArrayInputMetrics, timing: RigidArrayClock.State? = nil, validInput: Bool = true) -> Self? {
        guard echoes.count == 3, let time = echoes[0].captureTime,
              echoes.allSatisfy({ $0.captureTime == time && $0.leftRawReal.count == SonarSignal.count
                  && $0.rightRawReal.count == SonarSignal.count && $0.leftRawImaginary.count == SonarSignal.count
                  && $0.rightRawImaginary.count == SonarSignal.count && (0..<SonarSignal.count).contains($0.leftDirectSample)
                  && (0..<SonarSignal.count).contains($0.rightDirectSample) && $0.sampleRate == echoes[0].sampleRate }) else { return nil }
        let first = echoes[0]
        let origins = timing?.ready == true ? [timing!.anchors[0], timing!.anchors[1]] : [first.leftDirectSample, first.rightDirectSample]
        let raw = echoes.flatMap { [($0.leftRawReal, $0.leftRawImaginary), ($0.rightRawReal, $0.rightRawImaginary)] }
        let refs = Array(raw.prefix(2))
        let amplitudes = echoes.flatMap { echo in
            [hypot(Double(echo.leftRawReal[origins[0]]), Double(echo.leftRawImaginary[origins[0]])),
             hypot(Double(echo.rightRawReal[origins[1]]), Double(echo.rightRawImaginary[origins[1]]))]
        }
        let profiles = raw.enumerated().map { index, path in
            let speaker = index % 2
            return SonarComplexProfile.commonReferenced(real: path.0, imaginary: path.1,
                referenceReal: refs[speaker].0, referenceImaginary: refs[speaker].1,
                direct: origins[speaker], rate: first.sampleRate, carrier: first.carrier,
                normalization: Float(amplitudes[speaker]))
        }
        let direct = echoes.flatMap { [$0.leftDirectSample, $0.rightDirectSample] }
        return Self(time: time, sampleRate: first.sampleRate, input: input, directSamples: direct,
                    relativeDirectSamples: direct.enumerated().map {
                        SonarTimingAnchor.circularDifference($0.element, origins[$0.offset % 2], count: SonarSignal.count)
                    }, directAmplitude: amplitudes, linkDB: echoes.flatMap { [$0.leftLinkDB, $0.rightLinkDB] },
                    commonProfiles: profiles, independentEnvelopes: echoes.flatMap { [$0.left, $0.right] },
                    valid: validInput && echoes.allSatisfy { !$0.inputGap && !$0.clipping && $0.leftLinkDB >= 12 && $0.rightLinkDB >= 12 }
                        && profiles.allSatisfy(\.valid), timing: timing)
    }
}

struct ArrayStudy {
    struct Row: Codable { let stage: String; let elapsed: Double; let measurement: ArrayMeasurement }
    static let stages: [(name: String, seconds: Double, instruction: String)] = [
        ("rest", 6, "Keep your hand and shoulders still."),
        ("hand-left-right", 8, "Move only your hand left/right, about 20 cm in front of the keyboard. Keep your shoulder still."),
        ("rest", 4, "Return to rest and settle."),
        ("shoulder-only", 8, "Rest your hand. Move only your shoulder as in the false-trigger test."),
        ("rest", 4, "Keep still to finish the comparison.")
    ]
    private(set) var rows: [Row] = []
    private(set) var startedAt: Double?
    var stageIndex = 0
    var countdown = 6
    var finished: Bool { stageIndex >= Self.stages.count }

    mutating func append(_ measurement: ArrayMeasurement, now: Double) {
        if startedAt == nil { startedAt = now }
        update(now: now)
        guard !finished, rows.count < 500 else { return }
        rows.append(Row(stage: Self.stages[stageIndex].name, elapsed: now - startedAt!, measurement: measurement))
    }
    mutating func update(now: Double) {
        guard let startedAt else { return }
        var remaining = now - startedAt
        stageIndex = 0
        while stageIndex < Self.stages.count, remaining >= Self.stages[stageIndex].seconds {
            remaining -= Self.stages[stageIndex].seconds; stageIndex += 1
        }
        countdown = finished ? 0 : Int(ceil(Self.stages[stageIndex].seconds - remaining))
    }
}
