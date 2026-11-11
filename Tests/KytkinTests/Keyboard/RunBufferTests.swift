// P2-59a (001 §12.3 X3/X5/X6, X8 "Processor / buffer"): Return, keypad Enter, Tab and Option-Space end the buffer;
// snapshot `gaps` / `hasRun`; the kept re-rendered buffer (`bufferRenderedIn`) for the second double-Shift (P3-40: a
// fresh convert to the other language, no longer an undo). P3-40: the `untouchedSinceConvert` / `lastConvertGen`
// tests are gone with that state (the undo's "nothing touched the field" check); `NoUndoSignalTests` covers the rest. Pure value tests with a fake clock; nothing is installed or posted.
// P3-33: no word limit; the buffer holds ≤ 512 keys since the last Return/Enter, Tab, ⌥Space, click or focus change.

import XCTest

final class RunBufferTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
    private let abc = InputSourceID("com.apple.keylayout.ABC")
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")

    private func st(_ code: UInt16, _ layer: KeyLayer = .plain) -> Stroke { Stroke(keyCode: code, layer: layer) }

    private func processor(_ clock: FakeClock = FakeClock(), autoFix: Bool = false,
                           mode: TapMode = .active) -> KeyStreamProcessor {
        var config = KeyProcessorConfig()
        config.autoFixEnabled = autoFix
        config.mode = mode
        var p = KeyStreamProcessor(config: config, clock: clock)
        p.inputSourceChanged(to: abc, isOurs: false)
        return p
    }

    @discardableResult
    private func feed(_ p: inout KeyStreamProcessor, _ events: [KeyEvent]) -> [KeySignal] {
        events.compactMap { p.handle($0).1 }
    }

    private func type(_ p: inout KeyStreamProcessor, _ codes: [UInt16]) {
        for c in codes { _ = p.handle(F.key(c)) }
    }

    /// A double-Shift at `t` ms; returns its snapshot and generation.
    private func doubleShift(_ p: inout KeyStreamProcessor, at t: UInt64) -> (WordSnapshot, UInt64)? {
        for e in F.doubleShift(at: t) {
            if case let .doubleShift(snap, gen)? = p.handle(e).1 { return (snap, gen) }
        }
        XCTFail("no double-Shift at \(t)")
        return nil
    }

    // MARK: - KeyCode.endsBuffer

    func testEndsBufferKeys() {
        XCTAssertTrue(KeyCode.endsBuffer(KeyCode.returnKey, deviceFlags: 0))
        XCTAssertTrue(KeyCode.endsBuffer(KeyCode.keypadEnter, deviceFlags: 0))
        XCTAssertTrue(KeyCode.endsBuffer(KeyCode.tab, deviceFlags: 0))
        XCTAssertTrue(KeyCode.endsBuffer(KeyCode.tab, deviceFlags: KeyEvent.shiftMask))
        XCTAssertTrue(KeyCode.endsBuffer(KeyCode.space, deviceFlags: KeyEvent.optionMask))
        XCTAssertTrue(KeyCode.endsBuffer(KeyCode.space, deviceFlags: KeyEvent.optionMask | KeyEvent.shiftMask))
        XCTAssertFalse(KeyCode.endsBuffer(KeyCode.space, deviceFlags: 0))
        XCTAssertFalse(KeyCode.endsBuffer(KeyCode.space, deviceFlags: KeyEvent.shiftMask | KeyEvent.leftShiftDeviceBit))
        XCTAssertFalse(KeyCode.endsBuffer(a, deviceFlags: KeyEvent.optionMask))
        XCTAssertFalse(KeyCode.endsBuffer(KeyCode.delete, deviceFlags: 0))
    }

    // MARK: - Return / Enter / Tab / Option-Space end the buffer

    func testBufferEndingKeysEmitTheBoundaryAndEndTheBuffer() {
        let enders: [(UInt16, UInt64)] = [(KeyCode.returnKey, 0), (KeyCode.keypadEnter, 0), (KeyCode.tab, 0),
                                          (KeyCode.space, KeyEvent.optionMask)]
        for (code, flags) in enders {
            var p = processor()
            type(&p, [a, KeyCode.space, s])
            let (verdict, signal) = p.handle(F.key(code, flags: flags))
            XCTAssertEqual(verdict, .pass, "key \(code)")
            XCTAssertEqual(signal, .wordBoundary, "key \(code): the learner still sees the word end")
            XCTAssertTrue(p.buffer.isEmpty, "key \(code)")
            // What follows starts a fresh buffer: Backspace can't reach back over the ended line.
            _ = p.handle(F.key(KeyCode.delete))
            type(&p, [d])
            guard let (snap, _) = doubleShift(&p, at: 1_000) else { return }
            XCTAssertEqual(snap.strokes, [st(d)], "key \(code)")
            XCTAssertEqual(snap.previousWords, [], "key \(code)")
        }
    }

    func testBufferEndingKeyAfterSpacesEndsTheBufferWithoutABoundary() {
        var p = processor()
        type(&p, [a, KeyCode.space])
        XCTAssertNil(p.handle(F.key(KeyCode.returnKey)).1, "no word ended here")
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testPlainAndShiftSpaceKeepTheBuffer() {
        var p = processor()
        type(&p, [a])
        XCTAssertEqual(p.handle(F.key(KeyCode.space)).1, .wordBoundary)
        type(&p, [s])
        XCTAssertEqual(p.handle(F.key(KeyCode.space, flags: KeyEvent.shiftMask | KeyEvent.leftShiftDeviceBit)).1,
                       .wordBoundary)
        XCTAssertEqual(p.buffer.strokeCount, 2)
    }

    func testAutoFixReturnTriggerEndsTheBufferAfterAFix() {
        let clock = FakeClock()
        var p = processor(clock, autoFix: true)
        type(&p, [a, KeyCode.space])
        _ = p.finishReplacement(gen: 1, newRendering: nil, bufferAfter: nil) // the Space's auto-fix: keep
        _ = p.handle(F.key(KeyCode.space, origin: .replay))
        type(&p, [s])
        let (verdict, signal) = p.handle(F.key(KeyCode.returnKey))
        XCTAssertEqual(verdict, .hold)
        guard case let .wordEnded(snap, gen)? = signal else { return XCTFail("no wordEnded") }
        XCTAssertEqual(snap.strokes, [st(s)], "the snapshot is taken before the key")
        XCTAssertEqual(snap.previousWords, [[st(a)]])
        let held = p.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: [st(s)])
        XCTAssertEqual(held, [], "the fix posted the Return itself")
        XCTAssertTrue(p.buffer.isEmpty, "Return ends the buffer after a fix too")
    }

    func testAutoFixReturnTriggerKeptIsReplayedAndEndsTheBuffer() {
        let clock = FakeClock()
        var p = processor(clock, autoFix: true)
        type(&p, [a])
        _ = p.handle(F.key(KeyCode.returnKey))
        let held = p.finishReplacement(gen: 1, newRendering: nil, bufferAfter: nil)
        XCTAssertEqual(held.map(\.event.keyCode), [KeyCode.returnKey])
        XCTAssertEqual(p.handle(F.key(KeyCode.returnKey, origin: .replay)).1, .wordBoundary)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    // MARK: - Snapshot gaps / hasRun

    func testSnapshotCarriesTheGapsBetweenWords() {
        var b = WordBuffer()
        b.append(st(a)); b.boundary(); b.boundary()          // "a  "
        b.append(st(s)); b.boundary()                         // "s "
        b.append(st(d))                                       // "d"
        let snap = b.snapshot(renderedIn: abc)
        XCTAssertEqual(snap.previousWords, [[st(a)], [st(s)]])
        XCTAssertEqual(snap.gaps, [2, 1])
        XCTAssertEqual(snap.strokes, [st(d)])
        XCTAssertTrue(snap.hasRun)
        XCTAssertTrue(snap.isValid)
    }

    func testTrailingSpacesAreTheLastGap() {
        var b = WordBuffer()
        b.append(st(a)); b.boundary()
        b.append(st(s)); b.boundary(); b.boundary(); b.boundary()
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.strokes, [])
        XCTAssertEqual(snap.previousWords, [[st(a)], [st(s)]])
        XCTAssertEqual(snap.gaps, [1, 3], "the last gap is the trailing spaces before the caret")
        XCTAssertTrue(snap.hasRun, "a run without a current word")
        XCTAssertFalse(snap.isValid, "isValid keeps its meaning: the current word")
    }

    func testLeadingSpacesAreNotRecorded() {
        var b = WordBuffer()
        b.boundary(); b.boundary()
        b.append(st(a))
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.previousWords, [])
        XCTAssertEqual(snap.gaps, [])
        XCTAssertEqual(snap.strokes, [st(a)])
    }

    func testBackspaceAcrossAGap() {
        var b = WordBuffer()
        b.append(st(a)); b.boundary(); b.boundary()
        b.append(st(s))
        b.backspace()                                          // removes s
        XCTAssertEqual(b.snapshot(renderedIn: nil).gaps, [2])
        b.backspace()                                          // one of the two spaces
        var snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.previousWords, [[st(a)]])
        XCTAssertEqual(snap.gaps, [1])
        b.backspace()                                          // the last space: "a" is current again
        snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.previousWords, [])
        XCTAssertEqual(snap.gaps, [])
        XCTAssertEqual(snap.strokes, [st(a)])
    }

    /// P3-33: was "at 64 strokes"; the cap is 512 keys now, letters and spaces together.
    func testOldestWordAndItsGapDropAtTheCap() {
        var b = WordBuffer()
        for _ in 0..<250 { b.append(st(a)) }
        b.boundary(); b.boundary(); b.boundary()               // gap 3 after the first word
        for _ in 0..<250 { b.append(st(s)) }
        b.boundary(); b.boundary()                             // gap 2 after the second: 505 keys
        XCTAssertEqual(b.snapshot(renderedIn: nil).gaps, [3, 2])
        for _ in 0..<10 { b.append(st(d)) }                   // 515 > 512: the first word and its gap go
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.previousWords.count, 1)
        XCTAssertEqual(snap.previousWords.first?.first, st(s))
        XCTAssertEqual(snap.gaps, [2])
        XCTAssertEqual(snap.strokes.count, 10)
    }

    /// P3-33: was "the oldest word drops at four words"; every word is kept now, each with its gap.
    func testEveryWordAndItsGapIsKept() {
        var b = WordBuffer()
        for (i, code) in [a, s, d, a].enumerated() {
            b.append(st(code))
            for _ in 0...i { b.boundary() }                    // gaps 1, 2, 3, 4
        }
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.previousWords, [[st(a)], [st(s)], [st(d)], [st(a)]])
        XCTAssertEqual(snap.gaps, [1, 2, 3, 4])
    }

    /// P3-33: through the processor: everything typed since the last Return is in the snapshot, however many words,
    /// back to the last Return (a terminal ran the command, a chat sent the message).
    func testProcessorKeepsEverythingSinceTheLastReturn() {
        var p = processor()
        type(&p, [d, d, KeyCode.returnKey])
        for _ in 0..<60 { type(&p, [a, s, KeyCode.space]) }   // 60 words, 180 keys
        type(&p, [d])
        guard let (snap, _) = doubleShift(&p, at: 1_000) else { return }
        XCTAssertEqual(snap.previousWords.count, 60)
        XCTAssertTrue(snap.previousWords.allSatisfy { $0 == [st(a), st(s)] }, "nothing from before the Return")
        XCTAssertEqual(snap.gaps, Array(repeating: 1, count: 60))
        XCTAssertEqual(snap.strokes, [st(d)])
    }

    func testEmptyBufferHasNoRun() {
        let snap = WordBuffer().snapshot(renderedIn: nil)
        XCTAssertFalse(snap.hasRun)
        XCTAssertEqual(snap.gaps, [])
    }

    func testFixtureInitDefaultsToOneSpacePerGap() {
        let snap = WordSnapshot(strokes: [st(a)], previousWords: [[st(s)], [st(d)]], renderedIn: nil, isValid: true)
        XCTAssertEqual(snap.gaps, [1, 1])
    }

    func testDoubleShiftSnapshotCarriesGaps() {
        var p = processor()
        type(&p, [a, KeyCode.space, KeyCode.space, s, KeyCode.space])
        guard let (snap, _) = doubleShift(&p, at: 1_000) else { return }
        XCTAssertEqual(snap.previousWords, [[st(a)], [st(s)]])
        XCTAssertEqual(snap.gaps, [2, 1])
        XCTAssertTrue(snap.hasRun)
        XCTAssertEqual(snap.renderedIn, abc)
    }

    // MARK: - Kept buffer: switched (newRendering) and not switched (bufferRenderedIn)

    func testSwitchedConvertKeepsTheWholeBuffer() {
        var p = processor()
        type(&p, [a, KeyCode.space, s, KeyCode.space, d])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil)
        p.inputSourceChanged(to: hebrew, isOurs: true)
        guard let (snap, _) = doubleShift(&p, at: 2_000) else { return }
        XCTAssertEqual(snap.previousWords, [[st(a)], [st(s)]], "every word kept")
        XCTAssertEqual(snap.gaps, [1, 1])
        XCTAssertEqual(snap.strokes, [st(d)])
        XCTAssertEqual(snap.renderedIn, hebrew)
    }

    func testBufferRenderedInPingPongWithoutSwitching() {
        var p = processor()
        type(&p, [a, KeyCode.space, s])
        guard let (first, gen1) = doubleShift(&p, at: 1_000) else { return }
        XCTAssertEqual(first.renderedIn, abc)
        _ = p.finishReplacement(gen: gen1, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        XCTAssertEqual(p.bufferRendering, hebrew)
        XCTAssertEqual(p.inputSource, abc, "the input source didn't change")

        guard let (second, gen2) = doubleShift(&p, at: 2_000) else { return }
        XCTAssertEqual(second.renderedIn, hebrew, "a second double-Shift converts the kept buffer back")
        XCTAssertEqual(second.previousWords, [[st(a)]])
        XCTAssertEqual(second.strokes, [st(s)])
        _ = p.finishReplacement(gen: gen2, newRendering: nil, bufferAfter: nil, bufferRenderedIn: abc)
        XCTAssertNil(p.bufferRendering, "rendered in the input source again: nothing to override")

        guard let (third, _) = doubleShift(&p, at: 3_000) else { return }
        XCTAssertEqual(third.renderedIn, abc)
        XCTAssertEqual(third.strokes, [st(s)])
    }

    func testBufferRenderingSurvivesSpaceAndBackspace() {
        var p = processor()
        type(&p, [a, KeyCode.space, s])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        _ = p.handle(F.key(KeyCode.space))
        _ = p.handle(F.key(KeyCode.delete))
        _ = p.handle(F.key(KeyCode.delete))
        XCTAssertEqual(p.bufferRendering, hebrew)
        guard let (snap, _) = doubleShift(&p, at: 2_000) else { return }
        XCTAssertEqual(snap.renderedIn, hebrew)
        XCTAssertEqual(snap.strokes, [], "Backspace removed s")
        XCTAssertEqual(snap.previousWords, [[st(a)]])
        XCTAssertEqual(snap.gaps, [1])
    }

    func testNextLetterInvalidatesAKeptBufferInAnotherLayout() {
        var p = processor()
        type(&p, [a, KeyCode.space, s])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        let (verdict, signal) = p.handle(F.key(d))
        XCTAssertEqual(verdict, .pass)
        XCTAssertEqual(signal, .bufferInvalidated)
        XCTAssertNil(p.bufferRendering)
        guard let (snap, _) = doubleShift(&p, at: 2_000) else { return }
        XCTAssertEqual(snap.strokes, [st(d)], "only the new letter, typed in the input source")
        XCTAssertEqual(snap.previousWords, [])
        XCTAssertEqual(snap.renderedIn, abc)
    }

    func testOurMatchingSwitchClearsBufferRenderingAndKeepsTheBuffer() {
        var p = processor()
        type(&p, [a, KeyCode.space, s])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        p.inputSourceChanged(to: hebrew, isOurs: true)
        XCTAssertNil(p.bufferRendering)
        XCTAssertEqual(p.inputSource, hebrew)
        type(&p, [d])
        guard let (snap, _) = doubleShift(&p, at: 2_000) else { return }
        XCTAssertEqual(snap.previousWords, [[st(a)]], "a letter in the matching layout keeps the buffer")
        XCTAssertEqual(snap.strokes, [st(s), st(d)])
        XCTAssertEqual(snap.renderedIn, hebrew)
    }

    func testForeignSwitchClearsBufferRendering() {
        var p = processor()
        type(&p, [a])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        p.inputSourceChanged(to: hebrew, isOurs: false)
        XCTAssertNil(p.bufferRendering)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testInvalidationAndResetClearBufferRendering() {
        let clears: [(inout KeyStreamProcessor) -> Void] = [
            { _ = $0.handle(F.key(KeyCode.leftArrow)) },
            { _ = $0.handle(F.pointer(at: 5_000)) },
            { _ = $0.handle(F.key(KeyCode.returnKey)) },
            { $0.reset(.contextChange) },
        ]
        for (i, clear) in clears.enumerated() {
            var p = processor()
            type(&p, [a])
            guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
            _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
            clear(&p)
            XCTAssertNil(p.bufferRendering, "case \(i)")
        }
    }

    func testForgetOrAbortIgnoresBufferRenderedIn() {
        var p = processor()
        type(&p, [a])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: [], bufferRenderedIn: hebrew)
        XCTAssertNil(p.bufferRendering, "nothing kept, nothing rendered")

        var q = processor()
        type(&q, [a])
        guard let (_, gen2) = doubleShift(&q, at: 1_000) else { return }
        _ = q.handle(F.key(KeyCode.escape, command: true)) // a shortcut aborts the generation
        _ = q.finishReplacement(gen: gen2, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        XCTAssertNil(q.bufferRendering)
    }

    func testNewRenderingWithoutBufferRenderedInClearsAnOldOverride() {
        var p = processor()
        type(&p, [a])
        guard let (_, gen1) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen1, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        guard let (_, gen2) = doubleShift(&p, at: 2_000) else { return }
        // Converted back to ABC and switched to it: the buffer is in the new input source.
        _ = p.finishReplacement(gen: gen2, newRendering: abc, bufferAfter: nil)
        XCTAssertNil(p.bufferRendering)
        XCTAssertEqual(p.buffer.strokeCount, 1)
    }

    func testNothingWrittenKeepsBufferRendering() {
        var p = processor()
        type(&p, [a])
        guard let (_, gen1) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen1, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        guard let (_, gen2) = doubleShift(&p, at: 2_000) else { return }
        _ = p.finishReplacement(gen: gen2, newRendering: nil, bufferAfter: nil)
        XCTAssertEqual(p.bufferRendering, hebrew)
    }

    // MARK: - After a convert

    /// QA (P2-59c deviation): after an AX run that differs from the buffer, ConvertController finishes with
    /// `bufferAfter: []` and switches with `keepsBuffer: true` (`isOurs`). The finish and the change notification
    /// reach the tap thread in either order; both orders must end in the same state: buffer forgotten, no kept
    /// rendering, the new source. (P3-40: no longer "still untouched for the undo".)
    func testAXRunFinishAndOurSwitchEndTheSameInEitherOrder() {
        func state(_ p: KeyStreamProcessor) -> (Bool, InputSourceID?, InputSourceID?) {
            (p.buffer.isEmpty, p.bufferRendering, p.inputSource)
        }
        var finishFirst = processor()
        type(&finishFirst, [a, KeyCode.space, s])
        guard let (_, g1) = doubleShift(&finishFirst, at: 500) else { return }
        _ = finishFirst.finishReplacement(gen: g1, newRendering: nil, bufferAfter: [])
        finishFirst.inputSourceChanged(to: hebrew, isOurs: true)

        var switchFirst = processor()
        type(&switchFirst, [a, KeyCode.space, s])
        guard let (_, g2) = doubleShift(&switchFirst, at: 500) else { return }
        switchFirst.inputSourceChanged(to: hebrew, isOurs: true)
        _ = switchFirst.finishReplacement(gen: g2, newRendering: nil, bufferAfter: [])

        let x = state(finishFirst), y = state(switchFirst)
        XCTAssertTrue(x.0 && y.0, "the buffer is forgotten either way")
        XCTAssertNil(x.1)
        XCTAssertNil(y.1)
        XCTAssertEqual(x.2, hebrew)
        XCTAssertEqual(y.2, hebrew)
        XCTAssertFalse(switchFirst.keepBufferRevoked, "the switch arriving first doesn't abort the generation")
        guard let (snap, _) = doubleShift(&switchFirst, at: 1_500) else { return }
        XCTAssertFalse(snap.hasRun)
        XCTAssertEqual(snap.renderedIn, hebrew)
    }

    // MARK: - QA (P2-59a) additions

    func testOptionAndShiftLayerLettersInvalidateAKeptBufferInAnotherLayout() {
        for flags in [KeyEvent.optionMask, KeyEvent.shiftMask, KeyEvent.optionMask | KeyEvent.shiftMask] {
            var p = processor()
            type(&p, [a, KeyCode.space, s])
            guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
            _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
            XCTAssertEqual(p.handle(F.key(d, flags: flags)).1, .bufferInvalidated, "flags \(flags)")
            XCTAssertNil(p.bufferRendering)
            guard let (snap, _) = doubleShift(&p, at: 2_000) else { return }
            XCTAssertEqual(snap.strokes, [Stroke(keyCode: d, layer: F.key(d, flags: flags).layer)], "flags \(flags)")
            XCTAssertEqual(snap.previousWords, [])
            XCTAssertEqual(snap.renderedIn, abc)
        }
    }

    func testOptionBackspaceForgetsAKeptBufferAndTheConvert() {
        var p = processor()
        type(&p, [a, KeyCode.space, s])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        XCTAssertEqual(p.handle(F.key(KeyCode.delete, flags: KeyEvent.optionMask)).1, .bufferInvalidated)
        XCTAssertNil(p.bufferRendering)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testBackspaceToEmptyThenLetterStartsCleanInTheInputSource() {
        var p = processor()
        type(&p, [a])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        _ = p.handle(F.key(KeyCode.delete))
        XCTAssertTrue(p.buffer.isEmpty)
        XCTAssertNil(p.handle(F.key(s)).1, "nothing left to invalidate")
        XCTAssertNil(p.bufferRendering)
        guard let (snap, _) = doubleShift(&p, at: 2_000) else { return }
        XCTAssertEqual(snap.strokes, [st(s)])
        XCTAssertEqual(snap.renderedIn, abc)
    }

    func testBufferRenderedInOnAnEmptyBufferIsDropped() {
        var p = processor()
        guard let (snap, gen) = doubleShift(&p, at: 1_000) else { return }
        XCTAssertFalse(snap.hasRun)
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        XCTAssertNil(p.bufferRendering)
    }

    func testSettingsChangeKeepsTheKeptBufferAndTheConvert() {
        var p = processor()
        type(&p, [a])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        var c = p.config
        c.autoFixEnabled.toggle()
        p.updateConfig(c)
        XCTAssertEqual(p.bufferRendering, hebrew, "a settings change doesn't touch the field")
    }

    func testAutoFixSnapshotUsesTheKeptRendering() {
        var p = processor(autoFix: true)
        type(&p, [a])
        guard let (_, gen) = doubleShift(&p, at: 1_000) else { return }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        guard case let .wordEnded(snap, _)? = p.handle(F.key(KeyCode.space)).1 else {
            return XCTFail("Space after a word starts an auto-fix")
        }
        XCTAssertEqual(snap.renderedIn, hebrew, "P4 sees the word as it shows, not as the input source would type it")
    }

}
