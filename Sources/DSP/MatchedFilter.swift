import Foundation
import Accelerate

enum SonarBand: String, CaseIterable {
    case audible = "Wide · 4–12 kHz"
    case ultrasonic = "Ultrasonic · 20–22.8 kHz"
    case shared = "Shared receivers · 6–11.5 kHz"
}

enum SonarSource: String, CaseIterable {
    case both = "Both speakers"
    case left = "Left speaker only"
    case right = "Right speaker only"
    func permits(_ channel: Int) -> Bool {
        self == .both || (self == .left && channel == 0) || (self == .right && channel == 1)
    }
}

struct SonarSignal {
    static let count = 4096
    static let chirpCount = 512
    static let amplitude: Float = 0.025
    let sampleRate: Double
    let low: Double
    let peakAmplitude: Float
    let high: Double
    let left: [Float]
    let right: [Float]

    init(sampleRate: Double, band: SonarBand = .ultrasonic) {
        self.sampleRate = sampleRate
        switch band {
        case .audible: low=4_000; high=min(12_000,sampleRate/2-600)
        case .ultrasonic: low=20_200; high=min(22_800,sampleRate/2-600)
        case .shared: low=6_000; high=min(11_500,sampleRate/2-600)
        }
        peakAmplitude = band == .ultrasonic ? Self.amplitude : 0.0125
        var l = [Float](repeating: 0, count: Self.count)
        var r = l
        let duration = Double(Self.chirpCount) / sampleRate
        for i in 0..<Self.chirpCount {
            let t = Double(i) / sampleRate
            let window = pow(sin(.pi * Double(i) / Double(Self.chirpCount - 1)), 2)
            l[i] = Float(window * cos(2 * .pi * (low * t + (high - low) * t * t / (2 * duration))))
            r[i + Self.count / 2] = Float(window * cos(2 * .pi * (high * t - (high - low) * t * t / (2 * duration))))
        }
        left = l
        right = r
    }
}

struct SonarEcho {
    var captureTime: Double? = nil
    var left: [Float]
    var right: [Float]
    var timingLeader: String
    var leftEnvelope: [Float]
    var rightEnvelope: [Float]
    var leftDirectSample: Int
    var rightDirectSample: Int
    var leftLinkDB: Double
    var rightLinkDB: Double
    var clipping: Bool
    var bands: [Double]
    var noiseBands: [Double]?
    var receivedFrames: Int
    var inputGap: Bool
    var leftComplex=SonarComplexProfile.empty
    var rightComplex=SonarComplexProfile.empty
    var sampleRate = 48_000.0
    var leftRawReal: [Float] = []
    var leftRawImaginary: [Float] = []
    var rightRawReal: [Float] = []
    var rightRawImaginary: [Float] = []
    var carrier=21_500.0
}

// Runs on the DSP queue, never on the audio output render thread.
final class SonarDSP {
    static let plotCount = 240
    static let maxRange = 1.4
    private let signal: SonarSignal
    private let fft: FFTSetup
    private let logN = vDSP_Length(12)
    private var templateL: (r: [Float], i: [Float])
    private var templateR: (r: [Float], i: [Float])
    private var pending: [Float] = []
    private var nextSample: Int64?
    private var pendingGap = false
    private var received = 0
    private var frameIndex = 0
    private var noise: [Double] = []
    private var noiseCount = 0
    private var timingAnchor = SonarTimingAnchor()
    private let source: SonarSource

    init(signal: SonarSignal, source: SonarSource = .both) {
        self.signal = signal
        self.source = source
        fft = vDSP_create_fftsetup(vDSP_Length(12), FFTRadix(kFFTRadix2))!
        templateL = (signal.left, [Float](repeating: 0, count: SonarSignal.count))
        templateR = (signal.right, [Float](repeating: 0, count: SonarSignal.count))
        transform(&templateL, direction: FFTDirection(FFT_FORWARD))
        transform(&templateR, direction: FFTDirection(FFT_FORWARD))
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    private func transform(_ data: inout (r: [Float], i: [Float]), direction: FFTDirection) {
        data.r.withUnsafeMutableBufferPointer { real in
            data.i.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(fft, &split, 1, logN, direction)
            }
        }
    }

