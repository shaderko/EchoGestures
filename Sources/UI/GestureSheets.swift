import SwiftUI

struct AddGestureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = GestureKind.pose
    let add: (String, GestureKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New gesture").font(.title2.weight(.medium))
            TextField("Name your gesture", text: $name).textFieldStyle(.roundedBorder)
            Picker("Gesture type", selection: $kind) {
                ForEach(GestureKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text("Choose something you can repeat comfortably near your Mac. Similar gestures may be hard to distinguish.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add gesture") { add(name, kind); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 60)
            }
        }.padding(28).frame(width: 390)
    }
}

struct ShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let gesture: LearnedGesture
    let save: (Shortcut?, Shortcut?) -> Void
    @State private var shortcut: Shortcut
    @State private var exitShortcut: Shortcut
    @State private var hasExit: Bool

    init(gesture: LearnedGesture, save: @escaping (Shortcut?, Shortcut?) -> Void) {
        self.gesture = gesture
        self.save = save
        let entry = gesture.shortcut ?? Shortcut(key: "Space", command: false)
        _shortcut = State(initialValue: entry)
        _exitShortcut = State(initialValue: gesture.exitShortcut ?? entry)
        _hasExit = State(initialValue: gesture.exitShortcut != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Commands for \(gesture.name)").font(.title2.weight(.medium))
            Button("Use YouTube play/pause · K on both") {
                shortcut = Shortcut(key: "K", command: false)
                exitShortcut = shortcut
                hasExit = true
            }.buttonStyle(.borderless)
            ShortcutFields(title: "On enter", shortcut: $shortcut)
            Toggle("Run another shortcut on exit", isOn: $hasExit)
            if hasExit {
                ShortcutFields(title: "On exit", shortcut: $exitShortcut)
                Text("Enter once, hold without repeats, then exit once when you release. For an app that toggles pause/play with Space, use Space for both.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Entry goes to the foreground app. Exit returns to that same app, including when listening stops. A posted shortcut still depends on the app's focus and key bindings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Remove binding") { save(nil, nil); dismiss() }.disabled(gesture.shortcut == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(shortcut, hasExit ? exitShortcut : nil); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 440)
    }
}

private struct ShortcutFields: View {
    let title: String
    @Binding var shortcut: Shortcut
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(shortcut.label).font(.title3)
            }
            Picker(title + " key", selection: $shortcut.key) {
                ForEach(Shortcut.keys, id: \.name) { Text($0.name).tag($0.name) }
            }
            HStack(spacing: 16) {
                Toggle("⌘", isOn: $shortcut.command)
                Toggle("⌥", isOn: $shortcut.option)
                Toggle("⌃", isOn: $shortcut.control)
                Toggle("⇧", isOn: $shortcut.shift)
            }.toggleStyle(.checkbox)
        }
    }
}
