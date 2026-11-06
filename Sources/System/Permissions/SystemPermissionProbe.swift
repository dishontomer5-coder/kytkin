// P2-16: The real `PermissionProbing`: three silent checks, none of which can show a dialog
// (keyboard-event-tap.md §1, §4). Never call a request/prompt API from here.
//   - AXIsProcessTrusted()            Accessibility (same as AXIsProcessTrustedWithOptions with prompt false)
//   - CGPreflightListenEventAccess()  Input Monitoring
//   - IsSecureEventInputEnabled()     Secure Input (Carbon, no permission needed)
// Note: TCC answers for the *responsible* process. Run from Terminal (a headless probe), this reports
// Terminal's grants, not Kytkin's (context-monitoring.md §3, "Responsible-process gotcha").

import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

struct SystemPermissionProbe: PermissionProbing {
    func read() -> PermissionReading {
        PermissionReading(accessibilityTrusted: AXIsProcessTrusted(),
                          inputMonitoringGranted: CGPreflightListenEventAccess(),
                          secureInput: IsSecureEventInputEnabled())
    }
}
