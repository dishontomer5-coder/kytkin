# Menu-bar glyphs (P6-0c)

Drop the real artwork from Claude Design here. Until the files exist, Kytkin draws SF Symbol placeholders, so nothing
breaks.

| File | When it shows | Placeholder used today |
|---|---|---|
| `kytkin-menubar-active.pdf` | Normal | `keyboard` |
| `kytkin-menubar-paused.pdf` | Paused (also drawn dimmed) | `pause.circle` |
| `kytkin-menubar-attention.pdf` | A warning needs the user (badge) | `exclamationmark.circle` |
| `kytkin-menubar-off.pdf` | Kytkin turned off (also drawn dimmed) | `keyboard` (dimmed) |

Rules for each PDF (visual review §3.1, `docs/design/p6-0-review-visual.md`):

- 16 × 16 pt, single-colour vector, black on transparent. Kytkin marks it as a **template** image, so macOS tints it
  for light, dark and highlighted menu bars. Don't use colour.
- The names must match exactly. The code looks them up in `MenuBarGlyph.image(for:)`
  (`Sources/UI/StatusItemController.swift`) through `MenuModel.glyphName(_:)` (`Sources/Core/Controllers/MenuModel.swift`).
- `project.yml` bundles every `*.pdf` in this folder into `Contents/Resources/MenuBar/`. Run `./scripts/build.sh`
  after adding them (XcodeGen regenerates the project).

## App icon

The app icon is not in the project yet. When it's ready, add an asset catalog at
`Resources/Assets.xcassets/AppIcon.appiconset/` (with its `Contents.json` and the 16–1024 px PNGs). Then add
`Resources/Assets.xcassets` under `sources` in `project.yml` and set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in
the Kytkin target's settings. Settings → About and the setup window already show `NSImage.applicationIconName`, so
they pick it up with no code change.
