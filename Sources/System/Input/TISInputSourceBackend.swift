// P2-14: The real TISBackend (001 §2.2, R1). Replaces the P0 `CurrentInputSource` enum. Only translation:
// the switcher contract (tokens, failure path, dedupe) is in `InputSourceSwitcher` (Core), which is tested
// with a fake. Plain TISSelectInputSource, no CJK workaround (best effort, R1). Main actor (001 §2.1).
// Use `InputSourceSwitcher.makeTIS()` to get the app's switcher.

import Carbon
import Foundation

@MainActor final class TISInputSourceBackend: TISBackend {
    /// Each relay unregisters itself in its deinit, so dropping the backend removes both observers.
    private var relays: [DistributedNotificationRelay] = []

    var current: InputSourceInfo? {
        // Create rule: the source is retained.
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return UCKeyTranslateLayoutMapProvider.info(source)
    }

    func sources(includeDisabled: Bool) -> [InputSourceInfo] {
        var seen = Set<InputSourceID>()
        // Some IDs are listed twice (e.g. once per parent input method): keep the first.
        return Self.sources(id: nil, includeDisabled: includeDisabled)
            .map(Self.info)
            .filter { seen.insert($0.id).inserted }
    }

    func select(_ id: InputSourceID) -> Bool {
        // P2-14: only enabled, selectable sources. Selecting a disabled one is refused, never silently enabled.
        guard let source = Self.sources(id: id, includeDisabled: false).first else { return false }
        return TISSelectInputSource(source) == noErr
    }

    func observe(selectedChanged: @escaping @MainActor () -> Void,
                 enabledChanged: @escaping @MainActor () -> Void) {
        // R1: object == nil, 10–20 ms after the switch, often twice. The switcher dedupes.
        // P2-14 QA: `.deliverImmediately`, so an inactive menu-bar app isn't sent them late (see the relay).
        relays.append(DistributedNotificationRelay(name: kTISNotifySelectedKeyboardInputSourceChanged as String,
                                                   handler: selectedChanged))
        relays.append(DistributedNotificationRelay(name: kTISNotifyEnabledKeyboardInputSourcesChanged as String,
                                                   handler: enabledChanged))
    }

    /// Keyboard-category, select-capable sources (R1 §1). With `includeDisabled == false`, only sources that
    /// can really be selected: enabled, and for an input mode, its parent input method enabled too.
    private static func sources(id: InputSourceID?, includeDisabled: Bool) -> [TISInputSource] {
        var filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        if !includeDisabled { filter[kTISPropertyInputSourceIsEnabled] = true }
        if let id { filter[kTISPropertyInputSourceID] = id.rawValue }
        // Create rule: the list is retained.
        let list = (TISCreateInputSourceList(filter as CFDictionary, includeDisabled)?.takeRetainedValue()
            as? [TISInputSource]) ?? []
        return includeDisabled ? list : list.filter(parentIsEnabled)
    }

    /// `UCKeyTranslateLayoutMapProvider.info`, with `isEnabled` false for an input mode whose parent is disabled.
    private static func info(_ source: TISInputSource) -> InputSourceInfo {
        let info = UCKeyTranslateLayoutMapProvider.info(source)
        guard info.isEnabled, !parentIsEnabled(source) else { return info }
        return InputSourceInfo(id: info.id, name: info.name, languageCode: info.languageCode, isEnabled: false,
                               isConvertible: info.isConvertible, isInputMethod: info.isInputMethod)
    }

    /// P2-14 QA: an input mode can report IsEnabled while its parent input method is disabled, and then it
    /// can't be selected (TextInputSources.h: "Input modes can only be selected if both they and their parent
    /// input method are enabled"). After any `includeAllInstalled: true` call in the process (the layout map
    /// provider makes one for every map), TIS lists such modes (e.g. Kotoeri, Ainu) as enabled even though the
    /// user never added them (QA probe, 2026-11-06; R1 §1 saw the same). Non-modes always pass.
    private static func parentIsEnabled(_ source: TISInputSource) -> Bool {
        let type: String? = property(source, kTISPropertyInputSourceType)
        guard type == (kTISTypeKeyboardInputMode as String),
              let bundleID: String = property(source, kTISPropertyBundleID) else { return true }
        let filter: [CFString: Any] = [
            kTISPropertyBundleID: bundleID,
            kTISPropertyInputSourceType: kTISTypeKeyboardInputMethodModeEnabled as Any,
            kTISPropertyInputSourceIsEnabled: true,
        ]
        // Create rule: the list is retained.
        let parents = (TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue()
            as? [TISInputSource]) ?? []
        return !parents.isEmpty
    }

    /// Get rule: the property is not retained.
    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
    }
}

extension InputSourceSwitcher {
    /// P2-14: the app's switcher over the real Text Input Sources API.
    static func makeTIS(clock: any Clock = SystemClock()) -> InputSourceSwitcher {
        InputSourceSwitcher(backend: TISInputSourceBackend(), clock: clock)
    }
}
