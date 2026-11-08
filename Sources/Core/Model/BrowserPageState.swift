// P3-5: What the frontmost browser window is showing (001 §14.2). In memory only (a `Context` field), never persisted.
// The browser provider (P3-10/11/13) reports it with each observation; ContextAssembler sets `.unknown` when a
// browser activation's site grace runs out before the first read (§14.5).

enum BrowserPageState: Sendable, Equatable {
    /// A web page; `Context.siteDomain` is known.
    case page
    /// about:, chrome://, a new tab, file:, an extension page: no site, app rules apply.
    case notWebPage
    /// A text field outside the page has focus (address bar, find bar): the last site is kept, nothing is learned (D2).
    /// P3-31: the real address bar, or a field the engine can't tell apart from it (`AddressBarVerdict.unknown`):
    /// the browser's language applies here (P3-29).
    case editingAddress
    /// P3-31 (owner decision 2026-11-08): a text field outside the page that is known NOT to be the address bar (the
    /// Find box, ⌘F; a toolbar search box). It resolves like the page (the site's rule) and, like the bar, keeps the
    /// last site and learns nothing (D2, P3-9/P3-20).
    case editingBrowserField
    /// Couldn't tell (timeout, compact mode, a cold Gecko tree): this window's last site is kept, nothing is learned (D3).
    case unknown
}
