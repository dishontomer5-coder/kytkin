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
        XCTAssertEqual(plan(.convertSelection, bundle: "com.apple.Terminal", focus: field(selection: "akuo")),
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
    }

    // MARK: - Last word

    func testValidBufferIsBackspaceAndType() {
        XCTAssertEqual(plan(.convertLastWord, snap: snapshot(), typed: 4, focus: field()),
                       .steps([.backspaceAndType(count: 4)]))
        XCTAssertEqual(plan(.convertLastWord, bundle: "com.apple.Terminal", snap: snapshot(), typed: 4,
                            focus: field()), .steps([.backspaceAndType(count: 4)]))
    }

    func testBackspaceCountIsTheTypedLengthNotTheStrokeCount() {
        // A stroke can render as 0 or several graphemes; the controller counts what is on screen.
        XCTAssertEqual(plan(.convertLastWord, snap: snapshot(count: 3), typed: 5, focus: field()),
                       .steps([.backspaceAndType(count: 5)]))
    }

    func testStaleBufferReadsBeforeCaretThenWritesAX() {
        let expected = ReplacementPlan.steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)])
        XCTAssertEqual(plan(.convertLastWord, snap: snapshot(valid: false), typed: 4, focus: field()), expected)
        XCTAssertEqual(plan(.convertLastWord, snap: nil, focus: field()), expected)
        XCTAssertEqual(plan(.convertLastWord, snap: snapshot(), typed: nil, focus: field()), expected)
        XCTAssertEqual(plan(.convertLastWord, snap: snapshot(count: 0), typed: 0, focus: field()), expected)
    }

    func testStaleBufferWithoutAXRefuses() {
        XCTAssertEqual(plan(.convertLastWord, snap: nil, focus: field(readsCaret: false)), .refuse(.bufferStale))
        XCTAssertEqual(plan(.convertLastWord, snap: nil, focus: field(settable: false)), .refuse(.bufferStale))
        XCTAssertEqual(plan(.convertLastWord, bundle: "com.apple.Terminal", snap: nil, focus: field()),
                       .refuse(.bufferStale))
        var c = ReplacementCapabilities()
        c.record(.failedVerify, of: .axWriteSelection(verify: true), for: textEdit)
        XCTAssertEqual(plan(.convertLastWord, snap: nil, focus: field(), caps: c), .refuse(.bufferStale))
    }

    func testNoUnicodeAppWithValidBufferFallsBackToAX() {
        XCTAssertEqual(plan(.convertLastWord, bundle: "com.vmware.fusion", snap: snapshot(), typed: 4, focus: field()),
                       .steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]))
        XCTAssertEqual(plan(.convertLastWord, bundle: "com.vmware.fusion", snap: snapshot(), typed: 4,
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

    private let allKinds: [ReplacementRequest.Kind] = [.convertSelection, .convertLastWord, .autoFix, .undoFix]

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
        XCTAssertEqual(plan(.convertLastWord, bundle: "com.apple.Terminal", focus: field(marked: true)),
                       .refuse(.composing))
        XCTAssertEqual(plan(.convertLastWord, bundle: "com.apple.Terminal", snap: snapshot(), typed: 4,
                            focus: field(role: "AXSecureTextField", settable: false, readsCaret: false)),
                       .refuse(.secureField))
    }

    func testRefusalHasNoSteps() {
        XCTAssertEqual(ReplacementPlan.refuse(.composing).steps, [])
    }
}
