import Foundation

/// Dynamic time warping preserves sequence order while allowing moderate speed changes.
enum SequenceMatcher {
    static let length = 12
    typealias Sequence = [[Double]]

    /// Cropped/full variants of one performance must not calibrate each other's
    /// repeatability. Measure the nearest match from a different repetition.
    static func learnedRadius(repetitions: [[Sequence]]) -> Double {
        let nearest = repetitions.indices.flatMap { index in
            repetitions[index].map { template in
                repetitions.indices.filter { $0 != index }.flatMap { repetitions[$0] }
                    .map { distance(template, $0) }.min() ?? 0
            }
        }
        return max(0.07, (nearest.max() ?? 0) * 1.6 + 0.025)
    }

    static func resample(_ frames: [[Double]], count: Int = length) -> [[Double]] {
        guard !frames.isEmpty, frames.allSatisfy(EchoFeatures.valid), count > 1 else { return [] }
        return (0..<count).map { step in
            let index = Double(step) * Double(frames.count - 1) / Double(count - 1)
            let low = Int(index), high = min(frames.count - 1, low + 1)
            let fraction = index - Double(low)
            return zip(frames[low], frames[high]).map { $0 * (1 - fraction) + $1 * fraction }
        }
    }

    static func distance(_ first: [[Double]], _ second: [[Double]]) -> Double {
        guard !first.isEmpty, !second.isEmpty, first.allSatisfy(EchoFeatures.valid), second.allSatisfy(EchoFeatures.valid) else { return .infinity }
        var prior = Array(repeating: Double.infinity, count: second.count + 1)
        prior[0] = 0
        for row in first.indices {
            var current = Array(repeating: Double.infinity, count: second.count + 1)
            for column in second.indices {
                // Absolute shape anchors the movement; relative shape encodes its trajectory.
                var absolute = 0.0, relative = 0.0
                for feature in 0..<EchoFeatures.dimension {
                    let difference = first[row][feature] - second[column][feature]
                    let delta = (first[row][feature] - first[0][feature]) - (second[column][feature] - second[0][feature])
                    absolute += difference * difference
                    relative += delta * delta
                }
                let cost = sqrt(absolute * 0.65 + relative * 0.35)
                current[column + 1] = cost + min(prior[column], min(prior[column + 1], current[column]))
            }
            prior = current
        }
        return prior[second.count] / Double(max(first.count, second.count))
    }

    static func activity(_ frames: [[Double]]) -> Double {
        guard let first = frames.first, frames.allSatisfy(EchoFeatures.valid) else { return 0 }
        return frames.map { frame in sqrt(zip(frame, first).reduce(0) { $0 + pow($1.0 - $1.1, 2) }) }.max() ?? 0
    }

    /// Every captured frame contributes to one block average; no quality-based rejection.
    static func pooled(_ frames: [[Double]], blocks: Int = 4) -> [[Double]] {
        guard !frames.isEmpty, frames.allSatisfy(EchoFeatures.valid) else { return [] }
        let count = min(blocks, frames.count)
        return (0..<count).map { block in
            let start = block * frames.count / count, end = (block + 1) * frames.count / count
            return (0..<EchoFeatures.dimension).map { column in
                frames[start..<end].reduce(0) { $0 + $1[column] } / Double(end - start)
            }
        }
    }
}
