// P0-5: Thin adapter over the Text Input Sources (TIS) API.

import Carbon

enum CurrentInputSource {
    /// Language codes (BCP 47, e.g. "en", "he") of the currently selected keyboard input source.
    static func languages() -> [String] {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
        else { return [] }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        return (array as? [String]) ?? []
    }

    /// Name of the distributed notification posted when the selected input source changes.
    static var changedNotification: Notification.Name {
        Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
    }
}
