// P2-6: The system LayoutMap fixtures made by `scripts/dump-layoutmap` (UCKeyTranslate on macOS 26, ANSI),
// and LayoutMapBuilder's filtering. Tests never touch TIS: they read the checked-in JSON.

import XCTest

final class SystemLayoutFixtureTests: XCTestCase {
    static let ids = ["ABC", "US", "Hebrew", "Hebrew-PC", "Hebrew-QWERTY"].map { "com.apple.keylayout.\($0)" }

    private func fixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> LayoutMap {
        let data = try Fixtures.data("layoutmaps/com.apple.keylayout.\(name).json", file: file, line: line)
        return try JSONDecoder().decode(LayoutMap.self, from: data)
    }

    // MARK: - Every fixture

    /// The decoder enforces the per-cell rules (no control characters, ≤ 4 graphemes, non-empty,
    /// key codes 0–127, known layers). Plus the import size limit. The `com.apple.` id rule is import-only.
    func testEveryFixtureDecodesAndPassesValidationRulesExceptReservedID() throws {
        for id in Self.ids {
            let data = try Fixtures.data("layoutmaps/\(id).json")
            XCTAssertLessThanOrEqual(data.count, LayoutMap.maxFileBytes, id)
            let map = try JSONDecoder().decode(LayoutMap.self, from: data)
            XCTAssertEqual(map.id.rawValue, id)
            XCTAssertEqual(map.source, .system, id)
            XCTAssertNil(map.base, id)
            XCTAssertEqual(map.kbdType, 61, "\(id): generated on ANSI")
            XCTAssertFalse(map.name.isEmpty, id)
            XCTAssertGreaterThan(map.keys.count, 60, id)

            // validate() itself, with the id moved out of Apple's namespace: everything else must pass.
            var renamed = map
            renamed.id = InputSourceID("user.fixture")
            XCTAssertNoThrow(try LayoutMap.validate(try renamed.jsonData()), id)
            // And the real id is rejected on import, as 001 §4.3 says.
            XCTAssertThrowsError(try LayoutMap.validate(data)) {
                XCTAssertEqual($0 as? LayoutMapError, .reservedID(id))
            }
        }
    }

    func testFixturesAreCanonicalEncoderOutput() throws {
        for id in Self.ids {
            let data = try Fixtures.data("layoutmaps/\(id).json")
            let map = try JSONDecoder().decode(LayoutMap.self, from: data)
            XCTAssertEqual(try map.jsonData(), data, "\(id): regenerate with scripts/dump-layoutmap")
        }
    }

    func testNoNonTextKeysInFixtures() throws {
        for id in Self.ids {
            let map = try JSONDecoder().decode(LayoutMap.self, from: try Fixtures.data("layoutmaps/\(id).json"))
            // Return, Tab, Delete, Esc, keypad Enter, arrows type control codes: those cells are dropped.
            // (Apple's Hebrew layouts do type LRM/RLM on Option+Esc, which is real text and is kept.)
            for code: UInt16 in [36, 48, 51, 53, 76, 123, 124, 125, 126] {
                XCTAssertNil(map.keys[code]?.plain, "\(id) key \(code)")
                XCTAssertNil(map.keys[code]?.shift, "\(id) key \(code)")
            }
            for (code, cell) in map.keys {
                for layer in cell.definedLayers {
                    XCTAssertEqual(LayoutMapBuilder.typedText(cell[layer]!), cell[layer], "\(id) \(code).\(layer)")
                }
            }
        }
    }

    // MARK: - Known keys (R6 §4)

    func testABC() throws {
        let abc = try fixture("ABC")
        XCTAssertEqual(abc.language, "en")
        XCTAssertEqual(abc.keys[0]?.plain, "a")
        XCTAssertEqual(abc.keys[0]?.shift, "A")
        XCTAssertEqual(abc.keys[0]?.capsLock, "A")
        XCTAssertEqual(abc.keys[25]?.shift, "(")
        XCTAssertEqual(abc.keys[18]?.plain, "1")
        XCTAssertEqual(abc.keys[83]?.plain, "1", "keypad 1")
        XCTAssertEqual(abc.keys[49]?.plain, " ")
        XCTAssertEqual(abc.keys[49]?.option, "\u{00A0}", "Option+Space = NBSP")
        // Dead keys: Option + ` e u i n (R6 §2), stored as the standalone accent.
        XCTAssertEqual(abc.deadKeys, [14: [.option], 32: [.option], 34: [.option], 45: [.option], 50: [.option]])
        XCTAssertEqual(abc.keys[14]?.option, "´")
    }

