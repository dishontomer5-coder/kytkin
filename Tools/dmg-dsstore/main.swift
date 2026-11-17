// P6-2: writes the Finder layout (.DS_Store) of Kytkin's DMG window without AppleScript (no Apple Events, no Finder
// window: CLAUDE.md "Owner's machine is live"). Dev-only tool, compiled by scripts/package-dmg with swiftc into
// build/tools/. It is never part of the app target (project.yml).
//
//   dmg-dsstore write  <mounted volume> <volume name> <background path in volume> <win w>x<win h> <icon size> \
//                      <name>=<x>,<y> ...
//   dmg-dsstore verify <mounted volume>     resolves the background alias and prints the positions (a self-check)
//
// The .DS_Store format: a "buddy allocator" file holding one B-tree ("DSDB") of records (file name, 4-char code,
// typed value). It is undocumented by Apple. This writer follows the public descriptions of the format (Mark Mentovai's
// and Wim Lewis' write-ups, the Python `ds_store` / `mac_alias` projects' format notes, MIT/BSD); no code was copied.
// Records written for "." (the window): `bwsp` (window: bounds, no toolbar/sidebar/status bar), `icvp` (icon view:
// icon size, picture background as a classic Carbon alias to the image), `vstl` = icnv (icon view), `vSrn` = 1;
// per item: `Iloc` (icon centre). Everything fits in one leaf node.

import Foundation

// MARK: - Big-endian helpers

extension Data {
    mutating func u8(_ v: UInt8) { append(v) }
    mutating func u16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xffff)) }
    mutating func code(_ s: String) { precondition(s.utf8.count == 4); append(contentsOf: Array(s.utf8)) }
    mutating func utf16BE(_ s: String) { for u in s.utf16 { u16(u) } }
    func u32(at i: Int) -> UInt32 {
        (UInt32(self[startIndex + i]) << 24) | (UInt32(self[startIndex + i + 1]) << 16)
            | (UInt32(self[startIndex + i + 2]) << 8) | UInt32(self[startIndex + i + 3])
    }
    func u16(at i: Int) -> UInt16 { (UInt16(self[startIndex + i]) << 8) | UInt16(self[startIndex + i + 1]) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dmg-dsstore: \(message)\n".utf8))
    exit(1)
}

/// Seconds since 1904-01-01 (HFS dates), as stored in an alias record.
func hfsSeconds(_ date: Date) -> UInt32 { UInt32(clamping: Int64(date.timeIntervalSince1970) + 2_082_844_800) }

func statOrFail(_ path: String) -> stat {
    var st = stat()
    guard lstat(path, &st) == 0 else { fail("can't stat \(path)") }
    return st
}

// MARK: - Classic alias record (version 2), for icvp.backgroundImageAlias

