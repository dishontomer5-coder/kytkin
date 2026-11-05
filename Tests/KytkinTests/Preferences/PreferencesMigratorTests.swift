// P2-8: The migration chain (001 §4.1): steps run in order on the raw JSON object, each stamps
// `schemaVersion`, a missing step fails, and the codec reports `migratedFrom`.

import XCTest

final class PreferencesMigratorTests: XCTestCase {
    /// A pretend future chain: v1 → v2 renames general.enabled to general.isOn; v2 → v3 puts it back
    /// and records the trail, so the test can see both ran, in order.
    private let chain = PreferencesMigrator(currentVersion: 3, steps: [
        .init(from: 2) { obj in
            var o = obj
            var general = o["general"] as? [String: Any] ?? [:]
            general["enabled"] = general.removeValue(forKey: "isOn")
            o["general"] = general
            o["trail"] = (o["trail"] as? [String] ?? []) + ["2→3"]
            return o
        },
        .init(from: 1) { obj in
            var o = obj
            var general = o["general"] as? [String: Any] ?? [:]
            general["isOn"] = general.removeValue(forKey: "enabled")
            o["general"] = general
            o["trail"] = (o["trail"] as? [String] ?? []) + ["1→2"]
            return o
        },
    ])

    func testStandardChainIsAtV1WithNoSteps() throws {
        XCTAssertEqual(PreferencesMigrator.standard.currentVersion, Preferences.currentSchemaVersion)
        XCTAssertEqual(Preferences.currentSchemaVersion, 1)
        let out = try PreferencesMigrator.standard.migrate(["a": 1], from: 1)
        XCTAssertEqual(out["a"] as? Int, 1)
    }

    func testStepsRunInOrderAndStampTheVersion() throws {
        let out = try chain.migrate(["schemaVersion": 1, "general": ["enabled": false]], from: 1)
        XCTAssertEqual(out["trail"] as? [String], ["1→2", "2→3"])
        XCTAssertEqual(out["schemaVersion"] as? Int, 3)
        XCTAssertEqual((out["general"] as? [String: Any])?["enabled"] as? Bool, false)
    }

    func testChainCanStartInTheMiddle() throws {
        let out = try chain.migrate(["general": ["isOn": false]], from: 2)
        XCTAssertEqual(out["trail"] as? [String], ["2→3"])
        XCTAssertEqual(out["schemaVersion"] as? Int, 3)
    }

    func testCurrentOrNewerVersionIsUntouched() throws {
        let out = try chain.migrate(["x": 1], from: 5)
        XCTAssertEqual(out.keys.sorted(), ["x"])
    }

    func testMissingStepFails() {
        let gap = PreferencesMigrator(currentVersion: 3, steps: [.init(from: 1) { $0 }])
        XCTAssertThrowsError(try gap.migrate([:], from: 1)) {
            XCTAssertEqual($0 as? PreferencesMigrator.Failure, .noPath(from: 2))
        }
    }

    func testCodecMigratesAndReportsTheOldVersion() throws {
        let v1 = Data(#"{"schemaVersion":1,"general":{"enabled":false,"learnFromManualSwitches":false}}"#.utf8)
        let r = try PreferencesCodec.decodeDetailed(v1, migrator: chain)
        XCTAssertEqual(r.migratedFrom, 1)
        XCTAssertNil(r.newerSchemaVersion)
        XCTAssertFalse(r.prefs.general.enabled, "the value survived both steps")
        XCTAssertFalse(r.prefs.general.learnFromManualSwitches)
    }

    func testCodecTreatsAFailingStepAsCorrupt() {
        struct Boom: Error {}
        let failing = PreferencesMigrator(currentVersion: 2, steps: [.init(from: 1) { _ in throw Boom() }])
        XCTAssertThrowsError(try PreferencesCodec.decodeDetailed(Data(#"{"schemaVersion":1}"#.utf8), migrator: failing)) {
            XCTAssertEqual($0 as? PreferencesCodec.DecodeError, .migrationFailed(from: 1))
        }
    }

    func testCodecReportsNoPathAsMigrationFailed() {
        let noSteps = PreferencesMigrator(currentVersion: 2, steps: [])
        XCTAssertThrowsError(try PreferencesCodec.decodeDetailed(Data(#"{"schemaVersion":1}"#.utf8), migrator: noSteps)) {
            XCTAssertEqual($0 as? PreferencesCodec.DecodeError, .migrationFailed(from: 1))
        }
    }

    func testMissingSchemaVersionCountsAsCurrent() throws {
        let r = try PreferencesCodec.decodeDetailed(Data("{}".utf8), migrator: chain)
        XCTAssertNil(r.migratedFrom)
    }
}
