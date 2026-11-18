# Changelog

## 1.1.1

### Fixed

- The "Update available" menu line now comes back when you turn updates off and on again.

## 1.1.0

### New: one-click updates

- **Keep Kytkin up to date.** Turn it on in setup or in Settings → General → Updates. Once a day Kytkin checks GitHub
  for a new version. When there is one, the menu shows "Update available: Kytkin x.y.z…". Click it, then **Install Update**,
  and Kytkin updates itself and reopens. Nothing downloads or installs until you click.
- **Off unless you turn it on.** Nothing about you is sent: no system details, no IDs, nothing you type.
- **Check Now…** in Settings → General → Updates checks right away.
- If you had turned on "Check for updates" in 1.0.0, Kytkin keeps it on as "Keep Kytkin up to date".
- Updates are signed: Kytkin installs only an update from its GitHub releases that carries the developer's update
  signature. Every release is also signed with the same certificate as the copy you have, so your permissions
  (Accessibility) carry over.
- Updates use [Sparkle](https://sparkle-project.org/) (MIT License), the open-source updater many Mac apps use.

### Updating from 1.0.0

1.0.0 can't update itself yet: download `Kytkin-1.1.0.dmg` and drag Kytkin into Applications once more (choose
**Replace**). From 1.1.0 on, updates take one click.

## 1.0.0 (first release)

Kytkin is a small, free, open-source macOS menu-bar app that switches your keyboard language for you and fixes text
typed in the wrong layout.

### What it does

- **Remembers your language per app and per website.** Switch to Hebrew once in WhatsApp or on a website, and Kytkin
  switches back to Hebrew every time you return there.
- **Double-Shift fixes text typed in the wrong layout.** Press Shift twice to convert your selection, or, with nothing
  selected, the text before the cursor. Kytkin also switches the keyboard to the right language. Press Shift twice
  again to convert it back, or use the app's own ⌘Z.
- **Works in most apps**, including Slack, Gmail, Spotlight, Notes, Mail and most web pages.
- **Statistics:** Settings → Statistics shows three simple counts (kept only on your Mac, no names, sites or text).
- **Hebrew ⇄ English by default.** Your Mac's other keyboard layouts work too, and you can import layouts. Pick your
  two languages in Settings.
- Setup turns on "Open Kytkin when I log in" by default. Uncheck it there, or turn it off later in Settings → General
  → Open at Login.

### Install

1. Download `Kytkin-1.0.0.dmg`, open it and **drag Kytkin into the Applications folder**.
2. Open Kytkin from Applications. The first time, macOS says it can't open it: click **Done**, then open
   **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
3. Kytkin is self-signed and not notarized by Apple (that costs $99 a year), which is why macOS asks. The full source
   code is on GitHub.

### Privacy

- Nothing you type is saved or sent. Text is held in memory only briefly, for the conversion you asked for.
- No analytics, no telemetry, no account.
- The optional update check is **off by default**. If you turn it on, Kytkin asks GitHub once a day whether a newer
  version is out, sending only its version number. It never downloads or installs anything.

### Requirements

macOS 14 Sonoma or later, on Apple silicon or Intel. Tested on macOS 26.

### Download check

SHA-256: <filled in at release>

### Developer and support

Made by Tomer Dishon. Bug or question? Open an issue at https://github.com/dishontomer5-coder/kytkin/issues or email
dishontomer5@gmail.com.
