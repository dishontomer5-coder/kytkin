// P6-0a: Draws one SwiftUI view to `<name>-light.png` and `<name>-dark.png` (at the screen's scale, 2x on a Retina
// Mac): a stand-alone NSHostingView is laid out and drawn into a bitmap with `cacheDisplay(in:to:)`. No window is
// shown, ever (see `inWindow` and OffscreenWindow).

import AppKit
import SwiftUI

@MainActor final class Renderer {
    let outDir: URL
    let filter: String?
    private(set) var count = 0

    init(outDir: URL, filter: String?) {
        self.outDir = outDir
        self.filter = filter
    }

    /// `size` nil = the view's own fitting size. `backdrop` is drawn behind the view (the window background by
    /// default; a darker "desktop" for the menu mock, so its edges show).
    /// `inWindow`: the view sits in an `OffscreenWindow` that is never shown, because SwiftUI `Table` (NSTableView)
    /// creates no rows without a window. Only the Rules screens need it; everything else is drawn with no window at
    /// all (in a window that never reaches a screen, grouped Forms draw their text at 1x). `controlActiveState = .key`
    /// makes controls draw their front-window look (blue switches), since this process is never the active app.
    /// `write: false` draws without saving (the warm-up).
    func render<V: View>(_ name: String, size: CGSize? = nil, backdrop: NSColor = .windowBackgroundColor,
                         inWindow: Bool = false, write: Bool = true, _ make: () -> V) throws {
        if write, let filter, !name.contains(filter) { return }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let root = make()
                .frame(width: size?.width, height: size?.height)
                .background(Color(nsColor: backdrop))
                .environment(\.colorScheme, dark ? .dark : .light)
                // P6-0e: the app's AccentColor asset (#0E7A66); the renderer has no asset catalog.
                .tint(Color(red: 0x0E / 255, green: 0x7A / 255, blue: 0x66 / 255))
                .environment(\.controlActiveState, .key)   // draw controls as in the front window
            let host = NSHostingView(rootView: root)
            host.appearance = appearance
            host.frame = CGRect(origin: .zero, size: size ?? CGSize(width: 800, height: 600))
            var window: OffscreenWindow?
            if inWindow {
                let w = OffscreenWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                                        defer: true)
                w.isReleasedWhenClosed = false
                w.appearance = appearance
                w.contentView = host
                window = w
            }
            settle(host)
            if size == nil {
                let fit = host.fittingSize
                let frame = CGRect(origin: .zero, size: CGSize(width: ceil(fit.width), height: ceil(fit.height)))
                window?.setContentSize(frame.size)
                host.frame = frame
                settle(host)
            }
            let png = try draw(host, appearance: appearance)
            window?.contentView = nil
            guard write else { continue }
            let url = outDir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try png.write(to: url)
            count += 1
        }
    }

    /// Lets SwiftUI finish layout (onAppear, observation updates) on the main run loop. No events are handled.
    private func settle(_ host: NSView) {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        host.layoutSubtreeIfNeeded()
    }

    private func draw(_ host: NSView, appearance: NSAppearance) throws -> Data {
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { throw RenderError.bitmap }
        appearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: bounds, to: rep)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError.png }
        return data
    }

    enum RenderError: Error { case bitmap, png }
}

/// P6-0a: a window that is never shown. It is created with `defer: true` and never ordered in, made key or
/// activated, so the window server never puts it on screen. It only *answers* "key" and "main", so controls draw
/// in their active colors (an inactive window draws switches and buttons grey).
final class OffscreenWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
