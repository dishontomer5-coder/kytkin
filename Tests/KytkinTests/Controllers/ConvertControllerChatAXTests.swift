// P4-5 (owner-reproduced 2026-11-18: Slack's double-Shift did nothing on a Mac with no other accessibility helper app):
// Kytkin turns a chat app's Electron AX tree on itself (`AXManualAccessibility`, once per pid, never on a browser), and a
// chat app with no box at least switches the language. P4-5b (owner live test): with the tree on, Slack names no focused
// element for a composer that already had focus; a double-Shift walks the focused window for the box that says it is
// focused (read only, bounded) and converts in it. P4-5c (owner live test): the write at launch was missed and a
// re-write every ~0.9 s kept Slack from building its tree: a launch schedule off main, no re-write within 3 s, no waiting
// at double-Shift. Fakes only: a recording setter (no AX write reaches any app), a scripted replacer (scripted walks), a
// fake pasteboard + app, fake clocks. No AX, no events, no real clipboard.

import XCTest

/// Records every write; answers what the test says (in turn: the last one repeats). Touches no app.
final class FakeManualAXSetter: ManualAccessibilitySetting, @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private var calls: [Int32] = []
    private var answers: [ManualAccessibilityAnswer] = [.set]
    /// Runs after each write (e.g. the write takes time).
    var onWrite: (@Sendable (Int32) -> Void)?

    var pids: [Int32] { lock.withLock { calls } }
    func setAnswer(_ a: ManualAccessibilityAnswer) { lock.withLock { answers = [a] } }
    func setAnswers(_ a: [ManualAccessibilityAnswer]) { lock.withLock { answers = a } }

    func setManualAccessibility(pid: Int32, timeout: Double) -> ManualAccessibilityAnswer {
        let a = lock.withLock { () -> ManualAccessibilityAnswer in
            calls.append(pid)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        onWrite?(pid)
        return a
    }
}

/// Counts the launch schedule's waits.
@TextActor final class SleepCounter {
    private(set) var count = 0
    func slept() { count += 1 }
}

/// Which pids still run (the schedule's `isAlive`).
final class FakeAlivePids: @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private var dead: Set<Int32> = []
    func kill(_ pid: Int32) { _ = lock.withLock { dead.insert(pid) } }
    func isAlive(_ pid: Int32) -> Bool { lock.withLock { !dead.contains(pid) } }
}

