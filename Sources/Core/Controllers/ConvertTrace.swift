// P3-44 (owner test 2026-11-16: Slack's box was flattened and nobody could tell which path ran): one privacy-safe record
// per double-Shift, for the DEBUG log only (`AppEnvironment` wires `ConvertController`'s `diagnose` hook to an
// `os.Logger`, subsystem `io.github.kytkin.Kytkin.dev`, category `convert`, in Debug builds; Release passes nil).
//
// What it holds: the app's bundle ID, the paths tried in order (`ax`, `chromiumAX`, `clipboard`, `keys`, `switchOnly`)
// each with a stop reason that is an enum case name, and a few counts (pieces, units the caret read past the value…).
// **Never text**: no typed text, box text, clipboard content, selection or lengths of them other than these counts.
// Every `reason` is built from Kytkin's own enums (`String(describing:)` of a result / outcome enum, whose payloads
// are enums, step kinds, counts and input-source IDs), never from anything read from an app.

import Foundation

struct ConvertTrace: Sendable, Equatable {
    enum Path: String, Sendable, Equatable {
        /// The AX chain (read / write the box or the selection through Accessibility, Cocoa-style).
        case ax
        /// P3-42: select + type over changed pieces in a Chromium/Electron web box.
        case chromiumAX
        /// P3-37: ⌘A ⌘C, convert, ⌘V, restore.
        case clipboard
        /// The remembered buffer by Backspace + typing.
        case keys
        /// Nothing written: only the input language switched (or not even that: a beep).
        case switchOnly
    }

    struct Step: Sendable, Equatable {
        let path: Path
        /// An enum case name (with enum / count payloads only).
        let reason: String
    }

    var bundleID: String
    var steps: [Step] = []
    /// P3-42 / P3-44: why the Chromium AX path was not tried, when the app is one it could run in (enum names only).
    var chromiumSkipped: String?
    /// P3-44: what `ChromiumAXConvert` saw (enums and counts only).
    var chromium: ChromiumAXConvert.Diagnostic?
    /// P3-44: the clipboard copy was rich (nothing pasted).
    var richCopy: Bool?
    /// P3-46: the clipboard copy's type categories (counts) and the rich / plain verdict's reason (an enum name).
    var copy: ClipboardConvert.CopyDiagnostic?
    /// P3-49: a browser request: whether the page's host was known (nil = not a browser).
    var siteKnown: Bool?
    /// P3-49: a browser request: the page state Kytkin had (an enum name: page, editingAddress, unknown…).
    var pageState: String?
    /// The final outcome, as an enum case name.
    var outcome: String = ""

    /// The one log line (no text from any app: see the header).
    var line: String {
        var parts = ["paths=" + (steps.isEmpty ? "none" : steps.map { "\($0.path.rawValue):\($0.reason)" }
            .joined(separator: " > "))]
        if let siteKnown { parts.append("siteKnown=\(siteKnown)") }
        if let pageState { parts.append("pageState=\(pageState)") }
        if let chromiumSkipped { parts.append("chromiumSkipped=\(chromiumSkipped)") }
        if let c = chromium {
            parts.append("chromium{readCheck=\(c.readCheck?.rawValue ?? "-") caretPastValue=\(c.caretPastValue) "
                         + "pieces=\(c.pieces) atoms=\(c.atoms) maxShift=\(c.maxShift) "
                         + "otherTextTries=\(c.otherTextTries) readSpace=\(c.readSpace.rawValue) "
                         + "caretMapped=\(c.caretMapped) prefixMismatch=\(c.prefixMismatch.map { "\($0)" } ?? "-") "
                         + "atomRoles=\(c.atomRoles.isEmpty ? "-" : c.atomRoles.joined(separator: ","))}")
        }
        if let richCopy { parts.append("richCopy=\(richCopy)") }
        if let copy {
            parts.append("copiedTypes{\(copy.types.map { "\($0)" } ?? "unreadable")} "
                         + "copyVerdict=\(copy.reason?.rawValue ?? "-")"
                         + (copy.htmlPaste.map { " htmlPaste=\($0)" } ?? ""))
        }
        parts.append("outcome=\(outcome)")
        return parts.joined(separator: " ")
    }
}
