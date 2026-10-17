import AppKit
import SwiftUI

struct ArrayInspectorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var inspector: ArrayInspector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Microphone array").font(.title2.weight(.medium))
                    Text("Measured channels, not assumed microphone positions").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            if let calibration = inspector.calibration {
                WorkspaceCalibrationPrompt(calibration: calibration)
                Button("Stop calibration · keep measurements") { inspector.finish(metadata: model.audio.arrayMetadata) }
            } else if let study = inspector.study {
                Text(study.finished ? "Finishing" : ArrayStudy.stages[study.stageIndex].instruction).font(.headline)
                Text("\(study.countdown)").font(.system(size: 38, weight: .light, design: .monospaced))
            } else {
                HStack {
                    Button(model.audio.running ? "Stop listening" : "Start listening") {
                        if model.audio.running { model.stopListening() } else { model.startListening() }
                    }
                    Button("Start hand / shoulder comparison") { inspector.start() }
                        .disabled(!model.audio.running || model.audio.backgroundProgress < 1)
                }
                Button("Calibrate hand workspace") { inspector.startCalibration() }
                    .disabled(!model.audio.running || inspector.latest?.timing?.ready != true)
                Text("Workspace calibration: about 95 seconds. Mark center/left/right positions on the desk; keep an open palm facing the screen. Start only when ready to follow the prompts.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Center: 20 cm toward you from the front edge, 15 cm above the desk. Left/right: ±15 cm. Higher: 30 cm above desk. Near/far: 10/35 cm from front edge. Keep the Mac, screen angle and your torso still.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("30 seconds: still → hand only → still → shoulder only → still. Prompts advance automatically. Commands stay paused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let metadata = model.audio.arrayMetadata {
                Text(String(format: "%d HAL inputs · %.0f Hz · latency %@ frames · coordinates uncalibrated",
                    metadata.inputChannels, metadata.sampleRate, metadata.latencyFrames.map(String.init) ?? "unknown"))
                    .font(.caption.monospaced())
                ForEach(0..<metadata.channels.count, id: \.self) { index in
                    let channel = metadata.channels[index]
                    Text("HAL \(index): \(channel.name ?? "unnamed") · label \(channel.label.map(String.init) ?? "unavailable") · coordinates \(channel.reportedCoordinates.map { String(describing: $0) } ?? "unavailable")")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if let prediction = inspector.workspacePrediction {
                Text("Workspace: " + prediction.region + (prediction.distinct ? "" : " · tentative"))
                    .font(.headline)
                Text("Best response region, not a measured hand position. Commands remain paused.").font(.caption).foregroundStyle(.secondary)
            }
            if let frame = inspector.latest {
                if let timing = frame.timing {
                    Text(timing.ready ? "Shared timing · fixed receiver offsets · shift \(timing.shift) sample(s)" + (timing.heldForDisagreement ? " · inconsistent peak changes held" : "")
                        : "Still timing reference · \(timing.calibrationFrames)/36 frames")
                        .font(.caption.monospaced())
                }
                let magnitudes = frame.commonProfiles.map(\.magnitude)
                let scale = max(0.01, magnitudes.flatMap { Array($0.dropFirst(20)) }.max() ?? 1)
                Text("Shared origin and amplitude reference within each speaker probe").font(.caption.weight(.medium))
                ForEach(0..<6, id: \.self) { path in
                    HStack(spacing: 8) {
                        Text("Mic \(path / 2) · \(path % 2 == 0 ? "L" : "R")").font(.caption.monospaced()).frame(width: 80, alignment: .leading)
                        Canvas { context, size in
                            let values = Array(magnitudes[path].dropFirst(20))
                            guard values.count > 1 else { return }
                            var line = Path()
                            for (index, value) in values.enumerated() {
                                let point = CGPoint(x: Double(index) / Double(values.count - 1) * size.width,
                                    y: size.height * (1 - Double(min(value / scale, 1))))
                                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                            }
                            context.stroke(line, with: .color(path % 2 == 0 ? .blue : .orange), lineWidth: 1)
                        }.frame(height: 32).background(.quaternary.opacity(0.3))
                        Text(String(format: "fixed %+d · peak %+d", frame.timing.flatMap { timing in
                            timing.ready ? SonarTimingAnchor.circularDifference(timing.anchors[path], timing.anchors[path % 2], count: 4096) : nil
                        } ?? frame.relativeDirectSamples[path], frame.relativeDirectSamples[path]))
                            .font(.system(size: 10, design: .monospaced)).frame(width: 140, alignment: .trailing)
                    }
                }
                Text("Horizontal: excess path / 2, about 12 cm–1.4 m; this is not a measured hand distance. L/R probes are sequential.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    ForEach(0..<frame.input.rms.count, id: \.self) { index in
                        Text(String(format: "Mic %d RMS %.5f", index, frame.input.rms[index])).font(.caption.monospaced())
                    }
                }
                ForEach(0..<frame.input.pairs.count, id: \.self) { index in
                    let pair = frame.input.pairs[index]
                    Text("Mic \(pair.first)/\(pair.second): r \(pair.correlation.map { String(format: "%.3f", $0) } ?? "silent") · relative difference \(pair.relativeDifference.map { String(format: "%.1f%%", $0 * 100) } ?? "undefined")")
                        .font(.system(size: 11, design: .monospaced))
                }
                Text(frame.valid ? "Six probe responses valid" : "Weak, clipped or interrupted frame — retained and flagged")
                    .font(.caption).foregroundStyle(frame.valid ? Color.secondary : Color.orange)
            }
            Text(inspector.status).font(.caption).foregroundStyle(.secondary)
            if let url = inspector.savedURL {
                Button("Show saved array study") { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path) }
            }
            Text("Phase, amplitudes, direct-path offsets and numeric input checks save locally. No raw microphone audio or gesture training is saved by this test.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(24)
        }.frame(width: 720, height: 700)
    }
}

