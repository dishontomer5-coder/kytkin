// P2-12: Every keyboard decision the tap makes, as pure value logic (001 §2.2, §3c/d, §7 B1–B3).
// The KeyWatcher adapter (P2-17) turns each CGEvent into a KeyEvent, calls `handle`, applies the verdict, sends
// the signal off the tap thread, then calls `pollFlush` and re-posts any returned events marked `replay`.
//
// Rules held here:
// - Marker check first: `ours` events pass untouched and are never buffered; `replay` events are user typing.
// - Shift presses and releases come from changes in device bits 0x02 / 0x04, never `.maskShift` (R4 §2),
//   timed by the event's own timestamp (P2-11 decision).
// - While a replacement runs (active tap only), user keyDown/keyUp are held in a FIFO (≤ 32). A deadline
//   (400 ms convert, 150 ms auto-fix), an overflow, a shortcut, a click or a reset flushes them unchanged.
// - O(1) per event, no allocation except a snapshot on a trigger, no logging (lint-enforced).
// Time for deadlines comes from the injected Clock (same uptime base as event timestamps).
//
// Adapter protocol (B3, QA): after every `handle`, every main/worker hop, and on the deadline timer:
//   if let gen = activeGeneration, let due = nextDeadlineNanos, due <= now { posting = !commit.claimFlush(gen) }
//   pollFlush(postingStarted: posting)
// An abort (overflow, shortcut, click, reset, mode change) makes the flush due at once, but it still waits for a
// worker that already won the commit (up to the hard cap), so held keys never interleave with its posts.

import Foundation

struct KeyStreamProcessor: Sendable {
    private enum ReplacementKind: Sendable { case convert, autoFix }

    private struct Replacement: Sendable {
        let gen: UInt64
        let kind: ReplacementKind
        let deadlineNanos: UInt64
        /// Set once the flush was due while the worker was posting (B3): forced flush at this time.
        var hardCapNanos: UInt64?
        /// QA: aborted (overflow, shortcut, click, reset): the flush is due now, and the finish only replays.
        var aborted = false
    }

    private enum Phase: Sendable {
        case idle
        case replacing(Replacement)
    }

    let config: KeyProcessorConfig
    private let clock: any Clock
    private(set) var mode: TapMode
    /// The layout the buffer's strokes are typed in, as told by main.
    private(set) var inputSource: InputSourceID?
    private(set) var buffer = WordBuffer()

    private var detector: DoubleShiftDetector
    private var queue: HoldBackQueue
    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    // P2-12: last seen device Shift bits, so each flagsChanged yields exact per-side press/release edges.
    private var leftShiftHeld = false
    private var rightShiftHeld = false

    init(config: KeyProcessorConfig = .init(), clock: any Clock = SystemClock()) {
        self.config = config
        self.clock = clock
        mode = config.mode
        detector = DoubleShiftDetector(config: config.doubleShift)
        queue = HoldBackQueue(capacity: config.holdBackCapacity)
    }

    // MARK: - Reading

    /// A replacement is running and hasn't been aborted.
    var isReplacing: Bool {
        if case let .replacing(r) = phase { return !r.aborted }
        return false
    }

    /// The generation whose held events are still out (running or aborted), if any. The adapter claims the
    /// B3 flush for this generation.
    var activeGeneration: UInt64? {
        if case let .replacing(r) = phase { return r.gen }
        return nil
    }

    /// When the adapter's tap-thread timer should next call `pollFlush`.
    var nextDeadlineNanos: UInt64? {
        switch phase {
        case let .replacing(r): return r.hardCapNanos ?? (r.aborted ? 0 : r.deadlineNanos)
        case .idle: return nil
        }
    }

    var heldCount: Int { queue.count }

    // MARK: - Per event (tap thread)

    mutating func handle(_ e: KeyEvent) -> (TapVerdict, KeySignal?) {
        // P2-12: marker check first (design.md). Our own posted text must never reach the buffer or detector,
        // or auto-fix could loop on itself (R4 §5).
        if e.origin == .ours { return (.pass, nil) }

        switch e.kind {
        case .tapReset:
            let had = !buffer.isEmpty
            reset(.tapReEnabled)
            return (.pass, had ? .bufferInvalidated : nil)

        case .flagsChanged:
            return (.pass, handleFlags(e))

        case .pointerDown:
            _ = detector.handle(.pointerDown)
            // R5: a click during a replacement finishes it: flush, and the buffer is stale.
            abortReplacement()
            return (.pass, invalidateBuffer())

        case .keyDown, .keyUp:
            if holdsKeys { return hold(e) }
            guard e.kind == .keyDown else { return (.pass, nil) }
            _ = detector.handle(.otherKeyDown)
            return handleKeyDown(e)
        }
    }

