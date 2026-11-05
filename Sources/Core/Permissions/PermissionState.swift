// P2-13: A permission grant as read silently by PermissionsManager (P2-16, 001 §2.2).
// Only `.granted` turns a feature on; `unknown` (couldn't check) counts as not granted.

import Foundation

enum PermissionState: Sendable, Equatable {
    case granted, denied, notDetermined, unknown
}
