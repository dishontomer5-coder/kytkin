// P3-44: the DEBUG-only convert log. One line per double-Shift: the app's bundle ID, the paths tried (ax / chromiumAX /
// clipboard / keys / switchOnly) with each stop reason, and a few counts (`ConvertTrace.line`). Never any text: the
// trace is built only from Kytkin's own enums and counts (see `ConvertTrace`). Release builds pass no hook at all.
//
// Read it (owner, Terminal), right after the double-Shift:
//   log show --last 5m --predicate 'subsystem == "io.github.kytkin.Kytkin.dev"' --info --debug

import Foundation
import os

enum ConvertDiagnosticsLog {
    /// nil in Release: no logging there.
    static var hook: (@Sendable (ConvertTrace) -> Void)? {
        #if DEBUG
        let logger = Logger(subsystem: "io.github.kytkin.Kytkin.dev", category: "convert")
        return { trace in
            // Only the bundle ID and enum names / counts are public; there is no text in the trace to mark private.
            // P3-54: `.notice`, which macOS keeps on disk (`.info` lives in memory only and was gone by the time the
            // owner ran `log show`).
            logger.notice("double-Shift bundle=\(trace.bundleID, privacy: .public) \(trace.line, privacy: .public)")
        }
        #else
        return nil
        #endif
    }
}
