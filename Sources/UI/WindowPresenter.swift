// P2-56: The one show/hide helper for Kytkin's own windows (Settings, the welcome window, later alerts), so every
// window comes forward the same way in an LSUIElement (accessory) app.
//
// Showing:
//   1. `NSApp.unhide` first: closing Kytkin's last window hides the app, and a hidden app's windows stay hidden even
//      when ordered front.
//   2. `NSApp.activate()` (macOS 14 cooperative activation): works when the user just clicked our menu or launched
//      us, but may be refused otherwise.
//   3. `makeKeyAndOrderFront` + `orderFrontRegardless`, so the window is at least on top either way.
//   4. Fallback (P2-56): if a moment later the window still isn't key (activation was refused, so typing would go to
//      the app behind), ask once more with the older `activate(ignoringOtherApps:)`. Only ever right after a show the
//      user asked for, or the one-time welcome at launch, so Kytkin never keeps grabbing focus.
//      P3-12 (P2-63): and only if the user hasn't switched apps in those 0.3 s (`FocusFallbackPolicy`, Core).
// Closing: when the last titled window closes, Kytkin hides itself, so macOS activates the app you were in (an
// accessory app with no window would otherwise stay active and keys would go nowhere).

import AppKit

@MainActor enum WindowPresenter {
    /// How long to wait before checking that the window took the keyboard.
    static let keyCheckDelay: TimeInterval = 0.3

    static func show(_ window: NSWindow) {
        if !window.isVisible { window.center() }
        let frontmostAtShow = frontmostPID()   // P3-12: before we ask to activate
        NSApp.unhide(nil)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + keyCheckDelay) { [weak window] in
            MainActor.assumeIsolated {
                guard let window, FocusFallbackPolicy.shouldInsist(
                    windowVisible: window.isVisible, windowHasKeyboard: NSApp.isActive && window.isKeyWindow,
                    ownPID: ProcessInfo.processInfo.processIdentifier,
                    frontmostAtShow: frontmostAtShow, frontmostNow: frontmostPID()) else { return }
                // P2-56: the deprecated call goes through a protocol so the build stays free of warnings; it is
                // the way to insist once after cooperative activation was refused.
                (NSApp as LegacyActivating).activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private static func frontmostPID() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// From `windowWillClose`: hide Kytkin if `closing` was its last visible titled window.
    static func willClose(_ closing: NSWindow) {
        let others = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        if others.isEmpty { NSApp.hide(nil) }
    }
}

/// `NSApplication.activate(ignoringOtherApps:)` without the macOS 14 deprecation warning at the call site.
@MainActor private protocol LegacyActivating {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: LegacyActivating {}

/// P2-56: Kytkin's windows close on Esc too (⌘W comes from the hidden main menu, `MainMenu`).
/// P3-12 (P2-63): but Esc in a text field first clears it, then leaves it; only then does it close the window, and
/// never while a sheet is attached (`EscapeKeyAction`, Core).
final class KytkinWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        let editor = firstResponder as? NSTextView
        let focus: EscapeKeyAction.Focus = switch editor {
        // P3-15: only a search field is cleared by Esc; any other field just stops editing (EscapeKeyAction).
        case let text? where text.isEditable && text.isFieldEditor && text.delegate is NSSearchField:
            .searchField(isEmpty: text.string.isEmpty)
        case let text? where text.isEditable && text.isFieldEditor: .textField
        case let text? where text.isEditable: .textArea
        default: .nothingEdited
        }
        switch EscapeKeyAction.decide(sheetAttached: attachedSheet != nil, focus: focus) {
        case .ignore:
            break
        case .clearField:
            // Through the text system (not `string = ""`), so the field's binding hears it and ⌘Z can undo it.
            editor?.selectAll(nil)
            editor?.delete(nil)
            // P3-15 (P3-12 QA note): a field that refused the delete keeps its text; leave it instead of looping.
            if editor?.string.isEmpty == false { makeFirstResponder(nil) }
        case .stopEditing:
            makeFirstResponder(nil)
        case .closeWindow:
            performClose(sender)
        }
    }
}
