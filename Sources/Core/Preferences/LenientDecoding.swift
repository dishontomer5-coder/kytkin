// P2-8: Lenient field decoding for preferences.json (001 §4.1: "Every field has a default, so an
// empty `{}` still decodes"; unknown keys are ignored). A missing, mistyped or unknown-valued field
// falls back to its default instead of failing the whole file, which would quarantine it.
//
// Gap 4 (coordinator decision): whenever leniency throws a stored value away (a mistyped field, a
// dropped entry, a clamped number), it is recorded in `PreferencesDecodingLoss`, so the store can keep
// a copy of the original file before its first save overwrites it.

import Foundation

extension KeyedDecodingContainer {
    /// The value at `key`, or nil if it is missing, `null`, or doesn't decode as `T`.
    /// A present value that doesn't decode is recorded as a loss.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        do {
            return try decodeIfPresent(T.self, forKey: key)
        } catch {
            PreferencesDecodingLoss.record()
            return nil
        }
    }
}

/// Counts what lenient decoding dropped or defaulted. `PreferencesCodec` installs a recorder for the
/// duration of one decode (a task-local, so it reaches every nested `init(from:)` without changing
/// their signatures); outside such a decode, recording does nothing.
enum PreferencesDecodingLoss {
    final class Recorder: @unchecked Sendable { // @unchecked: `count` guarded by `lock`
        private let lock = NSLock()
        private var _count = 0

        var count: Int { lock.withLock { _count } }
        func record() { lock.withLock { _count += 1 } }
    }

    @TaskLocal static var current: Recorder?

    static func record() { current?.record() }
}
