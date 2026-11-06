// P2-17: The real KeyTapBackend: one session CGEventTap at the head of the stream (R4 recommendation B), its
// run-loop source, the hold-back deadline timer and the 1 s poll timer, all on the tap thread's run loop.
// Thin on purpose: every decision is in KeyTapEngine (tested). This file is excluded from the test target, so
// no test can ever install a tap or post an event (live-machine rule, CLAUDE.md).

import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

final class CGEventTapBackend: KeyTapBackend {
    /// 001 §2.2 / B9: Secure Input poll interval.
    static let pollIntervalSeconds: CFTimeInterval = 1
    /// Fire a hair late rather than early, so the deadline has really passed when the flush step runs.
    private static let deadlineSlackSeconds: CFTimeInterval = 0.000_5

    private let runLoop: CFRunLoop
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: EventHandler?
    private var deadlineTimer: CFRunLoopTimer?
    private var pollTimer: CFRunLoopTimer?

    init(runLoop: CFRunLoop) {
        self.runLoop = runLoop
    }

    deinit {
        uninstall()
        if let deadlineTimer { CFRunLoopTimerInvalidate(deadlineTimer) }
        if let pollTimer { CFRunLoopTimerInvalidate(pollTimer) }
    }

    // MARK: - Tap

    func install(mode: TapMode, handler: @escaping EventHandler) -> Bool {
        uninstall()
        guard mode != .off else { return false }
        self.handler = handler
        let options: CGEventTapOptions = mode == .active ? .defaultTap : .listenOnly
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                                           eventsOfInterest: KeyEventTranslator.eventsOfInterest,
                                           callback: { _, type, event, refcon in
                                               // P2-17: O(1). Everything else is in KeyTapEngine.handleTapEvent.
                                               guard let refcon else { return Unmanaged.passUnretained(event) }
                                               let backend = Unmanaged<CGEventTapBackend>.fromOpaque(refcon)
                                                   .takeUnretainedValue()
                                               guard let handler = backend.handler else {
                                                   return Unmanaged.passUnretained(event)
                                               }
                                               return handler(type, event) ? Unmanaged.passUnretained(event) : nil
                                           },
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            self.handler = nil
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(runLoop, src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        return true
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        tap = nil
        source = nil
        handler = nil
    }

    var isEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - System queries (silent, never prompt)

    func isGranted(_ mode: TapMode) -> Bool {
        switch mode {
        case .off: return true
        case .active: return AXIsProcessTrusted()
        case .listenOnly: return CGPreflightListenEventAccess()
        }
    }

    func post(_ event: CGEvent) {
        event.post(tap: .cgSessionEventTap)
    }

    var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    var currentDeviceFlags: UInt64 { CGEventSource.flagsState(.combinedSessionState).rawValue }

    // MARK: - Timers

    func attachTimers(deadline: @escaping () -> Void, poll: @escaping () -> Void) {
        let never = Date.distantFuture.timeIntervalSinceReferenceDate
        // Repeating with a huge interval so the timer stays valid after firing; `armDeadline` moves it.
        let d = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, never, 1e9, 0, 0) { _ in deadline() }
        let p = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                                                CFAbsoluteTimeGetCurrent() + Self.pollIntervalSeconds,
                                                Self.pollIntervalSeconds, 0, 0) { _ in poll() }
        if let p { CFRunLoopTimerSetTolerance(p, 0.1) } // B11: let the system coalesce the idle poll
        CFRunLoopAddTimer(runLoop, d, .commonModes)
        CFRunLoopAddTimer(runLoop, p, .commonModes)
        deadlineTimer = d
        pollTimer = p
    }

    func armDeadline(atUptimeNanos due: UInt64) {
        guard let deadlineTimer else { return }
        let now = SystemClock().nowNanos
        let wait = due > now ? CFTimeInterval(due - now) / 1e9 : 0
        CFRunLoopTimerSetNextFireDate(deadlineTimer, CFAbsoluteTimeGetCurrent() + wait + Self.deadlineSlackSeconds)
    }

    func cancelDeadline() {
        guard let deadlineTimer else { return }
        CFRunLoopTimerSetNextFireDate(deadlineTimer, Date.distantFuture.timeIntervalSinceReferenceDate)
    }

    func runSoon(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}
