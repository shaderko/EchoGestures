import Foundation

/// The same causal representation for poses, movements and rest.
/// Morphology comes from recent echoes; changes describe how each of the six paths evolves.
enum TemporalFeatures {
    static let window = 6
    static let dimension = EchoFeatures.dimension * 2 + 18

    static func extract(_ frames: [[Double]]) -> [Double]? {
        guard !frames.isEmpty, frames.allSatisfy(EchoFeatures.valid) else { return nil }
        let window = Array(frames.suffix(Self.window))
        let recent = Array(window.suffix(3))
        var result = (0..<EchoFeatures.dimension).map { column in
            recent.reduce(0) { $0 + $1[column] } / Double(recent.count)
        }
        // Keep the sign of change, not only its energy. Opposite trajectories
        // through the same echo shapes must not have identical motion features.
        let early = Array(window.prefix(min(3, window.count)))
        result += (0..<EchoFeatures.dimension).map { column in
            let beginning = early.reduce(0) { $0 + $1[column] } / Double(early.count)
            return result[column] - beginning
        }
        for path in 0..<6 {
            let bins = (path * 67)..<((path + 1) * 67)
            var stepEnergy = 0.0, netEnergy = 0.0, dispersion = 0.0
            for bin in bins {
                let mean = window.reduce(0) { $0 + $1[bin] } / Double(window.count)
                for frame in window { dispersion += pow(frame[bin] - mean, 2) }
                for index in 1..<window.count { stepEnergy += pow(window[index][bin] - window[index - 1][bin], 2) }
                netEnergy += pow(window.last![bin] - window[0][bin], 2)
            }
            result += [sqrt(stepEnergy / Double(max(1, window.count - 1))),
                       sqrt(netEnergy), sqrt(dispersion / Double(window.count))]
        }
        return result
    }

    static func teaching(_ example: GestureExample) -> [[Double]] {
        // Use every captured frame. Full rolling windows match live inference;
        // short partial examples can supply a shorter causal window.
        guard example.valid else { return [] }
        let start = min(window, example.frames.count) - 1
        return (start..<example.frames.count).compactMap { index in
            extract(Array(example.frames[max(0, index - window + 1)...index]))
        }
    }
}
