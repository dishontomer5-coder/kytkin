// P3-37 (c): `ClipboardConvert`, the clipboard flow on its own, over a fake pasteboard + app and a fake clock (no real
// clipboard, no real events): what it posts and in which order, every bounded wait, that the user's clipboard comes
// back exactly (every item, every type) and never over a newer copy, and every way it stops. Plus the event shapes it
// may post and the pair check for the shortcut keys.

import XCTest

final class ClipboardConvertTests: XCTestCase {
    private var clock: FakeClock!

    override func setUp() {
        clock = FakeClock(nowNanos: 1_000_000_000)
    }

    @TextActor private func make(box: String) -> (ClipboardConvert, FakePasteboard, RecordingPoster) {
        let poster = RecordingPoster()
        let pb = FakePasteboard(poster: poster, clock: clock, box: box)
        let clock = self.clock!
        let sut = ClipboardConvert(pasteboard: pb, poster: poster, clock: clock,
                                   sleep: { nanos in clock.advance(byNanos: nanos) })
        return (sut, pb, poster)
    }

    private func shortcuts(_ poster: RecordingPoster) -> [String] {
        poster.events.filter(\.isKeyDown).map { e in
            if e.keyCode == KeyCode.rightArrow { return "→" }
            return ClipboardShortcut.allCases.first { $0.keyCode == e.keyCode && e.modifierFlags != 0 }
                .map { "⌘" + $0.letter.uppercased() } ?? "?"
        }
    }

    private let upper: (String) -> ClipboardConvert.Conversion = { .replace($0.uppercased()) }

    // MARK: - The box

    @TextActor func testABoxIsCopiedConvertedPastedAndTheClipboardPutBackExactly() async {
        let (sut, pb, poster) = make(box: "akuo\nvh")
        var claims = 0
        let (result, pending) = await sut.run(.box, convert: upper, focusIsSame: { true },
                                              mayWrite: { claims += 1; return true })
        XCTAssertEqual(result, .pasted(original: "akuo\nvh", written: "AKUO\nVH"))
        XCTAssertEqual(claims, 1)
        XCTAssertEqual(shortcuts(poster), ["⌘A", "⌘C", "⌘V"], "no Right arrow after a paste")
        XCTAssertTrue(poster.events.allSatisfy(\.isSafeToPost))
        XCTAssertTrue(poster.events.allSatisfy { $0.marker == EventOrigin.oursMarker }, "never fed to the buffer")
        XCTAssertEqual(pb.transientWrites, ["AKUO\nVH"])
        XCTAssertFalse(pb.holdsUserClipboard, "the converted text is on the clipboard until the paste is read")
        let restoreAt = clock.nowNanos
        await sut.finish(pending!)
        XCTAssertEqual(pb.box, "AKUO\nVH", "pasted over the ⌘A selection")
        XCTAssertTrue(pb.holdsUserClipboard, "every item and type back")
        XCTAssertEqual(pb.restores, 1)
        XCTAssertGreaterThanOrEqual(clock.nowNanos - restoreAt, sut.timing.pasteMinNanos)
        XCTAssertLessThanOrEqual(clock.nowNanos - restoreAt, sut.timing.pasteReadWaitNanos + sut.timing.pasteSettleNanos)
    }

    @TextActor func testTheTransientWriteIsMarkedForClipboardManagers() async {
        let (sut, pb, _) = make(box: "akuo")
        _ = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        let types = pb.items.first?.map(\.type) ?? []
        XCTAssertTrue(types.contains(FakePasteboard.transient))
        XCTAssertTrue(types.contains(FakePasteboard.concealed))
    }

