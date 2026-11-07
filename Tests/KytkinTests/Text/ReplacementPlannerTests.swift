// P2-13: ReplacementPlanner chains (001 §2.2/§3c, R5 "Recommended fallback chains") and the hard rules:
// never plan for a secure field, while an IME is composing, or with unknown focus.

import XCTest

final class ReplacementPlannerTests: XCTestCase {
    private let textEdit = "com.apple.TextEdit"
    private let caps = ReplacementCapabilities()

    private func field(role: String? = "AXTextArea", secure: Bool = false, marked: Bool = false,
                       settable: Bool = true, selection: String? = nil, readsCaret: Bool = true) -> FocusInfo {
        FocusInfo(role: role, isSecure: secure, hasMarkedText: marked, selTextSettable: settable,
                  selRangeSettable: settable, selection: selection, canReadBeforeCaret: readsCaret)
    }

    private func snapshot(valid: Bool = true, count: Int = 4) -> WordSnapshot {
        WordSnapshot(strokes: (0..<count).map { Stroke(keyCode: UInt16($0), layer: .plain) },
                     previousWords: [], renderedIn: InputSourceID("com.apple.keylayout.ABC"), isValid: valid)
    }

    private func plan(_ kind: ReplacementRequest.Kind, bundle: String? = nil, snap: WordSnapshot? = nil,
                      typed: Int? = nil, focus: FocusInfo?, caps: ReplacementCapabilities? = nil,
                      paste: Bool = false) -> ReplacementPlan {
        ReplacementPlanner.plan(ReplacementRequest(kind: kind, bundleID: bundle ?? textEdit, snapshot: snap,
                                                   typedLength: typed),
                                caps: caps ?? self.caps, focus: focus, allowPasteboard: paste)
    }

    // MARK: - Selection

    func testSelectionInCocoaIsAXThenTypeOver() {
        XCTAssertEqual(plan(.convertSelection, focus: field(selection: "akuo")),
                       .steps([.axWriteSelection(verify: true), .typeOverSelection]))
    }

    func testSelectionWithoutSettableAXTypesOver() {
        // R5: NSTextField not being edited — selText isn't settable.
        XCTAssertEqual(plan(.convertSelection, focus: field(settable: false, selection: "akuo")),
                       .steps([.typeOverSelection]))
    }

    func testSelectionOnlyRangeSettableSkipsAX() {
        let f = FocusInfo(role: "AXTextField", isSecure: false, hasMarkedText: false, selTextSettable: false,
                          selRangeSettable: true, selection: "akuo")
        XCTAssertEqual(plan(.convertSelection, focus: f), .steps([.typeOverSelection]))
    }

    func testSelectionInKeysOnlyAppNeverUsesAX() {
        XCTAssertEqual(plan(.convertSelection, bundle: "com.microsoft.VSCode", focus: field(selection: "akuo")),
                       .steps([.typeOverSelection]))
        XCTAssertEqual(plan(.convertSelection, bundle: "com.google.Chrome", focus: field(selection: "akuo")),
                       .steps([.typeOverSelection]))
    }

    func testSelectionUnreadableRefuses() {
        XCTAssertEqual(plan(.convertSelection, focus: field(selection: nil)), .refuse(.selectionUnreadable))
        XCTAssertEqual(plan(.convertSelection, focus: field(selection: "")), .refuse(.selectionUnreadable))
    }

    func testSelectionAfterFailedVerifySkipsAX() {
        var c = ReplacementCapabilities()
        c.record(.failedVerify, of: .axWriteSelection(verify: true), for: textEdit)
        XCTAssertEqual(plan(.convertSelection, focus: field(selection: "akuo"), caps: c), .steps([.typeOverSelection]))
    }

    func testSelectionInNoUnicodeAppUsesAXOnly() {
        XCTAssertEqual(plan(.convertSelection, bundle: "com.apple.ScreenSharing", focus: field(selection: "x")),
                       .steps([.axWriteSelection(verify: true)]))
        XCTAssertEqual(plan(.convertSelection, bundle: "com.apple.ScreenSharing",
                            focus: field(settable: false, selection: "x")), .refuse(.noMethod))
    }

