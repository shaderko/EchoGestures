import Accelerate
import Foundation

/// Balanced multi-output ridge regression. Scores compare each gesture to rest;
/// adding classes does not divide a fixed total confidence among more gestures.
struct RidgeClassifier {
    struct Evidence {
        let againstBackground: [Double]
        let againstRival: [Double]
    }
    private var mean: [Double] = []
    private var targetMean: [Double] = []
    private var weights: [[Double]] = []
    private var dimension = 0

    mutating func fit(inputs: [[Double]], labels: [Int], classes: Int) -> Bool {
        guard let dimension = inputs.first?.count, dimension > 0, dimension <= 2048,
              inputs.count == labels.count, classes > 0,
              inputs.allSatisfy({ $0.count == dimension && $0.allSatisfy(\.isFinite) }),
              labels.allSatisfy({ (0..<classes).contains($0) }) else { return false }
        self.dimension = dimension
        let count = inputs.count
        let counts = (0..<classes).map { label in max(1, labels.filter { $0 == label }.count) }
        let sampleWeights = labels.map { Double(count) / Double(classes * counts[$0]) }
        let totalWeight = sampleWeights.reduce(0, +)
        mean = (0..<dimension).map { column in
            zip(inputs, sampleWeights).reduce(0) { $0 + $1.0[column] * $1.1 } / totalWeight
        }
        targetMean = (0..<classes).map { output in
            zip(labels, sampleWeights).reduce(0) { $0 + ($1.0 == output ? 1.0 : -1.0) * $1.1 } / totalWeight
        }
        let x = zip(inputs, sampleWeights).flatMap { frame, weight in zip(frame, mean).map { ($0 - $1) * sqrt(weight) } }
        let y = zip(labels, sampleWeights).flatMap { label, weight in
            (0..<classes).map { ((label == $0 ? 1.0 : -1.0) - targetMean[$0]) * sqrt(weight) }
        }
        var gram = Array(repeating: 0.0, count: dimension * dimension)
        var right = Array(repeating: 0.0, count: dimension * classes)
        // X transpose times X, and X transpose times Y. BLAS handles the dense work.
        cblas_dgemm(CblasRowMajor, CblasTrans, CblasNoTrans,
                    Int32(dimension), Int32(dimension), Int32(count), 1, x, Int32(dimension),
                    x, Int32(dimension), 0, &gram, Int32(dimension))
        cblas_dgemm(CblasRowMajor, CblasTrans, CblasNoTrans,
                    Int32(dimension), Int32(classes), Int32(count), 1, x, Int32(dimension),
                    y, Int32(classes), 0, &right, Int32(classes))
        for index in 0..<dimension { gram[index * dimension + index] += 0.1 }
        // LAPACK consumes column-major right-hand sides. Gram is symmetric.
        var solution = (0..<classes).flatMap { output in (0..<dimension).map { right[$0 * classes + output] } }
        var triangle: Int8 = 76 // L
        var size = Int32(dimension), outputs = Int32(classes), info: Int32 = 0
        var leadingMatrix = size, leadingRight = size
        dposv_(&triangle, &size, &outputs, &gram, &leadingMatrix, &solution, &leadingRight, &info)
        guard info == 0, solution.allSatisfy(\.isFinite) else { return false }
        weights = (0..<classes).map { Array(solution[($0 * dimension)..<(($0 + 1) * dimension)]) }
        return true
    }

    func evidence(_ frame: [Double], backgroundClasses: Int = 1) -> Evidence? {
        guard !weights.isEmpty, frame.count == dimension, frame.allSatisfy(\.isFinite),
              backgroundClasses > 0, backgroundClasses <= weights.count else { return nil }
        let logits = weights.indices.map { index in
            zip(zip(frame, mean), weights[index]).reduce(targetMean[index]) { $0 + ($1.0.0 - $1.0.1) * $1.1 }
        }
        // A softmax over every gesture dilutes an unchanged match as the library
        // grows. With 32 ideal gestures it can fall below the acceptance threshold.
        // Use the same two-class scale against background for every gesture.
        // These evidence scores need not sum to one; rival separation is checked
        // by GestureRecognizer, so two overlapping matches remain uncertain.
        guard let background = logits.prefix(backgroundClasses).max() else { return nil }
        func evidence(_ difference: Double) -> Double {
            let value = max(-60, min(60, difference * 2))
            return 1 / (1 + exp(-value))
        }
        let bestGesture = logits.dropFirst(backgroundClasses).max() ?? background
        var backgroundEvidence = logits.indices.map { index in
            evidence(index < backgroundClasses ? logits[index] - bestGesture : logits[index] - background)
        }
        // Rest and ignored movement both mean no command, but their training
        // weights remain separate so a large rest history cannot bury negatives.
        backgroundEvidence[0] = evidence(background - bestGesture)
        let separation = logits.indices.map { index in
            let rival = logits.indices.filter { $0 != index }.map { logits[$0] }.max() ?? logits[index]
            return evidence(logits[index] - rival)
        }
        return Evidence(againstBackground: backgroundEvidence, againstRival: separation)
    }
}
