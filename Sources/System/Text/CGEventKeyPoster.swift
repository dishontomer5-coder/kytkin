// P2-18: The live `KeyEventPosting` (R5 §B): one CGEvent per `SyntheticKeyEvent`, from a private event source,
// modifier flags cleared, Unicode via `keyboardSetUnicodeString`, the `ours` marker in `eventSourceUserData`,
// posted to the session stream. Re-checks `isSafeToPost` so nothing unmarked, no control character and no
// Return/Tab key can ever leave here (design.md invariant). Called on @TextActor only, never the tap thread.
// Not compiled into the test target: tests must never post real events.

import CoreGraphics

final class CGEventKeyPoster: KeyEventPosting {
    private let source = CGEventSource(stateID: .privateState)

    func post(_ event: SyntheticKeyEvent) -> Bool {
        guard event.isSafeToPost,
              let cg = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode, keyDown: event.isKeyDown)
        else { return false }
        cg.flags = CGEventFlags(rawValue: event.modifierFlags)
        if !event.unicode.isEmpty {
            event.unicode.withUnsafeBufferPointer {
                cg.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
        }
        cg.setIntegerValueField(.eventSourceUserData, value: event.marker)
        cg.post(tap: .cgSessionEventTap)
        return true
    }
}
