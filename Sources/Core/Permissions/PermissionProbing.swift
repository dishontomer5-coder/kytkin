// P2-16: The thin, read-only OS seam under PermissionsManager. It never prompts: implementations may only
// call silent checks (AXIsProcessTrusted, CGPreflightListenEventAccess). P2-45: Secure Input is not read here;
// KeyWatcher is its only owner (001 §12.2 W5).
// The real one is System/Permissions/SystemPermissionProbe; tests use a fake.

import Foundation

protocol PermissionProbing: Sendable {
    func read() -> PermissionReading
}
