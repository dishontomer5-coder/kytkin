// P2-47: What main may ask of the tap thread's processor through `KeyWatcher.perform` (001 §2.2 contract step 4).
// P2-20: moved from System/Keyboard/KeyWatcher.swift to Core, so Core's `KeyWatching` protocol and the controllers
// that are unit-tested with a fake watcher can name it. A plain value; nothing else changed.

import Foundation

/// P2-47: what main may ask of the processor through `KeyWatcher.perform` (001 §2.2 contract step 4). Deliberately
/// narrow: `handle`, `pollFlush` and `finishReplacement` belong to the tap thread and the worker hop, and the mode
/// changes only through `start(mode:)` / `stop()`, so the processor's mode always matches the installed tap.
enum KeyWatcherOperation: Sendable, Equatable {
    /// Forget the word and abort a replacement (held keys flush); the tap thread adds the current modifier flags.
    case reset(ResetReason)
    /// Main saw the input source change. `isOurs` means "keep the buffer": true ONLY for our own after-convert switch
    /// that re-rendered the buffer into `to` (P2-21/P2-52 item 7). Rule, menu and toggle switches are ours for the
    /// learner but pass `false` here: their buffer's strokes were typed in the old layout.
    /// P2-59 (001 §12.3 X5): `isOurs` keeps the **whole** buffer (every word, re-rendered into `to`), and a switch to the
    /// layout a kept buffer was re-rendered into (`bufferRenderedIn`) ends that override. P2-59c: also passed for the
    /// switch after an AX run convert, whose finish (`bufferAfter: []`) already forgot the buffer; skipping the reset
    /// keeps `untouchedSinceConvert` for the X6 undo.
    case inputSourceChanged(to: InputSourceID?, isOurs: Bool)
    /// P2-50 (001 §12 W6): new settings. `mode` and `holdBackCapacity` are ignored; the double-Shift gesture in progress
    /// is dropped; the buffer, held keys and an armed deadline are kept (`KeyStreamProcessor.updateConfig`).
    case updateConfig(KeyProcessorConfig)
    /// P3-37 (b): `reset(.contextChange)`, and the new frontmost app is a terminal with this pid (nil: not a terminal).
    /// Leaving a terminal parks its buffer; returning to the same one restores it (`KeyStreamProcessor.contextChanged`).
    case contextChanged(terminalPID: Int32?)
}