private struct WorkspaceCalibrationPrompt: View {
    let calibration: WorkspaceCalibration
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(calibration.current?.validation == true ? "SEPARATE CHECK · MAP FROZEN" : "TEACHING THE WORKSPACE")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(calibration.phase == "baseline" ? "Hand in lap · keep still" : calibration.phase == "prepare" ? "Move to the next mark" : calibration.current?.target.id == "shoulder" ? "Move only your shoulder" : "Hold the marked position")
                .font(.title3.weight(.medium))
            Text(calibration.current?.target.instruction ?? "Measuring the still complex echo reference.")
                .fixedSize(horizontal: false, vertical: true)
            Text("\(calibration.countdown)").font(.system(size: 38, weight: .light, design: .monospaced))
            WorkspaceMarks(target: calibration.current?.target)
            if let point = calibration.current?.target.centimeters {
                Text(String(format: "Right/left: %+.0f cm · toward you: %.0f cm · above desk: %.0f cm", point[0], point[1], point[2]))
                    .font(.caption.monospaced())
            }
            if let failure = calibration.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
    }
}

private struct WorkspaceMarks: View {
    let target: WorkspaceTarget?
    var body: some View {
        HStack(spacing: 12) {
            projection(title: "From above · keyboard at top", vertical: 1, extent: 45)
            projection(title: "Facing the screen · height", vertical: 2, extent: 40)
        }.frame(height: 135)
    }
    private func projection(title: String, vertical: Int, extent: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Canvas { context, size in
                let marks = WorkspaceTarget.marks.filter { $0.id != target?.id } + WorkspaceTarget.marks.filter { $0.id == target?.id }
                for mark in marks {
                    guard let point = mark.centimeters else { continue }
                    let x = size.width * (0.5 + point[0] / 50)
                    let value = point[vertical] / extent
                    let y = size.height * (vertical == 1 ? value : 1-value)
                    let selected = mark.id == target?.id
                    let rect = CGRect(x: x-5, y: y-5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: rect), with: .color(selected ? .orange : .secondary.opacity(0.35)))
                    if selected { context.draw(Text(mark.name).font(.caption.bold()), at: CGPoint(x: x, y: y+16)) }
                }
            }.background(.quaternary.opacity(0.2))
        }
    }
}
