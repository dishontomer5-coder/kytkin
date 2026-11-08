// P2-9: The RuleEngine's answer for a Context (001 §2.2).
// `target == nil` means "leave the language alone". `matched` is the winning rule; it is nil for
// `.defaultRule`, `.addressBar` (P3-29) and `.none`. `level` says which precedence tier decided.

import Foundation

struct Resolution: Sendable, Equatable {
    enum Level: Sendable, Equatable, CaseIterable {
        case chat, siteHost, site, app
        /// P3-29: a browser's address bar has focus and the browser has no app rule: the pair's Latin member.
        case addressBar
        /// No rule matched and DefaultBehavior is `switchTo`.
        case defaultRule
        /// No rule matched and DefaultBehavior is `keepCurrent`.
        case none
    }

    let target: InputSourceID?
    let matched: Rule?
    let level: Level
}
