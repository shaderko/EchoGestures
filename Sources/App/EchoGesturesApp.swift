import AppKit
import SwiftUI

@main
struct EchoGesturesApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("EchoGestures", id: "main") {
            MainView(model: model)
                .onAppear {
                    delegate.model = model
                    NSApp.activate(ignoringOtherApps: true)
                }
        }.defaultSize(width: 800, height: 620)
        MenuBarExtra("EchoGestures", systemImage: model.commandsEnabled ? "hand.raised.fill" : "hand.raised") {
            StatusMenu(model: model)
        }
    }
}

private struct StatusMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    var body: some View {
        Text(model.audio.status)
        Text(model.bestGuess)
        Divider()
        Button("Open EchoGestures") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button(model.commandsEnabled ? "Pause commands" : "Enable commands") { model.setCommands(!model.commandsEnabled) }
        if model.audio.running || model.audio.starting { Button("Stop listening") { model.stopListening() } }
        Divider()
        Button("Quit EchoGestures") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) { model?.stopListening() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