final class ConvertControllerChatAXTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"
    private let chrome = "com.google.Chrome"
    private let layouts = ConvertFixtures.layouts
    private let slackPID: Int32 = 4242

    private var log: ConvertLog!
    private var watcher: ConvertKeyWatcher!
    private var switches: SwitchRecorder!
    /// The convert's clock (budgets, copy waits).
    private var clock: FakeClock!
    /// P4-5c: the launch schedule's and the enabler's clock (write ages), moved by the schedule's waits.
    private var prepClock: FakeClock!
    private var sink: TraceSink!
    private var setter: FakeManualAXSetter!
    private var alive: FakeAlivePids!

    override func setUp() { reset() }

    private func reset() {
        log = ConvertLog()
        watcher = ConvertKeyWatcher(log: log)
        switches = SwitchRecorder(log: log)
        clock = FakeClock(nowNanos: 1_000_000_000)
        prepClock = FakeClock(nowNanos: 5_000_000_000)
        sink = TraceSink()
        setter = FakeManualAXSetter()
        alive = FakeAlivePids()
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

    private static let builtWindow = ChatFocusWalkReport.budget(stats(40, depth: 5))
    private static let bareWindow = ChatFocusWalkReport.notFound(stats(12, depth: 6))

    /// `focus`: what AX names as focused (nil = nothing). `walks`: what each double-Shift focus walk finds, in turn.
    /// `walkMs`: how long each walk takes on the convert's clock. `windows`: what the launch schedule's looks find.
    @TextActor private func rig(_ text: String = "akuo", focus: FocusInfo? = nil, walks: [ChatFocusWalkReport] = [],
                                walkMs: UInt64 = 0, windows: [ChatFocusWalkReport] = [builtWindow],
                                withEnabler: Bool = true) -> Rig {
        let poster = RecordingPoster()
        let r = ScriptedReplacer(log: log)
        r.focus = focus
        r.element = FakeElement(pid: slackPID)
        r.walkReports = walks
        r.windowReports = windows
        let clock = self.clock!
        let prepClock = self.prepClock!
        r.onWalk = { clock.advance(byMilliseconds: walkMs) }
        let pb = FakePasteboard(poster: poster, clock: clock, box: text)
        pb.copiedExtras = []   // a plain copy
        let log = self.log!
        let sink = self.sink!
        let sleeps = SleepCounter()
        let clipboard = ClipboardConvert(pasteboard: pb, poster: poster, clock: clock,
                                         sleep: { nanos in clock.advance(byNanos: nanos) })
        let alive = self.alive!
        let enabler = ChatAccessibilityEnabler(setter: setter, clock: prepClock, isAlive: { alive.isAlive($0) })
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { r }, switchLanguage: switches.hook,
                                    makeClipboard: { @TextActor @Sendable () -> ClipboardConvert? in clipboard },
                                    diagnose: { trace in sink.traces.append(trace) },
                                    chatAX: withEnabler ? enabler : nil,
                                    sleep: { nanos in
                                        prepClock.advance(byNanos: nanos)
                                        await sleeps.slept()
                                    })
        return Rig(sut: sut, replacer: r, sleeps: sleeps, pasteboard: pb, poster: poster, enabler: enabler)
    }

    /// Slack came to the front and its schedule ran to the end (a real tree: two tries, one write, one wait).
    @TextActor private func frontmostAndSettled(_ rig: Rig) async {
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        await rig.sut.chatPrepSettled()
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

    // MARK: - The enabler

    @TextActor func testAnUnansweredWriteIsTriedAgainAnAnsweredOneIsNot() async {
        let enabler = ChatAccessibilityEnabler(setter: setter, clock: prepClock)
        setter.setAnswer(.noAnswer)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1), .wrote(.noAnswer))
        setter.setAnswer(.notTrusted)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1), .wrote(.notTrusted))
        XCTAssertFalse(enabler.isSet(pid: 5))
        // Electron may answer an error and still turn the tree on: done.
        setter.setAnswer(.refused)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1), .wrote(.refused))
        prepClock.advance(byMilliseconds: 250)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1), .alreadySet(ageMs: 250))
        XCTAssertEqual(setter.pids, [5, 5, 5])
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: nil, timeout: 0.1), .notChatApp, "no pid: nothing sent")
        XCTAssertEqual(enabler.enable(bundleID: " COM.TinySpeck.SlackMacGap ", pid: 6, timeout: 0.1), .wrote(.refused))
        XCTAssertEqual(enabler.summary(pid: 5), "tries=0 writes=3 last=refused built=unknown")
        XCTAssertEqual(enabler.summary(pid: 99), "none")
    }

    @TextActor func testNoReWriteWithinThreeSecondsOfTheLastWrite() async {
        let enabler = ChatAccessibilityEnabler(setter: setter, clock: prepClock)
        enabler.enable(bundleID: slack, pid: 5, timeout: 0.1)
        prepClock.advance(byMilliseconds: 900)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1, force: true), .throttled(ageMs: 900))
        prepClock.advance(byMilliseconds: 2_099)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1, force: true), .throttled(ageMs: 2_999))
        prepClock.advance(byMilliseconds: 1)
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1, force: true), .wrote(.set))
        XCTAssertEqual(enabler.enable(bundleID: slack, pid: 5, timeout: 0.1, force: true), .throttled(ageMs: 0))
        XCTAssertEqual(setter.pids, [5, 5])
    }

    @TextActor func testRemembersABoundedNumberOfPids() async {
        let enabler = ChatAccessibilityEnabler(setter: setter, clock: prepClock)
        for pid in 1...Int32(ChatAccessibilityEnabler.maxRemembered + 1) {
            enabler.enable(bundleID: slack, pid: pid, timeout: 0.1)
        }
        XCTAssertFalse(enabler.isSet(pid: 1), "the oldest is dropped")
        XCTAssertTrue(enabler.isSet(pid: Int32(ChatAccessibilityEnabler.maxRemembered + 1)))
    }

    // MARK: - P4-5c: the launch schedule

    @TextActor func testFrontmostChatAppIsEnabledOnceAndTheScheduleStopsOnARealTree() async {
        let rig = rig()
        await frontmostAndSettled(rig)
        XCTAssertEqual(setter.pids, [slackPID], "one write")
        XCTAssertEqual(rig.replacer.windowWalks, 1, "looked once after a wait")
        XCTAssertEqual(rig.sleeps.count, 1)
        XCTAssertTrue(rig.enabler.isReady(pid: slackPID))
        XCTAssertEqual(rig.enabler.summary(pid: slackPID), "tries=2 writes=1 last=set built=yes")
        // Ready: coming to the front again, or launching, starts nothing.
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        rig.sut.chatAppLaunched(bundleID: slack, pid: slackPID)
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids, [slackPID])
        XCTAssertEqual(rig.replacer.windowWalks, 1)
    }

    @TextActor func testARelaunchedAppIsPreparedAgainAndOtherChatAppsToo() async {
        let rig = rig()
        rig.sut.chatAppLaunched(bundleID: slack, pid: 10)
        rig.sut.chatAppLaunched(bundleID: slack, pid: 11)
        rig.sut.chatAppBecameFrontmost(bundleID: "com.hnc.Discord", pid: 12)
        rig.sut.chatAppBecameFrontmost(bundleID: "com.microsoft.teams2", pid: 13)
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(Set(setter.pids), [10, 11, 12, 13])
        XCTAssertEqual(setter.pids.count, 4)
    }

    /// The owner's launches: the write while Slack is still starting gets no answer; the tree then takes 1–2 s.
    @TextActor func testAnUnansweredLaunchWriteIsRetriedAndABareWindowIsNotReWrittenTooSoon() async {
        setter.setAnswers([.noAnswer, .noAnswer, .set])
        let rig = rig(windows: [Self.bareWindow, Self.bareWindow, Self.builtWindow])
        rig.sut.chatAppLaunched(bundleID: slack, pid: slackPID)
        await rig.sut.chatPrepSettled()
        // 0 s noAnswer, 0.3 s noAnswer, 0.7 s set, 1.5 s bare (0.8 s since the write: no re-write),
        // 3 s bare (2.3 s: no re-write), 6 s a real tree.
        XCTAssertEqual(setter.pids, [slackPID, slackPID, slackPID])
        XCTAssertEqual(rig.replacer.windowWalks, 3)
        XCTAssertEqual(rig.sleeps.count, 5)
        XCTAssertEqual(rig.enabler.summary(pid: slackPID), "tries=6 writes=3 last=set built=yes")
    }

    @TextActor func testABareWindowIsReWrittenOnlyEveryThreeSeconds() async {
        let rig = rig(windows: [Self.bareWindow])
        rig.sut.chatAppLaunched(bundleID: slack, pid: slackPID)
        await rig.sut.chatPrepSettled()
        // 0 s write; bare at 0.3, 0.7, 1.5 (throttled), 3 s (3.0 s old: re-write), 6 s (3.0 s old: re-write); then it ends.
        XCTAssertEqual(setter.pids.count, 3)
        XCTAssertEqual(rig.sleeps.count, 5, "the schedule ends after its last try")
        XCTAssertFalse(rig.enabler.isReady(pid: slackPID))
    }

    @TextActor func testTheScheduleStopsWhenTheAppQuits() async {
        setter.setAnswer(.noAnswer)
        let alive = self.alive!
        setter.onWrite = { pid in alive.kill(pid) }   // the app quits right after the first try's write
        let rig = rig()
        rig.sut.chatAppLaunched(bundleID: slack, pid: slackPID)
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids.count, 1)
        XCTAssertEqual(rig.sleeps.count, 1, "the next try saw the app gone")
        XCTAssertNil(rig.enabler.state(pid: slackPID), "forgotten")
    }

    @TextActor func testStopCancelsTheSchedule() async {
        setter.setAnswer(.noAnswer)
        let rig = rig()
        rig.sut.chatAppLaunched(bundleID: slack, pid: slackPID)
        rig.sut.stopChatAppPreparation()
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids, [], "cancelled before its first try")
    }

    @TextActor func testOneSchedulePerPid() async {
        setter.setAnswer(.noAnswer)
        let rig = rig()
        rig.sut.chatAppLaunched(bundleID: slack, pid: slackPID)
        rig.sut.chatAppBecameFrontmost(bundleID: slack, pid: slackPID)
        rig.sut.chatAppLaunched(bundleID: slack, pid: slackPID)
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids.count, ConvertController.chatPrepScheduleNanos.count, "one write per try, one schedule")
    }

    @TextActor func testWithoutTheGrantTheScheduleStopsAtOnce() async {
        setter.setAnswer(.notTrusted)
        let rig = rig()
        rig.sut.chatAppLaunched(bundleID: slack, pid: slackPID)
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids, [slackPID])
        XCTAssertEqual(rig.sleeps.count, 0)
    }

    @TextActor func testBrowsersAndOtherAppsAreNeverWrittenTo() async {
        let rig = rig()
        for app in [chrome, "com.microsoft.edgemac", "app.zen-browser.zen", "com.apple.Safari", "com.apple.TextEdit",
                    "com.microsoft.VSCode"] {
            rig.sut.chatAppBecameFrontmost(bundleID: app, pid: 20)
            rig.sut.chatAppLaunched(bundleID: app, pid: 20)
            XCTAssertEqual(rig.enabler.enable(bundleID: app, pid: 20, timeout: 0.1, force: true), .notChatApp, app)
        }
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids, [], "R3b rule 1: nothing is ever set on a browser")
        XCTAssertEqual(rig.replacer.windowWalks, 0)
    }

    // MARK: - At double-Shift time: a box in focus

    @TextActor func testTheDoubleShiftEnablesAChatAppNotEnabledYet() async {
        let rig = rig(focus: Self.composer)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום")
        XCTAssertEqual(sink.traces.last?.chatAX, "wrote:set")
        XCTAssertEqual(sink.traces.last?.chatAXPrep, "none", "nothing was tried before this press")
        XCTAssertTrue(rig.replacer.walks.isEmpty, "a box was there: no walk")
        XCTAssertNil(sink.traces.last?.chatFocusWalk)
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids, [slackPID], "the safety net wrote the flag; the schedule found the tree")
    }

    @TextActor func testAnEnabledChatAppIsNotWrittenAgainWhenTheBoxIsThere() async {
        let rig = rig(focus: Self.composer)
        await frontmostAndSettled(rig)
        _ = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(setter.pids, [slackPID])
        XCTAssertEqual(sink.traces.last?.chatAX, "alreadySet(age=300ms)")
        XCTAssertEqual(sink.traces.last?.chatAXPrep, "tries=2 writes=1 last=set built=yes")
    }

    // MARK: - No box in focus: the walk

    /// The owner's P4-5b case: the tree is there, the composer had focus before it was built, AX names no focus.
    @TextActor func testTheWalkFindsTheFocusedComposerAndItConverts() async {
        let rig = rig(focus: nil, walks: [.found(Self.stats(660, ms: 58, depth: 23))], walkMs: 58)
        await frontmostAndSettled(rig)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.pasteboard.box, "שלום")
        XCTAssertEqual(rig.replacer.walks.count, 1)
        XCTAssertEqual(rig.replacer.walks.first?.pid, slackPID)
        XCTAssertEqual(rig.replacer.walks.first?.maxNodes, ChatFocusWalk.defaultMaxNodes)
        XCTAssertLessThanOrEqual(rig.replacer.walks.first?.budgetNanos ?? .max, ConvertController.chatFocusWaitNanos)
        XCTAssertEqual(setter.pids, [slackPID], "the tree was there: no re-write")
        XCTAssertEqual(sink.traces.last?.chatFocusWalk, "found nodes=660 ms=58 depth=23")
        XCTAssertNil(sink.traces.last?.chatAXRetry)
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testEveryDoubleShiftWalksAgainAndThePinEndsWithTheRequest() async {
        let rig = rig(focus: nil, walks: [.found(Self.stats(660, ms: 58, depth: 23))], walkMs: 58)
        await frontmostAndSettled(rig)
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
        await frontmostAndSettled(rig)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .pasteboard, switched: true))
        XCTAssertEqual(rig.replacer.focus?.role, "AXGroup", "the system focus is back after the request")
    }

    /// The first double-Shift right after Slack starts, when the launch write was missed: this press writes; the tree
    /// takes 1–2 s, so it just switches at once (no waiting, no second write) and the schedule looks again later.
    @TextActor func testAfterAFreshWriteABareWindowJustSwitchesAtOnce() async {
        let rig = rig(focus: nil, walks: [Self.bareWindow])
        let start = clock.nowNanos
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(clock.nowNanos, start, "no waiting")
        XCTAssertEqual(rig.replacer.walks.count, 1)
        XCTAssertEqual(sink.traces.last?.chatFocusWalk, "notFound nodes=12 ms=0 depth=6")
        XCTAssertNil(sink.traces.last?.chatAXRetry, "no re-write right after this press's own write")
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids, [slackPID])
        XCTAssertGreaterThanOrEqual(rig.replacer.windowWalks, 1, "the schedule looked again")
    }

    /// The owner's ~0.9 s presses: each one used to re-write and restart the build.
    @TextActor func testRepeatedPressesOnABareWindowNeverReWriteWithinThreeSeconds() async {
        let rig = rig(focus: nil, walks: [Self.bareWindow])
        await frontmostAndSettled(rig)   // written at 0 s
        for gen in UInt64(1)...4 {
            prepClock.advance(byMilliseconds: 600)
            _ = await rig.sut.handle(request(empty(), gen: gen), layouts: layouts)
            XCTAssertTrue(sink.traces.last?.chatAXRetry?.hasPrefix("rewrote(throttled(age=") == true,
                          sink.traces.last?.chatAXRetry ?? "nil")
            await rig.sut.chatPrepSettled()
        }
        XCTAssertEqual(setter.pids, [slackPID], "no rewrite storm")
    }

    @TextActor func testABareWindowOfAnEnabledAppIsReWrittenAfterThreeSeconds() async {
        let rig = rig(focus: nil, walks: [Self.bareWindow])
        await frontmostAndSettled(rig)
        prepClock.advance(bySeconds: 3)
        let out = await rig.sut.handle(request(empty()), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable), "no waiting for the new build")
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "rewrote(wrote:set)")
        XCTAssertEqual(rig.replacer.walks.count, 1)
        XCTAssertEqual(setter.pids, [slackPID, slackPID])
    }

    @TextActor func testAFullTreeWithNoFocusedBoxJustSwitchesAtOnce() async {
        for snap in [empty(), buffer("akuo")] {
            reset()
            let rig = rig(focus: nil, walks: [.notFound(Self.stats(660, ms: 58, depth: 30))], walkMs: 58)
            await frontmostAndSettled(rig)
            let out = await rig.sut.handle(request(snap), layouts: layouts)
            XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable), "never silent")
            XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
            XCTAssertEqual(log.beeps, 0)
            XCTAssertEqual(rig.poster.events.count, 0, "no keys, no clipboard in a chat app without a box")
            XCTAssertEqual(rig.pasteboard.restores, 0)
            XCTAssertEqual(rig.replacer.walks.count, 1)
            XCTAssertEqual(setter.pids, [slackPID], "no re-write")
            XCTAssertEqual(sink.traces.last?.chatFocusWalk, "notFound nodes=660 ms=58 depth=30")
            XCTAssertEqual(sink.traces.last?.steps.last, .init(path: .switchOnly, reason: "fieldUnreadable"))
            XCTAssertTrue(sink.traces.last?.steps.contains(.init(path: .switchOnly, reason: "chatNoBox")) == true)
            XCTAssertEqual(log.finishes.count, 1)
        }
    }

    @TextActor func testAWalkOutOfBudgetJustSwitches() async {
        let rig = rig(focus: nil, walks: [.budget(Self.stats(1_700, ms: 150, depth: 25))], walkMs: 150)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(rig.replacer.walks.count, 1)
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
        await frontmostAndSettled(rig)
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertEqual(clipboardKeys(rig.poster), 0, "nothing posted")
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
    }

    // MARK: - No walk

    @TextActor func testABusyAppThatDidNotAnswerIsNotWalkedAndTheScheduleKeepsTrying() async {
        // P4-5 QA: the safety net got no answer (Slack still launching): walks would only time out too.
        setter.setAnswer(.noAnswer)
        let rig = rig(focus: nil, walks: [.found(Self.stats(1))])
        let out = await rig.sut.handle(request(buffer("akuo")), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertTrue(rig.replacer.walks.isEmpty)
        XCTAssertEqual(rig.poster.events.count, 0, "P3-58: no keys in a chat app")
        XCTAssertEqual(sink.traces.last?.chatAXRetry, "notTried(wrote:noAnswer)")
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids.count, 1 + ConvertController.chatPrepScheduleNanos.count, "P4-5c: retried off main")
        XCTAssertFalse(rig.enabler.isSet(pid: slackPID))
    }

    @TextActor func testWithTheClipboardSwitchOffNothingIsWrittenNorWalked() async {
        // P4-5 QA: chat apps convert only by the clipboard; with it off double-Shift just switches.
        let rig = rig(focus: nil, walks: [.found(Self.stats(1))])
        let out = await rig.sut.handle(request(empty(), useClipboard: false), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        await rig.sut.chatPrepSettled()
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
        await rig.sut.chatPrepSettled()
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
        await rig.sut.chatPrepSettled()
        XCTAssertEqual(setter.pids, [])
        XCTAssertTrue(rig.replacer.walks.isEmpty)
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
        XCTAssertTrue(line.contains("chatAXPrep{none}"), line)
        XCTAssertTrue(line.contains("chatFocusWalk=found nodes=660 ms=58 depth=23"), line)
        for word in ["secretword", "akuo", "שלום"] { XCTAssertFalse(line.contains(word), line) }
    }
}
