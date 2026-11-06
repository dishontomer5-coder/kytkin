// P2-14: InputSourceSwitching over a TISBackend, with the binding switcher contract of 001 §2.2:
//   1. already current → return true, do nothing (no select, no token)
//   2. attributor.willSelect(id)
//   3. backend.select; on failure attributor.selectFailed() and return false
//   4. on success attributor.willSelect(id) again: re-arms the 500 ms window from the moment the
//      select returned, so a slow select can't eat it (§12 R1)
//   5. every selected-source notification → attributor.didObserve(current:); nil is dropped, the rest go to onChange
// The logic lives in Core so it's unit-tested with a fake backend (InputSourceSwitcherTests). The TIS calls
// and notification observers are in `TISInputSourceBackend` (System/Input). Main actor only (001 §2.1).

import Foundation

@MainActor final class InputSourceSwitcher: InputSourceSwitching {
    private let backend: any TISBackend
    private var attributor: SwitchAttributor

    var onChange: (@MainActor (InputSourceChange) -> Void)?
    var onSourcesListChanged: (@MainActor () -> Void)?

    init(backend: any TISBackend, clock: any Clock) {
        self.backend = backend
        // P2-14: seed with the startup source, so a notification that changes nothing is deduped.
        attributor = SwitchAttributor(clock: clock, current: backend.current?.id)
        backend.observe(
            selectedChanged: { [weak self] in self?.selectedSourceChanged() },
            enabledChanged: { [weak self] in self?.onSourcesListChanged?() }
        )
    }

    /// Empty ID only if TIS reports no current source and none was ever observed (not expected in practice).
    var current: InputSourceID {
        backend.current?.id ?? attributor.lastKnown ?? InputSourceID("")
    }

    /// The current source with its name and language, for the menu-bar label.
    var currentInfo: InputSourceInfo? { backend.current }

    func sources(includeDisabled: Bool) -> [InputSourceInfo] {
        backend.sources(includeDisabled: includeDisabled)
    }

    @discardableResult func select(_ id: InputSourceID, reason: SwitchReason) -> Bool {
        // 1. TIS sends no notification for a no-op select, so a token would only swallow a later real switch.
        if backend.current?.id == id { return true }
        // 2. Token before the select.
        attributor.willSelect(id)
        // 3. A failed select sends no notification: drop the token (P2-10 QA).
        guard backend.select(id) else {
            attributor.selectFailed()
            return false
        }
        // 4. Re-arm from the moment the select returned (§12 R1).
        attributor.willSelect(id)
        return true
    }

    /// 5. Called (through the backend) for each delivery of kTISNotifySelectedKeyboardInputSourceChanged.
    func selectedSourceChanged() {
        guard let id = backend.current?.id,
              let change = attributor.didObserve(current: id) else { return }
        onChange?(change)
    }
}
