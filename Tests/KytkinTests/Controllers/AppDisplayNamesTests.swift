// P2-22: the menu's app-name cache: hits are looked up once, misses fall back to the bundle ID and are retried.

import XCTest

@MainActor
final class AppDisplayNamesTests: XCTestCase {
    private var lookups: [String] = []

    private func make(_ table: [String: String], capacity: Int = 128) -> AppDisplayNames {
        AppDisplayNames(capacity: capacity) { [unowned self] id in
            self.lookups.append(id)
            return table[id]
        }
    }

    func testHitIsLookedUpOnce() {
        let names = make(["com.apple.Notes": "Notes"])
        XCTAssertEqual(names.name(for: "com.apple.Notes"), "Notes")
        XCTAssertEqual(names.name(for: "com.apple.Notes"), "Notes")
        XCTAssertEqual(lookups, ["com.apple.Notes"])
    }

    func testMissFallsBackToTheBundleIDAndIsRetried() {
        let names = make([:])
        XCTAssertEqual(names.name(for: "com.example.new"), "com.example.new")
        XCTAssertEqual(names.name(for: "com.example.new"), "com.example.new")
        XCTAssertEqual(lookups.count, 2, "an app installed later still gets its name")
        XCTAssertEqual(names.cachedCount, 0)
    }

    func testBlankNameIsAMiss() {
        let names = make(["a": "  "])
        XCTAssertEqual(names.name(for: "a"), "a")
    }

    func testBoundedCacheStartsOver() {
        let names = make(["a": "A", "b": "B", "c": "C"], capacity: 2)
        _ = names.name(for: "a")
        _ = names.name(for: "b")
        XCTAssertEqual(names.cachedCount, 2)
        XCTAssertEqual(names.name(for: "c"), "C")
        XCTAssertEqual(names.cachedCount, 1)
        XCTAssertEqual(names.name(for: "a"), "A")
        XCTAssertEqual(lookups, ["a", "b", "c", "a"])
    }
}
