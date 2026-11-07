// P2-6: LayoutMapProviding over TIS + UCKeyTranslate (001 §2.2, R6). Reads a layout's uchr data and asks
// UCKeyTranslate what each key types; LayoutMapBuilder (Core) decides what to keep. Read-only: it never
// selects, enables or switches an input source. Installed-but-disabled layouts are read the same way.
// This file is also compiled into the headless `scripts/dump-layoutmap` tool that makes the test fixtures.

import Carbon
import Foundation

@MainActor final class UCKeyTranslateLayoutMapProvider: LayoutMapProviding {
    private var cache: [InputSourceID: LayoutMap] = [:]
    private var cachedKbdType: Int?
    /// P2-43: the sources-changed notification arrives through `DistributedNotificationRelay` (`.deliverImmediately`),
    /// like the switcher's, so an inactive menu-bar app isn't sent it late. The relay unregisters itself in its deinit.
    private var relay: DistributedNotificationRelay?

    init() {
        // P2-6: rebuild when layouts are added, removed, enabled or disabled (001 §2.2).
        relay = DistributedNotificationRelay(name: kTISNotifyEnabledKeyboardInputSourcesChanged as String) {
            [weak self] in self?.invalidate()
        }
    }

    func invalidate() { cache.removeAll() }

    func convertibleLayouts(includeDisabled: Bool) -> [InputSourceInfo] {
        // Filter by type: an unfiltered includeAllInstalled list loads data for every source (R6 §1).
        let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary
        let sources = Self.sources(filter, includeAllInstalled: includeDisabled)
        // Some IDs are listed twice (e.g. WubihuaKeyboard, once per parent input method): keep the first.
        var seen = Set<InputSourceID>()
        return sources.map(Self.info).filter { $0.isConvertible && seen.insert($0.id).inserted }
    }

    func map(for id: InputSourceID) -> LayoutMap? {
        // P2-6: the keyboard type changes the output of some keys on ISO/JIS hardware (R6 §2).
        let kbdType = Int(LMGetKbdType())
        if kbdType != cachedKbdType {
            cache.removeAll()
            cachedKbdType = kbdType
        }
        if let map = cache[id] { return map }
        guard let source = Self.source(id: id), let map = Self.buildMap(source, id: id, kbdType: kbdType) else {
            return nil
        }
        cache[id] = map
        return map
    }

    // MARK: - TIS

    /// Lookup by ID including installed-but-disabled sources. Filtered, so it's < 1 ms (R6 §1).
    static func source(id: InputSourceID) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID: id.rawValue] as CFDictionary
        return sources(filter, includeAllInstalled: true).first
    }

    private static func sources(_ filter: CFDictionary, includeAllInstalled: Bool) -> [TISInputSource] {
        // Create rule: the list is retained.
        (TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    /// Get rule: the property is not retained.
    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
    }

    static func info(_ source: TISInputSource) -> InputSourceInfo {
        let id: String = property(source, kTISPropertyInputSourceID) ?? ""
        let type: String = property(source, kTISPropertyInputSourceType) ?? ""
        let isLayout = type == (kTISTypeKeyboardLayout as String)
        let hasData = isLayout && TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) != nil
        let isInputMethod = type == (kTISTypeKeyboardInputMethodModeEnabled as String)
            || type == (kTISTypeKeyboardInputMode as String)
            || type == (kTISTypeKeyboardInputMethodWithoutModes as String)
        let languages: [String] = property(source, kTISPropertyInputSourceLanguages) ?? []
        let enabled: NSNumber? = property(source, kTISPropertyInputSourceIsEnabled)
        return InputSourceInfo(id: InputSourceID(id), name: property(source, kTISPropertyLocalizedName) ?? id,
                               languageCode: languages.first ?? "", isEnabled: enabled?.boolValue ?? false,
                               isConvertible: hasData, isInputMethod: isInputMethod)
    }

    // MARK: - UCKeyTranslate

    /// `modifierKeyState` per layer: Carbon EventModifiers >> 8 (R6 §2).
    private static func modifierState(_ layer: KeyLayer) -> UInt32 {
        switch layer {
        case .plain: 0
        case .shift: UInt32(shiftKey >> 8)
        case .capsLock: UInt32(alphaLock >> 8)
        case .option: UInt32(optionKey >> 8)
        case .shiftOption: UInt32((shiftKey | optionKey) >> 8)
        }
    }

    static func buildMap(_ source: TISInputSource, id: InputSourceID, kbdType: Int) -> LayoutMap? {
        let info = info(source)
        guard info.isConvertible, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        // Native-endian 'uchr'. The pointer is only valid while `data` is alive, so build inside the closure.
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> LayoutMap? in
            guard let base = bytes.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return LayoutMapBuilder.build(id: id, name: info.name, language: info.languageCode, kbdType: kbdType) {
                code, layer in
                translate(layout, code, modifierState(layer), UInt32(kbdType))
            }
        }
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ code: UInt16, _ modifiers: UInt32,
                                  _ kbdType: UInt32) -> LayoutMapBuilder.Translation? {
        // Fresh dead-key state per cell, so a dead key in one cell can't leak into the next (R6 §2).
        var deadState: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 32)   // room for 4 graphemes with marks; longer output is dropped anyway
        guard UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, kbdType, 0,
                             &deadState, buffer.count, &length, &buffer) == noErr else { return nil }
        if length > 0 { return .text(String(utf16CodeUnits: buffer, count: length)) }
        guard deadState != 0 else { return nil }   // the key types nothing on this layer
        // Dead key: ask again without dead-key processing for its standalone form.
        var ignored: UInt32 = 0
        guard UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, kbdType,
                             OptionBits(kUCKeyTranslateNoDeadKeysMask), &ignored, buffer.count, &length,
                             &buffer) == noErr, length > 0 else { return nil }
        return .dead(String(utf16CodeUnits: buffer, count: length))
    }
}
