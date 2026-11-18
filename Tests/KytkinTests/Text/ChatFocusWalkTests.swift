// P4-5b: the chat focus walk (breadth first, read only, bounded by nodes, time and the first timeout) and the pin that
// lets a walked composer stand in for the focused element while it keeps `AXFocused = true`. Fake trees and fake
// elements only; no AX, no real app.

import XCTest

/// A node of a fake AX tree. Counts every read; can time out or take time on the fake clock.
final class FakeWalkNode: ChatFocusWalkNode {
    let role: String?
    var children: [FakeWalkNode]
    var focused: Bool?
    var readFails = false
    var readTimesOut = false
    var focusTimesOut = false
    /// Each read moves the clock this much.
    var readNanos: UInt64 = 0
    let clock: FakeClock
    private(set) var reads = 0
    private(set) var focusReads = 0
    private(set) var timeouts: [Double] = []

    init(_ role: String?, focused: Bool? = nil, clock: FakeClock, _ children: [FakeWalkNode] = []) {
        self.role = role
        self.focused = focused
        self.clock = clock
        self.children = children
    }

    func roleAndChildren(timeout: Double) -> ChatFocusNodeRead<FakeWalkNode> {
        reads += 1
        timeouts.append(timeout)
        clock.advance(byNanos: readNanos)
        if readTimesOut { return .timedOut }
        if readFails { return .failed }
        return .read(role: role, children: children)
    }

    func isFocused(timeout: Double) -> (focused: Bool?, timedOut: Bool) {
        focusReads += 1
        return (focusTimesOut ? nil : focused, focusTimesOut)
    }
}

/// A focus provider whose system answer and walk the test sets.
final class FakeWalkingFocusProvider: FocusedElementProviding {
    var system: Result<any AXTextElement, AXAccessError> = .failure(.noValue)
    var walk = ChatFocusWalkResult.unavailable
    /// The focused application (the fake composer's app, 4242, by default; nil = unknown).
    var appPID: Int32? = 4242
    private(set) var walks = 0
    func focusedTextElement(timeout: Double) -> Result<any AXTextElement, AXAccessError> { system }
    func focusedApplicationPID(timeout: Double) -> Int32? { appPID }
    func chatFocusWalk(pid: Int32, maxNodes: Int, budgetNanos: UInt64) -> ChatFocusWalkResult {
        walks += 1
        return walk
    }
}

final class ChatFocusWalkTests: XCTestCase {
    private var clock: FakeClock!

    override func setUp() { clock = FakeClock(nowNanos: 1_000_000_000) }

    private func node(_ role: String?, focused: Bool? = nil, _ children: [FakeWalkNode] = []) -> FakeWalkNode {
        FakeWalkNode(role, focused: focused, clock: clock, children)
    }

    /// Window → groups → … → the composer, like the owner's Slack (deep, with unfocused text boxes around).
    private func slackLikeTree(composerDepth: Int = 23) -> (root: FakeWalkNode, composer: FakeWalkNode) {
        let composer = node("AXTextArea", focused: true)
        var current = composer
        for level in stride(from: composerDepth - 1, through: 0, by: -1) {
            let siblings = [node("AXStaticText"), node("AXButton"), node("AXTextField", focused: false)]
            current = node(level == 0 ? "AXWindow" : "AXGroup", siblings + [current])
        }
        return (current, composer)
    }

    func testFindsTheFocusedComposerDeepInTheWindow() {
        let (root, composer) = slackLikeTree()
        guard case let .found(found, stats) = ChatFocusWalk.find(from: root, budgetNanos: 150_000_000, clock: clock)
        else { return XCTFail("not found") }
        XCTAssertTrue(found === composer)
        XCTAssertEqual(stats.depth, 23)
        XCTAssertGreaterThan(stats.nodes, 23)
    }

    func testAsksAXFocusedOnlyOfTextBoxes() {
        let button = node("AXButton", focused: true)   // a focused button is not a box
        let field = node("AXTextField", focused: false)
        let root = node("AXWindow", [button, node("AXGroup", [field])])
        guard case .notFound(let stats) = ChatFocusWalk.find(from: root, budgetNanos: 150_000_000, clock: clock)
        else { return XCTFail("a box was found") }
        XCTAssertEqual(stats.nodes, 4)
        XCTAssertEqual(button.focusReads, 0)
        XCTAssertEqual(field.focusReads, 1)
    }

    func testStopsAtTheNodeLimit() {
        let (root, _) = slackLikeTree()
        guard case .budget(let stats) = ChatFocusWalk.find(from: root, maxNodes: 10, budgetNanos: 150_000_000,
                                                           clock: clock)
        else { return XCTFail("expected the node limit") }
        XCTAssertEqual(stats.nodes, 10)
    }

