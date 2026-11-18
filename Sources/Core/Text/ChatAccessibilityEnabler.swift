// P4-5: turns on the accessibility tree of a chat app (Slack, Discord, Teams: Electron) once per process, through the
// `ManualAccessibilitySetting` seam. Asked when a chat app comes to the front (AppController → ConvertDispatcher → here,
// on @TextActor, never on main) and, as a safety net, by the double-Shift itself (ConvertController).
//
// Rules:
//   - Chat apps only (`ReplacementCapabilities.isChatApp`). Browsers never: R3b rule 1 (no attribute is ever set on a
//     browser) stays.
//   - Once per pid: an answered write (`set`, or `refused`, see `ManualAccessibilityAnswer`) is remembered for that pid;
//     a relaunched app has a new pid and is asked again. `noAnswer` / `notTrusted` are not remembered (asked next time).
//   - `force`: write again even for a remembered pid (the double-Shift found no box: the tree may have been dropped,
//     or the first write came before the app was ready). Harmless: the same value again.
//   - Remembers at most `maxRemembered` pids (oldest dropped first), so a long session with many relaunches stays small.
//
// Holds only pids: nothing from the app is read, kept or logged.

import Foundation

@TextActor final class ChatAccessibilityEnabler {
    /// What `enable` did, for the caller and the DEBUG trace (enum names only).
    enum Result: Equatable, Sendable {
        /// Not a chat app, or no pid: nothing sent.
        case notChatApp
        /// Done before for this pid: nothing sent.
        case alreadySet
        /// Written now (the tree may need a moment to appear).
        case wrote(ManualAccessibilityAnswer)

        var traceName: String {
            switch self {
            case .notChatApp: "notChatApp"
            case .alreadySet: "alreadySet"
            case .wrote(let a): "wrote:\(a.rawValue)"
            }
        }
    }

    static let maxRemembered = 64
    /// The messaging timeout when a chat app comes to the front (the usual B5 timeout).
    static let frontmostTimeout: Double = 0.25
    /// The messaging timeout at double-Shift time (inside the 400 ms budget).
    static let requestTimeout: Double = 0.1

    private let setter: any ManualAccessibilitySetting
    private var done: [Int32] = []

    nonisolated init(setter: any ManualAccessibilitySetting) {
        self.setter = setter
    }

    /// True when the write for `pid` was answered before.
    func isSet(pid: Int32) -> Bool { done.contains(pid) }

    @discardableResult
    func enable(bundleID: String, pid: Int32?, timeout: Double, force: Bool = false) -> Result {
        guard let pid, pid > 0, ReplacementCapabilities.isChatApp(bundleID) else { return .notChatApp }
        if !force, done.contains(pid) { return .alreadySet }
        let answer = setter.setManualAccessibility(pid: pid, timeout: timeout)
        switch answer {
        case .set, .refused:
            if !done.contains(pid) {
                done.append(pid)
                if done.count > Self.maxRemembered { done.removeFirst(done.count - Self.maxRemembered) }
            }
        case .noAnswer, .notTrusted:
            break
        }
        return .wrote(answer)
    }
}
