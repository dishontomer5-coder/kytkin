// P2-5: `overlaid(on:)`: a user map's cells on top of its base (001 §2.2, §4.3).

import XCTest

final class LayoutMapOverlayTests: XCTestCase {
    private func load(_ name: String) throws -> LayoutMap {
        try JSONDecoder().decode(LayoutMap.self, from: Fixtures.data("layoutmaps/\(name)"))
    }

    func testOverrideLayerWinsAndOtherLayersComeFromBase() throws {
        let merged = try load("sample-user.json").overlaid(on: load("sample-hebrew-base.json"))
        // Key 25: the user changes shift only; plain is the same; capsLock is kept from the base.
        XCTAssertEqual(merged.keys[25], KeyCell(plain: "9", shift: ")", capsLock: "9"))
        // Key 0: plain/capsLock overridden with the same text; shift kept from the base.
        XCTAssertEqual(merged.keys[0], KeyCell(plain: "ש", shift: "A", capsLock: "a"))
    }

    func testBaseOnlyKeysAreKept() throws {
        let base = try load("sample-hebrew-base.json")
        let merged = try load("sample-user.json").overlaid(on: base)
        XCTAssertEqual(merged.keys[31], base.keys[31])
        XCTAssertEqual(merged.keys[14], base.keys[14])
        XCTAssertEqual(Set(merged.keys.keys), Set(base.keys.keys))
    }

    func testOverrideOnlyKeysAreAdded() {
        let base = LayoutMap(id: InputSourceID("com.apple.keylayout.B"), name: "B", language: "he",
                             source: .system, keys: [0: KeyCell(plain: "ש")])
        let user = LayoutMap(id: InputSourceID("user.b"), name: "B+", language: "he", source: .user,
                             base: base.id, keys: [50: KeyCell(plain: ";")])
        let merged = user.overlaid(on: base)
        XCTAssertEqual(merged.keys, [0: KeyCell(plain: "ש"), 50: KeyCell(plain: ";")])
    }

    func testIdentityComesFromTheOverride() throws {
        let base = try load("sample-hebrew-base.json")
        let merged = try load("sample-user.json").overlaid(on: base)
        XCTAssertEqual(merged.id, InputSourceID("user.he-custom"))
        XCTAssertEqual(merged.name, "Hebrew (custom)")
        XCTAssertEqual(merged.language, "he")
        XCTAssertEqual(merged.source, .user)
        XCTAssertEqual(merged.base, base.id)
    }

    func testKbdTypeFallsBackToBase() {
        let base = LayoutMap(id: InputSourceID("com.apple.keylayout.B"), name: "B", language: "en",
                             source: .system, kbdType: 45)
        var user = LayoutMap(id: InputSourceID("user.b"), name: "B", language: "en", source: .user, base: base.id)
        XCTAssertEqual(user.overlaid(on: base).kbdType, 45)
        user.kbdType = 61
        XCTAssertEqual(user.overlaid(on: base).kbdType, 61)
    }

    func testOverridingADeadCellClearsItsDeadMarkUnlessTheOverrideKeepsIt() {
        let base = LayoutMap(id: InputSourceID("com.apple.keylayout.ABC"), name: "ABC", language: "en",
                             source: .system, keys: [14: KeyCell(plain: "e", option: "´"), 32: KeyCell(option: "¨")],
                             deadKeys: [14: [.option], 32: [.option]])
        let user = LayoutMap(id: InputSourceID("user.abc"), name: "ABC+", language: "en", source: .user,
                             base: base.id, keys: [14: KeyCell(option: "é"), 34: KeyCell(option: "ˆ")],
                             deadKeys: [34: [.option]])
        let merged = user.overlaid(on: base)
        XCTAssertEqual(merged.keys[14], KeyCell(plain: "e", option: "é"))
        XCTAssertEqual(merged.deadKeys, [32: [.option], 34: [.option]])
    }

    func testOverrideCanMarkAnOverriddenCellDead() {
        let base = LayoutMap(id: InputSourceID("com.apple.keylayout.ABC"), name: "ABC", language: "en",
                             source: .system, keys: [14: KeyCell(plain: "e")], deadKeys: [14: [.shift]])
        let user = LayoutMap(id: InputSourceID("user.abc"), name: "ABC+", language: "en", source: .user,
                             base: base.id, keys: [14: KeyCell(option: "´")], deadKeys: [14: [.option]])
        XCTAssertEqual(user.overlaid(on: base).deadKeys, [14: [.shift, .option]])
    }

    func testEmptyOverrideReproducesTheBaseCells() throws {
        let base = try load("sample-system.json")
        let user = LayoutMap(id: InputSourceID("user.abc"), name: "ABC", language: "en", source: .user, base: base.id)
        let merged = user.overlaid(on: base)
        XCTAssertEqual(merged.keys, base.keys)
        XCTAssertEqual(merged.deadKeys, base.deadKeys)
    }

    func testOverlaidMapRoundTrips() throws {
        let merged = try load("sample-user.json").overlaid(on: load("sample-hebrew-base.json"))
        XCTAssertEqual(try JSONDecoder().decode(LayoutMap.self, from: merged.jsonData()), merged)
    }
}
