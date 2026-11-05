// P0-6: Tests for the pure language-list → menu-bar label mapping.

import XCTest

final class InputSourceLabelTests: XCTestCase {
    func testEnglish() {
        XCTAssertEqual(InputSourceLabel.label(forLanguages: ["en"]), "EN")
    }

    func testHebrew() {
        XCTAssertEqual(InputSourceLabel.label(forLanguages: ["he"]), "HE")
    }

    func testEmptyListIsUnknown() {
        XCTAssertEqual(InputSourceLabel.label(forLanguages: []), "?")
    }

    func testEmptyStringIsUnknown() {
        XCTAssertEqual(InputSourceLabel.label(forLanguages: [""]), "?")
    }

    func testRegionSuffixIsDropped() {
        XCTAssertEqual(InputSourceLabel.label(forLanguages: ["en-US"]), "EN")
        XCTAssertEqual(InputSourceLabel.label(forLanguages: ["zh_Hans"]), "ZH")
    }

    func testOnlyFirstLanguageIsUsed() {
        XCTAssertEqual(InputSourceLabel.label(forLanguages: ["he", "en"]), "HE")
    }
}
