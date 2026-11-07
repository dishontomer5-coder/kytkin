// P3-6: What a browser read says about the front tab (001 §14.2). In memory only, never persisted.
// MERGE NOTE: 001 §14.12 gives this enum to P3-5 (Core/Model, with `Context.pageState`), which runs in parallel.
// P3-6 needs it for `BrowserObservation`; keep exactly one copy when both land.

enum BrowserPageState: Sendable, Equatable {
    case page            // a web page; `site` is known
    case notWebPage      // about:, chrome://, new tab, file:, extension page → no site, app rules apply
    case editingAddress  // a text field outside the page has focus (address bar, find bar): last site kept, no learning
    case unknown         // couldn't tell (timeout, compact mode, cold Gecko): this window's last site kept, no learning
}
