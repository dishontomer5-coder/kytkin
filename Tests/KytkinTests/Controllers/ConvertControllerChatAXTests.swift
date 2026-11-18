// P4-5 (owner-reproduced 2026-11-18: Slack's double-Shift did nothing on a Mac with no other accessibility helper app):
// Kytkin turns a chat app's Electron AX tree on itself (`AXManualAccessibility`, once per pid, never on a browser), a
// double-Shift that finds no box writes it again and looks once more (bounded), and a chat app with no box at least
// switches the language. Fakes only: a recording setter (no AX write reaches any app), a scripted replacer, a fake
// pasteboard + app, the fake clock. No AX, no events, no real clipboard.

import XCTest

/// Records every write; answers what the test says. Touches no app.
final class FakeManualAXSetter: ManualAccessibilitySetting, @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private var calls: [Int32] = []
    private var answer: ManualAccessibilityAnswer = .set
    /// Runs after each write (e.g. the tree appears).
    var onWrite: (@Sendable (Int32) -> Void)?

    var pids: [Int32] { lock.withLock { calls } }
    func setAnswer(_ a: ManualAccessibilityAnswer) { lock.withLock { answer = a } }

    func setManualAccessibility(pid: Int32, timeout: Double) -> ManualAccessibilityAnswer {
        let a = lock.withLock { () -> ManualAccessibilityAnswer in
            calls.append(pid)
            return answer
        }
        onWrite?(pid)
        return a
    }
}

/// The chat app's AX tree: the composer shows in focus after `appearsAfterSleeps` waits (nil = never).
@TextActor final class FakeChatTree {
    let replacer: ScriptedReplacer
    let box: FocusInfo
    var appearsAfterSleeps: Int?
    private(set) var sleeps = 0

    init(replacer: ScriptedReplacer, box: FocusInfo, appearsAfterSleeps: Int?) {
        self.replacer = replacer
        self.box = box
        self.appearsAfterSleeps = appearsAfterSleeps
    }

    func slept() {
        sleeps += 1
        if let n = appearsAfterSleeps, sleeps >= n { replacer.focus = box }
    }
}