    func testUSMatchesABCInTheTextLayers() throws {
        let abc = try fixture("ABC"), us = try fixture("US")
        XCTAssertEqual(us.keys, abc.keys)
        XCTAssertEqual(us.deadKeys, abc.deadKeys)
    }

    func testAppleHebrew() throws {
        let he = try fixture("Hebrew")
        XCTAssertEqual(he.language, "he")
        XCTAssertEqual(he.keys[0]?.plain, "ש")
        XCTAssertEqual(he.keys[0]?.capsLock, "a", "Caps Lock types lowercase Latin")
        XCTAssertEqual(he.keys[25]?.shift, ")", "parentheses are swapped")
        XCTAssertEqual(he.keys[29]?.shift, "(")
        XCTAssertEqual(he.keys[33]?.plain, "]")
        XCTAssertEqual(he.keys[30]?.plain, "[")
        XCTAssertEqual(he.keys[13]?.plain, "\u{05F3}", "geresh")
        XCTAssertEqual(he.keys[39]?.shift, "\u{05F4}", "gershayim")
        XCTAssertEqual(he.keys[26]?.shift, "₪")
        XCTAssertNil(he.keys[1]?.shift, "Shift+letter types nothing for most letters")
        XCTAssertEqual(he.keys[1]?.option, "\u{200E}", "LRM is kept: invisible but real text")
        XCTAssertTrue(he.deadKeys.isEmpty)
        // "akuo" on ABC keys is "שלום"; final letters have their own keys.
        let akuo: [UInt16] = [0, 40, 32, 31]
        XCTAssertEqual(akuo.compactMap { he.keys[$0]?.plain }.joined(), "שלום")
        let finals: [UInt16: String] = [37: "ך", 31: "ם", 34: "ן", 41: "ף", 47: "ץ"]
        for (code, letter) in finals { XCTAssertEqual(he.keys[code]?.plain, letter) }
    }

    func testHebrewPC() throws {
        let pc = try fixture("Hebrew-PC")
        XCTAssertEqual(pc.keys[0]?.plain, "ש")
        XCTAssertEqual(pc.keys[0]?.shift, "A", "PC: Shift+letter = uppercase Latin")
        XCTAssertEqual(pc.keys[13]?.plain, "'", "PC: ASCII apostrophe, not geresh")
        XCTAssertEqual(pc.keys[26]?.shift, "&", "PC keeps &")
        XCTAssertEqual(pc.keys[25]?.shift, ")")
    }

    func testHebrewQWERTYIsPhonetic() throws {
        let q = try fixture("Hebrew-QWERTY")
        XCTAssertEqual(q.keys[0]?.plain, "א")
        XCTAssertEqual(q.keys[1]?.plain, "ס")
        XCTAssertEqual(q.keys[17]?.plain, "ת")
        XCTAssertEqual(q.keys[4]?.plain, "ה")
    }

    // MARK: - LayoutMapBuilder

    func testTypedTextFilter() {
        XCTAssertEqual(LayoutMapBuilder.typedText("ש"), "ש")
        XCTAssertEqual(LayoutMapBuilder.typedText("לֹ"), "לֹ")
        XCTAssertEqual(LayoutMapBuilder.typedText("\u{200F}"), "\u{200F}")
        XCTAssertEqual(LayoutMapBuilder.typedText("\u{00A0}"), "\u{00A0}")
        for bad in ["", "\r", "\t", "\u{1B}", "\u{7F}", "\u{03}", "\u{1C}", "\u{10}", "\u{F700}", "a\n", "abcde"] {
            XCTAssertNil(LayoutMapBuilder.typedText(bad), bad.debugDescription)
        }
    }

    func testBuilderKeepsTextDropsControlAndMarksDeadKeys() {
        let map = LayoutMapBuilder.build(id: InputSourceID("com.apple.keylayout.Test"), name: "Test",
                                         language: "xx", kbdType: 40) { code, layer in
            switch (code, layer) {
            case (0, .plain): .text("a")
            case (0, .option): .dead("´")
            case (1, .option): .dead("\u{1B}")   // filtered: not marked dead either
            case (36, _): .text("\r")
            case (127, .shift): .text("Z")
            default: nil
            }
        }
        XCTAssertEqual(map.source, .system)
        XCTAssertEqual(map.kbdType, 40)
        XCTAssertEqual(map.keys, [0: KeyCell(plain: "a", option: "´"), 127: KeyCell(shift: "Z")])
        XCTAssertEqual(map.deadKeys, [0: [.option]])
    }
}
