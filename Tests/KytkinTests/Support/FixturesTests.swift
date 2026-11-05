// P2-4: Smoke test that fixture files reach the test bundle (keeping their folder).

import XCTest

final class FixturesTests: XCTestCase {
    func testSmokeFixtureLoads() throws {
        let json = try JSONSerialization.jsonObject(with: Fixtures.data("smoke.json")) as? [String: String]
        XCTAssertEqual(json?["fixture"], "smoke")
    }
}