final class ConvertControllerChatAXTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"
    private let chrome = "com.google.Chrome"
    private let layouts = ConvertFixtures.layouts
    private let slackPID: Int32 = 4242

    private var log: ConvertLog!
    private var watcher: ConvertKeyWatcher!
    private var switches: SwitchRecorder!
    private var clock: FakeClock!
    private var sink: TraceSink!
    private var setter: FakeManualAXSetter!

    override func setUp() { reset() }

    private func reset() {
        log = ConvertLog()
        watcher = ConvertKeyWatcher(log: log)
        switches = SwitchRecorder(log: log)
        clock = FakeClock(nowNanos: 1_000_000_000)
        sink = TraceSink()
        setter = FakeManualAXSetter()
    }

    private struct Rig {
        let sut: ConvertController
        let replacer: ScriptedReplacer
        let tree: FakeChatTree
        let pasteboard: FakePasteboard
        let poster: RecordingPoster
        let enabler: ChatAccessibilityEnabler
    }

    private static let composer = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false,
                                            selTextSettable: false, selRangeSettable: true, selection: nil)

    /// `focus`: what AX names before the tree shows (nil = nothing). `appearsAfterSleeps`: when the composer shows.
    /// `sleepNanos`: how far each wait moves the clock (nil = what was asked).
    @TextActor private func rig(_ text: String = "akuo", focus: FocusInfo? = nil, appearsAfterSleeps: Int? = nil,
                                sleepNanos: UInt64? = nil, withEnabler: Bool = true) -> Rig {
        let poster = RecordingPoster()
        let r = ScriptedReplacer(log: log)
        r.focus = focus
        r.element = FakeElement(pid: slackPID)
        let tree = FakeChatTree(replacer: r, box: Self.composer, appearsAfterSleeps: appearsAfterSleeps)
        let pb = FakePasteboard(poster: poster, clock: clock, box: text)
        pb.copiedExtras = []   // a plain copy
        let clock = self.clock!
        let log = self.log!
        let sink = self.sink!
        let clipboard = ClipboardConvert(pasteboard: pb, poster: poster, clock: clock,
                                         sleep: { nanos in clock.advance(byNanos: nanos) })
        let enabler = ChatAccessibilityEnabler(setter: setter)
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { r }, switchLanguage: switches.hook,
                                    makeClipboard: { @TextActor @Sendable () -> ClipboardConvert? in clipboard },
                                    diagnose: { trace in sink.traces.append(trace) },
                                    chatAX: withEnabler ? enabler : nil,
                                    sleep: { nanos in
                                        clock.advance(byNanos: sleepNanos ?? nanos)
                                        await tree.slept()
                                    })
        return Rig(sut: sut, replacer: r, tree: tree, pasteboard: pb, poster: poster, enabler: enabler)
    }

    private func empty() -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: IDs.abc, isValid: false)
    }

    private func buffer(_ current: String) -> WordSnapshot {
        WordSnapshot(strokes: ConvertFixtures.strokes(current), previousWords: [], renderedIn: IDs.abc, isValid: true)
    }

    private func request(_ snapshot: WordSnapshot, gen: UInt64 = 1, app: String? = nil,
                         pid: Int32? = 4242) -> ConvertRequest {
        ConvertRequest(snapshot: snapshot, gen: gen, bundleID: app ?? slack, mode: .convert, pair: ConvertFixtures.pair,
                       currentSource: IDs.abc, switchAfterConvert: true, useClipboard: true, processID: pid,
                       allowsChromiumAX: true)
    }

    private func clipboardKeys(_ poster: RecordingPoster) -> Int {
        poster.events.filter { $0.modifierFlags != 0 }.count
    }

    // MARK: - When a chat app comes to the front

    @TextActor func testFrontmostChatAppIsEnabledOncePerPid() async {
        let rig = rig()
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: 10)
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: 10)
        XCTAssertEqual(setter.pids, [10], "once per process")
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: 11)
        XCTAssertEqual(setter.pids, [10, 11], "a relaunched app (new pid) is enabled again")
        rig.sut.chatAppBecameFrontmost(bundleID: "com.hnc.Discord", pid: 12)
        rig.sut.chatAppBecameFrontmost(bundleID: "com.microsoft.teams2", pid: 13)
        XCTAssertEqual(setter.pids, [10, 11, 12, 13])
    }

    @TextActor func testBrowsersAndOtherAppsAreNeverWrittenTo() async {
        let rig = rig()
        for app in [chrome, "com.microsoft.edgemac", "app.zen-browser.zen", "com.apple.Safari", "com.apple.TextEdit",
                    "com.microsoft.VSCode"] {
            rig.sut.chatAppBecameFrontmost(bundleID: app, pid: 20)
            XCTAssertEqual(rig.enabler.enable(bundleID: app, pid: 20, timeout: 0.1, force: true), .notChatApp, app)
        }
        XCTAssertEqual(setter.pids, [], "R3b rule 1: nothing is ever set on a browser")
    }

    @TextActor func testAnUnansweredWriteIsTriedAgainAnAnsweredOneIsNot() async {
        let enabler = ChatAccessibilityEnabler(setter: setter)
        setter.setAnswer(.noAnswer)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1), .wrote(.noAnswer))
        setter.setAnswer(.notTrusted)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1), .wrote(.notTrusted))
        XCTAssertFalse(enabler.isSet(pid: 5))
        // Electron may answer an error and still turn the tree on: done.
        setter.setAnswer(.refused)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1), .wrote(.refused))
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1), .alreadySet)
        XCTAssertEqual(setter.pids, [5, 5, 5])
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: nil, timeout: 0.1), .notChatApp, "no pid: nothing sent")
        XCTAssertEqual(enabler.enable(bundleID: " COM.TinySpeck.SlackMacGap ", pid: 6, timeout: 0.1), .wrote(.refused))
    }

    @TextActor func testRemembersABoundedNumberOfPids() async {
        let enabler = ChatAccessibilityEnabler(setter: setter)
        for pid in 1...Int32(ChatAccessibilityEnabler.maxRemembered + 1) {
            enabler.enable(bundleID: slack, pid: pid, timeout: 0.1)
        }
        XCTAssertFalse(enabler.isSet(pid: 1), "the oldest is dropped")
        XCTAssertTrue(enabler.isSet(pid: Int32(ChatAccessibilityEnabler.maxRemembered + 1)))
    }

    // MARK: - At double-Shift time

    @TextActor func testTheDoubleShiftEnablesAChatAppNotEnabledYet() async {
        let rig = rig(focus: Self.composer)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום")
        XCTAssertEqual(setter.pids, [slackPID], "the safety net wrote the flag")
        XCTAssertEqual(sink.traces.last?.chatAX, "wrote:set")
        XCTAssertNil(sink.traces.last?.chatAXRetry, "a box was there: no retry")
        XCTAssertEqual(rig.tree.sleeps, 0, "no wait")
    }

    @TextActor func testAnEnabledChatAppIsNotWrittenAgainWhenTheBoxIsThere() async {
        let rig = rig(focus: Self.composer)
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        _ = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(setter.pids, [slackPID])
        XCTAssertEqual(sink.traces.last?.chatAX, "alreadySet")
    }

    /// The owner's case: Slack just started, no other helper app ran, the first double-Shift.
    @TextActor func testFirstDoubleShiftWaitsBrieflyForTheTreeAndConverts() async {
        let rig = rig(focus: nil, appearsAfterSleeps: 2)
        let start = clock.nowNanos
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום")
        XCTAssertEqual(setter.pids, [slackPID], "P4-5 QA: the safety net wrote just now: not written again")
        XCTAssertEqual(rig.tree.sleeps, 2)
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "found polls=2 atMs=60")
        XCTAssertLessThanOrEqual(clock.nowNanos - start, 1_000_000_000, "bounded (the clipboard's own waits included)")
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testNoBoxEvenAfterTheWaitJustSwitches() async {
        for snap in [empty(), buffer("akuo")] {
            reset()
            let rig = rig(focus: nil, appearsAfterSleeps: nil)
            let out = await rig.sut.handle(request(snap), layouts: layouts)
            XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable), "never silent")
            XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
            XCTAssertEqual(log.beeps, 0)
            XCTAssertEqual(rig.poster.events.count, 0, "no keys, no clipboard in a chat app without a box")
            XCTAssertEqual(rig.pasteboard.restores, 0)
            XCTAssertEqual(rig.tree.sleeps, 5, "150 ms in 30 ms steps")
            XCTAssertEqual(sink.traces.last?.chatAXRetry, "notFound polls=5 atMs=150")
            XCTAssertEqual(sink.traces.last?.steps.last, .init(path: .switchOnly, reason: "fieldUnreadable"))
            XCTAssertTrue(sink.traces.last?.steps.contains(.init(path: .switchOnly, reason: "chatNoBox")) == true)
            XCTAssertEqual(log.finishes.count, 1)
        }
    }

    @TextActor func testTheWaitStaysInsideTheBudgetAfterOtherWork() async {
        // The request already used 100 ms before the retry (a slow focus read): only 50 ms are left to wait.
        let rig = rig(focus: nil, appearsAfterSleeps: nil)
        setter.onWrite = { [clock] _ in clock!.advance(byMilliseconds: 50) }
        _ = await rig.sut.handle(request(empty()), layouts: layouts)
        // P4-5 QA: one write of 50 ms (the safety net; not repeated), then the wait up to 150 ms: 80, 110, 140, 150.
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "notFound polls=4 atMs=150")
        XCTAssertEqual(setter.pids, [slackPID])
    }

    @TextActor func testAnAlreadyEnabledAppWithNoBoxIsWrittenAgainOnce() async {
        // P4-5 QA: enabled when it came to the front (the tree may have been dropped since): forced once more, then wait.
        let rig = rig(focus: nil, appearsAfterSleeps: 1)
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(setter.pids, [slackPID, slackPID])
        XCTAssertEqual(sink.traces.last?.chatAX, "alreadySet")
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "found polls=1 atMs=30")
    }

    @TextActor func testABusyAppThatDidNotAnswerIsNotWrittenAgainNorWaitedFor() async {
        // P4-5 QA: the safety net got no answer (Slack still launching): another write and focus reads would only time
        // out too, so it just switches at once; the next double-Shift asks again (not remembered).
        setter.setAnswer(.noAnswer)
        let rig = rig(focus: nil, appearsAfterSleeps: 1)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(setter.pids, [slackPID])
        XCTAssertEqual(rig.tree.sleeps, 0)
        XCTAssertEqual(rig.poster.events.count, 0, "P3-58: no keys in a chat app")
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "notTried(wrote:noAnswer)")
        XCTAssertFalse(rig.enabler.isSet(pid: slackPID))
    }

    @TextActor func testWithTheClipboardSwitchOffNothingIsWrittenNorWaitedFor() async {
        // P4-5 QA: chat apps convert only by the clipboard; with it off double-Shift just switches.
        let rig = rig(focus: nil, appearsAfterSleeps: 1)
        let r = ConvertRequest(snapshot: empty(), gen: 1, bundleID: slack, mode: .convert, pair: ConvertFixtures.pair,
                               currentSource: IDs.abc, switchAfterConvert: true, useClipboard: false,
                               processID: slackPID, allowsChromiumAX: true)
        let out = await rig.sut.handle(r, layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(setter.pids, [])
        XCTAssertEqual(rig.tree.sleeps, 0)
        XCTAssertEqual(rig.poster.events.count, 0)
    }

    @TextActor func testAWindowOrWebViewInFocusIsNotABox() async {
        let group = FocusInfo(role: "AXGroup", isSecure: false, hasMarkedText: false, selTextSettable: false,
                              selRangeSettable: false, selection: nil)
        let rig = rig(focus: group, appearsAfterSleeps: 1)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true), "the composer showed")
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "found polls=1 atMs=30")
    }

    @TextActor func testWithoutTheGrantNothingWaits() async {
        setter.setAnswer(.notTrusted)
        let rig = rig(focus: nil, appearsAfterSleeps: 1)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(rig.tree.sleeps, 0)
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "notTried(wrote:notTrusted)")
    }

    @TextActor func testWithoutAPidNothingIsWritten() async {
        let rig = rig(focus: nil, appearsAfterSleeps: 1)
        let out = await rig.sut.handle(request(empty(), pid: nil), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(setter.pids, [])
        XCTAssertEqual(sink.traces.last?.chatAX, "notChatApp")
    }

    @TextActor func testWithoutTheEnablerAChatAppWithNoBoxStillSwitches() async {
        let rig = rig(focus: nil, withEnabler: false)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(rig.tree.sleeps, 0)
        XCTAssertNil(sink.traces.last?.chatAX)
    }

    @TextActor func testABrowserWithNoFocusIsNeverWrittenToNorWaitedFor() async {
        let rig = rig(focus: nil, appearsAfterSleeps: 1)
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(setter.pids, [])
        XCTAssertEqual(rig.tree.sleeps, 0)
        XCTAssertNil(sink.traces.last?.chatAX)
    }

    @TextActor func testAChatCopyStartedTooLateSwitchesInsteadOfOnlyBeeping() async {
        // Each wait takes far longer than asked (a busy Mac): the box shows, but the copy can no longer start in time.
        let rig = rig(focus: nil, appearsAfterSleeps: 1, sleepNanos: 250_000_000)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertEqual(clipboardKeys(rig.poster), 0, "nothing posted")
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
    }

    @TextActor func testAChatCopyWhoseFocusMovedSwitches() async {
        let rig = rig(focus: Self.composer)
        rig.replacer.setNowFocused(FakeElement(pid: 1))   // another element by the time the copy starts
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertEqual(rig.pasteboard.box, "akuo")
    }

    @TextActor func testTheTraceHoldsNoText() async {
        let rig = rig("secretword akuo", focus: nil, appearsAfterSleeps: 1)
        _ = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        let line = sink.traces.last?.line ?? ""
        XCTAssertTrue(line.contains("chatAX=wrote:set"), line)
        XCTAssertTrue(line.contains("chatAXRetry=found"), line)
        for word in ["secretword", "akuo", "שלום"] { XCTAssertFalse(line.contains(word), line) }
    }
}
