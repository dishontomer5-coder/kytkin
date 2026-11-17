// P6-0g (design v2 review, "Across the app" P3: "Menu-bar icon: outline 1.5 pt"): writes the six menu-bar template PDFs
// (`Resources/MenuBar/kytkin-menubar-{active,paused,off}-{a,b}.pdf`, 18 × 18 pt, black + alpha) from Claude Design's
// v2 SVG paths, with the outline half stroked at 1.5 pt instead of the export's 1.2 pt. Dev-only; never part of the
// app target. Run: xcrun swift Tools/menubar-glyphs/main.swift Resources/MenuBar
// The attention look stays drawn in code from the active PDF (MenuBarGlyph; the exported attention PDFs lost their
// mask).

import CoreGraphics
import Foundation

let outline: CGFloat = 1.5

/// The SVG paths (viewBox 0 0 18 18, y down): M/H/V, quarter-circle A after an H or V, C, Z. Absolute coordinates.
func path(_ d: String) -> CGPath {
    let p = CGMutablePath()
    var tokens = d.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)[...]
    var current = CGPoint.zero
    var lastWasHorizontal = true
    func num() -> CGFloat { CGFloat(Double(tokens.popFirst() ?? "0") ?? 0) }
    while let raw = tokens.popFirst() {
        let cmd = raw.prefix(1)
        if raw.count > 1 { tokens.insert(String(raw.dropFirst()), at: tokens.startIndex) }
        switch cmd {
        case "M":
            current = CGPoint(x: num(), y: num()); p.move(to: current)
        case "H":
            current = CGPoint(x: num(), y: current.y); p.addLine(to: current); lastWasHorizontal = true
        case "V":
            current = CGPoint(x: current.x, y: num()); p.addLine(to: current); lastWasHorizontal = false
        case "A":
            let r = num(); _ = num(); _ = num(); _ = num(); _ = num()
            let end = CGPoint(x: num(), y: num())
            let corner = lastWasHorizontal ? CGPoint(x: end.x, y: current.y) : CGPoint(x: current.x, y: end.y)
            p.addArc(tangent1End: corner, tangent2End: end, radius: r)
            current = end
            lastWasHorizontal.toggle()
        case "C":
            let c1 = CGPoint(x: num(), y: num()), c2 = CGPoint(x: num(), y: num())
            current = CGPoint(x: num(), y: num())
            p.addCurve(to: current, control1: c1, control2: c2)
        case "Z":
            p.closeSubpath()
        default:
            break
        }
    }
    return p
}

// The filled half (3.30 radius) and the outline half (2.70 radius) of each side, from the v2 SVGs.
let leftFilled = "M10.02 3.25 H5.30 A3.30 3.30 0 0 0 2.00 6.55 V11.45 A3.30 3.30 0 0 0 5.30 14.75 H6.38 C6.38 9.57 10.02 8.43 10.02 3.25 Z"
let rightOutline = "M12.06 3.85 H12.70 A2.70 2.70 0 0 1 15.40 6.55 V11.45 A2.70 2.70 0 0 1 12.70 14.15 H8.74 C8.74 9.52 12.06 8.49 12.06 3.85 Z"
let rightFilled = "M11.62 3.25 H12.70 A3.30 3.30 0 0 1 16.00 6.55 V11.45 A3.30 3.30 0 0 1 12.70 14.75 H7.98 C7.98 9.57 11.62 8.43 11.62 3.25 Z"
let leftOutline = "M9.26 3.85 H5.30 A2.70 2.70 0 0 0 2.60 6.55 V11.45 A2.70 2.70 0 0 0 5.30 14.15 H5.94 C5.94 9.52 9.26 8.49 9.26 3.85 Z"

enum Look: String { case active, paused, off }

func write(_ look: Look, side: String, to dir: URL) throws {
    let url = dir.appendingPathComponent("kytkin-menubar-\(look.rawValue)-\(side).pdf") as CFURL
    var box = CGRect(x: 0, y: 0, width: 18, height: 18)
    guard let ctx = CGContext(url, mediaBox: &box, [kCGPDFContextCreator: "Kytkin menubar-glyphs (P6-0g)"] as CFDictionary)
    else { throw NSError(domain: "menubar-glyphs", code: 1) }
    ctx.beginPDFPage(nil)
    ctx.translateBy(x: 0, y: 18)
    ctx.scaleBy(x: 1, y: -1)   // SVG coordinates (y down)
    let black = CGColor(gray: 0, alpha: 1)
    if look == .off {
        ctx.setAlpha(0.35)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    }
    let on = side == "a" ? leftFilled : rightFilled
    let other = side == "a" ? rightOutline : leftOutline
    ctx.setLineWidth(outline)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(black)
    switch look {
    case .active, .off:
        ctx.addPath(path(on)); ctx.setFillColor(black); ctx.fillPath()
    case .paused:
        // The on half at 45 % fill, outlined (its outline-sized shape, as the SVG).
        let pausedOn = side == "a" ? leftOutline : rightOutline
        ctx.addPath(path(pausedOn)); ctx.setFillColor(CGColor(gray: 0, alpha: 0.45)); ctx.fillPath()
        ctx.addPath(path(pausedOn)); ctx.strokePath()
    }
    ctx.addPath(path(other)); ctx.strokePath()
    if look == .off { ctx.endTransparencyLayer() }
    ctx.endPDFPage()
    ctx.closePDF()
}

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/MenuBar", isDirectory: true)
for look in [Look.active, .paused, .off] {
    for side in ["a", "b"] { try write(look, side: side, to: dir) }
}
print("wrote 6 PDFs to \(dir.path)")
