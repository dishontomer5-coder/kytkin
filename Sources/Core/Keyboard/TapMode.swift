// P2-12: How the event tap runs (001 §2.2). `active` can swallow and hold events (needs Accessibility);
// `listenOnly` (Input Monitoring) only watches, so every verdict is `.pass`.

import Foundation

enum TapMode: Sendable, Equatable {
    case off, listenOnly, active
}
