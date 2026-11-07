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
//   - Input Monitoring is "not needed" while Accessibility is allowed (the active tap covers it): no buttons, so
//     the user isn't asked for a second permission for nothing.

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
    ///   - accessibilityGranted: used by the Input Monitoring row only.
    ///   - showsQuitAndReopen: `TapModePolicy.showsQuitAndReopen` (Input Monitoring row only).
    ///   - appName: the name in System Settings' list ("Kytkin Dev" for Debug builds).
    static func make(_ pane: PermissionPane, state: PermissionState, accessibilityGranted: Bool,
                     showsQuitAndReopen: Bool, appName: String) -> PermissionRow {
        switch pane {
        case .accessibility:
            return accessibility(state: state, appName: appName)
        case .inputMonitoring:
            return inputMonitoring(state: state, accessibilityGranted: accessibilityGranted,
                                   showsQuitAndReopen: showsQuitAndReopen, appName: appName)
        }
    }

    private static func accessibility(state: PermissionState, appName: String) -> PermissionRow {
        let status = baseStatus(state)
        return PermissionRow(
            pane: .accessibility, title: "Accessibility", status: status, statusText: text(for: status),
            enables: "Lets Kytkin fix text you typed in the wrong language when you press Shift twice.",
            withoutIt: status == .granted ? nil
                : "Without it, pressing Shift twice only switches the language and can't fix text. "
                    + "Switching the language for each app still works.",
            hint: requestHint(state: state, pane: "Accessibility", appName: appName),
            showsGrant: showsButtons(state), grantTitle: "Allow Accessibility…",
            showsOpenSettings: showsButtons(state), showsQuitAndReopen: false)
    }

    private static func inputMonitoring(state: PermissionState, accessibilityGranted: Bool,
                                        showsQuitAndReopen: Bool, appName: String) -> PermissionRow {
        let status: Status
        if showsQuitAndReopen, state == .granted {
            status = .needsRelaunch
        } else if state != .granted, state != .unknown, accessibilityGranted {
            status = .notNeeded
        } else {
            status = baseStatus(state)
        }
        let buttons = showsButtons(state) && status != .notNeeded
        let hint: String? = switch status {
        case .needsRelaunch: "Click Quit & Reopen so Kytkin can start using it. Kytkin opens again by itself."
        case .notNeeded: nil
        default: requestHint(state: state, pane: "Input Monitoring", appName: appName)
        }
        let withoutIt: String? = switch status {
        case .granted, .needsRelaunch, .notNeeded: nil
        case .checking, .notGranted: "Without it or Accessibility, pressing Shift twice does nothing. "
            + "Switching the language for each app still works."
        }
        return PermissionRow(
            pane: .inputMonitoring, title: "Input Monitoring", status: status, statusText: text(for: status),
            enables: "A backup for when Accessibility is off: Kytkin can still notice Shift pressed twice and "
                + "learn from your typing (words are kept in memory only, never saved).",
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
        return "Waiting for you: in System Settings → Privacy & Security → \(pane), turn on “\(appName)”. "
            + "If it isn't in the list, click + under the list and choose \(appName)."
    }

    static func text(for status: Status) -> String {
        switch status {
        case .checking: "Checking…"
        case .granted: "Allowed"
        case .notGranted: "Not allowed"
        case .needsRelaunch: "Allowed, needs a restart of Kytkin"
        case .notNeeded: "Not needed (Accessibility covers it)"
        }
    }
}
