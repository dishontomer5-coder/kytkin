// P2-12: WordBuffer bounds (64 strokes / 3 words), boundaries, Backspace, invalidation, re-rendering.

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

    func testBoundaryStartsNewWordAndKeepsAtMostThree() {
        var b = WordBuffer()
        for w: UInt16 in 0..<5 {
            type(&b, [w, w])
            XCTAssertTrue(b.boundary())
        }
        type(&b, [9])
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.strokes, [s(9)])
        XCTAssertEqual(snap.previousWords, [[s(3), s(3)], [s(4), s(4)]])
        XCTAssertEqual(b.wordCount, 3)
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
        type(&b, Array(repeating: 1, count: 40))
        b.boundary()
        type(&b, Array(repeating: 2, count: 30))
        XCTAssertLessThanOrEqual(b.strokeCount, WordBuffer.maxStrokes)
        let snap = b.snapshot(renderedIn: nil)
        XCTAssertEqual(snap.strokes.count, 30)
        XCTAssertEqual(snap.previousWords, []) // the 40-stroke word was dropped to make room
    }

    func testNeverHoldsMoreThan64Strokes() {
        var b = WordBuffer()
        for i in 0..<500 {
            b.append(s(UInt16(i % 50)))
            if i % 7 == 0 { b.boundary() }
            XCTAssertLessThanOrEqual(b.strokeCount, WordBuffer.maxStrokes)
            XCTAssertLessThanOrEqual(b.wordCount, WordBuffer.maxWords)
        }
    }

    func testWordLongerThanCapOverflowsUntilBoundary() {
        var b = WordBuffer()
        type(&b, [5])
        b.boundary()
        type(&b, Array(repeating: 1, count: 65))
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

    func testExactly64StrokesFit() {
        var b = WordBuffer()
        type(&b, Array(repeating: 1, count: 64))
        XCTAssertTrue(b.snapshot(renderedIn: nil).isValid)
        XCTAssertEqual(b.strokeCount, 64)
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
        type(&b, Array(repeating: 1, count: 70))
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
        b.replaceCurrentWord(with: Array(repeating: s(1), count: 65))
        XCTAssertTrue(b.isEmpty)
    }
}