    func testStopsWhenTheTimeIsSpent() {
        let (root, _) = slackLikeTree()
        var all: [FakeWalkNode] = [root]
        var i = 0
        while i < all.count { all[i].readNanos = 10_000_000; all.append(contentsOf: all[i].children); i += 1 }
        guard case .budget(let stats) = ChatFocusWalk.find(from: root, budgetNanos: 50_000_000, clock: clock)
        else { return XCTFail("expected the time limit") }
        XCTAssertEqual(stats.nodes, 5)
        XCTAssertEqual(stats.nanos, 50_000_000)
        XCTAssertTrue(root.timeouts.allSatisfy { $0 <= ChatFocusWalk.maxReadTimeout && $0 >= ChatFocusWalk.minReadTimeout })
        XCTAssertEqual(root.timeouts.first ?? 0, 0.05, accuracy: 1e-9, "a read never waits longer than what is left")
    }

    func testStopsAtTheFirstTimeout() {
        let hung = node("AXGroup", [node("AXTextArea", focused: true)])
        hung.readTimesOut = true
        let after = node("AXTextArea", focused: true)
        let root = node("AXWindow", [hung, after])
        guard case .budget(let stats) = ChatFocusWalk.find(from: root, budgetNanos: 150_000_000, clock: clock)
        else { return XCTFail("expected a stop") }
        XCTAssertEqual(stats.nodes, 2)
        XCTAssertEqual(after.reads, 0, "nothing more is asked of an app that stopped answering")
    }

    func testAFocusReadTimeoutStopsToo() {
        let box = node("AXTextArea", focused: true)
        box.focusTimesOut = true
        guard case .budget = ChatFocusWalk.find(from: node("AXWindow", [box]), budgetNanos: 150_000_000, clock: clock)
        else { return XCTFail("expected a stop") }
    }

    func testSkipsUnreadableNodes() {
        let gone = node("AXGroup", [node("AXTextArea", focused: true)])
        gone.readFails = true
        let composer = node("AXTextArea", focused: true)
        guard case .found(let found, _) = ChatFocusWalk.find(from: node("AXWindow", [gone, node("AXGroup", [composer])]),
                                                            budgetNanos: 150_000_000, clock: clock)
        else { return XCTFail("not found") }
        XCTAssertTrue(found === composer)
    }

    func testNoTimeNoWalk() {
        let root = node("AXWindow")
        guard case .budget(let stats) = ChatFocusWalk.find(from: root, budgetNanos: 0, clock: clock)
        else { return XCTFail("expected budget") }
        XCTAssertEqual(stats.nodes, 0)
        XCTAssertEqual(root.reads, 0)
    }

    func testReportTraceNamesAreCountsOnly() {
        let s = ChatFocusWalk.Stats(nodes: 660, depth: 23, nanos: 58_400_000)
        XCTAssertEqual(ChatFocusWalkReport.found(s).traceName, "found nodes=660 ms=58 depth=23")
        XCTAssertEqual(ChatFocusWalkReport.notFound(s).traceName, "notFound nodes=660 ms=58 depth=23")
        XCTAssertEqual(ChatFocusWalkReport.budget(s).traceName, "budget nodes=660 ms=58 depth=23")
        XCTAssertEqual(ChatFocusWalkReport.unavailable.traceName, "unavailable")
    }

    // MARK: - The pin

    private func composerField() -> FakeTextField {
        let f = FakeTextField("akuo")
        f.role = "AXTextArea"
        f.focusedAnswer = .success(true)
        return f
    }

