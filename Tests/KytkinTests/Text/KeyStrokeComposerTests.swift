// P2-18: KeyStrokeComposer and SyntheticKeyEvent: chunking at grapheme boundaries, the control-character guard and
// the `ours` marker. (P2-59: the scan before the caret is RunBeforeCaret now, see RunBeforeCaretTests.)

import XCTest

final class KeyStrokeComposerTests: XCTestCase {
    // MARK: - Events

    func testEveryEventIsMarkedOursWithNoFlags() {
        let events = (KeyStrokeComposer.backspaces(3) ?? []) + (KeyStrokeComposer.typing("שלום world") ?? [])
        XCTAssertEqual(events.count, 6 + 2)
        for e in events {
            XCTAssertEqual(e.marker, 0x4B59544B)
            XCTAssertEqual(EventOrigin(userData: e.marker), .ours)
            XCTAssertEqual(e.modifierFlags, 0)
            XCTAssertTrue(e.isSafeToPost)
        }
        // Down/up pairs.
        XCTAssertEqual(events.map(\.isKeyDown), [true, false, true, false, true, false, true, false])
    }

    func testControlCharactersAreNeverTypable() {
        for bad in ["\n", "a\tb", "\r", "\u{2028}", "\u{2029}", "\u{1B}", "\u{7F}", "a\u{0}", "\u{85}"] {
            XCTAssertNil(KeyStrokeComposer.typing(bad), bad.debugDescription)
            XCTAssertNil(SyntheticKeyEvent.text(Array(bad.utf16), keyDown: true), bad.debugDescription)
        }
        XCTAssertNil(KeyStrokeComposer.typing(""))
        // Spaces and no-break spaces are fine (an auto-fix types its trigger Space).
        XCTAssertNotNil(KeyStrokeComposer.typing("שלום "))
        XCTAssertNotNil(KeyStrokeComposer.typing("a\u{00A0}b"))
    }

    func testUnsafeUnicodeEventsAreRejected() {
        XCTAssertNil(SyntheticKeyEvent.text([], keyDown: true))
        XCTAssertNil(SyntheticKeyEvent.text(Array(repeating: 0x61, count: 17), keyDown: true))
        XCTAssertNil(SyntheticKeyEvent.text([0xD83D], keyDown: true), "a lone surrogate")
        XCTAssertNotNil(SyntheticKeyEvent.text(Array(repeating: 0x61, count: 16), keyDown: true))
    }

    func testBackspaceBounds() {
        XCTAssertNil(KeyStrokeComposer.backspaces(0))
        XCTAssertNil(KeyStrokeComposer.backspaces(-1))
        XCTAssertNil(KeyStrokeComposer.backspaces(KeyStrokeComposer.maxBackspaces + 1))
        XCTAssertEqual(KeyStrokeComposer.backspaces(2)?.map(\.keyCode), [51, 51, 51, 51])
    }

    // MARK: - Chunking

    func testShortTextIsOneEvent() {
        XCTAssertEqual(KeyStrokeComposer.chunks("שלום"), [Array("שלום".utf16)])
    }

    func testChunksAreAtMost16UnitsAndKeepGraphemesWhole() {
        let text = String(repeating: "שָׁ", count: 10) + "👨‍👩‍👧" + String(repeating: "a", count: 20)
        let chunks = KeyStrokeComposer.chunks(text)
        XCTAssertTrue(chunks.allSatisfy { (1...16).contains($0.count) })
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        // Every chunk decodes to whole graphemes of the original text.
        var rebuilt: [Character] = []
        for c in chunks { rebuilt += Array(String(decoding: c, as: UTF16.self)) }
        XCTAssertEqual(rebuilt, Array(text))
    }

    func testOversizedGraphemeSplitsBetweenScalarsOnly() {
        // The Scotland flag tag sequence: 1 grapheme, 7 scalars, 14 units; two of them make a 28-unit cluster run.
        let flag = "🏴󠁧󠁢󠁳󠁣󠁴󠁿"
        let zwjRun = Array(repeating: "👩‍💻", count: 4).joined(separator: "\u{200D}")   // one long ZWJ grapheme
        XCTAssertEqual(zwjRun.count, 1)
        XCTAssertGreaterThan(zwjRun.utf16.count, 16)
        for text in [flag + flag, zwjRun] {
            let chunks = KeyStrokeComposer.chunks(text)
            XCTAssertTrue(chunks.allSatisfy { (1...16).contains($0.count) })
            XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
            for c in chunks {
                // No chunk splits a surrogate pair (the chunk round-trips) …
                XCTAssertEqual(Array(String(decoding: c, as: UTF16.self).utf16), c, "no split surrogates")
                // … and P3-55: an emoji is never typed at all.
                XCTAssertNil(SyntheticKeyEvent.text(c, keyDown: true), "P3-55: objects are never posted")
            }
        }
    }

    func testObjectsAreNeverPosted() {
        // P3-55: the owner's Slack box got a typed copy holding a literal U+FFFC.
        for text in ["שלום \u{FFFC} שלום", "😄", "a\u{FFFD}b", "👍🏽"] {
            XCTAssertNil(SyntheticKeyEvent.text(Array(text.utf16), keyDown: true), text)
        }
        XCTAssertNotNil(SyntheticKeyEvent.text(Array("שלום akuo".utf16), keyDown: true))
    }

    func testTextSymbolsALayoutTypesAreStillPosted() {
        // P3-55 QA: the object guard refuses emoji, not text symbols a layout types or invisible marks it produces.
        for text in ["\u{2122}", "\u{263A}", "\u{2194}", "\u{200F}", "\u{200E}", "\u{200C}", "\u{200D}",
                     "\u{05E9}\u{05C1}\u{05BC}", "\u{20AA}", "\u{00A9}"] {
            XCTAssertNotNil(SyntheticKeyEvent.text(Array(text.utf16), keyDown: true), text)
        }
        for text in ["\u{2764}\u{FE0F}", "1\u{FE0F}\u{20E3}", "\u{1F468}\u{200D}\u{1F469}", "\u{1F600}"] {
            XCTAssertNil(SyntheticKeyEvent.text(Array(text.utf16), keyDown: true), text)
        }
    }
}
