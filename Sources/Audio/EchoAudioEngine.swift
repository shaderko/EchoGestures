import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Owns the helper and temporary audio route. No system defaults or device rates are changed.
final class EchoAudioEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var status = "Sound off"
    @Published private(set) var backgroundProgress = 0.0
    @Published private(set) var responseCount = 0
    @Published private(set) var healthSummary = "No capture diagnostics yet"
    @Published private(set) var diagnosticStatus = ""
    @Published private(set) var arrayMetadata: ArrayDeviceMetadata?
    var inspectArray = false
    var onArrayMeasurement: ((ArrayMeasurement) -> Void)?
    var onFrame: (([Double], Double) -> Void)?
    var onDiscontinuity: (() -> Void)?

    private let arrayRequest = VoiceArrayMicrophones()
    private let worker = DispatchQueue(label: "dev.echogestures.dsp", qos: .userInitiated)
    private var aggregate: AudioDeviceID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var token = UUID()
    private var watchdog: Timer?
    private var lastFrame = 0.0
    private var background = EchoBackground()
    private var arrayClock = RigidArrayClock()
    private var freshness = CaptureFreshness()
    private var health = CaptureHealth()
    private var startedAt = 0.0
    private var lastSummary = 0.0
    private var lastSave = 0.0
    private var reportID = UUID()
    private let reportWriter = DispatchQueue(label: "dev.echogestures.capture-health", qos: .utility)

    func start() {
        guard !running, !starting else { return }
        starting = true
        token = UUID()
        let request = token
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: prepare(request)
        case .notDetermined:
            status = "Allow microphone access to analyze echoes locally."
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.token == request else { return }
                    if allowed { self.prepare(request) }
                    else { self.fail("Microphone access denied. Enable EchoGestures in Privacy & Security → Microphone.") }
                }
            }
        default: fail("Enable EchoGestures in Privacy & Security → Microphone.")
        }
    }

    private func prepare(_ request: UUID) {
        do {
            try arrayRequest.start(device: 0)
            status = "Opening three Mac microphones…"
            waitForArray(request, attempt: 0)
        } catch { fail(error.localizedDescription) }
    }

    private func waitForArray(_ request: UUID, attempt: Int) {
        guard token == request, starting else { return }
        guard arrayRequest.active else { fail(arrayRequest.failureDetail ?? "Microphone helper stopped."); return }
        if let input = try? AudioDevice.builtIn(uid: "BuiltInMicrophoneDevice", scope: kAudioObjectPropertyScopeInput), input.channels == 3 {
            do { try open(input: input, request: request) } catch { fail(error.localizedDescription) }
        } else if attempt < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.waitForArray(request, attempt: attempt + 1) }
        } else { fail("This Mac did not expose three microphone channels. Capture stopped.") }
    }

    private func open(input: AudioDevice, request: UUID) throws {
        let output = try AudioDevice.builtIn(uid: "BuiltInSpeakerDevice", scope: kAudioObjectPropertyScopeOutput)
        guard output.channels == 2 else { throw AudioFailure("Stereo Mac speakers are required.") }
        aggregate = try AudioDevice.aggregate(input: input, output: output)
        let capture = try AudioDevice.format(device: aggregate, scope: kAudioObjectPropertyScopeInput)
        let playback = try AudioDevice.format(device: aggregate, scope: kAudioObjectPropertyScopeOutput)
        guard capture.mChannelsPerFrame == 3, capture.mSampleRate >= 48_000,
              abs(capture.mSampleRate - playback.mSampleRate) < 1 else {
            throw AudioFailure("Three native channels and matching 48 kHz or higher input/output are required.")
        }
        arrayMetadata = ArrayDeviceMetadata.read(input, rate: capture.mSampleRate)
        let signal = SonarSignal(sampleRate: capture.mSampleRate)
        let emitter = ProbeEmitter(signal: signal)
        let processors = (0..<3).map { _ in SonarDSP(signal: signal) }
        let slots = DispatchSemaphore(value: 4)
        let queue = worker
        try AudioDevice.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { [weak self] _, input, time, output, _ in
            emitter.render(output)
            guard slots.wait(timeout: .now()) == .success else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var channels: [[Float]] = []
            for buffer in buffers {
                guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                                        count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
                channels += AudioSamples.split(samples, channels: Int(buffer.mNumberChannels))
            }
            guard channels.count == 3 else { slots.signal(); return }
            let stamp = Int64(time.pointee.mSampleTime)
            let host = time.pointee.mFlags.contains(.hostTimeValid)
                ? Double(AudioConvertHostTimeToNanos(time.pointee.mHostTime)) * 1e-9 : nil
            let captured = channels
            queue.async {
                let inputMetrics = ArrayInputMetrics.measure(captured)
                let results = zip(processors, captured).map { $0.consume($1, sampleTime: stamp, hostTime: host) }
                let count = results.map(\.count).min() ?? 0
                guard count > 0 else { slots.signal(); return }
                let frames = (0..<count).map { index in results.map { $0[index] } }
                // Include main-thread delivery in the four-buffer bound. Otherwise
                // DSP can enqueue indefinitely while UI/model work delays recognition.
                DispatchQueue.main.async {
                    defer { slots.signal() }
                    guard let self, self.token == request, self.running else { return }
                    for echoes in frames { self.accept(echoes, input: inputMetrics) }
                }
            }
        }, "Open audio I/O")
        background = EchoBackground()
        arrayClock = RigidArrayClock()
        freshness = CaptureFreshness()
        health = CaptureHealth()
        startedAt = ProcessInfo.processInfo.systemUptime
        lastSummary = 0
        lastSave = startedAt
        reportID = UUID()
        backgroundProgress = 0
        lastFrame = ProcessInfo.processInfo.systemUptime
        running = true
        starting = false
        status = "Keep your hand away · measuring empty space"
        try AudioDevice.check(AudioDeviceStart(aggregate, ioProc), "Start audio")
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.lastFrame
            if elapsed > 0.35 { self.onDiscontinuity?() }
            if elapsed > 3 { self.fail("Microphone data stopped. Start again for a fresh background.") }
        }
    }

    private func accept(_ echoes: [SonarEcho], input: ArrayInputMetrics) {
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = freshness.accept(captured: echoes.first?.captureTime, now: now)
        let qualified = fresh && echoes.count == 3 && echoes.allSatisfy {
            !$0.inputGap && !$0.clipping && $0.leftLinkDB >= 12 && $0.rightLinkDB >= 12
        }
        let timing = arrayClock.update(anchors: echoes.flatMap { [$0.leftDirectSample, $0.rightDirectSample] },
            time: echoes.first?.captureTime ?? now, qualified: qualified, interrupted: echoes.contains { $0.inputGap })
        if inspectArray, onArrayMeasurement != nil,
           let measurement = ArrayMeasurement.make(echoes, input: input, timing: timing, validInput: fresh) {
            onArrayMeasurement?(measurement)
        }
        guard fresh else {
            record(echoes, at: now, accepted: false, reason: "stale timestamp")
            onDiscontinuity?()
            status = "Delayed audio skipped · waiting for fresh echoes"
            return
        }
        lastFrame = now
        guard echoes.count == 3, echoes.allSatisfy({ !$0.inputGap && !$0.clipping }) else {
            record(echoes, at: now, accepted: false, reason: "gap or clipping")
            onDiscontinuity?()
            status = "Audio interrupted or clipping · commands paused"
            return
        }
        let links = echoes.flatMap { [$0.leftLinkDB, $0.rightLinkDB] }
        responseCount = links.filter { $0 >= 12 }.count
        guard responseCount == 6 else {
            record(echoes, at: now, accepted: false, reason: "weak probe")
            onDiscontinuity?()
            status = "Probe weak (\(responseCount)/6) · check built-in speaker volume"
            return
        }
        let features = background.consume(echoes.flatMap { [$0.left, $0.right] })
        backgroundProgress = background.progress
        record(echoes, at: now, accepted: true, reason: features == nil ? "background" : "features")
        if let features {
            status = "Listening · 3 microphones × 2 speakers"
            onFrame?(features, echoes[0].captureTime ?? lastFrame)
        }
    }

    func stop() {
        saveDiagnostics()
        token = UUID()
        watchdog?.invalidate()
        watchdog = nil
        if let ioProc, aggregate != 0 {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = 0
        arrayRequest.stop()
        running = false
        starting = false
        responseCount = 0
        backgroundProgress = 0
        status = "Sound off"
        onDiscontinuity?()
    }

    private func record(_ echoes: [SonarEcho], at now: Double, accepted: Bool, reason: String) {
        health.append(.init(elapsed: max(0, now - startedAt), captureAgeMilliseconds: freshness.age * 1000,
                            linkDB: echoes.flatMap { [$0.leftLinkDB, $0.rightLinkDB] },
                            directSamples: echoes.flatMap { [$0.leftDirectSample, $0.rightDirectSample] },
                            backgroundProgress: background.progress, residualEnergy: background.residualEnergy,
                            accepted: accepted, reason: reason))
        if now - lastSummary > 1 {
            lastSummary = now
            healthSummary = String(format: "Capture %.0f ms old · %d/%d skipped · %.0f s running",
                                   max(0, freshness.age * 1000), health.rejected, health.total, now - startedAt)
        }
        if now - lastSave > 30 { lastSave = now; saveDiagnostics() }
    }

    func saveDiagnostics() {
        guard health.total > 0 else { return }
        struct Report: Encodable {
            let version = 1
            let total: Int
            let rejected: Int
            let first: [CaptureHealthRow]
            let recent: [CaptureHealthRow]
        }
        let report = Report(total: health.total, rejected: health.rejected, first: health.first, recent: health.orderedRecent)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoGestures/Diagnostics", isDirectory: true)
        let id = reportID
        reportWriter.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("capture-\(id.uuidString).json")
                try JSONEncoder().encode(report).write(to: url, options: .atomic)
                DispatchQueue.main.async { self?.diagnosticStatus = "Saved timing/signal report locally" }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.diagnosticStatus = "Report save failed: " + message }
            }
        }
    }

    private func fail(_ message: String) { stop(); status = message }
}

enum AudioSamples {
    static func split(_ samples: [Float], channels: Int) -> [[Float]] {
        guard channels > 0, channels <= 32, samples.count % channels == 0 else { return [] }
        return (0..<channels).map { channel in stride(from: channel, to: samples.count, by: channels).map { samples[$0] } }
    }
}

/// Playback is precomputed and never feeds microphone samples back to the speakers.
private final class ProbeEmitter {
    let signal: SonarSignal
    private var frame = 0
    init(signal: SonarSignal) { self.signal = signal }
    func render(_ output: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels))
        for offset in 0..<frames {
            var channelOffset = 0
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for channel in 0..<Int(buffer.mNumberChannels) {
                    let path = channelOffset + channel
                    let value: Float = frame < SonarSignal.count * 6 ? 0
                        : path == 0 ? signal.left[frame % SonarSignal.count]
                        : path == 1 ? signal.right[frame % SonarSignal.count] : 0
                    data[offset * Int(buffer.mNumberChannels) + channel] = value
                }
                channelOffset += Int(buffer.mNumberChannels)
            }
            frame += 1
        }
    }
}
