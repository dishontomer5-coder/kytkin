// P2-26: One row of Settings → Permissions (001 §5.2, §6.2): what the permission is, its status in plain words,
// what it enables and what is lost without it, and which buttons to show. Pure, so every wording and button rule
// is unit-tested. The buttons themselves only ever act on the user's click (design.md).
//
// Button rules:
//   - "Allow…" (the request API) while not granted. macOS shows its dialog at most once ever, so after a first
//     click the row also says to use System Settings.
//   - "Open System Settings" for both notDetermined and denied (P2-46): a notDetermined permission may still have
//     been denied in an earlier run, and then only System Settings can turn it on.
//   - "Quit & Reopen" on the Input Monitoring row only while `TapModePolicy.showsQuitAndReopen` says so (P2-46).
//   - Input Monitoring is "not needed" while Accessibility is allowed: no buttons, so the user isn't asked for a
//     second permission for nothing. P2-64: on macOS 26 Accessibility alone gives listen access and the Input
//     Monitoring preflight then reads true although Kytkin isn't in that list, so this wins over "Allowed" and
//     over "needs a restart" too (P1-17 answered).

import Foundation

struct PermissionRow: Equatable, Sendable, Identifiable {
    enum Status: Equatable, Sendable {
        /// Not read yet.
        case checking
        case granted
        case notGranted
        /// Granted while Kytkin was running; the keyboard watcher needs a relaunch to use it.
        case needsRelaunch
        /// Not granted, but nothing needs it right now (Input Monitoring while Accessibility is allowed).
        case notNeeded
    }

    let pane: PermissionPane
    let title: String
    let status: Status
    let statusText: String
    /// One sentence: what it enables.
    let enables: String
    /// One sentence: what stops working without it. nil when granted.
    let withoutIt: String?
    /// An extra hint (after a request, or how to finish a relaunch). nil = none.
    let hint: String?
    let showsGrant: Bool
    let grantTitle: String
    let showsOpenSettings: Bool
    let showsQuitAndReopen: Bool

    var id: PermissionPane { pane }

    /// - Parameters:
    ///   - state: the permission as last read.
    ///   - accessibilityCoversIt: Accessibility is allowed (Input Monitoring row only; see the button rules above).
    ///   - showsQuitAndReopen: `TapModePolicy.showsQuitAndReopen` (Input Monitoring row only).
    ///   - appName: the name in System Settings' list ("Kytkin Dev" for Debug builds).
    static func make(_ pane: PermissionPane, state: PermissionState, accessibilityCoversIt: Bool,
                     showsQuitAndReopen: Bool, appName: String) -> PermissionRow {
        switch pane {
        case .accessibility:
            return accessibility(state: state, appName: appName)
        case .inputMonitoring:
            return inputMonitoring(state: state, accessibilityCoversIt: accessibilityCoversIt,
                                   showsQuitAndReopen: showsQuitAndReopen, appName: appName)
        }
    }

    private static func accessibility(state: PermissionState, appName: String) -> PermissionRow {
        let status = baseStatus(state)
        return PermissionRow(
            pane: .accessibility, title: "Accessibility", status: status, statusText: text(for: status),
            // P6-0c (copy review P-1, P1): every use, the website one too (the page address is read through it).
            enables: "Lets Kytkin read and replace the text you convert, and see which website you're on.",
            // P6-0c (P-2): website rules need it too (the browser watch attaches only with Accessibility).
            withoutIt: status == .granted ? nil
                : "Without it, Kytkin still switches the language for each app, but double-Shift and website rules "
                    + "don't work.",
            hint: requestHint(state: state, pane: "Accessibility", appName: appName),
            showsGrant: showsButtons(state), grantTitle: "Allow Accessibility…",
            showsOpenSettings: showsButtons(state), showsQuitAndReopen: false)
    }

    private static func inputMonitoring(state: PermissionState, accessibilityCoversIt: Bool,
                                        showsQuitAndReopen: Bool, appName: String) -> PermissionRow {
        let status: Status
        if accessibilityCoversIt {
            status = .notNeeded   // P2-64: whatever the preflight says
        } else if showsQuitAndReopen, state == .granted {
            status = .needsRelaunch
        } else {
            status = baseStatus(state)
        }
        let buttons = showsButtons(state) && status != .notNeeded
        let hint: String? = switch status {
        case .needsRelaunch: "Click Quit & Reopen so Kytkin can start using it. Kytkin opens again by itself."
        case .notNeeded: nil
        default: requestHint(state: state, pane: "Input Monitoring", appName: appName)
        }
        // P6-0c (copy review P-4): the "why" already says it's a backup.
        let withoutIt: String? = nil
        return PermissionRow(
            pane: .inputMonitoring, title: "Input Monitoring", status: status,
            // P6-0c (visual review P2): optional, so never a red "Not allowed".
            statusText: status == .notGranted ? "Optional" : text(for: status),
            // P6-0c (copy review P-3, P1): v1 learns nothing from typed words; it's only a double-Shift backup.
            enables: "Usually not needed. A backup so Kytkin can notice double-Shift when Accessibility is off.",
            withoutIt: withoutIt,
            hint: hint,
            showsGrant: buttons, grantTitle: "Allow Input Monitoring…",
            showsOpenSettings: buttons, showsQuitAndReopen: status == .needsRelaunch)
    }

    private static func baseStatus(_ state: PermissionState) -> Status {
        switch state {
        case .unknown: .checking
        case .granted: .granted
        case .denied, .notDetermined: .notGranted
        }
    }

    /// P2-46: both "not asked yet" and "said no" offer the request and the System Settings link.
    private static func showsButtons(_ state: PermissionState) -> Bool {
        state == .notDetermined || state == .denied
    }

    /// After the user clicked "Allow…" (state reads `.denied` until they switch it on).
    private static func requestHint(state: PermissionState, pane: String, appName: String) -> String? {
        guard state == .denied else { return nil }
        // P6-0c (copy review P-6).
        return "Waiting… In System Settings → Privacy & Security → \(pane), turn on \(appName). "
            + "Not in the list? Click + and choose \(appName)."
    }

    static func text(for status: Status) -> String {
        switch status {
        case .checking: "Checking…"
        case .granted: "Allowed"
        case .notGranted: "Not allowed"
        case .needsRelaunch: "Allowed. Quit & Reopen Kytkin to use it."   // P6-0c (P-5)
        case .notNeeded: "Not needed (Accessibility covers it)"
        }
    }
}
