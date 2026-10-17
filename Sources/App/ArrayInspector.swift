import Combine
import Foundation

/// Independent measurement records; these never become gesture training labels.
final class ArrayInspector: ObservableObject {
    @Published private(set) var latest: ArrayMeasurement?
    @Published private(set) var calibration: WorkspaceCalibration?
    @Published private(set) var workspacePrediction: WorkspacePrediction?
    private var workspaceMap: WorkspaceResponseMap?
    @Published private(set) var study: ArrayStudy?
    @Published private(set) var status = "Start listening to inspect the three input channels."
    @Published private(set) var savedURL: URL?
    private var lastUpdate = 0.0
    private var saving = false

    func start() {
        guard study == nil, calibration == nil, !saving else { return }
        study = ArrayStudy()
        savedURL = nil
        status = "Waiting for array frames. Follow the timed prompts; commands stay paused."
    }
    func startCalibration() {
        guard study == nil, calibration == nil, !saving, latest?.timing?.ready == true else { return }
        calibration = WorkspaceCalibration()
        workspaceMap = nil; workspacePrediction = nil; savedURL = nil
        status = "Follow the marked positions. The final round checks a frozen map; it does not train it."
    }
    func accept(_ measurement: ArrayMeasurement, metadata: ArrayDeviceMetadata?) {
        let now = ProcessInfo.processInfo.systemUptime
        if calibration != nil {
            calibration?.append(measurement)
            if calibration?.finished == true { finishCalibration(metadata: metadata) }
        } else if let workspaceMap {
            workspacePrediction = workspaceMap.predict(measurement)
        }
        if study != nil {
            study?.append(measurement, now: now)
            if study?.finished == true { finish(metadata: metadata) }
        }
        if now - lastUpdate >= 0.1 { latest = measurement; lastUpdate = now }
        if study == nil, calibration == nil, !saving, savedURL == nil { status = "Live measurements · channel positions are uncalibrated." }
    }
    private func finishCalibration(metadata: ArrayDeviceMetadata?) {
        guard let calibration, !saving else { return }
        self.calibration = nil
        workspaceMap = calibration.map
        struct Report: Encodable {
            let version = 1
            let metadata: ArrayDeviceMetadata?
            let targets = WorkspaceTarget.marks
            let trials = WorkspaceCalibration.trials
            let rows: [WorkspaceCalibration.Row]
            let features: WorkspaceFeatures?
            let completed: Bool
            let failure: String?
            let summary: String
            let note = "Approximate instructed hand positions, not measured capsule coordinates. Two teaching rounds; frozen map for separate reordered check. No old gesture examples were changed."
        }
        let report = Report(metadata: metadata, rows: calibration.rows, features: calibration.extractor,
                            completed: calibration.finished, failure: calibration.failure, summary: calibration.validationSummary)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoGestures/WorkspaceCalibrations/workspace-\(UUID().uuidString).json")
        saving = true
        status = "Saving the workspace calibration…"
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(report).write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    self.saving = false; self.savedURL = url
                    self.status = calibration.finished ? calibration.validationSummary : "Partial calibration saved. The separate check is incomplete."
                    if let failure = calibration.failure { self.status += " " + failure }
                }
            } catch {
                let detail = error.localizedDescription
                DispatchQueue.main.async { self.saving = false; self.status = "Calibration save failed: " + detail }
            }
        }
    }

    func finish(metadata: ArrayDeviceMetadata?) {
        if calibration != nil { finishCalibration(metadata: metadata) }
        guard let study, !saving else { return }
        self.study = nil
        guard !study.rows.isEmpty else { status = "No array data captured."; return }
        struct Report: Encodable {
            let version = 1
            let metadata: ArrayDeviceMetadata?
            let rows: [ArrayStudy.Row]
            let note = "Timed instructions, not verified anatomy/position. Numerical probe responses only; no raw microphone waveform. Common phase/origin per speaker, HAL channel IDs, sequential L/R probes."
        }
        let report = Report(metadata: metadata, rows: study.rows)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoGestures/ArrayStudies/array-\(UUID().uuidString).json")
        saving = true; status = "Saving array measurements locally…"
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(report).write(to: url, options: .atomic)
                DispatchQueue.main.async { self.saving = false; self.savedURL = url; self.status = "Saved \(study.rows.count) array frames. No gesture model was trained." }
            } catch {
                let detail = error.localizedDescription
                DispatchQueue.main.async { self.saving = false; self.status = "Array save failed: " + detail }
            }
        }
    }
}
