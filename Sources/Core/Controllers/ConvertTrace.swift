// P3-44 (owner test 2026-11-16: Slack's box was flattened and nobody could tell which path ran): one privacy-safe record
// per double-Shift, for the DEBUG log only (`AppEnvironment` wires `ConvertController`'s `diagnose` hook to an
// `os.Logger`, subsystem `io.github.kytkin.Kytkin.dev`, category `convert`, in Debug builds; Release passes nil).
//
// What it holds (P3-60 wording, DEBUG builds only): enum names (the paths tried in order: `ax`, `chromiumAX`,
// `clipboard`, `keys`, `switchOnly`, each with its result enum; check, verdict and skip reasons), counts (pieces,
// atoms, shifts, tag / attribute counts, copied type categories…), bundle IDs, input-source IDs, box lengths (UTF-16
// counts), AX role names, and the code points of characters that are not letters, digits or spaces near a prefix
// mismatch or among `AXValue`'s odd units (P3-57; a letter is only ever `L`, a digit `N`, a space `Z`). **Never
// letters or words**: no typed text, box text, clipboard content, selection, URL, host or title. Every `reason` is
// built from Kytkin's own enums (`String(describing:)` of a result / outcome enum, whose payloads are enums, step
// kinds, counts and input-source IDs), never from text read from an app.

import Foundation

struct ConvertTrace: Sendable, Equatable {
    enum Path: String, Sendable, Equatable {
        /// The AX chain (read / write the box or the selection through Accessibility, Cocoa-style).
        case ax
        /// P3-42: select + type over changed pieces in a Chromium/Electron web box.
        case chromiumAX
        /// P3-37 / P3-62: ⇧⌘↑ ⌘C (or ⌘C on a selection), convert, ⌘V, restore.
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
    /// P3-58: a chat app's clipboard convert (`box` / `selection`), nil = not one.
    var chatClipboard: String?
    /// P3-49: a browser request: whether the page's host was known (nil = not a browser).
    var siteKnown: Bool?
    /// P3-49: a browser request: the page state Kytkin had (an enum name: page, editingAddress, unknown…).
    var pageState: String?
    /// P3-50: a browser request: watched, or why not (`websiteRulesOff`, `siteRulesUnavailable`…).
    var siteWatch: String?
    /// P3-50: the convert's own check of the focused page (`ConvertController`): ordinary / wholeDocument / unknown,
    /// nil = not asked.
    var pageCheck: String?
    /// P6-0j: the focused element belongs to another app than the frontmost one (Spotlight and other system panels);
    /// `bundleID` is the focus owner's.
    var focusOwnerDiffers = false
    /// P4-5: a chat app: what the double-Shift's own `AXManualAccessibility` check did (`alreadySet`, `wrote:set`,
    /// `wrote:noAnswer`…), nil = not a chat app / no enabler.
    var chatAX: String?
    /// P4-5: a chat app named no text box: the flag was written again and the focus looked up again
    /// (`found` / `notFound` with the poll count and the ms since the request arrived), or why not (`notTried(…)`).
    var chatAXRetry: String?
    /// P4-5c: the chat pid's launch-schedule counts before this double-Shift (`tries=N writes=M last=<answer>
    /// built=yes|no|unknown`, or `none`: nothing was ever tried for it). Numbers and enum names only.
    var chatAXPrep: String?
    /// P4-5b: the walks of a chat app's focused window for its focused text box (`found` / `notFound` / `budget` /
    /// `unavailable` with node count, ms and depth; ` > ` between a first and a second walk). Counts only.
    var chatFocusWalk: String?
    /// The final outcome, as an enum case name.
    var outcome: String = ""

    /// The one log line (no text from any app: see the header).
    var line: String {
        var parts = ["paths=" + (steps.isEmpty ? "none" : steps.map { "\($0.path.rawValue):\($0.reason)" }
            .joined(separator: " > "))]
        if focusOwnerDiffers { parts.append("focusOwner≠frontmost") }
        if let chatAX { parts.append("chatAX=\(chatAX)") }                       // P4-5
        if let chatAXPrep { parts.append("chatAXPrep{\(chatAXPrep)}") }          // P4-5c
        if let chatAXRetry { parts.append("chatAXRetry=\(chatAXRetry)") }        // P4-5
        if let chatFocusWalk { parts.append("chatFocusWalk=\(chatFocusWalk)") }  // P4-5b
        if let chatClipboard { parts.append("chatClipboard=\(chatClipboard)") }
        if let siteKnown { parts.append("siteKnown=\(siteKnown)") }
        if let pageState { parts.append("pageState=\(pageState)") }
        if let siteWatch { parts.append("siteWatch=\(siteWatch)") }
        if let pageCheck { parts.append("pageCheck=\(pageCheck)") }
        if let chromiumSkipped { parts.append("chromiumSkipped=\(chromiumSkipped)") }
        if let c = chromium {
            parts.append("chromium{readCheck=\(c.readCheck?.rawValue ?? "-") caretPastValue=\(c.caretPastValue) "
                         + "pieces=\(c.pieces) atoms=\(c.atoms) maxShift=\(c.maxShift) "
                         + "otherTextTries=\(c.otherTextTries) readSpace=\(c.readSpace.rawValue) "
                         + "caretMapped=\(c.caretMapped) prefixMismatch=\(c.prefixMismatch.map { "\($0)" } ?? "-") "
                         + "atomRoles=\(Self.roleCounts(c.atomRoles)) "
                         + "prefixObjects=\(c.prefixObjects ?? "-") "
                         + "valueUnits=\(c.valueUnits) prefixUnexplained=\(c.prefixUnexplained) "
                         + "spanShape=\(c.spanShape ?? "-") oddUnits=\(c.oddUnits ?? "-") "
                         + "oddRunsStripped=\(c.oddRunsStripped)}")
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

    /// P3-48 QA: the atoms' roles as counts per role, in first-seen order (`AXStaticText:1,AXLink:2`), `-` = none.
    static func roleCounts(_ roles: [String]) -> String {
        guard !roles.isEmpty else { return "-" }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for r in roles {
            if counts[r] == nil { order.append(r) }
            counts[r, default: 0] += 1
        }
        return order.map { "\($0):\(counts[$0]!)" }.joined(separator: ",")
    }
}