    func testUnpinnedItIsTheSystemFocus() {
        let base = FakeWalkingFocusProvider()
        let pin = ChatFocusPin(base: base)
        guard case .failure(.noValue) = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("not the system's") }
        XCTAssertEqual(pin.focusedApplicationPID(timeout: 0.25), 4242)
    }

    func testAPinnedComposerStandsInWhileItSaysItIsFocused() {
        let base = FakeWalkingFocusProvider()
        let pin = ChatFocusPin(base: base)
        let composer = composerField()
        pin.pin(composer)
        guard case .success(let el) = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("no focus") }
        XCTAssertTrue(el.isSameElement(as: composer))
        // A window as the system focus changes nothing.
        let window = FakeTextField("")
        window.role = "AXWindow"
        base.system = .success(window)
        guard case .success(let el2) = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("no focus") }
        XCTAssertTrue(el2.isSameElement(as: composer))
        // It lost focus: what the system says (not a box: the convert stops).
        composer.focusedAnswer = .success(false)
        guard case .success(let el3) = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("no focus") }
        XCTAssertTrue(el3.isSameElement(as: window))
        composer.focusedAnswer = .failure(.timeout)
        base.system = .failure(.noValue)
        guard case .failure = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("an unknown focus is none") }
    }

    func testAnotherSystemBoxWinsOverThePin() {
        let base = FakeWalkingFocusProvider()
        let pin = ChatFocusPin(base: base)
        let composer = composerField()
        pin.pin(composer)
        let search = FakeTextField("x")
        search.role = "AXTextField"
        base.system = .success(search)
        guard case .success(let el) = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("no focus") }
        XCTAssertFalse(el.isSameElement(as: composer), "the focus moved: same-element checks fail")
        XCTAssertEqual(composer.focusedReads, 0)
        pin.unpin()
        XCTAssertNil(pin.pinned)
    }

    /// P4-5b QA: a background composer may still say `AXFocused = true`: focus in another app must never pass for it.
    func testThePinNeverStandsInWhenFocusIsInAnotherApp() {
        let base = FakeWalkingFocusProvider()
        let pin = ChatFocusPin(base: base)
        let composer = composerField()
        pin.pin(composer)
        // Another app in front, naming no focused element: nothing (the convert stops, ⌘V is never posted).
        base.appPID = 99
        guard case .failure = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("the pin stood in") }
        // Another app's non-box element in focus (its app not known): that element, not the pin.
        base.appPID = nil
        let finderList = FakeTextField("")
        finderList.role = "AXList"
        finderList.processID = 99
        base.system = .success(finderList)
        guard case .success(let el) = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("no focus") }
        XCTAssertFalse(el.isSameElement(as: composer))
        XCTAssertEqual(composer.focusedReads, 0, "the composer is not even asked")
        // Back in the chat app, still naming nothing: the pin again.
        base.appPID = 4242
        base.system = .failure(.noValue)
        guard case .success(let el2) = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("no focus") }
        XCTAssertTrue(el2.isSameElement(as: composer))
        // Focused application unknown (AX can't tell): the pin's own `AXFocused` decides.
        base.appPID = nil
        guard case .success(let el3) = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("no focus") }
        XCTAssertTrue(el3.isSameElement(as: composer))
    }

    /// P4-5b QA: a focus read that timed out is not followed by another read of the pinned element.
    func testASystemTimeoutAsksThePinNothing() {
        let base = FakeWalkingFocusProvider()
        let pin = ChatFocusPin(base: base)
        let composer = composerField()
        pin.pin(composer)
        base.system = .failure(.timeout)
        guard case .failure(.timeout) = pin.focusedTextElement(timeout: 0.25) else { return XCTFail("not the timeout") }
        XCTAssertEqual(composer.focusedReads, 0)
    }

    @TextActor func testTheExecutorPinsTheWalkedBoxForFocusReadsAndSameElementChecks() async {
        let base = FakeWalkingFocusProvider()
        let composer = composerField()
        base.walk = ChatFocusWalkResult(report: .found(.init(nodes: 660, depth: 23, nanos: 0)), element: composer)
        let executor = ReplacementExecutor(focusProvider: ChatFocusPin(base: base), poster: RecordingPoster())
        XCTAssertNil(executor.focusInfo(timeout: 0.25), "nothing focused before the walk")
        XCTAssertEqual(executor.pinChatFocus(pid: 4242, maxNodes: 2_000, budgetNanos: 100_000_000),
                       .found(.init(nodes: 660, depth: 23, nanos: 0)))
        let info = executor.focusInfo(timeout: 0.25)
        XCTAssertEqual(info?.role, "AXTextArea")
        guard let element = executor.focusedElement else { return XCTFail("no element") }
        XCTAssertTrue(executor.currentFocusedElement(timeout: 0.25)?.isSameElement(as: element) == true)
        executor.endReplacement()
        executor.unpinChatFocus()
        XCTAssertNil(executor.focusInfo(timeout: 0.25), "unpinned: the system's focus again")
    }

    @TextActor func testAnExecutorWithoutThePinCannotWalk() async {
        let executor = ReplacementExecutor(focusProvider: FakeWalkingFocusProvider(), poster: RecordingPoster())
        XCTAssertEqual(executor.pinChatFocus(pid: 1, maxNodes: 10, budgetNanos: 1), .unavailable)
    }

    func testANotFoundWalkPinsNothing() {
        let base = FakeWalkingFocusProvider()
        base.walk = ChatFocusWalkResult(report: .notFound(.init(nodes: 660, depth: 30, nanos: 0)), element: nil)
        let pin = ChatFocusPin(base: base)
        XCTAssertNil(pin.chatFocusWalk(pid: 1, maxNodes: 10, budgetNanos: 1).element)
        XCTAssertNil(pin.pinned)
    }
}
