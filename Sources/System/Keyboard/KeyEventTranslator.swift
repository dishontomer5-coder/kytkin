// P2-17: CGEvent → Core `KeyEvent` (001 §2.2 adapter contract step 1). Reads only the key code, flags, timestamp,
// auto-repeat and the `eventSourceUserData` marker. Never characters. No allocation.

import CoreGraphics
import Foundation

enum KeyEventTranslator {
    /// What KeyWatcher asks the tap for. The disabled-by-timeout / user-input notices arrive regardless of the mask.
    static let eventsOfInterest: CGEventMask = {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    // CGEventFlags bits (IOLLEvent.h), as raw values so the test can name them.
    static let capsLockMask = CGEventFlags.maskAlphaShift.rawValue        // 0x10000
    static let commandOrControlMask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue

    /// The Core kind for a tap event type. `nil` = not ours to look at (pass it untouched).
    /// The two "tap disabled" notices are handled by the watcher itself, so they map to nil here too.
    static func kind(for type: CGEventType) -> KeyEvent.Kind? {
        switch type {
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        case .flagsChanged: return .flagsChanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .pointerDown
        default: return nil
        }
    }

    /// True for `tapDisabledByTimeout` / `tapDisabledByUserInput`.
    static func isTapDisabledNotice(_ type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    /// The marker check that runs first in the callback (design.md: `ours` / `replay`).
    @inline(__always)
    static func origin(of event: CGEvent) -> EventOrigin {
        EventOrigin(userData: event.getIntegerValueField(.eventSourceUserData))
    }

    /// Builds the Core event. `origin` was already read (marker first); `timestampNanos` is already normalized.
    static func keyEvent(_ kind: KeyEvent.Kind, from event: CGEvent, origin: EventOrigin,
                         timestampNanos: UInt64) -> KeyEvent {
        let flags = event.flags.rawValue
        let isKey = kind != .pointerDown
        // Key codes are 0…127 (a 16-bit field); clamp anything odd instead of trapping in the callback.
        let rawCode = isKey ? event.getIntegerValueField(.keyboardEventKeycode) : 0
        let code = UInt16(clamping: max(0, rawCode))
        let autoRepeat = kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        return KeyEvent(kind: kind, keyCode: code, deviceFlags: flags, timestampNanos: timestampNanos,
                        origin: origin, isAutoRepeat: autoRepeat,
                        commandOrControl: flags & commandOrControlMask != 0,
                        capsLock: flags & capsLockMask != 0)
    }
}
