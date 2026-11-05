// P2-5: Turns Foundation's DecodingError into a LayoutMapError that names the field.

import Foundation

extension LayoutMapError {
    init(_ error: DecodingError) {
        func path(_ codingPath: [any CodingKey], _ last: (any CodingKey)? = nil) -> String {
            let parts = (codingPath + (last.map { [$0] } ?? [])).map(\.stringValue)
            return parts.isEmpty ? "(root)" : parts.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            self = .missingField(path(context.codingPath, key))
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            self = .wrongType(field: path(context.codingPath))
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty {
                let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
                self = .malformedJSON(underlying ?? context.debugDescription)
            } else {
                self = .wrongType(field: path(context.codingPath))
            }
        @unknown default:
            self = .malformedJSON(String(describing: error))
        }
    }
}
