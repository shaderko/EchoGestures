import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var selected: UUID?
    @State private var adding = false
    @State private var binding: LearnedGesture?
    @State private var showDiagnostics = false
    @State private var showArray = false

    private var gesture: LearnedGesture? { model.library.gestures.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path").font(.system(size: 24, weight: .light)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("EchoGestures").font(.system(size: 21, weight: .semibold))
                    Text("Your gestures. Your shortcuts.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.audio.running || model.audio.starting ? "Stop listening" : "Start listening") {
                    if model.audio.running || model.audio.starting { model.stopListening() } else { model.startListening() }
                }.buttonStyle(.bordered)
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("GESTURES").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button { adding = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless).help("Add gesture").accessibilityLabel("Add gesture")
                            .disabled(model.lesson != nil || model.fitting)
                    }.padding(.horizontal, 18).padding(.top, 20)
                    List(selection: $selected) {
                        ForEach(model.library.gestures) { gesture in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(gesture.name).fontWeight(.medium)
                                Text(gesture.enabled ? gesture.shortcut?.label ?? "Preview only" : "Disabled")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).tag(gesture.id).opacity(gesture.enabled ? 1 : 0.5)
                        }
                    }.listStyle(.sidebar).disabled(model.lesson != nil)
                    if model.library.gestures.isEmpty {
                        Text("Add a hand pose or movement to begin.").font(.caption).foregroundStyle(.secondary).padding(18)
                    }
                }.frame(width: 220)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    if let lesson = model.lesson {
                        lessonView(lesson)
                    } else if let gesture {
                        Text(gesture.name).font(.system(size: 28, weight: .medium))
                        Text(gesture.kind.rawValue + " · \(gesture.examples.count) saved repetitions")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button(gesture.examples.isEmpty ? "Teach gesture" : "Teach more") { model.teach(gesture.id) }
                                .buttonStyle(.borderedProminent).disabled(model.fitting)
                            Button(gesture.exitShortcut == nil ? gesture.shortcut?.label ?? "Assign shortcut" : "Enter / exit commands") { binding = gesture }.buttonStyle(.bordered)
                        }
                        if let exit = gesture.exitShortcut, let entry = gesture.shortcut {
                            Text("Enter \(entry.label) → hold → Exit \(exit.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Repeat it four times when prompted. For movements, make one quick motion, then settle before the next prompt.")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        predictionView
                        HStack {
                            Button(gesture.enabled ? "Disable gesture" : "Enable gesture") { model.toggleGesture(gesture.id) }
                                .buttonStyle(.borderless).disabled(model.fitting)
                            Button("Delete gesture", role: .destructive) { model.deleteGesture(gesture.id) }
                                .buttonStyle(.borderless).disabled(model.fitting)
                            Spacer()
                            Text("\(model.eventCount) preview / command events").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Spacer()
                        Image(systemName: "hand.raised.fingers.spread").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.tint)
                        Text("Teach it your way.").font(.system(size: 28, weight: .medium))
                        Text("Name a distinct hand pose or short movement. Show it a few times, then choose what it does.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Add gesture") { adding = true }.buttonStyle(.borderedProminent).disabled(model.fitting)
                        Spacer()
                        predictionView
                    }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(minHeight: 330)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(model.audio.running ? Color.green : .secondary).frame(width: 6, height: 6)
                    Text(model.audio.status).font(.caption)
                    Spacer()
                    if model.audio.running { Text("\(model.audio.responseCount)/6 responses").font(.caption.monospaced()) }
                }
                if model.audio.running && model.audio.backgroundProgress < 1 { ProgressView(value: model.audio.backgroundProgress) }
                DisclosureGroup("Signal diagnostics", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.audio.healthSummary)
                        Text(model.inferenceSummary)
                        HStack {
                            Button("Inspect microphone array") { model.beginArrayInspection(); showArray = true }
                                .buttonStyle(.borderless).disabled(model.lesson != nil)
                            Button("Save diagnostics") { model.saveDiagnostics() }.buttonStyle(.borderless)
                            Text(model.recognitionReportStatus.isEmpty ? model.audio.diagnosticStatus : model.recognitionReportStatus).foregroundStyle(.secondary)
                        }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
                HStack(alignment: .center) {
                    Toggle("Enable commands", isOn: Binding(get: { model.commandsEnabled }, set: { model.setCommands($0) }))
                        .toggleStyle(.switch).controlSize(.small).disabled(model.lesson != nil || model.fitting)
                    if !model.commands.permitted {
                        Button("Accessibility settings") { model.commands.openPermissionSettings() }.buttonStyle(.borderless)
                    }
                    Spacer()
                    Button("Teach ignored movement") { model.teachIgnoredMovement() }
                        .buttonStyle(.borderless).disabled(model.lesson != nil || model.fitting)
                    Button("Local data") { model.revealData() }.buttonStyle(.borderless)
                }
                HStack(alignment: .top) {
                    Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.canUndoDelete {
                        Button("Undo delete") { model.undoDelete() }.buttonStyle(.borderless)
                            .disabled(model.fitting || model.lesson != nil)
                    }
                }
                Text("Echoes only · No camera · Shortcuts go to the foreground app · Release to repeat")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(20)
        }
        .frame(minWidth: 780, minHeight: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Color(red: 0.22, green: 0.45, blue: 0.36))
        .sheet(isPresented: $adding) {
            AddGestureSheet { name, kind in
                if let id = model.addGesture(name: name, kind: kind) { selected = id }
            }
        }
        .sheet(isPresented: $showArray, onDismiss: { model.endArrayInspection() }) {
            ArrayInspectorView(model: model, inspector: model.arrayInspector)
        }
        .sheet(item: $binding) { gesture in
            ShortcutSheet(gesture: gesture) { entry, exit in model.bind(gesture.id, shortcut: entry, exitShortcut: exit) }
        }
        .onAppear { if selected == nil { selected = model.library.gestures.first(where: \.enabled)?.id ?? model.library.gestures.first?.id } }
        .onChange(of: model.library.gestures.map(\.id)) { _, ids in
            if let selected, !ids.contains(selected) {
                self.selected = model.library.gestures.first(where: \.enabled)?.id ?? ids.first
            }
        }
    }

    private var predictionView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.fitting ? "LEARNING FROM YOUR EXAMPLES…" : "LIVE PREVIEW")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(model.bestGuess).font(.title3.weight(.medium))
            Text(model.triggerStatus).font(.caption).foregroundStyle(.secondary)
            if model.similarity > 0 {
                ProgressView(value: model.similarity).frame(maxWidth: 200)
                Text("Similarity versus rest · not trigger confidence")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let movement = model.lastMovement {
                Text(movement).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.lastEvent).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lessonView(_ lesson: GuidedLesson) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("TEACHING · \(min(4, lesson.repetition + 1))/4").font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(model.teachingIgnored ? "Movement to ignore" : model.library.gestures.first { $0.id == lesson.gestureID }?.name ?? "Gesture")
                .font(.system(size: 28, weight: .medium))
            Spacer()
            Text(lesson.stage == .perform ? (model.teachingIgnored ? "Do the unwanted movement" : "Do your gesture") : lesson.stage == .prepare ? "Get ready" : "Return to rest")
                .font(.system(size: 30, weight: .medium)).foregroundStyle(lesson.stage == .perform ? Color.accentColor : .primary)
            Text("\(model.countdown)").font(.system(size: 64, weight: .ultraLight, design: .monospaced)).monospacedDigit()
            Text(lesson.stage == .perform ? (model.teachingIgnored ? "Keep your hand resting and move your shoulder, lean, or do another movement that caused a false shortcut. These examples teach what to ignore." : (model.library.gestures.first { $0.id == lesson.gestureID }?.kind == .motion ? "Make one quick movement, then settle. Its start and end are detected automatically." : "Keep your chosen pose still until the countdown ends.")) : "Keep your body comfortable. Follow the countdown; capture is automatic.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Stop lesson · keep examples") { model.finishLesson(cancelled: true) }.buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
