// P2-16: The real `PermissionProbing`: two silent checks, neither of which can show a dialog
// (keyboard-event-tap.md §1, §4). Never call a request/prompt API from here.
//   - AXIsProcessTrusted()            Accessibility (same as AXIsProcessTrustedWithOptions with prompt false)
//   - CGPreflightListenEventAccess()  Input Monitoring
// P2-45: IsSecureEventInputEnabled() is not read here; KeyWatcher is the only owner (001 §12.2 W5).
// Note: TCC answers for the *responsible* process. Run from Terminal (a headless probe), this reports
// Terminal's grants, not Kytkin's (context-monitoring.md §3, "Responsible-process gotcha").

import ApplicationServices
import CoreGraphics

struct SystemPermissionProbe: PermissionProbing {
    func read() -> PermissionReading {
        PermissionReading(accessibilityTrusted: AXIsProcessTrusted(),
                          inputMonitoringGranted: CGPreflightListenEventAccess())
    }
}
