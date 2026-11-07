// P2-20: Where AppController hands a convert request (flow (c), 001 §3). P2-21: the live implementation is
// `ConvertDispatcher` (main) → `ConvertController` (`@TextActor`, the §12 W9 hop).
//
// Contract: every request's `gen` MUST end with exactly one `KeyWatching.finishReplacement(gen:…)`, for every
// outcome (replaced, abandoned, refused, notConvertible, timedOut, halted, exhausted, toggle-only, stale, cancelled),
// so the user's held keys replay at once instead of waiting for the deadline or the 1 s cap.
// AppController finishes a generation itself whenever it doesn't hand it over (paused, disabled app, no feature).

import Foundation

struct ConvertRequest: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        /// Active tap + Accessibility: convert the text (or toggle when there is nothing to convert).
        case convert
        /// Listen-only tap, no Accessibility, Secure Input, or convert turned off for the app (P2-21): only toggle
        /// the pair's input source (001 §3 (c) step 10, §6.2).
        case toggleOnly
    }

    let snapshot: WordSnapshot
    let gen: UInt64
    let bundleID: String
    let mode: Mode
    /// P2-21: the active pair, the selected input source when the signal arrived, and the
    /// "Switch language after converting" setting (owner decision 001 §11 Q1), read on main.
    let pair: LanguagePair
    let currentSource: InputSourceID
    let switchAfterConvert: Bool

    init(snapshot: WordSnapshot, gen: UInt64, bundleID: String, mode: Mode, pair: LanguagePair = .default,
         currentSource: InputSourceID = LanguagePair.default.a, switchAfterConvert: Bool = true) {
        self.snapshot = snapshot
        self.gen = gen
        self.bundleID = bundleID
        self.mode = mode
        self.pair = pair
        self.currentSource = currentSource
        self.switchAfterConvert = switchAfterConvert
    }
}

@MainActor protocol ConvertControlling: AnyObject {
    /// Must end with `finishReplacement(gen: request.gen, …)` (see the contract above).
    func convert(_ request: ConvertRequest)
    /// Settings → Apps changed: the user's per-app overrides (001 §12 T5), for `ReplacementCapabilities`.
    func methodHintsChanged(_ overrides: [String: MethodHint])
}

/// P2-20: converts nothing and finishes the generation at once, so held keys replay right away. AppController's
/// default when no convert controller is passed (controller tests). Safe by construction: it never writes, posts
/// or switches anything. The app uses `ConvertDispatcher` (P2-21).
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
