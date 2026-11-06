// P2-17 QA: an adversarial soak of KeyTapEngine against the fake backend. Random user typing, double-Shifts, clicks,
// ⌘ shortcuts, workers that claim / finish / never finish, deadlines, resets, tap timeouts and mode switches.
// Invariants checked:
//   - every user key event reaches the app exactly once, in the order it was typed (passed or replayed);
//   - the engine's CGEvent FIFO never desyncs from the processor's queue;
//   - while keys are held, a deadline timer is always armed (typing can't stay swallowed);
//   - a key is never passed in a callback that also re-posted held keys (their relative order would be unclear);
//   - P2-47: no held key is replayed while a worker holds the posting claim, before its hard cap (B3), except by
//     that worker's own finish, a full FIFO, or a tap replacement (no tap can hold keys behind it then).
// P2-50 QA: runtime `updateConfig` (001 §12 W6) is mixed in: double-Shift on/off, window and side policy, auto-fix
// on/off and both deadlines change at random, mid-word and mid-replacement. The invariants above must still hold.
// Nothing is installed or posted: events are built in memory and handed to the fake.

import CoreGraphics
import XCTest

final class KeyTapEngineSoakTests: XCTestCase {
    private typealias T = TapEventFactory

    /// SplitMix64: deterministic, so a failure names a seed that reproduces it.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private enum Kind { case convert, autoFix }

    func testRandomSessionsDeliverEveryKeyExactlyOnceInOrder() {
        for seed: UInt64 in 1...40 {
            soak(seed: seed, steps: 1_500)
        }
    }

    private func soak(seed: UInt64, steps: Int) {
        var rng = Rng(state: seed)
        let clock = FakeClock(nowNanos: 10_000 * T.ms)
        let backend = FakeKeyTapBackend()
        let commit = HoldBackCommitLock()
        var config = KeyProcessorConfig()
        config.autoFixEnabled = seed % 2 == 0
        var signals: [KeySignal] = []
        let engine = KeyTapEngine(
            processor: KeyStreamProcessor(config: config, clock: clock), commit: commit, backend: backend,
            clock: clock, timestamps: EventTimestampNormalizer(numer: 1, denom: 1), machNow: { 0 },
            sendSignal: { signals.append($0) }, sendStatus: { _ in })
        engine.applyMode(.active, userInitiated: true)

        var expected: [UInt64] = []   // user key events, by unique timestamp, in typing order
        var output: [UInt64] = []     // what the app received, in order
        var postsInCallback = 0
        // P2-47: when each worker won the claim, and the exempt moments above.
        var claimedAt: [UInt64: UInt64] = [:]
        var finishing: UInt64?, windingDown = false, replacingTap = false, fifoMayOverflow = false
        backend.onPost = { e in
            output.append(e.timestamp)
            postsInCallback += 1
            if case let .posting(gen) = commit.state, let at = claimedAt[gen],
               clock.nowNanos < at + config.postingHardCapNanos,
               finishing != gen, !windingDown, !replacingTap, !fifoMayOverflow {
                XCTFail("seed \(seed): a held key was replayed while worker \(gen) was posting, before the hard cap")
            }
        }
        var workers: [UInt64: (kind: Kind, claimed: Bool)] = [:]
        var seenSignals = 0
        var down: [UInt16] = []
        let letters: [UInt16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, KeyCode.space]
        let fail = { (what: String) in XCTFail("seed \(seed): \(what)") }

        func tick(_ ms: UInt64) {
            clock.advance(byMilliseconds: ms)
            if let due = backend.armedDeadline, due <= clock.nowNanos { backend.fireDeadline() }
        }

        func key(_ code: UInt16, down isDown: Bool, flags: UInt64 = 0) {
            tick(1 + UInt64(rng.below(30)))
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)!
            e.flags = CGEventFlags(rawValue: flags)
            e.timestamp = clock.nowNanos
            expected.append(e.timestamp)
            postsInCallback = 0
            fifoMayOverflow = engine.processor.heldCount >= config.holdBackCapacity - 1
            defer { fifoMayOverflow = false }
            let passed = backend.deliver(isDown ? .keyDown : .keyUp, e) ?? true // no tap: straight to the app
            if passed {
                if postsInCallback > 0 { fail("a key passed in a callback that also re-posted held keys") }
                output.append(e.timestamp)
            }
        }

        func collectWorkers() {
            while seenSignals < signals.count {
                defer { seenSignals += 1 }
                switch signals[seenSignals] {
                case let .doubleShift(_, gen) where commit.state == .pending(gen: gen):
                    workers[gen] = (.convert, false)
                case let .wordEnded(_, gen) where commit.state == .pending(gen: gen):
                    workers[gen] = (.autoFix, false)
                default:
                    break
                }
            }
        }

