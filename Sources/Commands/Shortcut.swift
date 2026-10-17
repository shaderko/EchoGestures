import Foundation

struct Shortcut: Codable, Equatable {
    var key: String
    var command = true
    var option = false
    var control = false
    var shift = false

    static let keys: [(name: String, code: UInt16)] = [
        ("A", 0), ("S", 1), ("D", 2), ("F", 3), ("H", 4), ("G", 5), ("Z", 6), ("X", 7), ("C", 8), ("V", 9),
        ("B", 11), ("Q", 12), ("W", 13), ("E", 14), ("R", 15), ("Y", 16), ("T", 17),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29),
        ("O", 31), ("U", 32), ("I", 34), ("P", 35), ("Return", 36), ("L", 37), ("J", 38), ("K", 40),
        ("N", 45), ("M", 46), ("Tab", 48), ("Space", 49), ("Escape", 53),
        ("Left", 123), ("Right", 124), ("Down", 125), ("Up", 126)
    ].sorted { $0.name < $1.name }
    var keyCode: UInt16? { Self.keys.first { $0.name == key }?.code }
    var valid: Bool { keyCode != nil }
    var label: String { (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key }
}