    /// Returns the held events to re-post (oldest first) when an abort is pending or the deadline has passed,
    /// otherwise nil. The adapter calls it after every `handle` and from its deadline timer.
    /// `postingStarted`: the worker won the B3 commit for this generation, so wait (up to the hard cap).
    mutating func pollFlush(postingStarted: Bool = false) -> [HeldEvent]? {
        guard case var .replacing(r) = phase else { return nil }
        let now = clock.nowNanos
        guard r.aborted || now >= r.deadlineNanos else { return nil }
        // QA: wait for a posting worker only while waiting can keep order: keys can still be held.
        if postingStarted && mode == .active && !queue.isFull {
            guard let cap = r.hardCapNanos else {
                r.hardCapNanos = now + config.postingHardCapNanos
                phase = .replacing(r)
                return nil
            }
            guard now >= cap else { return nil }
        }
        // QA: flushing under a posting worker means it may have posted part of its text: the buffer can't be trusted.
        if postingStarted { buffer.invalidate() }
        // P2-12: deadline (or hard cap, or abort) → flush unchanged. A late finish for this gen is then ignored.
        phase = .idle
        return queue.drain()
    }

    // MARK: - From the worker / main (hopped onto the tap thread)

    /// The worker is done with `gen`. Returns the held events to replay, in order. A stale `gen` (the deadline
    /// or an abort already flushed) is ignored and returns nothing.
    mutating func finishReplacement(gen: UInt64, newRendering: InputSourceID?, bufferAfter: [Stroke]?) -> [HeldEvent] {
        guard case let .replacing(r) = phase, r.gen == gen else { return [] }
        phase = .idle
        // QA: after an abort the buffer was already cleared (click, reset) and main owns the input source,
        // so only replay.
        if !r.aborted {
            if let newRendering { inputSource = newRendering }
            if let bufferAfter { buffer.replaceCurrentWord(with: bufferAfter) }
        }
        var held = queue.drain()
        if r.kind == .autoFix, newRendering != nil, !held.isEmpty {
            // §3d: on a fix, the worker posted the trigger itself (marked `ours`), so don't replay it, and
            // end the word here because our own Space never reaches the buffer. The trigger is always the
            // first held event: an auto-fix only starts from idle with an empty FIFO.
            held.removeFirst()
            if !r.aborted { buffer.boundary() }
        }
        return held
    }

    /// Forget everything: context change, Secure Input, tap re-enabled, mode change, foreign input-source change.
    /// Held events are flushed unchanged on the next `pollFlush`.
    /// `deviceFlags`: the current modifier flags, if known, so a Shift still held across the reset is remembered
    /// (P2-11 QA) and can't be mistaken for the start of a new tap.
    mutating func reset(_ reason: ResetReason, deviceFlags: UInt64? = nil) {
        abortReplacement()
        _ = detector.handle(.reset)
        leftShiftHeld = false
        rightShiftHeld = false
        buffer.invalidate()
        if let deviceFlags { reseedShifts(deviceFlags) }
    }

    mutating func setMode(_ newMode: TapMode) {
        guard newMode != mode else { return }
        mode = newMode
        reset(.modeChange)
    }

    /// Main saw the input source change. Our own after-convert switch keeps the buffer (it was re-rendered);
    /// any other change invalidates it (001 §2.2).
    mutating func inputSourceChanged(to id: InputSourceID?, isOurs: Bool) {
        if !isOurs { reset(.inputSourceChanged) }
        inputSource = id
    }

    // MARK: - Private

    /// Keys are held while replacing, and while an abort waits for its flush (to keep them in order).
    /// QA: only an active tap can swallow; a `.hold` anywhere else would deliver the key now and replay it later.
    private var holdsKeys: Bool {
        guard mode == .active, case .replacing = phase else { return false }
        return !queue.isFull
    }

    private mutating func hold(_ e: KeyEvent) -> (TapVerdict, KeySignal?) {
        // `holdsKeys` checked the room, so this never fails; never answer `.hold` for an event not queued.
        guard queue.append(HeldEvent(event: e)) else { return (.pass, nil) }
        if e.kind == .keyDown { _ = detector.handle(.otherKeyDown) }
        // R5: a ⌘/⌃ shortcut during a replacement ends it (replayed after the held keys, so order holds).
        // A full FIFO aborts too: flush unchanged, never drop a key (B2).
        if (e.kind == .keyDown && e.commandOrControl) || queue.isFull {
            abortReplacement()
        }
        return (.hold, nil)
    }