    private struct Correlation {
        let real: [Float]; let imaginary: [Float]; let envelope: [Float]
    }
    private func correlation(_ input: (r: [Float], i: [Float]),
                             _ template: (r: [Float], i: [Float])) -> Correlation {
        let n = SonarSignal.count
        var result = (r: [Float](repeating: 0, count: n), i: [Float](repeating: 0, count: n))
        // Keep positive frequencies only: the analytic correlation's magnitude avoids carrier zero-crossings.
        for i in 1..<(n / 2) {
            result.r[i] = input.r[i] * template.r[i] + input.i[i] * template.i[i]
            result.i[i] = input.i[i] * template.r[i] - input.r[i] * template.i[i]
        }
        transform(&result, direction: FFTDirection(FFT_INVERSE))
        let scale = Float(2.0 / Double(n))
        return Correlation(real:result.r.map { $0*scale },imaginary:result.i.map { $0*scale },
                           envelope:zip(result.r,result.i).map { hypot($0,$1)*scale })
    }

    func consume(_ samples: [Float], sampleTime: Int64, hostTime: Double? = nil) -> [SonarEcho] {
        let gap = nextSample.map { $0 != sampleTime } ?? false
        if gap { pending.removeAll(keepingCapacity: true); timingAnchor = SonarTimingAnchor(); pendingGap = true }
        nextSample = sampleTime + Int64(samples.count)
        pending.append(contentsOf: samples)
        var results: [SonarEcho] = []
        while pending.count >= SonarSignal.count {
            let captureTime = hostTime.map { $0 + Double(samples.count - pending.count) / signal.sampleRate + Double(SonarSignal.count) / (2 * signal.sampleRate) }
            let frame = Array(pending.prefix(SonarSignal.count))
            pending.removeFirst(SonarSignal.count)
            received += SonarSignal.count
            var spectrum = (r: frame, i: [Float](repeating: 0, count: SonarSignal.count))
            transform(&spectrum, direction: FFTDirection(FFT_FORWARD))
            var bands: [Double] = []
            for b in 0..<6 {
                let low = signal.low + (signal.high - signal.low) * Double(b) / 6
                let high = signal.low + (signal.high - signal.low) * Double(b + 1) / 6
                let lo = Int(low * Double(SonarSignal.count) / signal.sampleRate)
                let hi = min(SonarSignal.count / 2 - 1, Int(high * Double(SonarSignal.count) / signal.sampleRate))
                var power = 0.0
                for i in lo...max(lo, hi) { power += Double(spectrum.r[i] * spectrum.r[i] + spectrum.i[i] * spectrum.i[i]) }
                bands.append(power / Double(max(1, hi - lo + 1)))
            }
            // Output has six silent superframes at startup; only the first three estimate ambient noise.
            if frameIndex < 3 {
                if noise.isEmpty { noise = bands.map { _ in 0 } }
                for i in 0..<6 { noise[i] += bands[i] }
                noiseCount += 1
            }
            frameIndex += 1
            if frameIndex < 9 { continue }
            let lc=correlation(spectrum,templateL), rc=correlation(spectrum,templateR)
            let left=lc.envelope, right=rc.envelope
            let anchors = timingAnchor.select(left: left, right: right, source: source)
            let dl = anchors.left, dr = anchors.right
            // Common normalization avoids amplifying destructive interference on
            // the weaker path. Both plots retain the same amplitude reference.
            let leadLeft = timingAnchor.leaderIsLeft ?? (source != .right)
            let normalizer = leadLeft ? left[dl] : right[dr]
            let linkL = Self.linkDB(left, peak: dl)
            let linkR = Self.linkDB(right, peak: dr)
            results.append(SonarEcho(captureTime: captureTime, left: rangeProfile(left, direct: dl, normalization: normalizer), right: rangeProfile(right, direct: dr, normalization: normalizer),
                                     timingLeader: leadLeft ? "left" : "right", leftEnvelope: left, rightEnvelope: right, leftDirectSample: dl, rightDirectSample: dr, leftLinkDB: linkL, rightLinkDB: linkR,
                                     clipping: frame.filter { abs($0) >= 0.98 }.count > 4,
                                     bands: bands, noiseBands: noiseCount > 0 ? noise.map { $0 / Double(noiseCount) } : nil,
                                     receivedFrames: received, inputGap: pendingGap,
                                     leftComplex:.referenced(real:lc.real,imaginary:lc.imaginary,direct:dl,rate:signal.sampleRate,carrier:(signal.low+signal.high)/2,normalization:normalizer),
                                     rightComplex:.referenced(real:rc.real,imaginary:rc.imaginary,direct:dr,rate:signal.sampleRate,carrier:(signal.low+signal.high)/2,normalization:normalizer),
                                     sampleRate: signal.sampleRate, leftRawReal: lc.real, leftRawImaginary: lc.imaginary,
                                     rightRawReal: rc.real, rightRawImaginary: rc.imaginary, carrier:(signal.low+signal.high)/2))
            pendingGap = false
        }
        return results
    }

