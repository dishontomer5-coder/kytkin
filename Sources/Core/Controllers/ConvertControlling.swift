// P2-20: Where AppController hands a convert request (flow (c), 001 §3). P2-21 replaces the placeholder below with
// the real ConvertController (main → `@TextActor` hop, §12 W9).
//
// Contract (binding for P2-21): every request's `gen` MUST end with exactly one
// `KeyWatching.finishReplacement(gen:…)`, for every outcome (replaced, abandoned, refused, notConvertible, timedOut,
// halted, exhausted), so the user's held keys replay at once instead of waiting for the deadline or the 1 s cap.
// AppController finishes a generation itself whenever it doesn't hand it over (paused, disabled app, no feature).

import Foundation

struct ConvertRequest: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        /// Active tap + Accessibility: convert the text.
        case convert
        /// Listen-only tap, no Accessibility, or Secure Input: only toggle the pair's input source (001 §6.2).
        case toggleOnly
    }

    let snapshot: WordSnapshot
    let gen: UInt64
    let bundleID: String
    let mode: Mode
}

@MainActor protocol ConvertControlling: AnyObject {
    /// Must end with `finishReplacement(gen: request.gen, …)` (see the contract above).
    func convert(_ request: ConvertRequest)
    /// Settings → Apps changed: the user's per-app overrides (001 §12 T5), for `ReplacementCapabilities`.
    func methodHintsChanged(_ overrides: [String: MethodHint])
}

/// P2-20 placeholder until P2-21: converts nothing and finishes the generation at once, so held keys replay right
/// away. Safe by construction: it never writes, posts or switches anything.
@MainActor final class FinishOnlyConvertController: ConvertControlling {
    private let finish: @MainActor (UInt64) -> Void
    private(set) var overrides: [String: MethodHint] = [:]

    init(finish: @escaping @MainActor (UInt64) -> Void) {
        self.finish = finish
    }

    func convert(_ request: ConvertRequest) {
        finish(request.gen)
    }

    func methodHintsChanged(_ overrides: [String: MethodHint]) {
        self.overrides = overrides
    }
}
