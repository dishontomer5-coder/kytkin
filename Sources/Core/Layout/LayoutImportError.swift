// P2-24: Why importing, removing or exporting a layout map didn't work, in words for the Languages tab. A rejected
// file says which rule it broke (`LayoutMapError.message`, P2-5 / P2-30).

import Foundation

enum LayoutImportError: Error, Equatable, Sendable {
    /// The picked file couldn't be opened or read.
    case unreadable
    /// The file was read but isn't a layout map Kytkin accepts.
    case invalid(LayoutMapError)
    /// Writing to (or deleting from) the layouts folder failed.
    case saveFailed
    /// Writing the exported file failed.
    case exportFailed

    var message: String {
        switch self {
        case .unreadable: "Kytkin couldn't read this file."
        case .invalid(let error): error.message
        case .saveFailed: "Kytkin couldn't save to its layouts folder. Try again."
        case .exportFailed: "Kytkin couldn't write the file there. Try another folder."
        }
    }
}
