import Foundation

/// Capture time is authoritative. A busy UI must never turn old audio into a new command.
struct CaptureFreshness {
    private(set) var lastCapture: Double?
    private(set) var rejected = 0
    private(set) var age = 0.0

    mutating func accept(captured: Double?, now: Double) -> Bool {
        guard let captured, captured.isFinite, now.isFinite else { rejected += 1; return false }
        age = now - captured
        guard age >= -0.05, age <= 0.25, lastCapture.map({ captured > $0 }) ?? true else {
            rejected += 1
            return false
        }
        lastCapture = captured
        return true
    }
}

struct CaptureHealthRow: Codable {
    let elapsed: Double
    let captureAgeMilliseconds: Double
    let linkDB: [Double]
    let directSamples: [Int]
    let backgroundProgress: Double
    let residualEnergy: [Double]
    let accepted: Bool
    let reason: String
}

/// Bounded diagnostics contain numeric signal summaries, never microphone audio.
struct CaptureHealth {
    private(set) var total = 0
    private(set) var rejected = 0
    private(set) var first: [CaptureHealthRow] = []
    private(set) var recent: [CaptureHealthRow] = []
    private var recentCursor = 0
    static let capacity = 720

    mutating func append(_ row: CaptureHealthRow) {
        total += 1
        if !row.accepted { rejected += 1 }
        if first.count < 120 { first.append(row) }
        if recent.count < Self.capacity { recent.append(row) }
        else { recent[recentCursor] = row; recentCursor = (recentCursor + 1) % Self.capacity }
    }
    var orderedRecent: [CaptureHealthRow] {
        guard recent.count == Self.capacity else { return recent }
        return Array(recent[recentCursor...] + recent[..<recentCursor])
    }
}
