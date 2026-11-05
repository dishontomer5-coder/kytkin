// P0-5: Owns the menu-bar status item. Shows the current input language ("EN"/"HE").

import AppKit

@MainActor
final class StatusItemController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var observer: NSObjectProtocol?

    init() {
        statusItem.menu = makeMenu()
        refreshTitle()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: CurrentInputSource.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTitle() }
        }
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
    }

    private func refreshTitle() {
        statusItem.button?.title = InputSourceLabel.label(forLanguages: CurrentInputSource.languages())
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let about = NSMenuItem(title: "Kytkin v\(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Kytkin",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q") // ⌘Q
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }
}