/// An alias to `relPath` (e.g. ".background/background.tiff") on the volume mounted at `volume` named `volName`.
/// Finder resolves it by volume name + creation date and the file's CNID (on HFS+ the inode number), falling back to
/// the paths in the extra tags.
func aliasRecord(volume: String, volName: String, relPath: String) -> Data {
    let volURL = URL(fileURLWithPath: volume)
    guard let volCreated = try? volURL.resourceValues(forKeys: [.volumeCreationDateKey]).volumeCreationDate else {
        fail("no volume creation date for \(volume)")
    }
    let components = relPath.split(separator: "/").map(String.init)
    guard let fileName = components.last, components.count >= 2 else { fail("background must be in a folder") }
    let parentName = components[components.count - 2]
    let target = statOrFail(volume + "/" + relPath)
    let parent = statOrFail(volume + "/" + components.dropLast().joined(separator: "/"))
    // CNIDs of every folder from the target's parent up to (not including) the volume root.
    var cnidPath: [UInt32] = []
    var walk = components.dropLast()
    while !walk.isEmpty {
        cnidPath.append(UInt32(truncatingIfNeeded: statOrFail(volume + "/" + walk.joined(separator: "/")).st_ino))
        walk = walk.dropLast()
    }

    func pascal(_ s: String, size: Int) -> Data {
        let bytes = Array(s.utf8.prefix(size))
        var d = Data([UInt8(bytes.count)])
        d.append(contentsOf: bytes)
        d.append(contentsOf: [UInt8](repeating: 0, count: size - bytes.count))
        return d
    }

    var a = Data()
    a.u32(0)                                   // application-specific / creator
    a.u16(0)                                   // record length, patched below
    a.u16(2)                                   // version 2
    a.u16(0)                                   // kind: file
    a.append(pascal(volName, size: 27))        // volume name (Str27)
    a.u32(hfsSeconds(volCreated))              // volume creation date
    a.append(contentsOf: Array("H+".utf8))     // file system type
    a.u16(5)                                   // disk type: ejectable (a mounted disk image)
    a.u32(UInt32(truncatingIfNeeded: parent.st_ino))   // parent folder CNID
    a.append(pascal(fileName, size: 63))       // target name (Str63)
    a.u32(UInt32(truncatingIfNeeded: target.st_ino))   // target CNID
    a.u32(hfsSeconds(Date(timeIntervalSince1970: TimeInterval(target.st_birthtimespec.tv_sec))))
    a.u32(0); a.u32(0)                         // file type, creator
    a.u16(0xffff); a.u16(0xffff)               // levels from / to: -1, -1 (not used)
    a.u32(0)                                   // volume attributes
    a.u16(0)                                   // volume file system ID
    a.append(Data(count: 10))                  // reserved
    precondition(a.count == 150, "alias header is 150 bytes")

    func tag(_ t: UInt16, _ data: Data) {
        a.u16(t); a.u16(UInt16(data.count)); a.append(data)
        if data.count % 2 == 1 { a.u8(0) }
    }
    func unicode(_ s: String) -> Data { var d = Data(); d.u16(UInt16(s.utf16.count)); d.utf16BE(s); return d }
    tag(0, Data(parentName.utf8))                                    // parent folder name
    var cnids = Data(); cnidPath.forEach { cnids.u32($0) }; tag(1, cnids)   // CNID path
    tag(2, Data((volName + ":" + components.joined(separator: ":")).utf8))  // Carbon path
    tag(14, unicode(fileName))                                       // Unicode file name
    tag(15, unicode(volName))                                        // Unicode volume name
    tag(18, Data(("/" + relPath).utf8))                              // POSIX path on the volume
    tag(19, Data(("/Volumes/" + volName).utf8))                      // POSIX path of the mount point
    a.u16(0xffff); a.u16(0)                                          // end
    let length = UInt16(a.count)
    a[4] = UInt8(length >> 8); a[5] = UInt8(length & 0xff)
    return a
}

// MARK: - Records and the .DS_Store file

enum Value {
    case long(UInt32), type(String), blob(Data)
}

struct Record {
    let name: String
    let code: String
    let value: Value

    var encoded: Data {
        var d = Data()
        d.u32(UInt32(name.utf16.count)); d.utf16BE(name); d.code(code)
        switch value {
        case .long(let v): d.code("long"); d.u32(v)
        case .type(let t): d.code("type"); d.code(t)
        case .blob(let b): d.code("blob"); d.u32(UInt32(b.count)); d.append(b)
        }
        return d
    }
}

func plist(_ object: [String: Any]) -> Data {
    do { return try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) } catch {
        fail("plist: \(error)")
    }
}

