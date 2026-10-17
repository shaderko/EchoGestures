import Foundation

/// A discriminative score can be high far away from every demonstration.
/// Require local support from recorded examples as a separate open-set check.
struct GestureSupport {
    private var examples: [[Double]] = []
    private var radius = 0.08

    init(repetitions: [[[Double]]]) {
        self.examples = repetitions.flatMap { $0 }
        let distances = repetitions.indices.flatMap { index -> [Double] in
            let other = repetitions.indices.filter { $0 != index }.flatMap { repetitions[$0] }
            return repetitions[index].map { Self.nearest($0, in: other) }
        }.filter(\.isFinite).sorted()
        if !distances.isEmpty {
            radius = max(0.08, distances[Int(Double(distances.count - 1) * 0.95)] * 1.25)
        }
    }

    func supports(_ input: [Double]) -> Bool {
        Self.nearest(input, in: examples) <= radius
    }

    /// Bounded local references; the classifier and stored recordings keep all
    /// frames. Each equal-duration block contributes one representative mean.
    static func references(_ example: GestureExample) -> [[Double]] {
        let inputs = TemporalFeatures.teaching(example)
        guard !inputs.isEmpty else { return [] }
        let blocks = min(8, inputs.count)
        return (0..<blocks).map { block in
            let first = block * inputs.count / blocks, last = (block + 1) * inputs.count / blocks
            return (0..<TemporalFeatures.dimension).map { column in
                inputs[first..<last].reduce(0) { $0 + $1[column] } / Double(last - first)
            }
        }
    }

    private static func nearest(_ input: [Double], in references: [[Double]]) -> Double {
        references.map { reference in
            sqrt(zip(input, reference).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
        }.min() ?? .infinity
    }
}
