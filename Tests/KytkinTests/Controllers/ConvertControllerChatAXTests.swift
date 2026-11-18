// P4-5 (owner-reproduced 2026-11-18: Slack's double-Shift did nothing on a Mac with no other accessibility helper app):
// Kytkin turns a chat app's Electron AX tree on itself (`AXManualAccessibility`, once per pid, never on a browser), and a
// chat app with no box at least switches the language. P4-5b (owner live test): with the tree on, Slack names no focused
// element for a composer that already had focus; a double-Shift walks the focused window for the box that says it is
// focused (read only, bounded) and converts in it. Fakes only: a recording setter (no AX write reaches any app), a
// scripted replacer (scripted walks), a fake pasteboard + app, the fake clock. No AX, no events, no real clipboard.

import XCTest

/// Records every write; answers what the test says. Touches no app.
final class FakeManualAXSetter: ManualAccessibilitySetting, @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private var calls: [Int32] = []
    private var answer: ManualAccessibilityAnswer = .set
    /// Runs after each write (e.g. the write takes time).
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

/// Counts the controller's waits.
@TextActor final class SleepCounter {
    private(set) var count = 0
    func slept() { count += 1 }
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
        let sleeps: SleepCounter
        let pasteboard: FakePasteboard
        let poster: RecordingPoster
        let enabler: ChatAccessibilityEnabler
    }

    private static let composer = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false,
                                            selTextSettable: false, selRangeSettable: true, selection: nil)

    private static func stats(_ nodes: Int, ms: UInt64 = 0, depth: Int = 0) -> ChatFocusWalk.Stats {
        ChatFocusWalk.Stats(nodes: nodes, depth: depth, nanos: ms * 1_000_000)
    }

    /// `focus`: what AX names as focused (nil = nothing). `walks`: what each focus walk finds, in turn.
    /// `walkMs`: how long each walk takes on the fake clock.
    @TextActor private func rig(_ text: String = "akuo", focus: FocusInfo? = nil, walks: [ChatFocusWalkReport] = [],
                                walkMs: UInt64 = 0, withEnabler: Bool = true) -> Rig {
        let poster = RecordingPoster()
        let r = ScriptedReplacer(log: log)
        r.focus = focus
        r.element = FakeElement(pid: slackPID)
        r.walkReports = walks
        let clock = self.clock!
        r.onWalk = { clock.advance(byMilliseconds: walkMs) }
        let pb = FakePasteboard(poster: poster, clock: clock, box: text)
        pb.copiedExtras = []   // a plain copy
        let log = self.log!
        let sink = self.sink!
        let sleeps = SleepCounter()
        let clipboard = ClipboardConvert(pasteboard: pb, poster: poster, clock: clock,
                                         sleep: { nanos in clock.advance(byNanos: nanos) })
        let enabler = ChatAccessibilityEnabler(setter: setter)
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { r }, switchLanguage: switches.hook,
                                    makeClipboard: { @TextActor @Sendable () -> ClipboardConvert? in clipboard },
                                    diagnose: { trace in sink.traces.append(trace) },
                                    chatAX: withEnabler ? enabler : nil,
                                    sleep: { nanos in
                                        clock.advance(byNanos: nanos)
                                        await sleeps.slept()
                                    })
        return Rig(sut: sut, replacer: r, sleeps: sleeps, pasteboard: pb, poster: poster, enabler: enabler)
    }

    private func empty() -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: IDs.abc, isValid: false)
    }

    private func buffer(_ current: String) -> WordSnapshot {
        WordSnapshot(strokes: ConvertFixtures.strokes(current), previousWords: [], renderedIn: IDs.abc, isValid: true)
    }

    private func request(_ snapshot: WordSnapshot, gen: UInt64 = 1, app: String? = nil,
                         pid: Int32? = 4242, useClipboard: Bool = true) -> ConvertRequest {
        ConvertRequest(snapshot: snapshot, gen: gen, bundleID: app ?? slack, mode: .convert, pair: ConvertFixtures.pair,
                       currentSource: IDs.abc, switchAfterConvert: true, useClipboard: useClipboard, processID: pid,
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

    // MARK: - At double-Shift time: a box in focus

    @TextActor func testTheDoubleShiftEnablesAChatAppNotEnabledYet() async {
        let rig = rig(focus: Self.composer)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום")
        XCTAssertEqual(setter.pids, [slackPID], "the safety net wrote the flag")
        XCTAssertEqual(sink.traces.last?.chatAX, "wrote:set")
        XCTAssertTrue(rig.replacer.walks.isEmpty, "a box was there: no walk")
        XCTAssertNil(sink.traces.last?.chatFocusWalk)
        XCTAssertEqual(rig.sleeps.count, 0, "no wait")
    }

    @TextActor func testAnEnabledChatAppIsNotWrittenAgainWhenTheBoxIsThere() async {
        let rig = rig(focus: Self.composer)
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        _ = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(setter.pids, [slackPID])
        XCTAssertEqual(sink.traces.last?.chatAX, "alreadySet")
    }

    // MARK: - P4-5b: no box in focus, the walk

    /// The owner's live case: Slack relaunched (enabled when it came to the front), the composer had focus before the
    /// tree was built, AX names no focused element. Every double-Shift used to just switch.
    @TextActor func testTheWalkFindsTheFocusedComposerAndItConverts() async {
        let rig = rig(focus: nil, walks: [.found(Self.stats(660, ms: 58, depth: 23))], walkMs: 58)
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום")
        XCTAssertEqual(rig.replacer.walks.count, 1)
        XCTAssertEqual(rig.replacer.walks.first?.pid, slackPID)
        XCTAssertEqual(rig.replacer.walks.first?.maxNodes, ChatFocusWalk.defaultMaxNodes)
        XCTAssertLessThanOrEqual(rig.replacer.walks.first?.budgetNanos ?? .max, ConvertController.chatFocusWaitNanos)
        XCTAssertEqual(setter.pids, [slackPID], "the tree was there: no re-write")
        XCTAssertEqual(rig.sleeps.count, 0, "no polling any more")
        XCTAssertEqual(sink.traces.last?.chatFocusWalk, "found nodes=660 ms=58 depth=23")
        XCTAssertNil(sink.traces.last?.chatAXRetry)
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testEveryDoubleShiftWalksAgainAndThePinEndsWithTheRequest() async {
        let rig = rig(focus: nil, walks: [.found(Self.stats(660, ms: 58, depth: 23))], walkMs: 58)
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        _ = await rig.sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertNil(rig.replacer.focus, "unpinned after the request")
        XCTAssertGreaterThanOrEqual(rig.replacer.unpins, 1)
        rig.pasteboard.box = "akuo"
        let second = await rig.sut.handle(request(empty(), gen: 2), layouts: layouts)
        XCTAssertEqual(second, .converted(to: IDs.hebrew, by: .pasteboard, switched: true), "not just the first one")
        XCTAssertEqual(rig.replacer.walks.count, 2)
    }

    @TextActor func testAWindowOrWebViewInFocusIsNotABoxTheWalkStillRuns() async {
        let group = FocusInfo(role: "AXGroup", isSecure: false, hasMarkedText: false, selTextSettable: false,
                              selRangeSettable: false, selection: nil)
        let rig = rig(focus: group, walks: [.found(Self.stats(300, ms: 20, depth: 12))])
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.replacer.focus?.role, "AXGroup", "the system focus is back after the request")
    }

    /// The first double-Shift right after Slack starts: this request's own write turned the tree on; it may still be
    /// building, so one short wait and a second walk.
    @TextActor func testAfterAFreshWriteASecondWalkFollowsAShortWait() async {
        let rig = rig(focus: nil, walks: [.notFound(Self.stats(12, depth: 3)), .found(Self.stats(660, ms: 58, depth: 23))])
        let start = clock.nowNanos
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(setter.pids, [slackPID], "the safety net's write only (P4-5 QA: not repeated)")
        XCTAssertEqual(rig.sleeps.count, 1)
        XCTAssertEqual(rig.replacer.walks.count, 2)
        XCTAssertEqual(sink.traces.last?.chatFocusWalk,
                       "notFound nodes=12 ms=0 depth=3 > found nodes=660 ms=58 depth=23")
        XCTAssertLessThanOrEqual(rig.replacer.walks[1].budgetNanos,
                                 ConvertController.chatFocusWaitNanos - ConvertController.chatSecondWalkWaitNanos)
        XCTAssertLessThanOrEqual(clock.nowNanos - start, 1_000_000_000)
    }

    @TextActor func testABareWindowOfAnEnabledAppIsWrittenAgainOnce() async {
        // Enabled when it came to the front, but the window shows no web content now (the tree may have been dropped).
        let rig = rig(focus: nil, walks: [.notFound(Self.stats(5, depth: 2)), .found(Self.stats(660, depth: 23))])
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(setter.pids, [slackPID, slackPID])
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "rewrote(wrote:set)")
        XCTAssertEqual(rig.sleeps.count, 1)
    }

    @TextActor func testAFullTreeWithNoFocusedBoxJustSwitchesAtOnce() async {
        for snap in [empty(), buffer("akuo")] {
            reset()
            let rig = rig(focus: nil, walks: [.notFound(Self.stats(660, ms: 58, depth: 30))], walkMs: 58)
            rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
            let out = await rig.sut.handle(request(snap), layouts: layouts)
            XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable), "never silent")
            XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
            XCTAssertEqual(log.beeps, 0)
            XCTAssertEqual(rig.poster.events.count, 0, "no keys, no clipboard in a chat app without a box")
            XCTAssertEqual(rig.pasteboard.restores, 0)
            XCTAssertEqual(rig.replacer.walks.count, 1, "the tree is there: no second walk")
            XCTAssertEqual(rig.sleeps.count, 0)
            XCTAssertEqual(setter.pids, [slackPID], "no re-write")
            XCTAssertEqual(sink.traces.last?.chatFocusWalk, "notFound nodes=660 ms=58 depth=30")
            XCTAssertEqual(sink.traces.last?.steps.last, .init(path: .switchOnly, reason: "fieldUnreadable"))
            XCTAssertTrue(sink.traces.last?.steps.contains(.init(path: .switchOnly, reason: "chatNoBox")) == true)
            XCTAssertEqual(log.finishes.count, 1)
        }
    }

    @TextActor func testAWalkOutOfBudgetJustSwitches() async {
        // The walk used all of the time it was given: no wait, no second walk.
        let rig = rig(focus: nil, walks: [.budget(Self.stats(1_700, ms: 150, depth: 25))], walkMs: 150)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(rig.replacer.walks.count, 1)
        XCTAssertEqual(rig.sleeps.count, 0)
        XCTAssertEqual(sink.traces.last?.chatFocusWalk, "budget nodes=1700 ms=150 depth=25")
    }

    @TextActor func testTheWalkGetsOnlyWhatIsLeftBeforeTheDeadline() async {
        // The safety net's write took 50 ms: the walk may use the 100 ms left of the 150 ms.
        setter.onWrite = { [clock] _ in clock!.advance(byMilliseconds: 50) }
        let rig = rig(focus: nil, walks: [.notFound(Self.stats(660))])
        _ = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(rig.replacer.walks.first?.budgetNanos, 100_000_000)
    }

    @TextActor func testAWalkThatEndsTooLateForTheCopySwitchesInsteadOfOnlyBeeping() async {
        // A busy Mac: the walk found the box but took 210 ms, so the copy can no longer start in time (200 ms).
        let rig = rig(focus: nil, walks: [.found(Self.stats(660, ms: 210, depth: 23))], walkMs: 210)
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertEqual(clipboardKeys(rig.poster), 0, "nothing posted")
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
    }

    // MARK: - No walk

    @TextActor func testABusyAppThatDidNotAnswerIsNotWalkedNorWaitedFor() async {
        // P4-5 QA: the safety net got no answer (Slack still launching): walks would only time out too.
        setter.setAnswer(.noAnswer)
        let rig = rig(focus: nil, walks: [.found(Self.stats(1))])
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(setter.pids, [slackPID])
        XCTAssertTrue(rig.replacer.walks.isEmpty)
        XCTAssertEqual(rig.sleeps.count, 0)
        XCTAssertEqual(rig.poster.events.count, 0, "P3-58: no keys in a chat app")
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "notTried(wrote:noAnswer)")
        XCTAssertFalse(rig.enabler.isSet(pid: slackPID))
    }

    @TextActor func testWithTheClipboardSwitchOffNothingIsWrittenNorWalked() async {
        // P4-5 QA: chat apps convert only by the clipboard; with it off double-Shift just switches.
        let rig = rig(focus: nil, walks: [.found(Self.stats(1))])
        let out = await rig.sut.handle(request(empty(), useClipboard: false), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(setter.pids, [])
        XCTAssertTrue(rig.replacer.walks.isEmpty)
        XCTAssertEqual(rig.poster.events.count, 0)
    }

    @TextActor func testWithoutTheGrantNothingIsWalked() async {
        setter.setAnswer(.notTrusted)
        let rig = rig(focus: nil, walks: [.found(Self.stats(1))])
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertTrue(rig.replacer.walks.isEmpty)
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "notTried(wrote:notTrusted)")
    }

    @TextActor func testWithoutAPidNothingIsWrittenNorWalked() async {
        let rig = rig(focus: nil, walks: [.found(Self.stats(1))])
        let out = await rig.sut.handle(request(empty(), pid: nil), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(setter.pids, [])
        XCTAssertTrue(rig.replacer.walks.isEmpty)
        XCTAssertEqual(sink.traces.last?.chatAX, "notChatApp")
    }

    @TextActor func testWithoutTheEnablerAChatAppWithNoBoxStillSwitches() async {
        let rig = rig(focus: nil, walks: [.found(Self.stats(1))], withEnabler: false)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertTrue(rig.replacer.walks.isEmpty)
        XCTAssertNil(sink.traces.last?.chatAX)
    }

    @TextActor func testABrowserWithNoFocusIsNeverWrittenToNorWalked() async {
        let rig = rig(focus: nil, walks: [.found(Self.stats(1))])
        let out = await rig.sut.handle(request(empty(), app: chrome), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(setter.pids, [])
        XCTAssertTrue(rig.replacer.walks.isEmpty)
        XCTAssertEqual(rig.sleeps.count, 0)
        XCTAssertNil(sink.traces.last?.chatAX)
    }

    // MARK: - Chat copy outcomes

    @TextActor func testAChatCopyWhoseFocusMovedSwitches() async {
        let rig = rig(focus: Self.composer)
        rig.replacer.setNowFocused(FakeElement(pid: 1))   // another element by the time the copy starts
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertEqual(rig.pasteboard.box, "akuo")
    }

    @TextActor func testTheTraceHoldsNoText() async {
        let rig = rig("secretword akuo", focus: nil, walks: [.found(Self.stats(660, ms: 58, depth: 23))])
        _ = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        let line = sink.traces.last?.line ?? ""
        XCTAssertTrue(line.contains("chatAX=wrote:set"), line)
        XCTAssertTrue(line.contains("chatFocusWalk=found nodes=660 ms=58 depth=23"), line)
        for word in ["secretword", "akuo", "שלום"] { XCTAssertFalse(line.contains(word), line) }
    }
}
