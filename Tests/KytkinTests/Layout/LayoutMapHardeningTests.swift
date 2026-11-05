// P2-30: LayoutMap import hardening (001 §4.3 "Hardening plan"): no system imports, file-name-safe ids,
// a scalar cap per cell, `jsonData()` refuses invalid maps, and one shared "typeable text" predicate.

import XCTest

final class LayoutMapHardeningTests: XCTestCase {
    private func assertInvalid(_ fixture: String, _ expected: LayoutMapError,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try Fixtures.data("layoutmaps/invalid/\(fixture).json", file: file, line: line)
        XCTAssertThrowsError(try LayoutMap.validate(data), fixture, file: file, line: line) { error in
            XCTAssertEqual(error as? LayoutMapError, expected, fixture, file: file, line: line)
        }
    }

    private static func json(id: String = "user.t", source: String = "imported", base: String? = nil,
                             plain: String = "a") throws -> Data {
        var object: [String: Any] = ["format": "kytkin-layoutmap", "version": 1, "id": id, "name": "T",
                                     "language": "he", "source": source, "keys": ["0": ["plain": plain]]]
        if let base { object["base"] = base }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func map(id: String = "user.t", source: LayoutMap.Source = .imported,
                            base: InputSourceID? = nil, keys: [UInt16: KeyCell] = [0: KeyCell(plain: "a")],
                            deadKeys: [UInt16: [KeyLayer]] = [:]) -> LayoutMap {
        LayoutMap(id: InputSourceID(id), name: "T", language: "he", source: source, base: base,
                  keys: keys, deadKeys: deadKeys)
    }

    private func assertEncodeThrows(_ map: LayoutMap, _ expected: LayoutMapError,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try map.jsonData(), file: file, line: line) {
            XCTAssertEqual($0 as? LayoutMapError, expected, file: file, line: line)
        }
    }

    // MARK: (1) system maps are export only

    func testSystemSourceIsRejectedOnImport() throws { try assertInvalid("source-system", .systemSourceImport) }

    func testSystemMapsStillDecodeAndExport() throws {
        let data = try Fixtures.data("layoutmaps/sample-system.json")
        let map = try JSONDecoder().decode(LayoutMap.self, from: data)
        XCTAssertEqual(map.source, .system)
        XCTAssertNoThrow(try map.jsonData(), "a system map with a com.apple. id is exportable")
    }

    func testReservedIDIsReportedBeforeSystemSource() throws {
        XCTAssertThrowsError(try LayoutMap.validate(Self.json(id: "com.apple.keylayout.ABC", source: "system"))) {
            XCTAssertEqual($0 as? LayoutMapError, .reservedID("com.apple.keylayout.ABC"))
        }
    }

    // MARK: (2) ids

    func testIDWithPathCharactersIsRejected() throws {
        try assertInvalid("id-bad-characters", .invalidIDCharacters("user.he/../custom"))
    }

    func testIDCharacterSet() throws {
        for bad in ["he custom", "he\u{0}x", "עברית", "ab:c", "a\\b", "é", "a\u{200E}", "a\n", "a*"] {
            XCTAssertThrowsError(try LayoutMap.validate(Self.json(id: bad)), bad.debugDescription) {
                XCTAssertEqual($0 as? LayoutMapError, .invalidIDCharacters("user." + bad), bad.debugDescription)
            }
        }
        for good in ["he-custom", "He_Custom.v2", "user.ABC-xyz_09", "0", "..", "user..", "-"] {
            XCTAssertNoThrow(try LayoutMap.validate(Self.json(id: good)), good)
        }
    }

    func testIDLengthLimitCountsTheUserPrefix() throws {
        // 60 characters + "user." = 65.
        try assertInvalid("id-too-long", .idTooLong(length: 65))
        let fiftyNine = String(repeating: "x", count: 59)
        XCTAssertEqual(try LayoutMap.validate(Self.json(id: fiftyNine)).id.rawValue.count, 64)
        let prefixed64 = "user." + fiftyNine
        XCTAssertNoThrow(try LayoutMap.validate(Self.json(id: prefixed64)))
        XCTAssertThrowsError(try LayoutMap.validate(Self.json(id: prefixed64 + "x"))) {
            XCTAssertEqual($0 as? LayoutMapError, .idTooLong(length: 65))
        }
    }

    func testIDThatIsOnlyTheUserPrefixIsRejected() throws {
        try assertInvalid("id-only-prefix", .idOnlyPrefix)
        // "user" without the dot is a name: it becomes "user.user".
        XCTAssertEqual(try LayoutMap.validate(Self.json(id: "user")).id, InputSourceID("user.user"))
    }