/// Lays out the buddy-allocated file: header (32 bytes) at 0, the DSDB header block at 32 (32 bytes), the allocator's
/// root block at 2048 (2 KiB) and the one leaf node at 4096 (4 KiB). Offsets are relative to byte 4 of the file.
func dsStore(records: [Record]) -> Data {
    let sorted = records.sorted {
        let a = $0.name.lowercased(), b = $1.name.lowercased()
        return a != b ? a.utf16.lexicographicallyPrecedes(b.utf16) : $0.code < $1.code
    }
    var leaf = Data()
    leaf.u32(0)                                  // P = 0: a leaf
    leaf.u32(UInt32(sorted.count))
    sorted.forEach { leaf.append($0.encoded) }
    guard leaf.count <= 4096 else { fail("records don't fit in one node") }
    leaf.append(Data(count: 4096 - leaf.count))

    var dsdb = Data()
    dsdb.u32(2)            // root node: block 2
    dsdb.u32(0)            // levels of internal nodes
    dsdb.u32(UInt32(sorted.count))
    dsdb.u32(1)            // nodes
    dsdb.u32(0x1000)       // page size
    dsdb.append(Data(count: 32 - dsdb.count))

    var root = Data()
    root.u32(3); root.u32(0)                     // block count, unknown
    let addresses: [UInt32] = [0x800 | 11, 0x20 | 5, 0x1000 | 12]   // offset | log2(size)
    for i in 0..<256 { root.u32(i < addresses.count ? addresses[i] : 0) }
    root.u32(1); root.u8(4); root.append(Data("DSDB".utf8)); root.u32(1)   // directory: "DSDB" → block 1
    // Free lists, one per log2 size 0...31: what isn't used in the 2^31 address space.
    // Used: [0,32) header, [32,64) DSDB, [2048,4096) root, [4096,8192) leaf.
    var free: [Int: [UInt32]] = [6: [64], 7: [128], 8: [256], 9: [512], 10: [1024]]
    for k in 13...30 { free[k] = [UInt32(1) << UInt32(k)] }
    for k in 0..<32 {
        let list = free[k] ?? []
        root.u32(UInt32(list.count)); list.forEach { root.u32($0) }
    }
    guard root.count <= 2048 else { fail("root block overflow") }
    root.append(Data(count: 2048 - root.count))

    var body = Data(count: 8192)                 // the allocator's address space we use: [0, 8192)
    var header = Data()
    header.append(Data("Bud1".utf8))
    header.u32(0x800); header.u32(0x800); header.u32(0x800)
    header.append(Data([0x00, 0x00, 0x10, 0x0c, 0x00, 0x00, 0x00, 0x87, 0x00, 0x00, 0x20, 0x0b, 0x00, 0x00, 0x00, 0x00]))
    body.replaceSubrange(0..<32, with: header)
    body.replaceSubrange(32..<64, with: dsdb)
    body.replaceSubrange(2048..<4096, with: root)
    body.replaceSubrange(4096..<8192, with: leaf)
    var file = Data()
    file.u32(1)                                  // magic
    file.append(body)
    return file
}

// MARK: - Reading back (verify)

func readRecords(_ file: Data) -> [(String, String, String, Data)] {
    guard file.count >= 4 + 8192, file.u32(at: 0) == 1, file[4..<8] == Data("Bud1".utf8) else { fail("not a DS_Store") }
    let node = 4 + 4096
    let count = Int(file.u32(at: node + 4))
    var i = node + 8
    var out: [(String, String, String, Data)] = []
    for _ in 0..<count {
        let n = Int(file.u32(at: i)); i += 4
        var units: [UInt16] = []
        for k in 0..<n { units.append(file.u16(at: i + 2 * k)) }
        i += 2 * n
        let name = String(decoding: units, as: UTF16.self)
        let code = String(decoding: file[i..<i + 4], as: UTF8.self); i += 4
        let type = String(decoding: file[i..<i + 4], as: UTF8.self); i += 4
        var data = Data()
        switch type {
        case "long", "type": data = file[i..<i + 4]; i += 4
        case "blob": let len = Int(file.u32(at: i)); data = file[i + 4..<i + 4 + len]; i += 4 + len
        default: fail("unexpected type \(type)")
        }
        out.append((name, code, type, Data(data)))
    }
    return out
}

