// P2-14: Why Kytkin asked for a switch (001 §2.2). Not used for attribution (every select is "ours");
// the caller states it for the DEBUG menu and later diagnostics.

import Foundation

enum SwitchReason: Sendable {
    case rule, afterConvert, afterFix, undo, menu
}
