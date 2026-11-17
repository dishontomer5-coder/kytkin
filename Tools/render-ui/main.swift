// P6-0a: Headless UI renderer (dev-only; never part of the app target). Draws every Settings tab, the Add Website
// sheet, the welcome window's steps, the status-bar menu and the menu-bar label to PNG at 2x, in light and dark.
//
//   ./scripts/render-ui [OUT_DIR] [NAME_FILTER]
//
// Safety (CLAUDE.md "Owner's machine is live"): the process sets its activation policy to `.prohibited` (it can never
// become the active app or show a Dock icon), creates NO window at all (each SwiftUI view is drawn by a stand-alone
// NSHostingView with `cacheDisplay`, which needs no window), never calls NSApp.activate / orderFront / run, and runs
// only the main run loop briefly so SwiftUI can lay out. All data is fake (Sample.swift, Fakes.swift): no preferences
// file, TIS, TCC, System Settings, clipboard, Apple Events or other apps are touched.

import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: render-ui REPO_ROOT OUT_DIR [NAME_FILTER]\n".utf8))
    exit(2)
}
let repoRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
let filter = arguments.count >= 4 ? arguments[3] : nil

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    // P6-0e: the real menu-bar artwork from the repo (the app reads it from its bundle).
    MenuBarGlyph.resourceDirectory = repoRoot.appendingPathComponent("Resources/MenuBar", isDirectory: true)
    // P6-0e: the app icon the screens show (`NSImage.applicationIconName`); the renderer has no bundle icon. The
    // process can't show a Dock icon (activation policy .prohibited), so this only changes what is drawn.
    NSApplication.shared.applicationIconImage = NSImage(contentsOf: repoRoot.appendingPathComponent(
        "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png"))
    // P6-0g: About's icon (light and dark) from the asset catalog's PNGs; no app icons from this Mac in Rules.
    let aboutIcons = repoRoot.appendingPathComponent("Resources/Assets.xcassets/AboutIcon.imageset")
    AboutSettingsView.iconImage = { dark in
        NSImage(contentsOf: aboutIcons.appendingPathComponent(dark ? "AboutIcon-dark-256.png" : "AboutIcon-256.png"))
    }
    RuleIcon.appIcon = { _ in nil }
    do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let renderer = Renderer(outDir: outDir, filter: filter)
        try Screens(repoRoot: repoRoot).renderAll(with: renderer)
        print("✅ \(renderer.count) PNGs in \(outDir.path)")
    } catch {
        FileHandle.standardError.write(Data("render-ui failed: \(error)\n".utf8))
        exit(1)
    }
}