func verify(volume: String) {
    guard let file = FileManager.default.contents(atPath: volume + "/.DS_Store") else { fail("no .DS_Store") }
    var ok = true
    for (name, code, _, data) in readRecords(file) {
        switch code {
        case "Iloc": print("Iloc \(name): (\(data.u32(at: 0)), \(data.u32(at: 4)))")
        case "bwsp":
            let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            print("bwsp WindowBounds: \(p?["WindowBounds"] ?? "?")")
        case "icvp":
            let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            print("icvp iconSize: \(p?["iconSize"] ?? "?") backgroundType: \(p?["backgroundType"] ?? "?")")
            guard let alias = p?["backgroundImageAlias"] as? Data else { ok = false; print("icvp: no alias"); continue }
            // The system's own alias resolver (alias record → bookmark → URL), as Finder would resolve it.
            guard let bookmark = CFURLCreateBookmarkDataFromAliasRecord(kCFAllocatorDefault, alias as CFData)?
                    .takeRetainedValue() as Data? else { ok = false; print("alias: not a valid alias record"); continue }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  bookmarkDataIsStale: &stale) {
                print("alias resolves to: \(url.path)")
            } else {
                ok = false; print("alias: does not resolve")
            }
        default: print("\(code) \(name)")
        }
    }
    exit(ok ? 0 : 1)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: see the header of Tools/dmg-dsstore/main.swift") }
switch args[1] {
case "verify":
    verify(volume: args[2])
case "write":
    guard args.count >= 8 else { fail("write needs: volume volname background WxH iconsize name=x,y...") }
    let volume = args[2], volName = args[3], background = args[4]
    let wh = args[5].split(separator: "x").compactMap { Int($0) }
    guard wh.count == 2, let iconSize = Int(args[6]) else { fail("bad window size or icon size") }
    let alias = aliasRecord(volume: volume, volName: volName, relPath: background)
    // Window frame in screen points; Finder's WindowBounds include the title bar (~28 pt), so the content is w x h.
    let bounds = "{{200, 120}, {\(wh[0]), \(wh[1] + 28)}}"
    var records: [Record] = [
        Record(name: ".", code: "bwsp", value: .blob(plist([
            "WindowBounds": bounds, "ShowToolbar": false, "ShowSidebar": false, "ContainerShowSidebar": false,
            "ShowStatusBar": false, "ShowPathbar": false, "ShowTabView": false, "SidebarWidth": 0,
        ]))),
        Record(name: ".", code: "icvp", value: .blob(plist([
            "viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": alias,
            "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
            "iconSize": Double(iconSize), "textSize": 13.0, "gridSpacing": 100.0, "gridOffsetX": 0.0,
            "gridOffsetY": 0.0, "labelOnBottom": true, "showIconPreview": true, "showItemInfo": false,
            "arrangeBy": "none", "scrollPositionX": 0.0, "scrollPositionY": 0.0,
        ]))),
        Record(name: ".", code: "vSrn", value: .long(1)),
        Record(name: ".", code: "vstl", value: .type("icnv")),
    ]
    for item in args[7...] {
        let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
        let xy = parts.count == 2 ? parts[1].split(separator: ",").compactMap { UInt32($0) } : []
        guard xy.count == 2 else { fail("bad item \(item) (want name=x,y)") }
        guard FileManager.default.fileExists(atPath: volume + "/" + parts[0]) else { fail("no \(parts[0]) on volume") }
        var loc = Data(); loc.u32(xy[0]); loc.u32(xy[1]); loc.append(Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0]))
        records.append(Record(name: parts[0], code: "Iloc", value: .blob(loc)))
    }
    do { try dsStore(records: records).write(to: URL(fileURLWithPath: volume + "/.DS_Store")) } catch {
        fail("write: \(error)")
    }
default:
    fail("unknown command \(args[1])")
}
