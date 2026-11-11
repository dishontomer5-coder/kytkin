// P2-12: WordBuffer bounds, boundaries, Backspace, invalidation, re-rendering.
// P3-33: no word limit; ≤ `WordBuffer.maxStrokes` (512) keys, letters plus spaces; the oldest word goes first.

import XCTest

final class WordBufferTests: XCTestCase {
    private func s(_ code: UInt16, _ layer: KeyLayer = .plain) -> Stroke { Stroke(keyCode: code, layer: layer) }

    private func type(_ buffer: inout WordBuffer, _ codes: [UInt16]) {
        for c in codes { buffer.append(s(c)) }
    }

    func testAppendAndSnapshot() {
        var b = WordBuffer()
        XCTAssertTrue(b.isEmpty)
        type(&b, [0, 1, 2])
        let snap = b.snapshot(renderedIn: InputSourceID("abc"))
        XCTAssertEqual(snap.strokes, [s(0), s(1), s(2)])
        XCTAssertEqual(snap.previousWords, [])
        XCTAssertEqual(snap.renderedIn, InputSourceID("abc"))
        XCTAssertTrue(snap.isValid)
    }

    func testEmptySnapshotIsInvalid() {
        XCTAssertFalse(WordBuffer().snapshot(renderedIn: nil).isValid)
    }

