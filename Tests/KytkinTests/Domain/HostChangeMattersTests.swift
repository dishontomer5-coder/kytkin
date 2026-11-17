// P3-19: the one "does this host change matter" rule shared by ContextAssembler and SwitchController.

import XCTest

final class HostChangeMattersTests: XCTestCase {
    private let overrides: Set<String> = ["mail.google.com"]
    private func matters(_ a: String?, _ b: String?) -> Bool {
        HostNormalizer.hostChangeMatters(a, b, hasOverride: overrides.contains)
    }

    func testTheSameHostNeverMatters() {
        XCTAssertFalse(matters("mail.google.com", "mail.google.com"))
        XCTAssertFalse(matters("Mail.Google.com.", "mail.google.com"), "compared after normalizing")
        XCTAssertFalse(matters(nil, nil))
    }

    func testAChangeMattersOnlyWhenEitherSideHasAnOverride() {
        XCTAssertTrue(matters("www.google.com", "mail.google.com"))
        XCTAssertTrue(matters("MAIL.google.com", "docs.google.com"), "the override is found after normalizing")
        XCTAssertFalse(matters("www.google.com", "docs.google.com"))
        XCTAssertFalse(matters(nil, "docs.google.com"))
        XCTAssertTrue(matters(nil, "mail.google.com"))
    }
}