    func testExistingIDRulesStillHold() throws {
        XCTAssertEqual(try LayoutMap.validate(Self.json(id: "he-custom")).id, InputSourceID("user.he-custom"))
        XCTAssertEqual(try LayoutMap.validate(Self.json(id: "user.he")).id, InputSourceID("user.he"))
        XCTAssertThrowsError(try LayoutMap.validate(Self.json(id: "com.apple.x"))) {
            XCTAssertEqual($0 as? LayoutMapError, .reservedID("com.apple.x"))
        }
    }

    func testReservedIDPrefixIgnoresCase() throws {
        // QA (P2-30): Apple's namespace in any case is reserved, on import and on export.
        for id in ["COM.APPLE.x", "Com.Apple.keylayout.ABC", "com.Apple."] {
            XCTAssertThrowsError(try LayoutMap.validate(Self.json(id: id)), id) {
                XCTAssertEqual($0 as? LayoutMapError, .reservedID(id), id)
            }
            assertEncodeThrows(Self.map(id: id), .reservedID(id))
        }
        // Only the prefix counts: "com.applex" and "user.com.apple.x" are ordinary names.
        XCTAssertEqual(try LayoutMap.validate(Self.json(id: "com.applex")).id, InputSourceID("user.com.applex"))
        XCTAssertNoThrow(try LayoutMap.validate(Self.json(id: "user.COM.APPLE.x")))
    }

    // MARK: (3) scalar cap

    func testMoreThan16ScalarsInOneGraphemeIsRejected() throws {
        try assertInvalid("string-too-many-scalars", .tooManyScalars(keyCode: 0, layer: .plain))
    }

    func testExactly16ScalarsIsAccepted() throws {
        let sixteen = "a" + String(repeating: "\u{0301}", count: 15)
        XCTAssertEqual(sixteen.count, 1)
        XCTAssertEqual(sixteen.unicodeScalars.count, 16)
        XCTAssertEqual(try LayoutMap.validate(Self.json(plain: sixteen)).keys[0]?.plain, sixteen)
    }

    func testGraphemeLimitIsStillReportedFirst() throws {
        XCTAssertThrowsError(try LayoutMap.validate(Self.json(plain: String(repeating: "a\u{0301}\u{0301}\u{0301}\u{0301}", count: 5)))) {
            XCTAssertEqual($0 as? LayoutMapError, .tooManyCharacters(keyCode: 0, layer: .plain))
        }
    }

    // MARK: (5) shared typeable-text predicate

    func testPrivateUseAndSeparatorsAreRejectedOnImport() throws {
        try assertInvalid("string-private-use", .untypeableCharacter(keyCode: 0, layer: .plain))
        try assertInvalid("string-line-separator", .untypeableCharacter(keyCode: 0, layer: .plain))
        try assertInvalid("string-paragraph-separator", .untypeableCharacter(keyCode: 0, layer: .plain))
    }

    func testControlCharacterKeepsItsOwnError() throws {
        // A Cc next to a Zl still reports the control character.
        XCTAssertThrowsError(try LayoutMap.validate(Self.json(plain: "\u{2028}\n"))) {
            XCTAssertEqual($0 as? LayoutMapError, .controlCharacter(keyCode: 0, layer: .plain))
        }
    }

    func testTypeablePredicate() {
        for kept: Unicode.Scalar in ["a", "ש", "\u{05B9}", "\u{200E}", "\u{200F}", "\u{00A0}", " ", "€", "\u{1F600}"] {
            XCTAssertTrue(LayoutMap.isTypeable(kept), String(kept.value, radix: 16))
        }
        for rejected: Unicode.Scalar in ["\u{0}", "\n", "\t", "\u{7F}", "\u{85}", "\u{F700}", "\u{E000}",
                                          "\u{F8FF}", "\u{F0000}", "\u{2028}", "\u{2029}"] {
            XCTAssertFalse(LayoutMap.isTypeable(rejected), String(rejected.value, radix: 16))
        }
    }

    func testBuilderAndImporterAgree() throws {
        let samples = ["a", "ש", "לֹ", "\u{200E}", "\u{200F}", "\u{00A0}", "", "\r", "\u{F700}", "\u{2028}",
                       "a\u{2029}", "abcde", "a" + String(repeating: "\u{0301}", count: 15),
                       "a" + String(repeating: "\u{0301}", count: 16)]
        for text in samples {
            let builderKeeps = LayoutMapBuilder.typedText(text) != nil
            let importerAccepts = (try? LayoutMap.validate(Self.json(plain: text))) != nil
            XCTAssertEqual(builderKeeps, importerAccepts, text.debugDescription)
            XCTAssertEqual(builderKeeps, LayoutMap.cellViolation(text) == nil, text.debugDescription)
        }
    }

