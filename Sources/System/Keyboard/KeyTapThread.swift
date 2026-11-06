// P2-17: The dedicated tap thread `io.github.kytkin.tap` with its own CFRunLoop (001 §2.1), so main-thread work
// can never stall the event tap (R4 §4). Other threads hop onto it with `CFRunLoopPerformBlock` + `CFRunLoopWakeUp`.

import Foundation

final class KeyTapThread: Thread, @unchecked Sendable { // @unchecked: `runLoop` is written once, before `ready`
    static let name = "io.github.kytkin.tap"

    private let ready = DispatchSemaphore(value: 0)
    /// P2-50: entered when `main()` begins (before `ready`), left when it returns, so others can wait for the exit.
    /// Only meaningful after `startAndWait()`.
    private let exited = DispatchGroup()
    private var loop: CFRunLoop?

    override init() {
        super.init()
        name = Self.name
        qualityOfService = .userInteractive
    }

    /// Starts the thread and returns once its run loop exists.
    func startAndWait() {
        start()
        ready.wait()
    }

    override func main() {
        exited.enter()
        let loop = CFRunLoopGetCurrent()!
        self.loop = loop
        // A never-firing timer keeps the run loop alive while no tap is installed.
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, Date.distantFuture.timeIntervalSinceReferenceDate,
                                                        1e9, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, keepAlive, .commonModes)
        ready.signal()
        CFRunLoopRun()
        CFRunLoopTimerInvalidate(keepAlive)
        exited.leave()
    }

    var isCurrent: Bool { Thread.current === self }

    /// The tap thread's run loop. Valid after `startAndWait()` returned.
    var runLoop: CFRunLoop { loop! }

    /// Runs `block` on the tap thread, soon. Never blocks the caller.
    func async(_ block: @escaping @Sendable () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    /// Runs `block` on the tap thread and waits for its result, at most `timeout` seconds (nil on timeout).
    /// For start/stop only: never call it from the tap thread's own hot path.
    func sync<T: Sendable>(timeout: TimeInterval = 1, _ block: @escaping @Sendable () -> T) -> T? {
        if isCurrent { return block() }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        async {
            box.set(block())
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.get()
    }

    /// P2-50: waits at most `timeout` seconds for the thread to exit (after `stopRunLoop`). True = it has exited.
    func waitUntilExited(timeout: TimeInterval) -> Bool {
        exited.wait(timeout: .now() + timeout) == .success
    }

    /// P2-50: runs `block` on `queue` once the thread has exited (at once if it already has).
    func onExit(queue: DispatchQueue, _ block: @escaping @Sendable () -> Void) {
        exited.notify(queue: queue, execute: block)
    }

    /// Ends the run loop; the thread then exits.
    func stopRunLoop() {
        async { CFRunLoopStop(CFRunLoopGetCurrent()) }
    }

    /// Carries a `sync` result across threads.
    private final class ResultBox<T: Sendable>: @unchecked Sendable { // @unchecked: guarded by `lock`
        private let lock = NSLock()
        private var value: T?

        func set(_ v: T) { lock.withLock { value = v } }
        func get() -> T? { lock.withLock { value } }
    }
}