    func testPasteboardIsNeverPlannedUntilAllowed() {
        for hint in MethodHint.allCases where hint != .disabled {
            let c = ReplacementCapabilities(overrides: [textEdit: hint])
            XCTAssertFalse(plan(.convertSelection, focus: field(selection: "x"), caps: c).steps.contains(.pasteboard),
                           "\(hint)")
        }
    }

    func testPasteboardPlacementWhenAllowed() {
        XCTAssertEqual(plan(.convertSelection, focus: field(selection: "x"), paste: true),
                       .steps([.axWriteSelection(verify: true), .typeOverSelection, .pasteboard]))
        let prefer = ReplacementCapabilities(overrides: [textEdit: .preferPaste])
        XCTAssertEqual(plan(.convertSelection, focus: field(selection: "x"), caps: prefer, paste: true),
                       .steps([.pasteboard, .axWriteSelection(verify: true), .typeOverSelection]))
        // Never in terminals (bracketed paste, R5).
        XCTAssertFalse(plan(.convertSelection, bundle: "com.apple.Terminal", focus: field(selection: "x"),
                            paste: true).steps.contains(.pasteboard))
        // P2-36 (001 §12 T3): keysOnly allows the opt-in paste (⌘V is a key), still without AX.
        XCTAssertEqual(plan(.convertSelection, bundle: "com.google.Chrome", focus: field(selection: "x"), paste: true),
                       .steps([.typeOverSelection, .pasteboard]))
        let terminal = ReplacementCapabilities(overrides: [textEdit: .terminal])
        XCTAssertEqual(plan(.convertSelection, focus: field(selection: "x"), caps: terminal, paste: true),
                       .refuse(.terminalSelection))
    }

    // MARK: - Terminals (P2-36, 001 §12 T1)

