// P2-16: The thin, read-only OS seam under PermissionsManager. It never prompts: implementations may only
// call silent checks (AXIsProcessTrusted, CGPreflightListenEventAccess, IsSecureEventInputEnabled).
// The real one is System/Permissions/SystemPermissionProbe; tests use a fake.

import Foundation

protocol PermissionProbing: Sendable {
    func read() -> PermissionReading
}
