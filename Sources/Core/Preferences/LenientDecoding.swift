// P2-8: Lenient field decoding for preferences.json (001 §4.1: "Every field has a default, so an
// empty `{}` still decodes"; unknown keys are ignored). A missing, mistyped or unknown-valued field
// falls back to its default instead of failing the whole file, which would quarantine it.

import Foundation

extension KeyedDecodingContainer {
    /// The value at `key`, or nil if it is missing, `null`, or doesn't decode as `T`.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
