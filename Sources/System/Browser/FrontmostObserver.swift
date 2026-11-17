// P3-10: The one `AXObserver`, on the frontmost browser's pid (001 §14.3.4). Its run-loop source is added to the
// AX thread's run loop, so callbacks arrive there. Registered on the app element: AXFocusedWindowChanged,
// AXMainWindowChanged, AXFocusedUIElementChanged, AXTitleChanged, AXLoadComplete (Chromium/WebKit post it; harmless
// if Gecko doesn't). Gecko only: AXValueChanged on the cached `urlbar-input` element (the engine drops it while the
// bar has focus). Not registered: AXUIElementDestroyed, AXWindowCreated, AXLayoutChanged (popup and tooltip noise,
// R3b §5).
//
// The callback reads nothing from the element: it only maps the notification name to a `BrowserTrigger`.
// Never sets an attribute or performs an action. Never compiled into the tests. AX thread only. Never logs.
// P3-21: detaching from a hung browser held the AX thread ~1.5 s (one 0.25 s timeout per removal). Removals now stop
// at the first kAXErrorCannotComplete and are skipped when the browser process is gone; the run-loop source is always
// removed, and releasing the observer drops whatever registrations are left.

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
    private var pid: Int32 = 0
    private var app: AXUIElement?
    private var registered: [String] = []
    private var valueElement: AXUIElement?
    /// The run loop the source was added to (the AX thread's). Kept so `detach()` removes it from that run loop even
    /// if it ever ran elsewhere (e.g. a deinit off the AX thread): a source left behind would call back with a
    /// dangling `refcon`.
    private var runLoop: CFRunLoop?

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
                var ok = true
                for n in names where ok { ok = Self.remove(observer, app, n) }   // P3-21: stop at a timeout
                return false
            }
        }
        let loop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
        runLoop = loop
        self.observer = observer
        self.pid = pid
        self.app = app
        registered = names
        return true
    }

    func observeValueChanges(of node: AXUIElement?) {
        guard let observer else { return }
        if let old = valueElement {
            _ = Self.remove(observer, old, Self.valueChanged)
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
        // P3-21: a quit browser has nothing to unregister; a hung one gets one try, not one per notification.
        var ok = Self.processExists(pid)
        if ok, let old = valueElement { ok = Self.remove(observer, old, Self.valueChanged) }
        if let app {
            for n in registered where ok { ok = Self.remove(observer, app, n) }
        }
        if let runLoop { CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode) }
        runLoop = nil
        self.observer = nil
        app = nil
        registered = []
        valueElement = nil
    }

    /// P3-21: false = the browser didn't answer (kAXErrorCannotComplete): don't ask it again.
    private static func remove(_ observer: AXObserver, _ element: AXUIElement, _ name: String) -> Bool {
        AXObserverRemoveNotification(observer, element, name as CFString) != .cannotComplete
    }

    /// P3-21: the process still exists (signal 0 checks without sending anything).
    private static func processExists(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
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
