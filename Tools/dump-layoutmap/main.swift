// P2-6: Headless tool that writes `kytkin-layoutmap` JSON for installed keyboard layouts (001 §8).
// It only reads layout data (TIS + UCKeyTranslate). It never selects, enables or switches an input
// source, opens no window and needs no permission. Build and run it with `scripts/dump-layoutmap`.
//
//   dump-layoutmap [--out DIR] [ID ...]   write DIR/<ID>.json (default: the five fixture layouts)
//   dump-layoutmap --list                 print the convertible layouts (installed, enabled or not)

import Foundation

let defaultIDs = ["ABC", "US", "Hebrew", "Hebrew-PC", "Hebrew-QWERTY"].map { "com.apple.keylayout.\($0)" }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dump-layoutmap: \(message)\n".utf8))
    exit(1)
}

var outDir = "Tests/KytkinTests/Fixtures/layoutmaps"
var ids: [String] = []
var list = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--out":
        guard let dir = args.popFirst() else { fail("--out needs a directory") }
        outDir = dir
    case "--list": list = true
    case "-h", "--help":
        FileHandle.standardOutput.write(Data("usage: dump-layoutmap [--out DIR] [ID ...] | --list\n".utf8))
        exit(0)
    case let option where option.hasPrefix("-"): fail("unknown option \(option) (see --help)")
    default: ids.append(arg)
    }
}

let provider = UCKeyTranslateLayoutMapProvider()

if list {
    for info in provider.convertibleLayouts(includeDisabled: true).sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
        let line = "\(info.id.rawValue)\t\(info.languageCode)\t\(info.isEnabled ? "enabled" : "disabled")\t\(info.name)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
    exit(0)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var skipped = 0
for raw in ids.isEmpty ? defaultIDs : ids {
    let id = InputSourceID(raw)
    guard let map = provider.map(for: id) else {
        FileHandle.standardError.write(Data("skipped \(raw): not installed or not a keyboard layout\n".utf8))
        skipped += 1
        continue
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(raw).json")
    do {
        try map.jsonData().write(to: url, options: .atomic)
    } catch {
        fail("can't write \(url.path): \(error)")
    }
    let dead = map.deadKeys.values.reduce(0) { $0 + $1.count }
    FileHandle.standardOutput.write(Data("wrote \(url.path) (\(map.keys.count) keys, \(dead) dead cells, kbdType \(map.kbdType.map(String.init) ?? "-"))\n".utf8))
}
exit(skipped == 0 ? 0 : 2)