    private static func linkDB(_ envelope: [Float], peak: Int) -> Double {
        let floor = envelope.sorted()[envelope.count / 2]
        return 20 * log10(Double(max(envelope[peak], 1e-12) / max(floor, 1e-12)))
    }

    private func rangeProfile(_ envelope: [Float], direct: Int, normalization: Float) -> [Float] {
        let n = envelope.count
        let normalization = max(normalization, 1e-12)
        return (0..<Self.plotCount).map { i in
            let range = Double(i) / Double(Self.plotCount - 1) * Self.maxRange
            let lag = range * 2 / 343 * signal.sampleRate
            let lower = Int(lag)
            let fraction = Float(lag - Double(lower))
            let a = envelope[(direct + lower) % n]
            let b = envelope[(direct + lower + 1) % n]
            return (a + (b - a) * fraction) / normalization
        }
    }

    static func subtract(_ profile: [Float], background: [Float]) -> [Float] {
        zip(profile, background).map { max(0, $0 - $1) }
    }

    struct Peak {
        var range: Double
        var prominenceDB: Double
    }

    static func peak(_ values: [Float], center: Double, previous: Double? = nil) -> Peak? {
        guard values.count > 4 else { return nil }
        let spacing = maxRange / Double(values.count - 1)
        let lo = max(1, Int(max(0.15, center - 0.25) / spacing))
        let hi = min(values.count - 2, Int(min(1.3, center + 0.25) / spacing))
        guard hi > lo else { return nil }
        let floor = max(values[lo...hi].sorted()[(hi - lo) / 2], 0.0002)
        var candidates: [Int] = []
        for i in lo...hi where values[i] >= values[i - 1] && values[i] > values[i + 1] {
            if let previous, abs(Double(i) * spacing - previous) > 0.12 { continue }
            candidates.append(i)
        }
        guard let best = candidates.max(by: { values[$0] < values[$1] }) else { return nil }
        let prominence = 20 * log10(Double(max(values[best], 1e-12) / floor))
        guard prominence > 10, values[best] > 0.003 else { return nil }
        let a = Double(values[best - 1]), b = Double(values[best]), c = Double(values[best + 1])
        let denominator = a - 2 * b + c
        let correction = abs(denominator) > 1e-12 ? min(0.5, max(-0.5, 0.5 * (a - c) / denominator)) : 0
        return Peak(range: (Double(best) + correction) * spacing, prominenceDB: prominence)
    }
}