    /// P3-33: was "keeps at most three words"; now every word since the last reset is kept.
    func testBoundaryStartsNewWordAndKeepsEveryWord() {
        var b = WordBuffer()
        for w: UInt16 in 0..<5 {
            type(&b, [w, w])
            XCTAssertTrue(b.boundary())
        }
        type(&b, [9])
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.strokes, [s(9)])
        XCTAssertEqual(snap.previousWords, (0..<5).map { [s($0), s($0)] })
        XCTAssertEqual(snap.gaps, Array(repeating: 1, count: 5))
        XCTAssertEqual(b.wordCount, 6)
        XCTAssertEqual(b.keyCount, 16)
    }

    /// P3-33: a long buffer (100 words, 499 keys) is held whole.
    func testLongBufferHeldWhole() {
        var b = WordBuffer()
        for w in 0..<100 {
            type(&b, Array(repeating: UInt16(w % 50), count: 4))
            b.boundary()
        }
        XCTAssertEqual(b.keyCount, 500)
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.previousWords.count, 100)
        XCTAssertTrue(snap.strokes.isEmpty)
        XCTAssertEqual(snap.gaps.reduce(0, +), 100)
    }

    /// P3-33: at the cap the oldest whole words (and their spaces) go, so the buffer starts on a word boundary.
    func testCapDropsOldestWordsWithTheirSpaces() {
        var b = WordBuffer()
        for w in 0..<200 {   // 200 × (2 letters + 1 space) = 600 keys > 512
            type(&b, [UInt16(w % 100), UInt16(w % 100)])
            b.boundary()
            XCTAssertLessThanOrEqual(b.keyCount, WordBuffer.maxStrokes)
        }
        type(&b, [7])
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertLessThanOrEqual(b.keyCount, WordBuffer.maxStrokes)
        XCTAssertGreaterThan(b.keyCount, WordBuffer.maxStrokes - 3)   // only whole words were dropped
        XCTAssertEqual(snap.strokes, [s(7)])
        XCTAssertEqual(snap.previousWords.last, [s(99), s(99)])
        XCTAssertTrue(snap.previousWords.allSatisfy { $0.count == 2 })   // never a cut word
    }

    /// P3-33: spaces count toward the cap too, so the key path never backspaces more than `maxStrokes`.
    func testSpacesCountTowardTheCap() {
        var b = WordBuffer()
        type(&b, [1])
        b.boundary()
        type(&b, [2])
        b.boundary()                          // 4 keys: 1, space, 2, space
        for _ in 0..<509 { b.boundary() }     // 508 fill to 512; the 509th drops the first word
        XCTAssertEqual(b.keyCount, 511)
        XCTAssertEqual(b.snapshot(renderedIn: nil).previousWords, [[s(2)]])
        for _ in 0..<100 { b.boundary() }     // only spaces left to drop: nothing is known before the caret
        XCTAssertLessThanOrEqual(b.keyCount, WordBuffer.maxStrokes)
        XCTAssertTrue(b.isEmpty)
    }

    func testRepeatedWhitespaceMakesNoEmptyWords() {
        var b = WordBuffer()
        XCTAssertFalse(b.boundary())
        type(&b, [1])
        XCTAssertTrue(b.boundary())
        XCTAssertFalse(b.boundary())
        XCTAssertFalse(b.boundary())
        XCTAssertEqual(b.wordCount, 1)
        XCTAssertEqual(b.snapshot(renderedIn: nil).previousWords, [[s(1)]])
    }

    func testStrokeCapDropsOldestWords() {
        var b = WordBuffer()
        // P3-33: scaled to the 512 cap (was 40 + 30 against 64).
        type(&b, Array(repeating: 1, count: 300))
        b.boundary()
        type(&b, Array(repeating: 2, count: 250))
        XCTAssertLessThanOrEqual(b.keyCount, WordBuffer.maxStrokes)
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.strokes.count, 250)
        XCTAssertEqual(snap.previousWords, []) // the 300-stroke word was dropped to make room
    }

    /// P3-33: was "never more than 64 strokes / 3 words"; now never more than 512 keys, letters plus spaces.
    func testNeverHoldsMoreThanTheCap() {
        var b = WordBuffer()
        for i in 0..<3_000 {
            b.append(s(UInt16(i % 50)))
            if i % 7 == 0 { b.boundary() }
            if i % 13 == 0 { b.backspace() }
            XCTAssertLessThanOrEqual(b.keyCount, WordBuffer.maxStrokes)
            let snap = b.snapshot(renderedIn: nil)
            XCTAssertEqual(snap.strokes.count + snap.previousWords.reduce(0) { $0 + $1.count }
                           + snap.gaps.reduce(0, +), b.keyCount)
        }
    }

    func testWordLongerThanCapOverflowsUntilBoundary() {
        var b = WordBuffer()
        type(&b, [5])
        b.boundary()
        type(&b, Array(repeating: 1, count: WordBuffer.maxStrokes + 1))
        XCTAssertFalse(b.snapshot(renderedIn: nil).isValid)
        XCTAssertFalse(b.isEmpty)
        type(&b, [1, 1]) // still ignored
        XCTAssertEqual(b.strokeCount, 0)
        XCTAssertFalse(b.boundary())
        type(&b, [3])
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.strokes, [s(3)])
        XCTAssertTrue(snap.isValid)
    }

    func testExactlyMaxStrokesFit() {
        var b = WordBuffer()
        type(&b, Array(repeating: 1, count: WordBuffer.maxStrokes))
        XCTAssertTrue(b.snapshot(renderedIn: nil).isValid)
        XCTAssertEqual(b.strokeCount, WordBuffer.maxStrokes)
    }

    func testCapIs512() {
        XCTAssertEqual(WordBuffer.maxStrokes, 512)   // P3-33
        XCTAssertEqual(KeyStrokeComposer.maxBackspaces, WordBuffer.maxStrokes)
    }

    func testBackspaceInsideWord() {
        var b = WordBuffer()
        type(&b, [1, 2, 3])
        b.backspace()
        XCTAssertEqual(Array(b.currentWord), [s(1), s(2)])
    }

    func testBackspaceOverSingleSpaceRejoinsWord() {
        var b = WordBuffer()
        type(&b, [1, 2])
        b.boundary()
        b.backspace()
        XCTAssertEqual(Array(b.currentWord), [s(1), s(2)])
        XCTAssertEqual(b.snapshot(renderedIn: nil).previousWords, [])
    }

    func testBackspaceOverDoubleSpace() {
        var b = WordBuffer()
        type(&b, [1])
        b.boundary()
        b.boundary()
        b.backspace()
        XCTAssertTrue(b.currentWord.isEmpty)
        b.backspace()
        XCTAssertEqual(Array(b.currentWord), [s(1)])
    }

    func testBackspaceOnEmptyDoesNothing() {
        var b = WordBuffer()
        b.backspace()
        XCTAssertTrue(b.isEmpty)
    }

    func testBackspaceWhileOverflowedInvalidates() {
        var b = WordBuffer()
        type(&b, Array(repeating: 1, count: WordBuffer.maxStrokes + 6))
        b.backspace()
        XCTAssertTrue(b.isEmpty)
    }

    func testInvalidateClearsEverything() {
        var b = WordBuffer()
        type(&b, [1])
        b.boundary()
        type(&b, [2])
        b.invalidate()
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.wordCount, 0)
        b.backspace() // the old gap is forgotten too
        XCTAssertTrue(b.isEmpty)
    }

    func testReplaceCurrentWordKeepsPreviousWords() {
        var b = WordBuffer()
        type(&b, [1])
        b.boundary()
        type(&b, [2, 3])
        b.replaceCurrentWord(with: [s(2, .shift), s(3)])
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.strokes, [s(2, .shift), s(3)])
        XCTAssertEqual(snap.previousWords, [[s(1)]])
    }

    func testReplaceCurrentWordTooLongInvalidates() {
        var b = WordBuffer()
        type(&b, [1])
        b.replaceCurrentWord(with: Array(repeating: s(1), count: WordBuffer.maxStrokes + 1))
        XCTAssertTrue(b.isEmpty)
    }
}