    func testSelectionInTerminalIsRefused() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                   "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper"] {
            XCTAssertEqual(plan(.convertSelection, bundle: id, focus: field(selection: "akuo")),
                           .refuse(.terminalSelection), id)
            XCTAssertEqual(plan(.convertSelection, bundle: id, focus: field(selection: "akuo"), paste: true),
                           .refuse(.terminalSelection), id)
        }
        // Even when the selection couldn't be read: the terminal hint is the better explanation.
        XCTAssertEqual(plan(.convertSelection, bundle: "com.apple.Terminal", focus: field(selection: nil)),
                       .refuse(.terminalSelection))
        // A user override to terminal works the same in any app.
        let c = ReplacementCapabilities(overrides: [textEdit: .terminal])
        XCTAssertEqual(plan(.convertSelection, focus: field(selection: "akuo"), caps: c), .refuse(.terminalSelection))
    }

    func testTerminalLastWordIsBackspaceAndTypeOnly() {
        XCTAssertEqual(plan(.convertRun, bundle: "com.mitchellh.ghostty", snap: snapshot(), typed: 4,
                            focus: field()), .steps([.backspaceAndType(count: 4)]))
        // Stale buffer: no AX path in a terminal, so a beep.
        XCTAssertEqual(plan(.convertRun, bundle: "com.mitchellh.ghostty", snap: nil, focus: field()),
                       .refuse(.bufferStale))
        XCTAssertEqual(plan(.convertRun, bundle: "com.mitchellh.ghostty", snap: snapshot(), typed: 4,
                            focus: field(), paste: true), .steps([.backspaceAndType(count: 4)]))
    }

    func testTerminalNeverPlansAXOrPaste() {
        let c = ReplacementCapabilities(overrides: [textEdit: .terminal])
        for kind in allKinds {
            let steps = plan(kind, snap: snapshot(), typed: 4, focus: field(selection: "x"), caps: c, paste: true).steps
            XCTAssertFalse(steps.contains(.pasteboard), "\(kind)")
            XCTAssertFalse(steps.contains(.axWriteSelection(verify: true)), "\(kind)")
            XCTAssertFalse(steps.contains(.axReadRunBeforeCaret(maxChars: 256)), "\(kind)")
        }
    }

    func testHardRulesBeatTheTerminalRefusal() {
        XCTAssertEqual(plan(.convertSelection, bundle: "com.apple.Terminal", focus: field(secure: true, selection: "x")),
                       .refuse(.secureField))
        XCTAssertEqual(plan(.convertSelection, bundle: "com.apple.Terminal", focus: nil), .refuse(.focusUnknown))
        XCTAssertEqual(plan(.convertSelection, bundle: "com.apple.Terminal", focus: field(marked: true, selection: "x")),
                       .refuse(.composing))
    }

    // MARK: - Control characters in the selection (P2-36, 001 §12 T2)

    private let unsafeSelections = ["two\nlines", "tab\there", "cr\rhere", "crlf\r\nhere", "esc\u{1B}",
                                    "nul\u{0}", "del\u{7F}", "c1\u{85}", "ls\u{2028}", "ps\u{2029}", "\n"]

    func testUnsafeSelectionIsOnlyReplacedByAVerifiedAXWrite() {
        for sel in unsafeSelections {
            XCTAssertEqual(plan(.convertSelection, focus: field(selection: sel)),
                           .steps([.axWriteSelection(verify: true)]), sel.debugDescription)
            XCTAssertEqual(plan(.convertSelection, focus: field(selection: sel), paste: true),
                           .steps([.axWriteSelection(verify: true)]), sel.debugDescription)
            let prefer = ReplacementCapabilities(overrides: [textEdit: .preferPaste])
            XCTAssertEqual(plan(.convertSelection, focus: field(selection: sel), caps: prefer, paste: true),
                           .steps([.axWriteSelection(verify: true)]), sel.debugDescription)
        }
    }

    func testUnsafeSelectionWithoutAXRefuses() {
        var broken = ReplacementCapabilities()
        broken.record(.failedVerify, of: .axWriteSelection(verify: true), for: textEdit)
        for sel in unsafeSelections {
            XCTAssertEqual(plan(.convertSelection, focus: field(settable: false, selection: sel)),
                           .refuse(.unsafeSelection), sel.debugDescription)
            XCTAssertEqual(plan(.convertSelection, focus: field(selection: sel), caps: broken, paste: true),
                           .refuse(.unsafeSelection), sel.debugDescription)
            // keysOnly apps (IDEs, so also their embedded terminals) never type it.
            XCTAssertEqual(plan(.convertSelection, bundle: "com.microsoft.VSCode", focus: field(selection: sel),
                                paste: true), .refuse(.unsafeSelection), sel.debugDescription)
            XCTAssertEqual(plan(.convertSelection, bundle: "com.jetbrains.intellij", focus: field(selection: sel)),
                           .refuse(.unsafeSelection), sel.debugDescription)
            // A noUnicode app without AX is unsafe first (the reason the user can act on).
            XCTAssertEqual(plan(.convertSelection, bundle: "com.apple.ScreenSharing",
                                focus: field(settable: false, selection: sel)), .refuse(.unsafeSelection))
        }
    }

    func testSafeCharactersAreStillTyped() {
        // Spaces, NBSP, LRM/RLM, niqqud, emoji and Hebrew are not control characters.
        for sel in ["two words", "a\u{00A0}b", "\u{200E}שלום\u{200F}", "שָׁלוֹם", "👍🏽 ok", " "] {
            XCTAssertFalse(ReplacementPlanner.containsUnsafeCharacter(sel), sel.debugDescription)
            XCTAssertEqual(plan(.convertSelection, bundle: "com.microsoft.VSCode", focus: field(selection: sel)),
                           .steps([.typeOverSelection]), sel.debugDescription)
        }
        for sel in unsafeSelections {
            XCTAssertTrue(ReplacementPlanner.containsUnsafeCharacter(sel), sel.debugDescription)
        }
    }

    func testRunIgnoresTheSelectionCheck() {
        // The control-character rule is about the selection only; the buffer run is rebuilt from strokes.
        XCTAssertEqual(plan(.convertRun, snap: snapshot(), typed: 4, focus: field(selection: "a\nb", readsCaret: false)),
                       .steps([.backspaceAndType(count: 4)]))
    }

    // MARK: - Run (P2-59, 001 §12.3 X4)

    private let read = ReplacementStep.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars)
    private let ax = ReplacementStep.axWriteSelection(verify: true)

    /// A buffer of `words` words of 2 strokes, `gap` spaces between them, and `trailing` spaces after the last
    /// (then `strokes` is empty). The planner reads only whether there is a run; the count is `typedLength`.
    private func run(words: Int, trailing: Bool = false) -> WordSnapshot {
        let w = [Stroke(keyCode: 0, layer: .plain), Stroke(keyCode: 1, layer: .plain)]
        let previous = Array(repeating: w, count: trailing ? words : words - 1)
        return WordSnapshot(strokes: trailing ? [] : w, previousWords: previous,
                            renderedIn: InputSourceID("com.apple.keylayout.ABC"), isValid: !trailing)
    }

    func testMaxRunReadIs256Units() {
        XCTAssertEqual(ReplacementPlanner.maxRunReadChars, 256)
    }

    func testReadableFieldReadsTheRunFirstThenAXThenTheBufferKeys() {
        XCTAssertEqual(plan(.convertRun, snap: snapshot(), typed: 4, focus: field()), .steps([read, ax,
                                                                                              .backspaceAndType(count: 4)]))
        XCTAssertEqual(plan(.convertRun, snap: run(words: 3), typed: 8, focus: field()),
                       .steps([read, ax, .backspaceAndType(count: 8)]))
        // Trailing spaces: no current word, still a run (`isValid` keeps its P4 meaning).
        XCTAssertEqual(plan(.convertRun, snap: run(words: 2, trailing: true), typed: 6, focus: field()),
                       .steps([read, ax, .backspaceAndType(count: 6)]))
    }

    func testReadableFieldWithoutABufferRunIsAXOnly() {
        let expected = ReplacementPlan.steps([read, ax])
        XCTAssertEqual(plan(.convertRun, snap: nil, focus: field()), expected)
        XCTAssertEqual(plan(.convertRun, snap: snapshot(valid: false), typed: 4, focus: field()), expected,
                       "strokes that aren't valid are no run")
        XCTAssertEqual(plan(.convertRun, snap: snapshot(), typed: nil, focus: field()), expected,
                       "typedRun was nil: dead key or combining mark, no key step")
        XCTAssertEqual(plan(.convertRun, snap: snapshot(count: 0), typed: 0, focus: field()), expected)
        XCTAssertEqual(plan(.convertRun, snap: snapshot(), typed: 0, focus: field()), expected)
    }

    func testUnreadableFieldTypesTheWholeBuffer() {
        XCTAssertEqual(plan(.convertRun, snap: run(words: 3), typed: 8, focus: field(readsCaret: false)),
                       .steps([.backspaceAndType(count: 8)]))
        XCTAssertEqual(plan(.convertRun, snap: snapshot(), typed: 4, focus: field(settable: false)),
                       .steps([.backspaceAndType(count: 4)]))
    }

    func testKeysOnlyAndTerminalNeverReadThroughAX() {
        for id in ["com.apple.Terminal", "com.mitchellh.ghostty", "com.microsoft.VSCode", "com.google.Chrome"] {
            XCTAssertEqual(plan(.convertRun, bundle: id, snap: run(words: 3), typed: 8, focus: field()),
                           .steps([.backspaceAndType(count: 8)]), id)
            XCTAssertEqual(plan(.convertRun, bundle: id, snap: nil, focus: field()), .refuse(.bufferStale), id)
            XCTAssertEqual(plan(.convertRun, bundle: id, snap: snapshot(), typed: nil, focus: field()),
                           .refuse(.noMethod), "\(id): a run that can't be counted")
        }
    }

    func testBackspaceCountIsTheTypedLengthNotTheStrokeCount() {
        // A stroke can render as 0 or several graphemes; the controller counts what is on screen.
        XCTAssertEqual(plan(.convertRun, snap: snapshot(count: 3), typed: 5, focus: field(readsCaret: false)),
                       .steps([.backspaceAndType(count: 5)]))
    }

    func testNoBufferAndNoAXRefuses() {
        XCTAssertEqual(plan(.convertRun, snap: nil, focus: field(readsCaret: false)), .refuse(.bufferStale))
        XCTAssertEqual(plan(.convertRun, snap: nil, focus: field(settable: false)), .refuse(.bufferStale))
        XCTAssertEqual(plan(.convertRun, bundle: "com.apple.Terminal", snap: nil, focus: field()),
                       .refuse(.bufferStale))
        var c = ReplacementCapabilities()
        c.record(.failedVerify, of: .axWriteSelection(verify: true), for: textEdit)
        XCTAssertEqual(plan(.convertRun, snap: nil, focus: field(), caps: c), .refuse(.bufferStale))
        XCTAssertEqual(plan(.convertRun, snap: snapshot(), typed: 4, focus: field(), caps: c),
                       .steps([.backspaceAndType(count: 4)]), "AX broken here: the buffer keys only")
    }

    func testNoUnicodeAppIsAXOnly() {
        XCTAssertEqual(plan(.convertRun, bundle: "com.vmware.fusion", snap: snapshot(), typed: 4, focus: field()),
                       .steps([read, ax]))
        XCTAssertEqual(plan(.convertRun, bundle: "com.vmware.fusion", snap: snapshot(), typed: 4,
                            focus: field(settable: false)), .refuse(.noMethod))
    }

    // MARK: - Auto-fix and undo (P4)

    func testAutoFixIsKeysOnlyNeverAX() {
        XCTAssertEqual(plan(.autoFix, snap: snapshot(), typed: 4, focus: field()), .steps([.backspaceAndType(count: 4)]))
        XCTAssertEqual(plan(.autoFix, snap: snapshot(valid: false), typed: 4, focus: field()), .refuse(.bufferStale))
        XCTAssertEqual(plan(.autoFix, bundle: "com.utmapp.UTM", snap: snapshot(), typed: 4, focus: field()),
                       .refuse(.noMethod))
        XCTAssertEqual(plan(.autoFix, snap: snapshot(), typed: 4, focus: field(), paste: true),
                       .steps([.backspaceAndType(count: 4)]))
    }

    func testUndoUsesTheControllersCount() {
        XCTAssertEqual(plan(.undoFix, typed: 5, focus: field()), .steps([.backspaceAndType(count: 5)]))
        XCTAssertEqual(plan(.undoFix, typed: nil, focus: field()), .refuse(.bufferStale))
    }

    // MARK: - Hard rules (every kind)

    private let allKinds: [ReplacementRequest.Kind] = [.convertSelection, .convertRun, .autoFix, .undoFix]

    func testNeverPlansForASecureField() {
        for kind in allKinds {
            XCTAssertEqual(plan(kind, snap: snapshot(), typed: 4, focus: field(secure: true, selection: "x")),
                           .refuse(.secureField), "\(kind)")
            // The role alone is enough, even if the adapter forgot the flag.
            XCTAssertEqual(plan(kind, snap: snapshot(), typed: 4,
                                focus: field(role: "AXSecureTextField", selection: "x")),
                           .refuse(.secureField), "\(kind)")
        }
    }

    func testNeverPlansWhileComposing() {
        for kind in allKinds {
            XCTAssertEqual(plan(kind, snap: snapshot(), typed: 4, focus: field(marked: true, selection: "x")),
                           .refuse(.composing), "\(kind)")
        }
    }

    func testUnknownFocusRefuses() {
        for kind in allKinds {
            XCTAssertEqual(plan(kind, snap: snapshot(), typed: 4, focus: nil), .refuse(.focusUnknown), "\(kind)")
        }
    }

    func testDisabledAppRefusesEverything() {
        let c = ReplacementCapabilities(overrides: [textEdit: .disabled])
        for kind in allKinds {
            XCTAssertEqual(plan(kind, snap: snapshot(), typed: 4, focus: field(selection: "x"), caps: c),
                           .refuse(.disabledForApp), "\(kind)")
        }
    }

    func testHardRulesComeBeforeEveryOtherCheck() {
        // Secure wins over composing, and both win over missing selection / stale buffer / keys-only hints.
        XCTAssertEqual(plan(.convertSelection, focus: field(secure: true, marked: true)), .refuse(.secureField))
        XCTAssertEqual(plan(.convertRun, bundle: "com.apple.Terminal", focus: field(marked: true)),
                       .refuse(.composing))
        XCTAssertEqual(plan(.convertRun, bundle: "com.apple.Terminal", snap: snapshot(), typed: 4,
                            focus: field(role: "AXSecureTextField", settable: false, readsCaret: false)),
                       .refuse(.secureField))
    }

    func testRefusalHasNoSteps() {
        XCTAssertEqual(ReplacementPlan.refuse(.composing).steps, [])
    }
}
