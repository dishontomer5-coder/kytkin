// P2-8: preferences.json `convert` (001 §4.2, Settings → Convert & Fix §5.2).
// P2-31: `doubleShiftWindowMs` is clamped to 200–500 ms on decode and on every assignment, so a
// hand-edited 5 or 90000 can't make double-Shift impossible or fire on any two Shift taps.

import Foundation

extension Preferences {
    struct Convert: Sendable, Equatable {
        static let windowRangeMs = 200...500
        static let defaultWindowMs = 300

        var doubleShiftEnabled = true
        var doubleShiftSides: DoubleShiftConfig.SidePolicy = .sameSide
        var doubleShiftWindowMs: Int = Convert.defaultWindowMs {
            didSet {
                let clamped = Self.clampedWindow(doubleShiftWindowMs)
                if clamped != doubleShiftWindowMs { doubleShiftWindowMs = clamped }
            }
        }
        /// Owner decision 001 §11 Q1: convert also switches the language, with its own toggle.
        var switchLanguageAfterConvert = true
        /// P3-37 (owner 2026-11-11): in apps whose text box Kytkin can't read (not terminals), double-Shift may copy the
        /// box through the clipboard, paste the converted text and put the clipboard back. On by default.
        var useClipboardInUnreadableApps = true

        init() {}

        static func clampedWindow(_ ms: Int) -> Int {
            min(max(ms, windowRangeMs.lowerBound), windowRangeMs.upperBound)
        }

        /// The detector tunables these settings describe. Max hold stays at the R4 default.
        var doubleShiftConfig: DoubleShiftConfig {
            DoubleShiftConfig(windowNanos: UInt64(Self.clampedWindow(doubleShiftWindowMs)) * 1_000_000,
                              sides: doubleShiftSides)
        }
    }
}

extension Preferences.Convert: Codable {
    private enum CodingKeys: String, CodingKey {
        case doubleShiftEnabled, doubleShiftSides, doubleShiftWindowMs, switchLanguageAfterConvert
        case useClipboardInUnreadableApps   // P3-37
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(Bool.self, .doubleShiftEnabled) { doubleShiftEnabled = v }
        if let v = c.lenient(DoubleShiftConfig.SidePolicy.self, .doubleShiftSides) { doubleShiftSides = v }
        // P2-31: a fractional or huge number still clamps; a non-number keeps the default. A changed
        // value counts as a decoding loss, so the store keeps the original file.
        if let v = c.lenient(Double.self, .doubleShiftWindowMs), v.isFinite {
            let bounded = min(max(v.rounded(), Double(Self.windowRangeMs.lowerBound)),
                              Double(Self.windowRangeMs.upperBound))
            doubleShiftWindowMs = Int(bounded)
            if bounded != v { PreferencesDecodingLoss.record() }
        }
        if let v = c.lenient(Bool.self, .switchLanguageAfterConvert) { switchLanguageAfterConvert = v }
        if let v = c.lenient(Bool.self, .useClipboardInUnreadableApps) { useClipboardInUnreadableApps = v }
    }
}
