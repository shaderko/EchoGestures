import Foundation

/// Six independent response blocks, in microphone order. No position or hand identity is assumed.
struct EchoFeatures {
    static let dimension = 402
    static let version = 1

    static func extract(_ paths: [[Float]]) -> [Double]? {
        guard paths.count == 6, paths.allSatisfy({ $0.count == 240 && $0.allSatisfy(\.isFinite) }) else { return nil }
        var features: [Double] = []
        for microphone in 0..<3 {
            var pair: [Double] = []
            for path in paths[(microphone * 2)..<(microphone * 2 + 2)] {
                for bin in 0..<67 {
                    let index = (0.12 + Double(bin) * 0.78 / 66) * 239 / 1.4
                    let low = Int(index)
                    let fraction = index - Double(low)
                    pair.append(Double(path[low]) * (1 - fraction) + Double(path[low + 1]) * fraction)
                }
            }
            let norm = max(1e-12, sqrt(pair.reduce(0) { $0 + $1 * $1 }))
            features += pair.map { $0 / norm / sqrt(3) }
        }
        return features
    }

    static func valid(_ frame: [Double]) -> Bool {
        frame.count == dimension && frame.allSatisfy(\.isFinite)
    }
}

/// A fresh, frozen empty-space baseline for each uninterrupted capture route.
struct EchoBackground {
    static let requiredFrames = 36
    private(set) var count = 0
    private var sums = Array(repeating: Array(repeating: 0.0, count: 240), count: 6)
    private(set) var residualEnergy: [Double] = []
    var ready: Bool { count >= Self.requiredFrames }
    var progress: Double { Double(count) / Double(Self.requiredFrames) }

    mutating func consume(_ paths: [[Float]]) -> [Double]? {
        guard paths.count == 6, paths.allSatisfy({ $0.count == 240 && $0.allSatisfy(\.isFinite) }) else { return nil }
        if !ready {
            for path in 0..<6 { for bin in 0..<240 { sums[path][bin] += Double(paths[path][bin]) } }
            count += 1
            return nil
        }
        let residuals = zip(paths, sums).map { path, sum in zip(path, sum).map { Float(Double($0) - $1 / Double(Self.requiredFrames)) } }
        residualEnergy = residuals.map { path in sqrt(path.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(path.count)) }
        return EchoFeatures.extract(residuals)
    }
}
