// P2-5: Import validation (001 §4.3): every rejected case names what's wrong.

import XCTest

final class LayoutMapValidationTests: XCTestCase {
    private func assertInvalid(_ fixture: String, _ expected: LayoutMapError,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try Fixtures.data("layoutmaps/invalid/\(fixture).json", file: file, line: line)
        XCTAssertThrowsError(try LayoutMap.validate(data), fixture, file: file, line: line) { error in
            XCTAssertEqual(error as? LayoutMapError, expected, fixture, file: file, line: line)
        }
    }

    // MARK: Format and version

    func testWrongFormat() throws { try assertInvalid("format-wrong", .wrongFormat("some-other-format")) }
    func testMissingFormat() throws { try assertInvalid("format-missing", .wrongFormat(nil)) }
    func testFutureVersion() throws { try assertInvalid("version-2", .unsupportedVersion(2)) }
    func testMissingVersion() throws { try assertInvalid("version-missing", .unsupportedVersion(nil)) }
    func testVersionAsString() throws { try assertInvalid("version-string", .unsupportedVersion(nil)) }

    // MARK: Key codes

    func testKeyCodeAbove127() throws { try assertInvalid("keycode-128", .invalidKeyCode("128")) }
    func testNegativeKeyCode() throws { try assertInvalid("keycode-negative", .invalidKeyCode("-1")) }
    func testNonNumericKeyCode() throws { try assertInvalid("keycode-not-number", .invalidKeyCode("a")) }
    func testNonCanonicalKeyCode() throws { try assertInvalid("keycode-leading-zero", .invalidKeyCode("07")) }
    func testDeadKeyCodeOutOfRange() throws { try assertInvalid("deadkey-keycode-200", .invalidKeyCode("200")) }

    // MARK: Layers and strings

    func testUnknownLayer() throws { try assertInvalid("layer-unknown", .unknownLayer(keyCode: 0, layer: "control")) }
    func testUnknownDeadKeyLayer() throws {
        try assertInvalid("deadkey-layer-unknown", .unknownLayer(keyCode: 14, layer: "command"))
    }
    func testEmptyString() throws { try assertInvalid("string-empty", .emptyString(keyCode: 0, layer: .plain)) }
    func testMoreThanFourGraphemes() throws {
        try assertInvalid("string-too-long", .tooManyCharacters(keyCode: 0, layer: .plain))
    }
    func testLayerValueNotAString() throws { try assertInvalid("layer-wrong-type", .wrongType(field: "keys.0.plain")) }
    func testControlCharacterInCell() throws {
        try assertInvalid("string-control-char", .controlCharacter(keyCode: 0, layer: .plain))
    }

    // MARK: Fields and structure

