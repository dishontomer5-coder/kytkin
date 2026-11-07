// P3-10: The one `AXObserver`, on the frontmost browser's pid (001 §14.3.4). Its run-loop source is added to the
// AX thread's run loop, so callbacks arrive there. Registered on the app element: AXFocusedWindowChanged,
// AXMainWindowChanged, AXFocusedUIElementChanged, AXTitleChanged, AXLoadComplete (Chromium/WebKit post it; harmless
// if Gecko doesn't). Gecko only: AXValueChanged on the cached `urlbar-input` element (the engine drops it while the
// bar has focus). Not registered: AXUIElementDestroyed, AXWindowCreated, AXLayoutChanged (popup and tooltip noise,
// R3b §5).
//
// The callback reads nothing from the element: it only maps the notification name to a `BrowserTrigger`.
// Never sets an attribute or performs an action. Never compiled into the tests. AX thread only. Never logs.

import ApplicationServices
import Foundation

final class FrontmostObserver: BrowserNotificationObserving {
    typealias Node = AXUIElement

    var onTrigger: ((BrowserTrigger) -> Void)?

    private static let appNotifications: [(String, BrowserTrigger)] = [
        ("AXFocusedWindowChanged", .focusedWindowChanged),
        ("AXMainWindowChanged", .mainWindowChanged),
        ("AXFocusedUIElementChanged", .focusedElementChanged),
        ("AXTitleChanged", .titleChanged),
        ("AXLoadComplete", .loadComplete),
    ]
    private static let valueChanged = "AXValueChanged"

    private var observer: AXObserver?
    private var app: AXUIElement?
    private var registered: [String] = []
    private var valueElement: AXUIElement?

    init() {}

    deinit {
        detach()
    }

    func attach(pid: Int32) -> Bool {
        detach()
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let observer = created else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXElementTree.messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var names: [String] = []
        for (name, _) in Self.appNotifications {
            switch AXObserverAddNotification(observer, app, name as CFString, refcon) {
            case .success:
                names.append(name)
            case .notificationUnsupported, .notificationAlreadyRegistered:
                continue   // this browser doesn't post it; the others and the poll cover it
            default:
                // R2: right after launch the browser answers kAXErrorCannotComplete; undo and let the engine retry.
                for n in names { AXObserverRemoveNotification(observer, app, n as CFString) }
                return false
            }
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        self.app = app
        registered = names
        return true
    }

    func observeValueChanges(of node: AXUIElement?) {
        guard let observer else { return }
        if let old = valueElement {
            AXObserverRemoveNotification(observer, old, Self.valueChanged as CFString)
            valueElement = nil
        }
        guard let node else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if AXObserverAddNotification(observer, node, Self.valueChanged as CFString, refcon) == .success {
            valueElement = node
        }
    }

    func detach() {
        guard let observer else { return }
        if let old = valueElement { AXObserverRemoveNotification(observer, old, Self.valueChanged as CFString) }
        if let app {
            for n in registered { AXObserverRemoveNotification(observer, app, n as CFString) }
        }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        app = nil
        registered = []
        valueElement = nil
    }

    // MARK: - Callback

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let me = Unmanaged<FrontmostObserver>.fromOpaque(refcon).takeUnretainedValue()
        me.handle(notification as String)
    }

    private func handle(_ name: String) {
        let trigger: BrowserTrigger?
        if name == Self.valueChanged {
            trigger = .addressValueChanged
        } else {
            trigger = Self.appNotifications.first { $0.0 == name }?.1
        }
        if let trigger { onTrigger?(trigger) }
    }
}
