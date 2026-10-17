import Foundation

/// Remembers only successful held entries. A failed/preview entry can never cause an exit shortcut.
struct CommandSession<Target> {
    struct Active {
        let target: Target
        let shortcut: Shortcut
    }
    private var active: [UUID: Active] = [:]
    func contains(_ id: UUID) -> Bool { active[id] != nil }

    mutating func remember(_ id: UUID, target: Target, exit: Shortcut?) {
        guard let exit else { return }
        active[id] = Active(target: target, shortcut: exit)
    }
    mutating func release(_ id: UUID) -> Active? { active.removeValue(forKey: id) }
    mutating func drain() -> [Active] { let result = Array(active.values); active = [:]; return result }
}
