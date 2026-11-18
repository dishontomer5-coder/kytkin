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

    // P4-3 QA: an update downloads only from this repository's GitHub releases.
    func testTrustedDownloadIsOnlyThisRepositorysReleaseDMG() {
        func ok(_ s: String) -> Bool { UpdaterConfiguration.isTrustedDownload(URL(string: s)) }
        XCTAssertTrue(ok(Appcast.downloadURL(version: "1.1.1")), "what make-appcast writes")
        XCTAssertTrue(ok("https://GitHub.com/dishontomer5-coder/kytkin/releases/download/v1.2.0/Kytkin-1.2.0.dmg"))
        XCTAssertFalse(UpdaterConfiguration.isTrustedDownload(nil))
        XCTAssertFalse(ok("http://github.com/dishontomer5-coder/kytkin/releases/download/v1.1.1/Kytkin-1.1.1.dmg"))
        XCTAssertFalse(ok("https://evil.example/dishontomer5-coder/kytkin/releases/download/v1.1.1/Kytkin-1.1.1.dmg"))
        XCTAssertFalse(ok("https://github.com.evil.example/dishontomer5-coder/kytkin/releases/download/v1/K.dmg"))
        XCTAssertFalse(ok("https://github.com/someone-else/kytkin/releases/download/v1.1.1/Kytkin-1.1.1.dmg"))
        XCTAssertFalse(ok("https://github.com/dishontomer5-coder/kytkin/releases/download/../../../x/K.dmg"))
        XCTAssertFalse(ok("https://u:p@github.com/dishontomer5-coder/kytkin/releases/download/v1/K.dmg"))
        XCTAssertFalse(ok("https://github.com:8443/dishontomer5-coder/kytkin/releases/download/v1/K.dmg"))
        XCTAssertFalse(ok("https://github.com/dishontomer5-coder/kytkin/releases/download/v1/K.dmg?x=1"))
        XCTAssertFalse(ok("https://github.com/dishontomer5-coder/kytkin/releases/download/v1/Kytkin.zip"))
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