    private mutating func handleFlags(_ e: KeyEvent) -> KeySignal? {
        var fired = false
        let left = e.leftShiftDown
        if left != leftShiftHeld {
            leftShiftHeld = left
            let input: ShiftInput = left ? .shiftDown(.left, atNanos: e.timestampNanos)
                                         : .shiftUp(.left, atNanos: e.timestampNanos)
            if detector.handle(input) { fired = true }
        }
        let right = e.rightShiftDown
        if right != rightShiftHeld {
            rightShiftHeld = right
            let input: ShiftInput = right ? .shiftDown(.right, atNanos: e.timestampNanos)
                                          : .shiftUp(.right, atNanos: e.timestampNanos)
            if detector.handle(input) { fired = true }
        }
        if e.keyCode != KeyCode.leftShift && e.keyCode != KeyCode.rightShift {
            // Cmd / Option / Control / Fn / Caps Lock.
            _ = detector.handle(.otherModifierChanged)
        }
        return fired ? doubleShiftFired() : nil
    }

    private mutating func doubleShiftFired() -> KeySignal? {
        guard config.doubleShiftEnabled else { return nil }
        guard case .idle = phase else { return nil } // already replacing: one convert at a time
        generation &+= 1
        let gen = generation
        let snapshot = buffer.snapshot(renderedIn: inputSource)
        // §3c: the second release passes; from now on user keys are held. Listen-only can't hold, so main
        // only toggles the language (§3c step 10).
        if mode == .active { startReplacement(.convert, gen: gen) }
        return .doubleShift(snapshot, gen: gen)
    }

    private mutating func handleKeyDown(_ e: KeyEvent) -> (TapVerdict, KeySignal?) {
        let code = e.keyCode
        if e.commandOrControl || KeyCode.invalidatesBuffer(code) {
            return (.pass, invalidateBuffer())
        }
        if KeyCode.isWordBoundary(code) {
            if let trigger = autoFixTrigger(e) { return trigger }
            return (.pass, buffer.boundary() ? .wordBoundary : nil)
        }
        if code == KeyCode.delete {
            if e.deviceFlags & KeyEvent.optionMask != 0 {
                return (.pass, invalidateBuffer()) // ⌥⌫ deletes a whole word we can't count
            }
            buffer.backspace()
            return (.pass, nil)
        }
        if KeyCode.typesNothing(code) { return (.pass, nil) }
        buffer.append(Stroke(keyCode: code, layer: e.layer))
        return (.pass, nil)
    }

    /// §3d (P4): Space / Return / Tab after a word is held for auto-fix. The trigger is the first held event,
    /// so "keep" or a deadline replays it in place.
    private mutating func autoFixTrigger(_ e: KeyEvent) -> (TapVerdict, KeySignal?)? {
        guard config.autoFixEnabled, mode == .active, e.origin == .user, !e.isAutoRepeat else { return nil }
        // QA: never start over held events (a full, aborted FIFO the adapter hasn't flushed yet).
        guard case .idle = phase, queue.isEmpty else { return nil }
        let snapshot = buffer.snapshot(renderedIn: inputSource)
        guard snapshot.isValid else { return nil }
        generation &+= 1
        let gen = generation
        startReplacement(.autoFix, gen: gen)
        queue.append(HeldEvent(event: e))
        return (.hold, .wordEnded(snapshot, gen: gen))
    }

    private mutating func startReplacement(_ kind: ReplacementKind, gen: UInt64) {
        let wait = kind == .convert ? config.convertDeadlineNanos : config.autoFixDeadlineNanos
        phase = .replacing(Replacement(gen: gen, kind: kind, deadlineNanos: clock.nowNanos + wait, hardCapNanos: nil))
    }

    private mutating func abortReplacement() {
        if case var .replacing(r) = phase {
            r.aborted = true
            phase = .replacing(r)
        }
    }

    private mutating func invalidateBuffer() -> KeySignal? {
        guard !buffer.isEmpty else { return nil }
        buffer.invalidate()
        return .bufferInvalidated
    }

    /// A Shift already down at reset joins the detector as held and spoiled, so it can't start a tap,
    /// and its later release is a real edge.
    private mutating func reseedShifts(_ flags: UInt64) {
        leftShiftHeld = flags & KeyEvent.leftShiftDeviceBit != 0
        rightShiftHeld = flags & KeyEvent.rightShiftDeviceBit != 0
        guard leftShiftHeld || rightShiftHeld else { return }
        if leftShiftHeld { _ = detector.handle(.shiftDown(.left, atNanos: 0)) }
        if rightShiftHeld { _ = detector.handle(.shiftDown(.right, atNanos: 0)) }
        _ = detector.handle(.otherModifierChanged)
    }
}
