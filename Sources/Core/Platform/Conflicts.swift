// P2-19: What ConflictDetector publishes for the menu warning (P2-22) and the learning pause (P2-20).
// 001 §2.2 ConflictDetector, §12 R2, owner decision P2-38 (plan.md).

import Foundation

struct Conflicts: Sendable, Equatable {
    /// Display names of other input switchers running now, in `KnownSwitchers.entries` order.
    var runningSwitchers: [String] = []
    /// macOS "Automatically switch to a document's input source" is on.
    var perDocumentInputEnabled = false

    static let none = Conflicts()

    /// Nothing to warn about.
    var isEmpty: Bool { runningSwitchers.isEmpty && !perDocumentInputEnabled }

    /// P2-38 / 001 §12 R2: while per-document input is on, macOS restores each window's source on focus
    /// changes, which looks exactly like a user switch, so the learner must not learn. Other running
    /// switchers do NOT pause learning: the learner's 500 ms settle already discards their switches on
    /// app change (R1 §3), and the warning tells the user to quit them.
    var pausesLearning: Bool { perDocumentInputEnabled }
}
