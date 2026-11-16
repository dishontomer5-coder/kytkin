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
    /// P3-37: Settings → Convert "Use the clipboard in apps Kytkin can't read" (on by default in the preferences; off
    /// here by default so a request built without it never touches the clipboard).
    let useClipboard: Bool
    /// P3-37: the browser's address bar has focus (`BrowserPageState.editingAddress`). The clipboard never copies it
    /// (design.md: a focused address bar is never read).
    let inAddressBar: Bool
    /// P3-41: the frontmost app's process (the context's pid), nil = unknown. A terminal whose AX can't name its focused
    /// element still converts by keys while the focus (if AX names one at all) belongs to this process.
    let processID: Int32?
    /// P3-42: the Chromium/Electron AX convert may run for this request: false on a whole-document web app (Google Docs,
    /// Sheets…; the sites the clipboard is blocked on), in a focused address bar or browser field. Off by default so a
    /// request built without it never uses the path.
    let allowsChromiumAX: Bool
    /// P3-47 QA: the front app is a known browser whose page host Kytkin hasn't read (yet): a whole-document site
    /// (Google Docs…) can't be ruled out, so the clipboard never copies the whole box. P3-49 (Coordinator 2026-11-16): a
    /// selection may still be pasted, line breaks included (checked against AX's selection, P3-40).
    let browserSiteUnknown: Bool
    /// P3-49: the browser page state for this request (nil = not a watched browser), for the DEBUG trace only.
    var pageState: BrowserPageState?
    /// P3-50: whether Kytkin watches this browser, or why not (an enum-like name), for the DEBUG trace only.
    var siteWatch: String?
    /// P3-53 QA: the page's host is a webmail host (`PageCategory.isWebmail`; the host itself is not kept).
    var webmailPage = false

    init(snapshot: WordSnapshot, gen: UInt64, bundleID: String, mode: Mode, pair: LanguagePair = .default,
         currentSource: InputSourceID = LanguagePair.default.a, switchAfterConvert: Bool = true,
         useClipboard: Bool = false, inAddressBar: Bool = false, processID: Int32? = nil,
         allowsChromiumAX: Bool = false, browserSiteUnknown: Bool = false) {
        self.snapshot = snapshot
        self.gen = gen
        self.bundleID = bundleID
        self.mode = mode
        self.pair = pair
        self.currentSource = currentSource
        self.switchAfterConvert = switchAfterConvert
        self.useClipboard = useClipboard
        self.inAddressBar = inAddressBar
        self.processID = processID
        self.allowsChromiumAX = allowsChromiumAX
        self.browserSiteUnknown = browserSiteUnknown
    }

    /// The same request with other values for the fields that change on the way (the dispatcher's resolved pair; the
    /// controller's emptied snapshot, P3-37).
    func with(snapshot: WordSnapshot? = nil, pair: LanguagePair? = nil) -> ConvertRequest {
        var copy = ConvertRequest(snapshot: snapshot ?? self.snapshot, gen: gen, bundleID: bundleID, mode: mode,
                                  pair: pair ?? self.pair, currentSource: currentSource,
                                  switchAfterConvert: switchAfterConvert, useClipboard: useClipboard,
                                  inAddressBar: inAddressBar, processID: processID, allowsChromiumAX: allowsChromiumAX,
                                  browserSiteUnknown: browserSiteUnknown)
        copy.pageState = pageState
        copy.siteWatch = siteWatch
        copy.webmailPage = webmailPage
        return copy
    }
}

@MainActor protocol ConvertControlling: AnyObject {
    /// Must end with `finishReplacement(gen: request.gen, …)` (see the contract above).
    func convert(_ request: ConvertRequest)
    /// Settings → Apps changed: the user's per-app overrides (001 §12 T5), for `ReplacementCapabilities`.
    func methodHintsChanged(_ overrides: [String: MethodHint])
    /// P3-37 (b): a terminal's word buffer started (its first key after an empty buffer): note which element has focus,
    /// so a buffer kept across clicks and app switches is used only in that same window / tab / split.
    func anchorTerminalBuffer(epoch: UInt64)
}

extension ConvertControlling {
    /// P3-37: a controller that never converts has no terminal buffer to anchor.
    func anchorTerminalBuffer(epoch: UInt64) {}
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
