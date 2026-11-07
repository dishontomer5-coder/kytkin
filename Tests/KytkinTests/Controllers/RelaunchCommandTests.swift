// P2-22 QA: "Quit & Reopen"'s command. The script is run headlessly with /bin/echo standing in for `open`,
// so no test ever opens an app.

import XCTest

final class RelaunchCommandTests: XCTestCase {
    private let trickyPath = "/Applications/Kytkin Dev\"; touch /tmp/kytkin-pwned; \".app $(id) `id`"

    func testThePathAndPidAreArgumentsNotScript() {
        let args = RelaunchCommand.arguments(pid: 4242, bundlePath: trickyPath)
        XCTAssertEqual(args.count, 6)
        XCTAssertEqual(args[0], "-c")
        XCTAssertFalse(args[1].contains("Kytkin Dev"), "the path is never pasted into the script")
        XCTAssertFalse(args[1].contains("4242"))
        XCTAssertEqual(Array(args[3...]), ["4242", trickyPath, "/usr/bin/open"])
        XCTAssertEqual(RelaunchCommand.shell, "/bin/sh")
    }

    /// The process is gone: the opener gets the exact path, spaces and quotes included, and nothing else runs.
    func testOpensTheExactPathOnceTheProcessHasExited() throws {
        let (status, out) = try run(RelaunchCommand.arguments(pid: try deadPID(), bundlePath: trickyPath,
                                                               opener: "/bin/echo"))
        XCTAssertEqual(status, 0)
        XCTAssertEqual(out, trickyPath + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/kytkin-pwned"))
    }

    /// The process never exits (here: the test runner itself): the shell gives up and opens nothing.
    func testGivesUpWithoutOpeningWhenTheProcessDoesNotExit() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let (status, out) = try run(RelaunchCommand.arguments(pid: pid, bundlePath: "/x.app", opener: "/bin/echo",
                                                              maxPolls: 2))
        XCTAssertEqual(status, 1)
        XCTAssertEqual(out, "")
    }

    private func deadPID() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    private func run(_ arguments: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: RelaunchCommand.shell)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
