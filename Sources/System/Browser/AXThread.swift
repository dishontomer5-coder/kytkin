// P3-10: The AX thread `io.github.kytkin.ax` with its own CFRunLoop (001 §14.1). Browser AX calls are synchronous
// IPC to the browser and can block for up to the 0.25 s messaging timeout, so they never run on main. The observer's
// run-loop source and the read timer live on this run loop. Created on the first attach, it lives for the process;
// an idle run loop costs nothing (its keep-alive timer is set to the distant future and never fires, B15).
//
// Unlike KeyTapThread, nothing ever waits for this thread, not even for it to start (B16): blocks sent before its run
// loop exists are queued and run first, in order.

import Foundation

/// Runs blocks on the AX thread. A seam so the watcher's hop logic can be tested with a queue drained by hand.
protocol AXThreadExecuting: AnyObject, Sendable {
    /// Runs `block` on the AX thread, soon. Never blocks the caller.
    func async(_ block: @escaping @Sendable () -> Void)
}

final class AXThread: Thread, AXThreadExecuting, @unchecked Sendable { // @unchecked: state is guarded by `lock`
    static let name = "io.github.kytkin.ax"

    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var pending: [@Sendable () -> Void] = []

    override init() {
        super.init()
        name = Self.name
        qualityOfService = .userInitiated
    }

    override func main() {
        let loop = CFRunLoopGetCurrent()!
        // A never-firing timer keeps the run loop alive while nothing is attached.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, Date.distantFuture.timeIntervalSinceReferenceDate,
                                                        1e9, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, keepAlive, .commonModes)
        let queued = lock.withLock {
            self.loop = loop
            defer { pending = [] }
            return pending
        }
        for block in queued { block() }
        CFRunLoopRun()
        CFRunLoopTimerInvalidate(keepAlive)
    }

    var isCurrent: Bool { Thread.current === self }

    func async(_ block: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard let loop else {
                pending.append(block)
                return
            }
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(loop)
        }
    }

    /// Ends the run loop; the thread then exits. Tests only (the app's AX thread lives for the process).
    func stopRunLoop() {
        async { CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
}
