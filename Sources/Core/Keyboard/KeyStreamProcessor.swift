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
// - P2-59 (001 §12.3 X3/X5/X6): Return, keypad Enter, Tab and Option-Space end the buffer; a convert can keep the
//   buffer re-rendered (`bufferRendering`); the last finished convert is remembered until anything touches the field.
// Time for deadlines comes from the injected Clock (same uptime base as event timestamps).
//
// Adapter protocol (B3, QA): after every `handle`, every main/worker hop, and on the deadline timer:
//   guard let gen = activeGeneration; read `now` once
//   if let due = nextDeadlineNanos, due <= now { posting = !commit.claimFlush(gen) }
//   else if commit.state == .posting(gen) { posting = true }   // P2-17 QA: the hard-cap wait (due = the cap)
//   else { return }                                             // not due: never flush without the claim
//   pollFlush(postingStarted: posting)
// (KeyTapEngine.runFlushStep is the reference implementation.)
// An abort (overflow, shortcut, click, reset, mode change) makes the flush due at once, but it still waits for a
// worker that already won the commit (up to the hard cap), so held keys never interleave with its posts.
// P2-35 (001 §12 K4): a generation force-flushed while its worker was posting (hard cap, full FIFO, or no longer
// active) is remembered. Until its stale `finishReplacement` arrives or another `postingHardCapNanos` passes, a
// double-Shift or auto-fix trigger starts nothing (passes, no signal, no hold), so two workers never post at once.
// `reset` doesn't clear it: the worker is still running.

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

    /// P2-50: replaced at runtime by `updateConfig` (001 §12 W6), except `mode` and `holdBackCapacity`.
    private(set) var config: KeyProcessorConfig
    private let clock: any Clock
    private(set) var mode: TapMode
    /// The layout the buffer's strokes are typed in, as told by main.
    private(set) var inputSource: InputSourceID?
    private(set) var buffer = WordBuffer()
    /// P2-59 (001 §12.3 X5): the layout the kept buffer is rendered in after a convert that kept it without switching
    /// (`finishReplacement(bufferRenderedIn:)`). Nil = the buffer is in `inputSource`. Snapshots use
    /// `bufferRendering ?? inputSource`. The next letter typed while it differs from `inputSource` first invalidates
    /// the buffer (that stroke is in another layout); Space and Backspace keep it.
    private(set) var bufferRendering: InputSourceID?
    /// P2-59 (X6): the last convert generation finished (not aborted, no keyDown held behind it). Cleared by any
    /// keyDown (user or replay), a click, a reset, a buffer invalidation and the start of the next replacement.
    /// Snapshots carry it as `untouchedSinceConvert`.
    private(set) var lastConvertGen: UInt64?

    private var detector: DoubleShiftDetector
    private var queue: HoldBackQueue
    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    /// P2-35: a generation flushed while its worker was posting, and when we stop waiting for its finish.
    private var stalePosting: (gen: UInt64, untilNanos: UInt64)?
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
            lastConvertGen = nil // P2-59 (X6): the caret may have moved
            _ = detector.handle(.pointerDown)
            // R5: a click during a replacement finishes it: flush, and the buffer is stale.
            abortReplacement()
            return (.pass, invalidateBuffer())

        case .keyDown, .keyUp:
            // P2-59 (X6): any user or replayed key (held or not) touches the field after the last convert.
            if e.kind == .keyDown { lastConvertGen = nil }
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
        if postingStarted {
            forgetBuffer()
            // P2-35: its worker may still be posting: block new replacements until its finish or the cap.
            stalePosting = (r.gen, now + config.postingHardCapNanos)
        }
        // P2-12: deadline (or hard cap, or abort) → flush unchanged. A late finish for this gen is then ignored.
        phase = .idle
        return queue.drain()
    }

    // MARK: - From the worker / main (hopped onto the tap thread)

    /// The worker is done with `gen`. Returns the held events to replay, in order. A stale `gen` (the deadline
    /// or an abort already flushed) is ignored and returns nothing.
    /// `bufferAfter`: nil = the text is unchanged, keep the buffer; non-empty = the current word is now these
    /// strokes; empty = the text changed and no strokes describe it: forget the whole buffer (P2-21 QA: keeping the
    /// earlier words would let a Backspace make one of them "current" again, over text that is no longer there).
    /// P2-59 (001 §12.3 X5): `newRendering` keeps its meaning ("the input source is now this"; a kept buffer is in it).
    /// `bufferRenderedIn`: the kept buffer was re-rendered into this layout while the input source stayed the same
    /// (convert with "switch after converting" off), so a second double-Shift converts it back. A finished convert
    /// that wasn't aborted becomes `lastConvertGen` (X6).
    mutating func finishReplacement(gen: UInt64, newRendering: InputSourceID?, bufferAfter: [Stroke]?,
                                    bufferRenderedIn: InputSourceID? = nil) -> [HeldEvent] {
        // P2-59c (X5): a re-rendered kept buffer is the whole buffer; new strokes for the current word contradict it.
        assert(bufferRenderedIn == nil || bufferAfter?.isEmpty != false,
               "P2-59: bufferRenderedIn never comes with a non-empty bufferAfter")
        // P2-35: the force-flushed worker is done posting, so new replacements may start again.
        if stalePosting?.gen == gen { stalePosting = nil }
        guard case let .replacing(r) = phase, r.gen == gen else { return [] }
        phase = .idle
        // QA: after an abort the buffer was already cleared (click, reset) and main owns the input source,
        // so only replay.
        if !r.aborted {
            if let newRendering { inputSource = newRendering }
            if let bufferAfter {
                if bufferAfter.isEmpty { forgetBuffer() } else { buffer.replaceCurrentWord(with: bufferAfter) }
            }
            // P2-59: the buffer's rendering after this finish. Neither given: unchanged (nothing was written).
            if let bufferRenderedIn {
                bufferRendering = buffer.isEmpty || bufferRenderedIn == inputSource ? nil : bufferRenderedIn
            } else if newRendering != nil {
                bufferRendering = nil
            }
        }
        var held = queue.drain()
        if r.kind == .autoFix, newRendering != nil, !held.isEmpty {
            // §3d: on a fix, the worker posted the trigger itself (marked `ours`), so don't replay it, and
            // end the word here because our own Space never reaches the buffer. The trigger is always the
            // first held event: an auto-fix only starts from idle with an empty FIFO.
            let trigger = held.removeFirst().event
            if !r.aborted {
                buffer.boundary()
                // P2-59 (X3): a Return / Tab / Option-Space trigger ends the buffer here too (→ P4-7).
                if KeyCode.endsBuffer(trigger.keyCode, deviceFlags: trigger.deviceFlags) { forgetBuffer() }
            }
        }
        // P2-59 (X6): set last, after any buffer change above, so this finish's own bookkeeping doesn't clear it.
        // QA (P2-59a): not when a held keyDown is about to be replayed: it types after the convert, so the field is
        // already "touched". Its replay would clear it anyway, but a double-Shift handled before the replay comes back
        // through the tap must not see this generation as untouched. ≤ 32 compares, on a finish only (not per key).
        if r.kind == .convert, !r.aborted, !held.contains(where: { $0.event.kind == .keyDown }) {
            lastConvertGen = gen
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
        forgetBuffer()
        if let deviceFlags { reseedShifts(deviceFlags) }
    }

    /// `deviceFlags`: as for `reset`. P2-50: the adapter passes them when a new tap goes in, so a Shift held across
    /// a mode switch is remembered.
    mutating func setMode(_ newMode: TapMode, deviceFlags: UInt64? = nil) {
        guard newMode != mode else { return }
        mode = newMode
        reset(.modeChange, deviceFlags: deviceFlags)
    }

    /// P2-50 (001 §12 W6): the settings changed at runtime (Convert tab, auto-fix toggle).
    /// - `mode` is ignored (it follows the installed tap) and so is `holdBackCapacity` (the FIFO is sized at init).
    /// - The DoubleShiftDetector restarts under the new window/side policy: a half-done gesture is dropped. A Shift
    ///   still down joins it as held and spoiled (as after a reset), so its release can't count as a tap.
    /// - The word buffer, the held keys and a running replacement's armed deadline are left alone (the deadline is an
    ///   absolute time fixed when the replacement started).
    mutating func updateConfig(_ newConfig: KeyProcessorConfig) {
        var c = newConfig
        c.mode = config.mode
        c.holdBackCapacity = config.holdBackCapacity
        config = c
        detector = DoubleShiftDetector(config: c.doubleShift)
        spoilHeldShifts()
    }

    /// Main saw the input source change. Our own after-convert switch keeps the buffer (it was re-rendered);
    /// any other change invalidates it (001 §2.2).
    /// P2-59 (X5): our switch keeps the whole buffer; once the source is the layout the buffer was re-rendered into,
    /// `bufferRendering` has nothing left to say.
    mutating func inputSourceChanged(to id: InputSourceID?, isOurs: Bool) {
        if !isOurs { reset(.inputSourceChanged) }
        inputSource = id
        if bufferRendering == id { bufferRendering = nil }
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
        guard !staleWorkerMayPost() else { return nil } // P2-35: passes, no signal, no hold
        generation &+= 1
        let gen = generation
        let snapshot = currentSnapshot()
        // P2-59 (X6): the snapshot carries the last convert; this new generation replaces it (set again at its finish).
        lastConvertGen = nil
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
            let ended = buffer.boundary()
            // P2-59 (001 §12.3 X3): Return, keypad Enter, Tab and Option-Space end the buffer, after the boundary
            // (the learner's `wordBoundary` is unchanged), so the buffer only ever spans plain spaces.
            if KeyCode.endsBuffer(code, deviceFlags: e.deviceFlags) { forgetBuffer() }
            return (.pass, ended ? .wordBoundary : nil)
        }
        if code == KeyCode.delete {
            if e.deviceFlags & KeyEvent.optionMask != 0 {
                return (.pass, invalidateBuffer()) // ⌥⌫ deletes a whole word we can't count
            }
            buffer.backspace()
            return (.pass, nil)
        }
        if KeyCode.typesNothing(code) { return (.pass, nil) }
        // P2-59 (X5): a letter typed while the kept buffer shows another layout would mix two renderings: forget the
        // kept words first. One optional compare, no allocation (B1).
        var signal: KeySignal?
        if let rendering = bufferRendering {
            if rendering != inputSource { signal = invalidateBuffer() }
            bufferRendering = nil
        }
        buffer.append(Stroke(keyCode: code, layer: e.layer))
        return (.pass, signal)
    }

    /// §3d (P4): Space / Return / Tab after a word is held for auto-fix. The trigger is the first held event,
    /// so "keep" or a deadline replays it in place.
    private mutating func autoFixTrigger(_ e: KeyEvent) -> (TapVerdict, KeySignal?)? {
        guard config.autoFixEnabled, mode == .active, e.origin == .user, !e.isAutoRepeat else { return nil }
        // QA: never start over held events (a full, aborted FIFO the adapter hasn't flushed yet).
        guard case .idle = phase, queue.isEmpty else { return nil }
        guard !staleWorkerMayPost() else { return nil } // P2-35: the trigger passes like any boundary
        let snapshot = currentSnapshot()
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

    /// P2-35: true while a force-flushed generation's worker may still be posting. Clears itself at the cap.
    private mutating func staleWorkerMayPost() -> Bool {
        guard let stale = stalePosting else { return false }
        if clock.nowNanos >= stale.untilNanos {
            stalePosting = nil
            return false
        }
        return true
    }

    private mutating func abortReplacement() {
        if case var .replacing(r) = phase {
            r.aborted = true
            phase = .replacing(r)
        }
    }

    private mutating func invalidateBuffer() -> KeySignal? {
        guard !buffer.isEmpty else {
            forgetBuffer()
            return nil
        }
        forgetBuffer()
        return .bufferInvalidated
    }

    /// P2-59: every buffer invalidation also forgets the kept rendering and the last convert (X5/X6).
    private mutating func forgetBuffer() {
        buffer.invalidate()
        bufferRendering = nil
        lastConvertGen = nil
    }

    /// P2-59 (X5/X6): the buffer as a worker sees it. Allocates: call it only on a trigger.
    private func currentSnapshot() -> WordSnapshot {
        buffer.snapshot(renderedIn: bufferRendering ?? inputSource, untouchedSinceConvert: lastConvertGen)
    }

    /// A Shift already down at reset joins the detector as held and spoiled, so it can't start a tap,
    /// and its later release is a real edge.
    private mutating func reseedShifts(_ flags: UInt64) {
        leftShiftHeld = flags & KeyEvent.leftShiftDeviceBit != 0
        rightShiftHeld = flags & KeyEvent.rightShiftDeviceBit != 0
        spoilHeldShifts()
    }

    /// Tells a fresh detector about the Shifts we know are down, as held and spoiled.
    private mutating func spoilHeldShifts() {
        guard leftShiftHeld || rightShiftHeld else { return }
        if leftShiftHeld { _ = detector.handle(.shiftDown(.left, atNanos: 0)) }
        if rightShiftHeld { _ = detector.handle(.shiftDown(.right, atNanos: 0)) }
        _ = detector.handle(.otherModifierChanged)
    }
}
