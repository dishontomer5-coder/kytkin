// P2-26: The welcome window (001 §6.1, §2.2 UI "OnboardingWindowController"): an AppKit NSWindow hosting the SwiftUI
// `OnboardingView`, like Settings (design.md: no SwiftUI scenes). Shown by itself only on the first launch (the root
// asks `OnboardingModel.shouldShowAtLaunch`), and from Settings → General → "Show Welcome Again".
// - Showing and closing go through `WindowPresenter` (P2-56). One window, reused.
// - Closing it any way (Done, Skip, ⌘W, Esc, the close button) calls `model.finish()`: the "seen" flag stays set and
//   the 1 s permission poll stops.

import AppKit
import SwiftUI

@MainActor final class OnboardingWindowController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private var window: NSWindow?

    init(model: OnboardingModel) {
        self.model = model
        super.init()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// `firstLaunch`: shown by itself at launch (the default pair may be picked), else reopened by the user.
    func show(firstLaunch: Bool) {
        if !isOpen { model.begin(firstLaunch: firstLaunch) }
        let window = self.window ?? makeWindow()
        WindowPresenter.show(window)
        model.setVisible(true)
    }

    /// Silent refresh (the root calls it when a permission or the keyboard state changed).
    func reload() {
        guard isOpen else { return }
        model.reload()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: OnboardingView(model: model, close: { [weak self] in
            self?.window?.performClose(nil)
        }))
        hosting.sizingOptions = []
        let window = KytkinWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]   // no minimize, like Settings (QA P2-23)
        window.title = "Welcome to Kytkin"
        window.setContentSize(OnboardingView.size)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        self.window = window
        return window
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        model.reload()   // e.g. back from System Settings
    }

    func windowDidBecomeMain(_ notification: Notification) {
        model.languages.refresh()   // e.g. back from System Settings → Keyboard → Input Sources
    }

    func windowWillClose(_ notification: Notification) {
        model.finish()
        if let window { WindowPresenter.willClose(window) }
    }
}
