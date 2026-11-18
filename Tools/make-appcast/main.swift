// P4-3: scripts/make-appcast's writer. Usage:
//   make-appcast <out.xml> <version> <build> <changelog.md> <sign_update output>
// Prints the problem and exits 1 when anything is off, so no broken feed is ever written.

import Foundation

let args = CommandLine.arguments
guard args.count == 6 else {
    FileHandle.standardError.write(Data("usage: make-appcast <out.xml> <version> <build> <changelog.md> <sign_update output>\n".utf8))
    exit(2)
}
let (out, version, build, changelogPath, signOutput) = (args[1], args[2], args[3], args[4], args[5])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-appcast: \(message)\n".utf8))
    exit(1)
}

guard let signed = Appcast.parseSignUpdateOutput(signOutput) else {
    fail("couldn't read sign_update's output (expected sparkle:edSignature=\"…\" length=\"…\")")
}
let changelog = (try? String(contentsOfFile: changelogPath, encoding: .utf8)) ?? ""
guard let notes = Appcast.changelogSection(changelog, version: version) else {
    fail("CHANGELOG.md has no \"## \(version)\" section")
}
let release = AppcastRelease(version: version, build: build, length: signed.length, edSignature: signed.signature,
                             published: Date(), notesMarkdown: notes)
do {
    let xml = try Appcast.xml(for: release)
    try Data(xml.utf8).write(to: URL(fileURLWithPath: out), options: .atomic)
} catch {
    fail("\(error)")
}
