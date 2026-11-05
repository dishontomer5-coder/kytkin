// P2-9: The RuleEngine's answer for a Context (001 §2.2).
// `target == nil` means "leave the language alone". `matched` is the winning rule; it is nil for
// `.defaultRule` and `.none`. `level` says which precedence tier decided.

import Foundation

struct Resolution: Sendable, Equatable {
    enum Level: Sendable, Equatable, CaseIterable {
        case chat, siteHost, site, app
        /// No rule matched and DefaultBehavior is `switchTo`.
        case defaultRule
        /// No rule matched and DefaultBehavior is `keepCurrent`.
        case none
    }

    let target: InputSourceID?
    let matched: Rule?
    let level: Level
}
