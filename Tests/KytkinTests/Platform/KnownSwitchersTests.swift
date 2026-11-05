// P2-13: KnownSwitchers matching for the conflict warning (001 §2.2, R1 "Risks", P1-12).

import XCTest

final class KnownSwitchersTests: XCTestCase {
    func testFlicKeyByBundleID() {
        XCTAssertEqual(KnownSwitchers.match(bundleID: "com.talalfi.FlicKey", name: nil)?.name, "FlicKey")
        XCTAssertEqual(KnownSwitchers.match(bundleID: "COM.TALALFI.FLICKEY", name: "Renamed")?.name, "FlicKey")
    }

    func testByNameWhenBundleIDUnknown() {
        XCTAssertEqual(KnownSwitchers.match(bundleID: "com.example.unknown", name: "FlicKey")?.name, "FlicKey")
        XCTAssertEqual(KnownSwitchers.match(bundleID: nil, name: "Input Source Pro")?.name, "Input Source Pro")
        XCTAssertEqual(KnownSwitchers.match(bundleID: nil, name: "kawa")?.name, "Kawa")
        XCTAssertEqual(KnownSwitchers.match(bundleID: nil, name: "Punto Switcher")?.name, "Punto Switcher")
        XCTAssertEqual(KnownSwitchers.match(bundleID: nil, name: "Caramba Switcher")?.name, "Caramba Switcher")
    }

    func testNameMatchIsWholeWord() {
        XCTAssertNil(KnownSwitchers.match(bundleID: nil, name: "Kawasaki Tools"))
        XCTAssertNil(KnownSwitchers.match(bundleID: nil, name: "Input Source"))
        XCTAssertNil(KnownSwitchers.match(bundleID: nil, name: "Punto"))
        XCTAssertNil(KnownSwitchers.match(bundleID: nil, name: ""))
        XCTAssertNil(KnownSwitchers.match(bundleID: nil, name: nil))
    }

    func testOrdinaryAppsDontMatch() {
        XCTAssertNil(KnownSwitchers.match(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        XCTAssertNil(KnownSwitchers.match(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"))
    }

    func testKytkinItselfNeverMatches() {
        XCTAssertNil(KnownSwitchers.match(bundleID: "io.github.kytkin.Kytkin", name: "Kytkin"))
        XCTAssertNil(KnownSwitchers.match(bundleID: "io.github.kytkin.Kytkin.dev", name: "FlicKey"))
    }

    func testRunningListIsDedupedAndOrdered() {
        let apps: [(bundleID: String?, name: String?)] = [
            ("com.apple.Safari", "Safari"), (nil, "Kawa"), ("com.talalfi.FlicKey", "FlicKey"),
            ("com.example.flickey-helper", "FlicKey"),
        ]
        XCTAssertEqual(KnownSwitchers.running(in: apps), ["FlicKey", "Kawa"])
        XCTAssertEqual(KnownSwitchers.running(in: []), [])
    }

    func testEntriesAreWellFormed() {
        XCTAssertFalse(KnownSwitchers.entries.isEmpty)
        XCTAssertEqual(Set(KnownSwitchers.entries.map(\.name)).count, KnownSwitchers.entries.count)
        for e in KnownSwitchers.entries {
            XCTAssertFalse(e.nameContains.isEmpty, e.name)
            XCTAssertFalse(e.bundleIDs.contains { $0.lowercased().hasPrefix(KnownSwitchers.ownBundleIDPrefix) })
        }
    }
}
