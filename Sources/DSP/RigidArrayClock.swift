import Foundation

/// The rigid array may share clock drift, never independent sensor motion.
/// Only unanimous receiver shifts update the clock; disagreements hold the last
/// shift. This is a timing constraint, not measured capsule geometry.
struct RigidArrayClock {
    struct State: Codable {
        let epoch: UUID
        let calibrationFrames: Int
        let anchors: [Int]
        let shift: Int
        let heldForDisagreement: Bool
        var ready: Bool { calibrationFrames >= RigidArrayClock.requiredFrames }
    }
    static let requiredFrames = 36
    private var epoch = UUID()
    private var calibration: [[Int]] = []
    private var origins: [Int] = []
    private var shift = 0
    private var lastTime: Double?

    mutating func update(anchors: [Int], time: Double, qualified: Bool, interrupted: Bool = false) -> State? {
        guard anchors.count == 6, anchors.allSatisfy({ (0..<4096).contains($0) }), time.isFinite else { return nil }
        if let lastTime, time <= lastTime { return nil }
        if interrupted || lastTime.map({ time - $0 > 0.35 }) == true { self = Self() }
        lastTime = time
        if origins.isEmpty {
            if qualified { calibration.append(anchors) }
            if calibration.count == Self.requiredFrames {
                origins = (0..<6).map { path in
                    let reference = calibration[0][path]
                    let differences = calibration.map { Self.difference($0[path], reference) }.sorted()
                    return Self.wrap(reference + differences[differences.count / 2])
                }
                calibration = []
            }
            return State(epoch: epoch, calibrationFrames: origins.isEmpty ? calibration.count : Self.requiredFrames,
                         anchors: origins.isEmpty ? anchors : origins, shift: 0, heldForDisagreement: false)
        }
        let changes = zip(anchors, origins).map { Self.difference($0, $1) }
        // Each receiver's paired speaker origins share its legacy timing leader.
        // Count three receiver votes, not six supposedly independent votes.
        var votes: [Int] = []
        for receiver in 0..<3 {
            let first = changes[receiver * 2]
            let second = changes[receiver * 2 + 1]
            votes.append((first + second) / 2)
        }
        votes.sort()
        let proposed = votes[1]
        let agrees = qualified && (votes.last! - votes.first! <= 1) && abs(proposed - shift) <= 1
        if agrees { shift = proposed }
        return State(epoch: epoch, calibrationFrames: Self.requiredFrames,
                     anchors: origins.map { Self.wrap($0 + shift) }, shift: shift, heldForDisagreement: !agrees)
    }
    private static func difference(_ first: Int, _ second: Int) -> Int {
        SonarTimingAnchor.circularDifference(first, second, count: 4096)
    }
    private static func wrap(_ sample: Int) -> Int { (sample % 4096 + 4096) % 4096 }
}
