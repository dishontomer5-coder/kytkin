// P2-14: The real TISBackend (001 §2.2, R1). Replaces the P0 `CurrentInputSource` enum. Only translation:
// the switcher contract (tokens, failure path, dedupe) is in `InputSourceSwitcher` (Core), which is tested
// with a fake. Plain TISSelectInputSource, no CJK workaround (best effort, R1). Main actor (001 §2.1).
// Use `InputSourceSwitcher.makeTIS()` to get the app's switcher.

import Carbon
import Foundation

@MainActor final class TISInputSourceBackend: TISBackend {
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    deinit {
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
    }

    var current: InputSourceInfo? {
        // Create rule: the source is retained.
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return UCKeyTranslateLayoutMapProvider.info(source)
    }

    func sources(includeDisabled: Bool) -> [InputSourceInfo] {
        var seen = Set<InputSourceID>()
        // Some IDs are listed twice (e.g. once per parent input method): keep the first.
        return Self.sources(id: nil, includeDisabled: includeDisabled)
            .map(UCKeyTranslateLayoutMapProvider.info)
            .filter { seen.insert($0.id).inserted }
    }

    func select(_ id: InputSourceID) -> Bool {
        // P2-14: only enabled sources. Selecting a disabled one is refused, never silently enabled.
        guard let source = Self.sources(id: id, includeDisabled: false).first else { return false }
        return TISSelectInputSource(source) == noErr
    }

    func observe(selectedChanged: @escaping @MainActor () -> Void,
                 enabledChanged: @escaping @MainActor () -> Void) {
        let center = DistributedNotificationCenter.default()
        // R1: object == nil, 10–20 ms after the switch, often twice. The switcher dedupes.
        observers.append(center.addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { selectedChanged() } })
        observers.append(center.addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { enabledChanged() } })
    }

    /// Keyboard-category, select-capable sources (R1 §1). `IsEnabled` is filtered explicitly when only enabled
    /// ones are wanted: after an includeAllInstalled call, TIS can return never-enabled input modes (R1).
    private static func sources(id: InputSourceID?, includeDisabled: Bool) -> [TISInputSource] {
        var filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        if !includeDisabled { filter[kTISPropertyInputSourceIsEnabled] = true }
        if let id { filter[kTISPropertyInputSourceID] = id.rawValue }
        // Create rule: the list is retained.
        return (TISCreateInputSourceList(filter as CFDictionary, includeDisabled)?.takeRetainedValue()
            as? [TISInputSource]) ?? []
    }
}

extension InputSourceSwitcher {
    /// P2-14: the app's switcher over the real Text Input Sources API.
    static func makeTIS(clock: any Clock = SystemClock()) -> InputSourceSwitcher {
        InputSourceSwitcher(backend: TISInputSourceBackend(), clock: clock)
    }
}
