import AppKit
import ApplicationServices

/// Posts the configured key to a named process; posting is not proof the app handled it.
final class CommandDispatcher {
    struct Target {
        let processID: pid_t
        let bundleID: String?
        let name: String
        let launchedAt: Date?
    }
    enum Result {
        case posted(Target)
        case blocked(String)
    }
    var permitted: Bool { AXIsProcessTrusted() }

    func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func send(_ shortcut: Shortcut, to target: Target? = nil) -> Result {
        guard permitted else { return .blocked("Accessibility permission is missing") }
        let application: NSRunningApplication?
        if let target {
            application = NSRunningApplication(processIdentifier: target.processID)
            guard application?.bundleIdentifier == target.bundleID,
                  application?.launchDate == target.launchedAt else { return .blocked("original app is no longer running") }
        } else { application = NSWorkspace.shared.frontmostApplication }
        guard let application, !application.isTerminated else { return .blocked("no target app") }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .blocked("EchoGestures is foreground; switch to the app you want to control")
        }
        guard let code = shortcut.keyCode,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            return .blocked("shortcut could not be created")
        }
        var flags: CGEventFlags = []
        if shortcut.command { flags.insert(.maskCommand) }
        if shortcut.option { flags.insert(.maskAlternate) }
        if shortcut.control { flags.insert(.maskControl) }
        if shortcut.shift { flags.insert(.maskShift) }
        down.flags = flags
        up.flags = flags
        down.postToPid(application.processIdentifier)
        up.postToPid(application.processIdentifier)
        return .posted(Target(processID: application.processIdentifier, bundleID: application.bundleIdentifier,
                              name: application.localizedName ?? "app", launchedAt: application.launchDate))
    }
}