        for _ in 0..<steps {
            let r = rng.below(100)
            switch r {
            case 0..<50:
                if !down.isEmpty, rng.below(2) == 0 {
                    key(down.remove(at: rng.below(down.count)), down: false)
                } else if down.count < 3 {
                    let code = letters[rng.below(letters.count)]
                    down.append(code)
                    key(code, down: true)
                }
            case 50..<58:
                tick(1)
                for (type, e) in T.doubleShift(at: clock.nowNanos / T.ms) {
                    _ = backend.deliver(type, e)
                }
                tick(200)
            case 58..<61:
                tick(5)
                _ = backend.deliver(.leftMouseDown, T.mouseDown(at: clock.nowNanos / T.ms))
            case 61..<71:
                if let gen = workers.filter({ !$0.value.claimed }).keys.sorted().first {
                    workers[gen]?.claimed = commit.claimPosting(gen: gen)
                    if workers[gen]?.claimed == true { claimedAt[gen] = clock.nowNanos }
                    if workers[gen]?.claimed == false { workers[gen] = nil } // abandoned: it never finishes
                }
            case 71..<81:
                if let gen = workers.keys.sorted().first, let w = workers.removeValue(forKey: gen) {
                    postsInCallback = 0
                    finishing = gen // QA: only the posting worker's own finish may replay under its claim
                    defer { finishing = nil }
                    engine.finishReplacement(gen: gen,
                                             newRendering: w.kind == .convert ? InputSourceID("com.apple.keylayout.Hebrew") : nil,
                                             bufferAfter: nil)
                }
            case 81..<84:
                key(8, down: true, flags: CGEventFlags.maskCommand.rawValue)
                key(8, down: false, flags: CGEventFlags.maskCommand.rawValue)
            case 84:
                engine.reset(.contextChange)
            case 85:
                _ = backend.deliver(.tapDisabledByTimeout, T.key(0))
                replacingTap = true
                backend.runSoonBlocks()
                replacingTap = false
            case 86:
                let target: TapMode = engine.mode == .active ? .listenOnly : .active
                replacingTap = true
                engine.applyMode(target, userInitiated: true)
                replacingTap = false
            case 87:
                backend.firePoll()
            case 92..<96:
                // P2-50 QA: a settings change. The hard cap stays (the B3 check above reads it).
                var c = config
                c.doubleShiftEnabled = rng.below(8) != 0 // mostly on, so the soak still holds keys
                c.autoFixEnabled = rng.below(2) == 0
                c.convertDeadlineNanos = UInt64(100 + rng.below(500)) * T.ms
                c.autoFixDeadlineNanos = UInt64(50 + rng.below(300)) * T.ms
                c.doubleShift.windowNanos = UInt64(200 + rng.below(400)) * T.ms
                c.doubleShift.sides = [.either, .sameSide, .leftOnly, .sameSide, .either, .rightOnly][rng.below(6)]
                c.mode = rng.below(2) == 0 ? .listenOnly : .off // ignored: the mode follows the tap
                c.holdBackCapacity = 1 + rng.below(4)          // ignored: the FIFO is sized at init
                let mode = engine.processor.mode
                engine.perform(.updateConfig(c))
                if engine.processor.mode != mode { fail("updateConfig changed the mode") }
                if engine.processor.config.holdBackCapacity != config.holdBackCapacity {
                    fail("updateConfig changed the FIFO capacity")
                }
            case 88..<92:
                // A worker that never finishes (stuck), past the hard cap.
                tick(400 + UInt64(rng.below(1_200)))
            default:
                tick(UInt64(rng.below(120)))
            }
            collectWorkers()

            if engine.heldCGEventCount != engine.processor.heldCount {
                fail("CGEvent FIFO (\(engine.heldCGEventCount)) desynced from the processor (\(engine.processor.heldCount))")
                return
            }
            if engine.processor.heldCount > 0, backend.armedDeadline == nil {
                fail("keys are held but no deadline is armed")
                return
            }
        }

        // Wind down: let the workers finish, wait past every cap, and stop. Nothing may stay behind.
        windingDown = true
        for (gen, w) in workers.sorted(by: { $0.key < $1.key }) {
            engine.finishReplacement(gen: gen, newRendering: w.kind == .convert ? InputSourceID("com.apple.keylayout.Hebrew") : nil,
                                     bufferAfter: nil)
        }
        tick(3_000)
        tick(3_000)
        engine.applyMode(.off, userInitiated: true)
        XCTAssertEqual(engine.heldCGEventCount, 0, "seed \(seed)")
        XCTAssertGreaterThan(backend.posted.count, 10, "seed \(seed): the soak must exercise hold and replay")
        if output != expected {
            let firstDiff = zip(output, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            fail("delivered \(output.count) of \(expected.count) key events; first difference at \(String(describing: firstDiff))")
        }
    }
}
