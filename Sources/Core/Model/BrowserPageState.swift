// P3-5: What the frontmost browser window is showing (001 §14.2). In memory only (a `Context` field), never persisted.
// The browser provider (P3-10/11/13) reports it with each observation; ContextAssembler sets `.unknown` when a
// browser activation's site grace runs out before the first read (§14.5).

enum BrowserPageState: Sendable, Equatable {
    /// A web page; `Context.siteDomain` is known.
    case page
    /// about:, chrome://, a new tab, file:, an extension page: no site, app rules apply.
    case notWebPage
    /// A text field outside the page has focus (address bar, find bar): the last site is kept, nothing is learned (D2).
    case editingAddress
    /// Couldn't tell (timeout, compact mode, a cold Gecko tree): this window's last site is kept, nothing is learned (D3).
    case unknown
}