    @TextActor func testTheCopyWaitIsBounded() async {
        let (sut, pb, poster) = make(box: "akuo")
        pb.copyDelayNanos = nil   // an app that never copies
        let start = clock.nowNanos
        let (result, pending) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .boxEmpty)
        XCTAssertLessThanOrEqual(clock.nowNanos - start, sut.timing.copyWaitNanos + sut.timing.pollNanos)
        XCTAssertEqual(shortcuts(poster), ["⌘A", "⌘C", "→"], "the ⌘A selection is dropped, nothing pasted")
        XCTAssertTrue(pb.holdsUserClipboard)
        await sut.finish(pending!)
        XCTAssertTrue(pb.holdsUserClipboard)
        XCTAssertEqual(pb.restores, 0, "nothing to undo")
    }

    @TextActor func testALateCopyIsUndone() async {
        let (sut, pb, _) = make(box: "akuo")
        pb.copyDelayNanos = 400_000_000   // after the 250 ms wait
        let (result, pending) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .boxEmpty)
        await sut.finish(pending!)
        XCTAssertTrue(pb.holdsUserClipboard, "the app's late copy was replaced by the user's clipboard")
        XCTAssertEqual(pb.restores, 1)
    }

    @TextActor func testAnEmptyCopyIsAnEmptyBoxAndTheClipboardComesBack() async {
        let (sut, pb, poster) = make(box: "")
        pb.copiesInstead = ""
        let (result, pending) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .boxEmpty)
        XCTAssertNil(pending)
        XCTAssertTrue(pb.holdsUserClipboard)
        XCTAssertEqual(shortcuts(poster), ["⌘A", "⌘C", "→"])
    }

    @TextActor func testNothingToConvertRestoresAndDropsTheSelection() async {
        let (sut, pb, poster) = make(box: "שלום")
        let (result, pending) = await sut.run(.box, convert: { _ in .nothing }, focusIsSame: { true },
                                              mayWrite: { true })
        XCTAssertEqual(result, .nothingToConvert)
        XCTAssertNil(pending)
        XCTAssertTrue(pb.holdsUserClipboard)
        XCTAssertEqual(shortcuts(poster), ["⌘A", "⌘C", "→"])
        XCTAssertTrue(pb.transientWrites.isEmpty)
    }

    @TextActor func testAConversionThatChangesNothingIsNothingToConvert() async {
        let (sut, pb, poster) = make(box: "ABC")
        let (result, _) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .nothingToConvert)
        XCTAssertFalse(shortcuts(poster).contains("⌘V"))
        XCTAssertTrue(pb.holdsUserClipboard)
    }

    @TextActor func testTooLongRestores() async {
        let (sut, pb, _) = make(box: "akuo")
        let (result, _) = await sut.run(.box, convert: { _ in .tooLong }, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .tooLong)
        XCTAssertTrue(pb.holdsUserClipboard)
    }

    @TextActor func testAClipboardThatCantBeCopiedExactlyIsNeverTouched() async {
        let (sut, pb, poster) = make(box: "akuo")
        pb.snapshotFails = true
        let (result, pending) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .unavailable)
        XCTAssertNil(pending)
        XCTAssertTrue(poster.events.isEmpty, "nothing posted")
    }

    @TextActor func testARefusedClaimPostsNothing() async {
        let (sut, _, poster) = make(box: "akuo")
        let (result, _) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { false })
        XCTAssertEqual(result, .abandoned)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testFocusMovedBeforeTheSelectAllPostsNothing() async {
        let (sut, _, poster) = make(box: "akuo")
        let (result, _) = await sut.run(.box, convert: upper, focusIsSame: { false }, mayWrite: { true })
        XCTAssertEqual(result, .focusChanged)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testFocusMovedBeforeThePasteStopsAndRestores() async {
        let (sut, pb, poster) = make(box: "akuo")
        var checks = 0
        let (result, pending) = await sut.run(.box, convert: upper, focusIsSame: { checks += 1; return checks == 1 },
                                              mayWrite: { true })
        XCTAssertEqual(result, .focusChanged)
        XCTAssertNil(pending)
        XCTAssertEqual(shortcuts(poster), ["⌘A", "⌘C"], "no ⌘V, no arrow into another element")
        XCTAssertTrue(pb.holdsUserClipboard)
    }

    @TextActor func testTheBudgetStopsBeforeThePaste() async {
        let (sut, pb, poster) = make(box: "akuo")
        let clock = self.clock!
        let (result, _) = await sut.run(.box, convert: { text in
            clock.advance(byMilliseconds: 500)   // a slow convert
            return .replace(text.uppercased())
        }, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .timedOut)
        XCTAssertFalse(shortcuts(poster).contains("⌘V"))
        XCTAssertTrue(pb.holdsUserClipboard)
    }

    @TextActor func testAFailedTransientWriteRestores() async {
        let (sut, pb, poster) = make(box: "akuo")
        pb.writeFails = true
        let (result, _) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(pb.holdsUserClipboard)
        XCTAssertEqual(shortcuts(poster), ["⌘A", "⌘C", "→"])
    }

    @TextActor func testAPostRefusedPartWayIsAFailure() async {
        let (sut, _, poster) = make(box: "akuo")
        poster.failFrom = 2   // ⌘A goes out, ⌘C doesn't
        let (result, pending) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .failed)
        XCTAssertNotNil(pending, "a copy that might still land is watched")
    }

    @TextActor func testTheFirstPostRefusedIsUnavailable() async {
        let (sut, pb, poster) = make(box: "akuo")
        poster.failFrom = 0
        let (result, _) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(pb.holdsUserClipboard)
    }

    // MARK: - The restore

    @TextActor func testANewerCopyIsNeverOverwritten() async {
        let (sut, pb, _) = make(box: "akuo")
        let (_, pending) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        pb.externalCopy("the user copied this meanwhile")
        await sut.finish(pending!)
        XCTAssertEqual(pb.string(), "the user copied this meanwhile")
        XCTAssertEqual(pb.restores, 0)
    }

    @TextActor func testTheRestoreWaitsItsWholeBoundWhenTheReadCantBeSeen() async {
        let (sut, pb, _) = make(box: "akuo")
        pb.pasteDelayNanos = nil   // the app never reads (or the adapter can't tell)
        let (_, pending) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        let start = clock.nowNanos
        await sut.finish(pending!)
        XCTAssertTrue(pb.holdsUserClipboard)
        XCTAssertEqual(clock.nowNanos - start, sut.timing.pasteReadWaitNanos, "bounded, no settle without a read")
    }

    @TextActor func testTheRestoreNeverComesBeforeTheMinimumEvenAfterAnEarlyRead() async {
        let (sut, pb, _) = make(box: "akuo")
        pb.pasteDelayNanos = 0
        let (_, pending) = await sut.run(.box, convert: upper, focusIsSame: { true }, mayWrite: { true })
        let start = clock.nowNanos
        await sut.finish(pending!)
        XCTAssertGreaterThanOrEqual(clock.nowNanos - start, sut.timing.pasteMinNanos)
        XCTAssertTrue(pb.holdsUserClipboard)
        XCTAssertEqual(pb.box, "AKUO")
    }

    // MARK: - A known selection

    @TextActor func testAKnownSelectionIsPastedOverWithoutSelectAllOrCopy() async {
        let (sut, pb, poster) = make(box: "")
        let (result, pending) = await sut.run(.selection("akuo\nvh"), convert: upper, focusIsSame: { true },
                                              mayWrite: { true })
        XCTAssertEqual(result, .pasted(original: "akuo\nvh", written: "AKUO\nVH"))
        XCTAssertEqual(shortcuts(poster), ["⌘V"])
        await sut.finish(pending!)
        XCTAssertTrue(pb.holdsUserClipboard)
    }

    @TextActor func testAKnownSelectionWithNothingToConvertTouchesNothing() async {
        let (sut, pb, poster) = make(box: "")
        let (result, _) = await sut.run(.selection("שלום"), convert: { _ in .nothing }, focusIsSame: { true },
                                        mayWrite: { true })
        XCTAssertEqual(result, .nothingToConvert)
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(pb.restores, 0)
        XCTAssertTrue(pb.holdsUserClipboard)
    }

    // MARK: - Event shapes and keys

    func testOnlyTheThreeShortcutsAndAPlainRightArrowMayBePosted() {
        for s in ClipboardShortcut.allCases {
            XCTAssertTrue(SyntheticKeyEvent.shortcut(s, keyDown: true).isSafeToPost)
            XCTAssertEqual(SyntheticKeyEvent.shortcut(s, keyDown: true).modifierFlags, SyntheticKeyEvent.commandFlag)
        }
        XCTAssertTrue(SyntheticKeyEvent.rightArrow(keyDown: true).isSafeToPost)
        XCTAssertEqual(SyntheticKeyEvent.rightArrow(keyDown: false).modifierFlags, 0)
        XCTAssertEqual(ClipboardShortcut.selectAll.keyCode, 0)
        XCTAssertEqual(ClipboardShortcut.copy.keyCode, 8)
        XCTAssertEqual(ClipboardShortcut.paste.keyCode, 9)
        // Never Return, Tab or ⌃C, whatever the flags.
        XCTAssertNil(SyntheticKeyEvent.text([0x0D], keyDown: true))
        XCTAssertNil(KeyStrokeComposer.typing("a\nb"))
    }

    func testThePairMustTypeACVOnTheANSIKeys() {
        XCTAssertTrue(ConvertFixtures.layouts.clipboardShortcutsAreSafe, "ABC ⇄ Hebrew")
        // A layout whose A position types `q` (AZERTY): ⌘ + that key would be ⌘Q.
        var azerty = ConvertFixtures.abc
        azerty.keys[0] = KeyCell(plain: "q", shift: "Q")
        azerty.keys[12] = KeyCell(plain: "a", shift: "A")
        let hebrew = ConvertFixtures.hebrew
        let pair = LanguagePair(a: IDs.abc, b: IDs.hebrew)
        XCTAssertFalse(LayoutSnapshot(pair: pair, a: azerty, b: hebrew)!.clipboardShortcutsAreSafe)
        // P3-37 QA: ABC ⇄ AZERTY. ABC types a/c/v, but with AZERTY in front ⌘ + key 0 is ⌘Q: never.
        var french = azerty
        french.id = IDs.hebrew
        XCTAssertFalse(LayoutSnapshot(pair: pair, a: ConvertFixtures.abc, b: french)!.clipboardShortcutsAreSafe)
        // Dvorak's C key types `j` (⌘J), V `k`.
        var dvorak = ConvertFixtures.abc
        dvorak.id = IDs.hebrew
        dvorak.keys[8] = KeyCell(plain: "j", shift: "J")
        dvorak.keys[9] = KeyCell(plain: "k", shift: "K")
        XCTAssertFalse(LayoutSnapshot(pair: pair, a: ConvertFixtures.abc, b: dvorak)!.clipboardShortcutsAreSafe)
        // Two non-Latin layouts: nothing vouches for the keys.
        var hebrew2 = hebrew
        hebrew2.id = IDs.abc
        XCTAssertFalse(LayoutSnapshot(pair: pair, a: hebrew2, b: hebrew)!.clipboardShortcutsAreSafe)
    }
}
