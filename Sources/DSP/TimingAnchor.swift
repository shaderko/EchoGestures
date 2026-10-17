import Foundation

// Speaker and microphone geometry is fixed within a run. Bootstrap the second
// arrival near the stronger direct-path candidate; thereafter both origins share
// the stronger channel's clock shift. This prevents a broad cross-probe response
// half a period away from being treated as an independent timing reference.
struct SonarTimingAnchor {
    private(set) var leaderIsLeft: Bool?
    private var leader: Int?
    private var otherOffset = 0
    static let radius = 96 // ~69 cm acoustic path difference at 48 kHz.

    static func circularDifference(_ a: Int, _ b: Int, count: Int) -> Int {
        (a - b + count + count / 2) % count - count / 2
    }
    private static func peak(_ envelope: [Float], near: Int? = nil, radius: Int = 8) -> Int {
        guard let near else { return envelope.indices.max { envelope[$0] < envelope[$1] }! }
        return (-radius...radius).map { (near + $0 + envelope.count) % envelope.count }
            .max { envelope[$0] < envelope[$1] }!
    }
    private static func quality(_ envelope: [Float], at peak: Int) -> Double {
        let floor = max(envelope.sorted()[envelope.count / 2], 1e-12)
        return 20 * log10(Double(max(envelope[peak], 1e-12) / floor))
    }

    mutating func select(left: [Float], right: [Float], source: SonarSource = .both) -> (left: Int, right: Int) {
        precondition(!left.isEmpty && left.count == right.count)
        let n = left.count
        if let isLeft = leaderIsLeft, let prior = leader {
            let next = Self.peak(isLeft ? left : right, near: prior)
            leader = next
            let other = (next + otherOffset + n) % n
            return isLeft ? (next, other) : (other, next)
        }
        let l = Self.peak(left), r = Self.peak(right)
        let ql = Self.quality(left, at: l), qr = Self.quality(right, at: r)
        let isLeft = source == .left || (source == .both && ql >= qr)
        let primary = isLeft ? l : r
        let secondary = Self.peak(isLeft ? right : left, near: primary, radius: min(Self.radius, n / 4))
        if (isLeft ? ql : qr) >= 15 {
            leaderIsLeft = isLeft
            leader = primary
            otherOffset = Self.circularDifference(secondary, primary, count: n)
        }
        return isLeft ? (primary, secondary) : (secondary, primary)
    }
}
