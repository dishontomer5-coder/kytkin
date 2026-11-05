// P2-5: Decoding and encoding `kytkin-layoutmap` v1 (001 §4.3) with hand-written fixtures.

import XCTest

final class LayoutMapCodecTests: XCTestCase {
    private func decode(_ fixture: String) throws -> LayoutMap {
        try JSONDecoder().decode(LayoutMap.self, from: Fixtures.data("layoutmaps/\(fixture)"))
    }

    func testDecodesSystemMap() throws {
        let map = try decode("sample-system.json")
        XCTAssertEqual(map.id, InputSourceID("com.apple.keylayout.ABC"))
        XCTAssertEqual(map.name, "ABC (hand-written sample)")
        XCTAssertEqual(map.language, "en")
        XCTAssertEqual(map.source, .system)
        XCTAssertNil(map.base)
        XCTAssertEqual(map.kbdType, 61)
        XCTAssertEqual(map.keys.count, 5)
        XCTAssertEqual(map.keys[0], KeyCell(plain: "a", shift: "A", capsLock: "A", option: "å", shiftOption: "Å"))
        XCTAssertEqual(map.keys[31], KeyCell(plain: "o", shift: "O", capsLock: "O"))
        XCTAssertEqual(map.keys[49]?.plain, " ")
        XCTAssertEqual(map.deadKeys, [14: [.option]])
    }

    func testDecodesUserMapFrom001Example() throws {
        let map = try decode("sample-user.json")
        XCTAssertEqual(map.id, InputSourceID("user.he-custom"))
        XCTAssertEqual(map.source, .user)
        XCTAssertEqual(map.base, InputSourceID("com.apple.keylayout.Hebrew"))
        XCTAssertEqual(map.keys[0], KeyCell(plain: "ש", capsLock: "a"))
        XCTAssertEqual(map.keys[25], KeyCell(plain: "9", shift: ")"))
        XCTAssertEqual(map.deadKeys, [14: [.option]])
    }

    func testOptionalFieldsDefaultAndUnknownTopLevelFieldsAreIgnored() throws {
        let map = try decode("sample-imported.json")
        XCTAssertEqual(map.source, .imported)
        XCTAssertNil(map.base)
        XCTAssertNil(map.kbdType)
        XCTAssertEqual(map.deadKeys, [:])
        XCTAssertEqual(map.keys[127], KeyCell(plain: "x"))
    }

    func testMultiScalarGraphemeCountsAsOneCharacter() throws {
        let map = try decode("sample-imported.json")
        XCTAssertEqual(map.keys[0]?.option, "שׁ")
        XCTAssertEqual(map.keys[38]?.shift, "לֹ")
    }

    func testFourGraphemesIsTheLimit() throws {
        let ok = try JSONDecoder().decode(LayoutMap.self, from: Self.json(cell: #"{ "plain": "abcd" }"#))
        XCTAssertEqual(ok.keys[0]?.plain, "abcd")
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutMap.self, from: Self.json(cell: #"{ "plain": "abcde" }"#))) {
            XCTAssertEqual($0 as? LayoutMapError, .tooManyCharacters(keyCode: 0, layer: .plain))
        }
    }

    func testEncodingWritesFormatVersionStringKeysAndOmitsEmptyLayers() throws {
        let map = LayoutMap(id: InputSourceID("user.t"), name: "T", language: "he", source: .user,
                            base: InputSourceID("com.apple.keylayout.Hebrew"),
                            keys: [7: KeyCell(plain: "z"), 120: KeyCell(shift: "Q")], deadKeys: [7: [.plain]])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: map.jsonData()) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "kytkin-layoutmap")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["source"] as? String, "user")
        XCTAssertEqual(object["base"] as? String, "com.apple.keylayout.Hebrew")
        XCTAssertNil(object["kbdType"])
        let keys = try XCTUnwrap(object["keys"] as? [String: [String: String]])
        XCTAssertEqual(keys, ["7": ["plain": "z"], "120": ["shift": "Q"]])
        XCTAssertEqual(object["deadKeys"] as? [String: [String]], ["7": ["plain"]])
    }

    func testEncodingLeavesOutEmptyDeadKeys() throws {
        let map = LayoutMap(id: InputSourceID("user.t"), name: "T", language: "en", source: .imported)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: map.jsonData()) as? [String: Any])
        XCTAssertNil(object["deadKeys"])
        XCTAssertNil(object["base"])
        XCTAssertEqual((object["keys"] as? [String: Any])?.count, 0)
    }

    func testRoundTripOfEveryValidFixture() throws {
        for name in ["sample-system.json", "sample-hebrew-base.json", "sample-user.json", "sample-imported.json"] {
            let map = try decode(name)
            let again = try JSONDecoder().decode(LayoutMap.self, from: map.jsonData())
            XCTAssertEqual(again, map, name)
        }
    }

    func testRoundTripOfEveryKeyCodeAndLayer() throws {
        var keys: [UInt16: KeyCell] = [:]
        for code in LayoutMap.keyCodeRange {
            var cell = KeyCell()
            for layer in KeyLayer.allCases { cell[layer] = "\(code)\(layer.rawValue.prefix(1))" }
            keys[code] = cell
        }
        let map = LayoutMap(id: InputSourceID("com.apple.keylayout.Full"), name: "Full", language: "en",
                            source: .system, kbdType: 45, keys: keys, deadKeys: [0: KeyLayer.allCases])
        XCTAssertEqual(try JSONDecoder().decode(LayoutMap.self, from: map.jsonData()), map)
    }

    func testExportIsStableAndSorted() throws {
        let map = try decode("sample-system.json")
        XCTAssertEqual(try map.jsonData(), try map.jsonData())
        let text = try XCTUnwrap(String(data: map.jsonData(), encoding: .utf8))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"format\"")).lowerBound,
                          try XCTUnwrap(text.range(of: "\"version\"")).lowerBound)
    }

    func testInputSourceIDEncodesAsBareString() throws {
        let data = try JSONEncoder().encode([InputSourceID("com.apple.keylayout.ABC")])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"["com.apple.keylayout.ABC"]"#)
    }

    func testKeyCellSubscriptAndDefinedLayers() {
        var cell = KeyCell()
        XCTAssertEqual(cell.definedLayers, [])
        for layer in KeyLayer.allCases { cell[layer] = layer.rawValue }
        XCTAssertEqual(cell, KeyCell(plain: "plain", shift: "shift", capsLock: "capsLock",
                                     option: "option", shiftOption: "shiftOption"))
        XCTAssertEqual(cell.definedLayers, KeyLayer.allCases)
        cell[.shift] = nil
        XCTAssertEqual(cell.definedLayers, [.plain, .capsLock, .option, .shiftOption])
    }

    func testKeyLayerRawValuesMatchTheJSONNames() {
        XCTAssertEqual(KeyLayer.allCases.map(\.rawValue), ["plain", "shift", "capsLock", "option", "shiftOption"])
    }

    func testStrokeIsKeyCodePlusLayer() {
        XCTAssertEqual(Stroke(keyCode: 0, layer: .shift), Stroke(keyCode: 0, layer: .shift))
        XCTAssertNotEqual(Stroke(keyCode: 0, layer: .shift), Stroke(keyCode: 0, layer: .capsLock))
        XCTAssertNotEqual(Stroke(keyCode: 0, layer: .plain), Stroke(keyCode: 1, layer: .plain))
    }

    static func json(cell: String) -> Data {
        Data(#"{ "format": "kytkin-layoutmap", "version": 1, "id": "user.t", "name": "T", "language": "he", "source": "imported", "keys": { "0": \#(cell) } }"#.utf8)
    }
}
