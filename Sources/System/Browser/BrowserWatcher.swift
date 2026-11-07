// P3-10: The main-actor face of the AX thread (001 §14.1, §14.2 `BrowserWatching`). It only keeps the attach
// bookkeeping (pid, request, attachID) and hops: main → AX thread with `AXThreadExecuting.async`, AX thread → main
// with `postToMain` (`DispatchQueue.main.async` in the app). Nothing here ever waits for the AX thread (B16).
//
// - The AX thread and the engine are made on the first attach and live for the process.
// - A new pid or a changed request → a new attachID and a fresh attach. The same pid with the same request (the
//   browser came back to the front) → no re-attach, just a read; the current attachID is returned.
// - A result is delivered only if it is for the current attach (pid and attachID). After `detach()` nothing more is
//   delivered; ContextMonitor drops stale attachIDs again (§14.1).
// - P3-7: the Apple Event gate opens for the attached pid only when its request carries a dialect (opted in ∧
//   granted ∧ Kytkin on), and closes on detach, on main and at once, so a read already queued on the AX thread can't
//   send to a browser that is no longer in front or while Kytkin is paused or off.
// - `isolated deinit` detaches the engine, so a released watcher leaves no observer or timer on the AX thread.
// Never logs (Browser/ folder, lint rule 2b).

import Foundation

@MainActor final class BrowserWatcher: BrowserWatching {
    typealias MakeEngine = (_ deliver: @escaping @Sendable (Int32, UInt64, BrowserObservation, Bool) -> Void)
        -> any BrowserWatchEngineDriving
    typealias PostToMain = @Sendable (@escaping @Sendable @MainActor () -> Void) -> Void

    var onObservation: (@MainActor (_ pid: Int32, _ attachID: UInt64, BrowserObservation, _ sawWindow: Bool) -> Void)?

    private struct Current: Equatable {
        let pid: Int32
        let request: BrowserWatchRequest
        let attachID: UInt64
    }

    private let makeThread: () -> any AXThreadExecuting
    private let makeEngine: MakeEngine
    private let postToMain: PostToMain
    private let appleEventGate: AppleEventSendGate?
    private var thread: (any AXThreadExecuting)?
    private var engine: (any BrowserWatchEngineDriving)?
    private var current: Current?
    private var lastAttachID: UInt64 = 0

    /// - Parameters:
    ///   - makeThread: returns the started AX thread (called once, on the first attach).
    ///   - makeEngine: builds the engine; `deliver` is the only way results reach main.
    ///   - postToMain: runs a block on main later; never synchronously.
    init(makeThread: @escaping () -> any AXThreadExecuting, makeEngine: @escaping MakeEngine,
         postToMain: @escaping PostToMain = { block in DispatchQueue.main.async { block() } },
         appleEventGate: AppleEventSendGate? = nil) {
        self.makeThread = makeThread
        self.appleEventGate = appleEventGate
        self.makeEngine = makeEngine
        self.postToMain = postToMain
    }

    isolated deinit {
        appleEventGate?.allow(pid: nil)
        if let engine, let thread, current != nil {
            thread.async { engine.detach() }
        }
    }

    /// The attach in force (nil = detached). For tests and P3-14's DEBUG line.
    var currentAttachID: UInt64? { current?.attachID }

    @discardableResult
    func attach(pid: Int32, bundleID: String, request: BrowserWatchRequest) -> UInt64 {
        let (thread, engine) = started()
        appleEventGate?.allow(pid: request.appleScript != nil ? pid : nil)   // P3-7
        if let current, current.pid == pid, current.request == request {
            thread.async { engine.reread() }
            return current.attachID
        }
        lastAttachID += 1
        let id = lastAttachID
        current = Current(pid: pid, request: request, attachID: id)
        thread.async { engine.attach(pid: pid, request: request, attachID: id) }
        return id
    }

    func detach() {
        appleEventGate?.allow(pid: nil)   // P3-7: before anything else, even if nothing was attached
        guard current != nil else { return }
        current = nil
        guard let thread, let engine else { return }
        thread.async { engine.detach() }
    }

    func wake() {
        guard current != nil, let thread, let engine else { return }
        thread.async { engine.wake() }
    }

    // MARK: - Internals

    private func started() -> (any AXThreadExecuting, any BrowserWatchEngineDriving) {
        if let thread, let engine { return (thread, engine) }
        let thread = makeThread()
        let post = postToMain
        let engine = makeEngine { [weak self] pid, attachID, observation, sawWindow in
            post { self?.receive(pid: pid, attachID: attachID, observation, sawWindow: sawWindow) }
        }
        self.thread = thread
        self.engine = engine
        return (thread, engine)
    }

    private func receive(pid: Int32, attachID: UInt64, _ observation: BrowserObservation, sawWindow: Bool) {
        guard let current, current.pid == pid, current.attachID == attachID else { return }   // stale: dropped
        onObservation?(pid, attachID, observation, sawWindow)
    }
}
