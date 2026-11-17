// P2-5: Why a `kytkin-layoutmap` file was rejected. Each case names the field or key so Settings
// can show it (001 §4.3: "Errors are shown in Settings with the line or key").

import Foundation

enum LayoutMapError: Error, Equatable, Sendable {
    case fileTooLarge(bytes: Int)
    /// Not parseable JSON. The associated text is Foundation's parser message (it includes the line).
    case malformedJSON(String)
    /// `format` isn't "kytkin-layoutmap". `nil` = missing or not a string.
    case wrongFormat(String?)
    /// `version` isn't 1. `nil` = missing or not an integer.
    case unsupportedVersion(Int?)
    case missingField(String)
    /// A field has the wrong JSON type. The associated value is the dotted path, e.g. "keys.0.plain".
    case wrongType(field: String)
    case invalidSource(String)
    case emptyID
    /// Imported IDs must not claim Apple's namespace.
    case reservedID(String)
    /// `source: "user"` needs a `base` to override.
    case missingBase
    /// A key in `keys` or `deadKeys` isn't a decimal key code 0–127.
    case invalidKeyCode(String)
    case unknownLayer(keyCode: UInt16, layer: String)
    case emptyString(keyCode: UInt16, layer: KeyLayer)
    case tooManyCharacters(keyCode: UInt16, layer: KeyLayer)
    /// A cell contains a control character (newline, tab, NUL…), which a key must not type.
    case controlCharacter(keyCode: UInt16, layer: KeyLayer)
    /// P2-30: `source: "system"` on import. System maps are generated, export only (001 §4.3).
    case systemSourceImport
    /// P2-30: the id (with its `user.` prefix) uses something other than `[A-Za-z0-9._-]`.
    case invalidIDCharacters(String)
    /// P2-30: the id (with its `user.` prefix) is longer than 64 characters.
    case idTooLong(length: Int)
    /// P2-30: the id is just `user.`, with no name after it.
    case idOnlyPrefix
    /// P2-30: a cell has more than 16 Unicode scalars (e.g. one letter with a long run of combining marks).
    case tooManyScalars(keyCode: UInt16, layer: KeyLayer)
    /// P2-30: a cell contains a private-use character (Co) or a line/paragraph separator (Zl/Zp).
    case untypeableCharacter(keyCode: UInt16, layer: KeyLayer)

    /// Short English text for the Languages tab.
    var message: String {
        switch self {
        case .fileTooLarge(let bytes): "The file is too large (\(bytes) bytes, the limit is 256 KB)."
        case .malformedJSON(let detail): "The file isn’t valid JSON: \(detail)"
        case .wrongFormat(let found): "This isn’t a Kytkin layout map (format: \(found ?? "missing or not text"))."
        case .unsupportedVersion(let found):
            "Unsupported layout map version \(found.map(String.init) ?? "(missing or not a whole number)"). This Kytkin reads version 1."
        case .missingField(let field): "The field \"\(field)\" is missing."
        case .wrongType(let field): "The field \"\(field)\" has the wrong type."
        case .invalidSource(let found): "Unknown source \"\(found)\" (use system, imported or user)."
        case .emptyID: "The id is empty."
        case .reservedID(let id): "The id \"\(id)\" is reserved for Apple layouts. Use another id."
        case .missingBase: "A user map needs a \"base\" layout to override."
        case .invalidKeyCode(let key): "Key \"\(key)\" isn’t a key code from 0 to 127."
        case .unknownLayer(let code, let layer): "Key \(code): unknown layer \"\(layer)\"."
        case .emptyString(let code, let layer): "Key \(code), \(layer.rawValue): the text is empty."
        case .tooManyCharacters(let code, let layer): "Key \(code), \(layer.rawValue): more than 4 characters."
        case .controlCharacter(let code, let layer):
            "Key \(code), \(layer.rawValue): the text contains a control character (like a newline or tab)."
        // P2-30: the id messages don't repeat the id: it may be long or contain characters that don't display.
        case .systemSourceImport:
            "This is an exported system layout, which can’t be imported. Change \"source\" to \"imported\" to use it as a full map."
        case .invalidIDCharacters:
            "The id may only use the letters A–Z and a–z, the digits 0–9, and the characters . _ -"
        case .idTooLong(let length):
            "The id is too long (\(length) characters including \"user.\", the limit is \(LayoutMap.maxIDLength))."
        case .idOnlyPrefix: "The id needs a name after \"user.\"."
        case .tooManyScalars(let code, let layer):
            "Key \(code), \(layer.rawValue): the text has too many accents or combining marks (the limit is \(LayoutMap.maxScalarsPerCell) code points)."
        case .untypeableCharacter(let code, let layer):
            "Key \(code), \(layer.rawValue): the text contains a character a key can’t type (a private-use character or a line separator)."
        }
    }
}