    func testBuilderDropsSeparatorsAndLongCombiningRuns() {
        let map = LayoutMapBuilder.build(id: InputSourceID("com.apple.keylayout.Test"), name: "Test",
                                         language: "xx", kbdType: nil) { code, layer in
            switch (code, layer) {
            case (0, .plain): .text("\u{2028}")
            case (1, .plain): .text("a" + String(repeating: "\u{0301}", count: 16))
            case (2, .plain): .text("\u{200F}")
            case (3, .option): .dead("\u{2029}")
            default: nil
            }
        }
        XCTAssertEqual(map.keys, [2: KeyCell(plain: "\u{200F}")])
        XCTAssertTrue(map.deadKeys.isEmpty)
        XCTAssertNoThrow(try map.jsonData())
    }

    // MARK: (4) jsonData refuses invalid maps

    func testEncodeRefusesKeyCodeOver127() {
        assertEncodeThrows(Self.map(keys: [128: KeyCell(plain: "a")]), .invalidKeyCode("128"))
        assertEncodeThrows(Self.map(deadKeys: [200: [.plain]]), .invalidKeyCode("200"))
    }

    func testEncodeRefusesBadCells() {
        assertEncodeThrows(Self.map(keys: [3: KeyCell(shift: "")]), .emptyString(keyCode: 3, layer: .shift))
        assertEncodeThrows(Self.map(keys: [3: KeyCell(option: "abcde")]), .tooManyCharacters(keyCode: 3, layer: .option))
        assertEncodeThrows(Self.map(keys: [3: KeyCell(plain: "a" + String(repeating: "\u{0301}", count: 16))]),
                           .tooManyScalars(keyCode: 3, layer: .plain))
        assertEncodeThrows(Self.map(keys: [3: KeyCell(capsLock: "\n")]), .controlCharacter(keyCode: 3, layer: .capsLock))
        assertEncodeThrows(Self.map(keys: [3: KeyCell(shiftOption: "\u{F701}")]),
                           .untypeableCharacter(keyCode: 3, layer: .shiftOption))
    }

    func testEncodeRefusesBadIDsAndMissingBase() {
        assertEncodeThrows(Self.map(id: ""), .emptyID)
        assertEncodeThrows(Self.map(id: "com.apple.keylayout.ABC"), .reservedID("com.apple.keylayout.ABC"))
        assertEncodeThrows(Self.map(id: "a/b"), .invalidIDCharacters("user.a/b"))
        assertEncodeThrows(Self.map(id: String(repeating: "x", count: 60)), .idTooLong(length: 65))
        assertEncodeThrows(Self.map(id: "user."), .idOnlyPrefix)
        assertEncodeThrows(Self.map(source: .user), .missingBase)
        assertEncodeThrows(Self.map(source: .user, base: InputSourceID("")), .missingBase)
        assertEncodeThrows(Self.map(id: "", source: .system), .emptyID)
    }

    func testEncodedNonSystemMapsAlwaysImportAgain() throws {
        let maps = [Self.map(), Self.map(id: "no-prefix"),
                    Self.map(source: .user, base: InputSourceID("com.apple.keylayout.Hebrew"))]
        for map in maps {
            XCTAssertNoThrow(try LayoutMap.validate(map.jsonData()), map.id.rawValue)
        }
    }

    // MARK: Messages

    func testNewErrorsHaveUserFacingMessages() {
        let errors: [LayoutMapError] = [.systemSourceImport, .invalidIDCharacters("user.a/b"), .idTooLong(length: 65),
                                        .idOnlyPrefix, .tooManyScalars(keyCode: 7, layer: .shift),
                                        .untypeableCharacter(keyCode: 9, layer: .option)]
        for error in errors { XCTAssertFalse(error.message.isEmpty, "\(error)") }
        XCTAssertTrue(LayoutMapError.systemSourceImport.message.contains("imported"))
        XCTAssertTrue(LayoutMapError.idTooLong(length: 65).message.contains("65"))
        XCTAssertTrue(LayoutMapError.idTooLong(length: 65).message.contains("64"))
        XCTAssertTrue(LayoutMapError.tooManyScalars(keyCode: 7, layer: .shift).message.contains("Key 7, shift"))
        XCTAssertTrue(LayoutMapError.untypeableCharacter(keyCode: 9, layer: .option).message.contains("Key 9, option"))
        // The id isn't echoed: it may contain characters that don't display.
        XCTAssertFalse(LayoutMapError.invalidIDCharacters("user.a/b").message.contains("a/b"))
    }
}
