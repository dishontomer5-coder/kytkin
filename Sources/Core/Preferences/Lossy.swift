// P2-8: Decodes one element of a JSON array or object without failing its siblings.
// `[Lossy<Rule>]` keeps every good rule and drops only the bad entry (P2-9 note in todo.md).

import Foundation

struct Lossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
