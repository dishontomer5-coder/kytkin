// P4-3: Config/Info.plist (the real file, read from the repository) carries Sparkle's keys exactly as
// UpdaterConfiguration requires: the stable feed, nothing automatic, no system profile; and the public-key check.

import XCTest

final class UpdaterConfigurationTests: XCTestCase {
    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/KytkinTests/Updates/this.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Config/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheRealInfoPlistMatches() throws {
        XCTAssertEqual(UpdaterConfiguration.infoPlistProblems(try infoPlist()), [])
    }

    func testTheFeedIsTheLatestReleasesAsset() {
        XCTAssertEqual(UpdaterConfiguration.feedURL,
                       "https://github.com/dishontomer5-coder/kytkin/releases/latest/download/appcast.xml")
    }

    func testProblemsAreFound() throws {
        var info = try infoPlist()
        info["SUEnableSystemProfiling"] = true
        info["SUScheduledCheckInterval"] = 3600
        info["SUEnableAutomaticChecks"] = nil
        info["SUAutomaticallyUpdate"] = 0   // a number, not a boolean
        XCTAssertEqual(UpdaterConfiguration.infoPlistProblems(info).count, 4)
        XCTAssertTrue(UpdaterConfiguration.infoPlistProblems(info).contains("SUEnableAutomaticChecks is missing"))
    }

    func testAboutCreditsSparkle() {
        let acks = AboutInfo(infoDictionary: [:]).acknowledgements
        XCTAssertEqual(acks.map(\.title), ["Public Suffix List", "Sparkle"])
        XCTAssertEqual(acks.last?.license, "MIT License")
    }

    func testPublicKeyCheck() throws {
        XCTAssertFalse(UpdaterConfiguration.isUsablePublicKey(nil))
        XCTAssertFalse(UpdaterConfiguration.isUsablePublicKey(""))
        XCTAssertFalse(UpdaterConfiguration.isUsablePublicKey("REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"))
        XCTAssertFalse(UpdaterConfiguration.isUsablePublicKey(Data(count: 31).base64EncodedString()))
        XCTAssertTrue(UpdaterConfiguration.isUsablePublicKey(Data(repeating: 7, count: 32).base64EncodedString()))
        // Until the owner pastes the real key, the shipped file has the placeholder (updates off by themselves).
        let key = try infoPlist()["SUPublicEDKey"] as? String
        XCTAssertNotNil(key)
    }
}
