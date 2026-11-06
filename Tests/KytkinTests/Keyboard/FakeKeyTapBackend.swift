// P2-17: A KeyTapBackend that installs nothing and posts nothing: it records what KeyTapEngine asked for.
// Tests feed CGEvents they created (never posted) straight into the stored handler, as the tap callback would.

import CoreGraphics
import Foundation

final class FakeKeyTapBackend: KeyTapBackend, @unchecked Sendable { // @unchecked: tests drive it from one thread
    var granted: Set<TapMode> = [.active, .listenOnly]
    var installSucceeds = true
    private(set) var installs: [TapMode] = []
    private(set) var uninstallCount = 0
    private(set) var reEnableCount = 0
    private(set) var handler: EventHandler?
    var enabled = false
    var secureInput = false
    var deviceFlags: UInt64 = 0

    /// Events "re-posted" (never really posted): key code and marker of each.
    private(set) var posted: [(keyCode: Int64, marker: Int64, keyDown: Bool)] = []
    private(set) var armedDeadline: UInt64?
    private(set) var soon: [() -> Void] = []
    private var deadlineHandler: (() -> Void)?
    private var pollHandler: (() -> Void)?

    func install(mode: TapMode, handler: @escaping EventHandler) -> Bool {
        installs.append(mode)
        guard installSucceeds else { return false }
        self.handler = handler
        enabled = true
        return true
    }

    func uninstall() {
        uninstallCount += 1
        handler = nil
        enabled = false
    }

    var isEnabled: Bool { enabled }

    func reEnable() {
        reEnableCount += 1
        enabled = handler != nil
    }

    func isGranted(_ mode: TapMode) -> Bool {
        mode == .off || granted.contains(mode)
    }

    /// Runs at each post, e.g. to check the commit state at that moment.
    var onPost: (() -> Void)?

    func post(_ event: CGEvent) {
        onPost?()
        posted.append((event.getIntegerValueField(.keyboardEventKeycode),
                       event.getIntegerValueField(.eventSourceUserData), event.type == .keyDown))
    }

    var isSecureInputEnabled: Bool { secureInput }
    var currentDeviceFlags: UInt64 { deviceFlags }

    func attachTimers(deadline: @escaping () -> Void, poll: @escaping () -> Void) {
        deadlineHandler = deadline
        pollHandler = poll
    }

    func armDeadline(atUptimeNanos due: UInt64) { armedDeadline = due }
    func cancelDeadline() { armedDeadline = nil }
    func runSoon(_ block: @escaping () -> Void) { soon.append(block) }

    // MARK: - Test driving

    /// As the tap callback: true = passed, false = swallowed. Nil if no tap is installed.
    @discardableResult
    func deliver(_ type: CGEventType, _ event: CGEvent) -> Bool? {
        handler?(type, event)
    }

    func fireDeadline() { deadlineHandler?() }
    func firePoll() { pollHandler?() }

    func runSoonBlocks() {
        let blocks = soon
        soon = []
        blocks.forEach { $0() }
    }

    func clearPosted() { posted = [] }
}
