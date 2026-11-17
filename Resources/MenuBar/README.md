# Menu-bar glyphs (P6-0c, artwork P6-0e)

Claude Design's template PDFs (`docs/design/artwork/Colors.md`, sources in `docs/design/artwork/MenuBar/`). The filled
half of the key is the language that is on: `-a` = the pair's first language (left half), `-b` = the second.

| File | When it shows |
|---|---|
| `kytkin-menubar-active-{a,b}.pdf` | Normal |
| `kytkin-menubar-paused-{a,b}.pdf` | Paused (the on half at 45 % fill) |
| `kytkin-menubar-off-{a,b}.pdf` | Kytkin turned off (35 %; the letters fade to 35 % too) |
| attention | Drawn in code from the active PDF (see below) |

- P6-0g (design v2 review, P3: "outline 1.5 pt, gap to EN 5 pt"): the six PDFs here are written by
  `xcrun swift Tools/menubar-glyphs/main.swift Resources/MenuBar` from the v2 SVG paths, with the outline half at
  1.5 pt (the export had 1.2 pt). The 5 pt gap is `MenuModel.ItemLayout.gap`.
- 18 × 18 pt, black + alpha. Kytkin marks them as **template** images, so macOS tints them for every menu bar.
- The whole status item is one image, drawn by `MenuBarGlyph.itemImage(for:)` (`Sources/UI/MenuBarGlyph.swift`): the
  glyph, 5 pt (P6-0g), then the letters (SF Pro Text 13 pt medium) in a fixed 20 pt frame. Names come from
  `MenuModel.glyphName(_:side:)` (`Sources/Core/Controllers/MenuModel.swift`).
- **Attention:** the exported `kytkin-menubar-attention-{a,b}.pdf` lost the SVG mask (only the badge dot is left), so
  they aren't bundled. `MenuBarGlyph` draws the same thing as `kytkin-menubar-attention-*.svg` from the active PDF (a
  circle r 3.3 at (15.4, 3.4) cut out, then a badge r 2.2). A fixed re-export (the cut-out as a path, not a mask) can
  be dropped in here under the same names. The code then still draws its own, so the code needs a small change too.
- `project.yml` bundles every `*.pdf` here into `Contents/Resources/`. If a PDF is missing, an SF Symbol stands in.
