// P2-4: Loads test fixtures from the `Fixtures/` resource folder copied into the test bundle.

import Foundation
import XCTest

enum Fixtures {
    private final class BundleToken {}

    /// `Fixtures/<relativePath>` inside the test bundle, e.g. `url("layoutmaps/com.apple.keylayout.ABC.json")`.
    static func url(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let root = try XCTUnwrap(Bundle(for: BundleToken.self).resourceURL, file: file, line: line)
            .appendingPathComponent("Fixtures", isDirectory: true)
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing fixture: Fixtures/\(relativePath)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    static func data(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        try Data(contentsOf: url(relativePath, file: file, line: line))
    }
}