    func testMalformedJSON() throws {
        let data = try Fixtures.data("layoutmaps/invalid/malformed.json")
        XCTAssertThrowsError(try LayoutMap.validate(data)) { error in
            guard case .malformedJSON(let detail)? = error as? LayoutMapError else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty)
        }
    }
    func testRootIsNotAnObject() throws { try assertInvalid("root-array", .wrongType(field: "(root)")) }
    func testMissingName() throws { try assertInvalid("name-missing", .missingField("name")) }
    func testMissingKeys() throws { try assertInvalid("keys-missing", .missingField("keys")) }
    func testUnknownSource() throws { try assertInvalid("source-unknown", .invalidSource("cloud")) }
    func testEmptyID() throws { try assertInvalid("id-empty", .emptyID) }
    func testAppleIDIsReserved() throws { try assertInvalid("id-reserved", .reservedID("com.apple.keylayout.Hebrew")) }
    func testUserMapNeedsBase() throws { try assertInvalid("user-without-base", .missingBase) }
    func testUserMapWithEmptyBaseNeedsBase() throws { try assertInvalid("user-base-empty", .missingBase) }

    // MARK: Hostile input (must throw, never crash)

    private static func map(_ extra: String = "", cell: String = #"{ "plain": "a" }"#) -> Data {
        Data(("{ \"format\": \"kytkin-layoutmap\", \"version\": 1, \"id\": \"user.t\", \"name\": \"T\", "
              + "\"language\": \"he\", \"source\": \"imported\", \"keys\": { \"0\": \(cell) }\(extra) }").utf8)
    }

    func testDeepNestingIsRejectedNotACrash() {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        for data in [Data(deep.utf8), Self.map(", \"extra\": \(deep)")] {
            XCTAssertThrowsError(try LayoutMap.validate(data)) {
                guard case .malformedJSON? = $0 as? LayoutMapError else { return XCTFail("got \($0)") }
            }
        }
    }

    func testHugeAndFractionalNumbersAreRejected() {
        XCTAssertThrowsError(try LayoutMap.validate(Self.map(", \"kbdType\": 99999999999999999999999")))
        XCTAssertThrowsError(try LayoutMap.validate(Self.map(", \"kbdType\": 1.5")))
        let fractionalVersion = Data(#"{ "format": "kytkin-layoutmap", "version": 1.5 }"#.utf8)
        XCTAssertThrowsError(try LayoutMap.validate(fractionalVersion)) {
            XCTAssertEqual($0 as? LayoutMapError, .unsupportedVersion(nil))
        }
    }

    func testNullCellValueIsAWrongType() {
        XCTAssertThrowsError(try LayoutMap.validate(Self.map(cell: #"{ "plain": null }"#))) {
            XCTAssertEqual($0 as? LayoutMapError, .wrongType(field: "keys.0.plain"))
        }
    }

    func testEmptyInputIsMalformed() {
        XCTAssertThrowsError(try LayoutMap.validate(Data())) {
            guard case .malformedJSON? = $0 as? LayoutMapError else { return XCTFail("got \($0)") }
        }
    }

    func testDeadKeyListsAreNormalized() throws {
        let map = try LayoutMap.validate(Self.map(#", "deadKeys": { "0": ["option", "plain", "option"], "1": [] }"#))
        XCTAssertEqual(map.deadKeys, [0: [.plain, .option]])
    }

    func testFileOver256KBIsRejectedBeforeParsing() {
        let data = Data(repeating: UInt8(ascii: " "), count: LayoutMap.maxFileBytes + 1)
        XCTAssertThrowsError(try LayoutMap.validate(data)) {
            XCTAssertEqual($0 as? LayoutMapError, .fileTooLarge(bytes: LayoutMap.maxFileBytes + 1))
        }
    }

    func testFileOfExactly256KBIsNotRejectedForSize() throws {
        var data = try Fixtures.data("layoutmaps/sample-user.json")
        data.append(Data(repeating: UInt8(ascii: " "), count: LayoutMap.maxFileBytes - data.count))
        XCTAssertEqual(data.count, LayoutMap.maxFileBytes)
        XCTAssertNoThrow(try LayoutMap.validate(data))
    }

    // MARK: Valid imports

    func testValidUserMapKeepsItsUserID() throws {
        let map = try LayoutMap.validate(Fixtures.data("layoutmaps/sample-user.json"))
        XCTAssertEqual(map.id, InputSourceID("user.he-custom"))
        XCTAssertEqual(map, try JSONDecoder().decode(LayoutMap.self, from: Fixtures.data("layoutmaps/sample-user.json")))
    }

    func testImportedIDGetsUserPrefix() throws {
        let map = try LayoutMap.validate(Fixtures.data("layoutmaps/sample-imported.json"))
        XCTAssertEqual(map.id, InputSourceID("user.he-niqqud"))
    }

    func testValidatedMapRoundTripsThroughValidate() throws {
        let map = try LayoutMap.validate(Fixtures.data("layoutmaps/sample-imported.json"))
        XCTAssertEqual(try LayoutMap.validate(map.jsonData()), map)
    }

    func testErrorsHaveAMessageNamingTheKey() {
        XCTAssertTrue(LayoutMapError.unknownLayer(keyCode: 12, layer: "control").message.contains("12"))
        XCTAssertTrue(LayoutMapError.unknownLayer(keyCode: 12, layer: "control").message.contains("control"))
        XCTAssertTrue(LayoutMapError.invalidKeyCode("128").message.contains("128"))
        XCTAssertTrue(LayoutMapError.unsupportedVersion(2).message.contains("2"))
    }
}
