// P2-5: The modifier layers a LayoutMap records per key (001 §2.2, §4.3).
// Raw values are the JSON layer names in `kytkin-layoutmap` v1.

import Foundation

enum KeyLayer: String, Codable, CaseIterable, Sendable {
    case plain, shift, capsLock, option, shiftOption
}
