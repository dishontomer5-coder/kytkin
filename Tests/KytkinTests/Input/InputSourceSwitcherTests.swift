// P2-14: InputSourceSwitcher against a fake TISBackend: the binding switcher contract of 001 §2.2
// (token before and re-armed after a successful select, selectFailed on error, no select when already
// current) and change attribution through SwitchAttributor. No real input source is ever touched.

import XCTest

@MainActor
private final class FakeTISBackend: TISBackend {
    var sourceList: [InputSourceInfo]
    var currentID: InputSourceID?
    /// What select() returns; on success it also makes the target current (like TIS does).
    var selectSucceeds = true
    /// Runs inside select(), before it returns (to simulate a slow select or an early notification).
    var duringSelect: (() -> Void)?
    private(set) var selectCalls: [InputSourceID] = []
    private(set) var selectedChanged: (@MainActor () -> Void)?
    private(set) var enabledChanged: (@MainActor () -> Void)?
    private(set) var observeCount = 0

    init(sources: [InputSourceInfo], current: InputSourceID?) {
        sourceList = sources
        currentID = current
    }

    var current: InputSourceInfo? {
        guard let currentID else { return nil }
        return sourceList.first { $0.id == currentID }
            ?? InputSourceInfo(id: currentID, name: currentID.rawValue, languageCode: "", isEnabled: true,
                               isConvertible: false, isInputMethod: false)
    }

    func sources(includeDisabled: Bool) -> [InputSourceInfo] {
        includeDisabled ? sourceList : sourceList.filter(\.isEnabled)
    }

    func select(_ id: InputSourceID) -> Bool {
        selectCalls.append(id)
        if selectSucceeds { currentID = id }
        duringSelect?()
        return selectSucceeds
    }

    func observe(selectedChanged: @escaping @MainActor () -> Void,
                 enabledChanged: @escaping @MainActor () -> Void) {
        observeCount += 1
        self.selectedChanged = selectedChanged
        self.enabledChanged = enabledChanged
    }

    /// The OS posts kTISNotifySelectedKeyboardInputSourceChanged.
    func postSelectedChanged() { selectedChanged?() }
    /// Someone else (the user, the OS) switched the source.
    func externalSwitch(to id: InputSourceID) {
        currentID = id
        postSelectedChanged()
    }
}

@MainActor
final class InputSourceSwitcherTests: XCTestCase {
    private let abc = InputSourceInfo(id: InputSourceID("com.apple.keylayout.ABC"), name: "ABC", languageCode: "en",
                                      isEnabled: true, isConvertible: true, isInputMethod: false)
    private let hebrew = InputSourceInfo(id: InputSourceID("com.apple.keylayout.Hebrew"), name: "Hebrew",
                                         languageCode: "he", isEnabled: true, isConvertible: true,
                                         isInputMethod: false)
    private let russian = InputSourceInfo(id: InputSourceID("com.apple.keylayout.Russian"), name: "Russian",
                                          languageCode: "ru", isEnabled: false, isConvertible: true,
                                          isInputMethod: false)

    private var clock: FakeClock!
    private var backend: FakeTISBackend!
    private var switcher: InputSourceSwitcher!
    private var changes: [InputSourceChange] = []

    override func setUp() async throws {
        try await super.setUp()
        clock = FakeClock(nowNanos: 1_000_000_000)
        backend = FakeTISBackend(sources: [abc, hebrew, russian], current: abc.id)
        switcher = InputSourceSwitcher(backend: backend, clock: clock)
        changes = []
        switcher.onChange = { [weak self] in self?.changes.append($0) }
    }

    // MARK: - Basics

    func testObservesOnceAtInit() {
        XCTAssertEqual(backend.observeCount, 1)
    }

    func testCurrentAndInfoComeFromBackend() {
        XCTAssertEqual(switcher.current, abc.id)
        XCTAssertEqual(switcher.currentInfo?.languageCode, "en")
    }

    func testSourcesPassThrough() {
        XCTAssertEqual(switcher.sources(includeDisabled: false), [abc, hebrew])
        XCTAssertEqual(switcher.sources(includeDisabled: true), [abc, hebrew, russian])
    }

    // MARK: - Contract step 1: already current

    func testSelectCurrentIsNoOpReturningTrue() {
        XCTAssertTrue(switcher.select(abc.id, reason: .rule))
        XCTAssertEqual(backend.selectCalls, [])
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [])
    }

    func testSelectCurrentLeavesNoTokenThatSwallowsAUserSwitch() {
        switcher.select(abc.id, reason: .rule)
        backend.externalSwitch(to: hebrew.id)
        clock.advance(byMilliseconds: 100)
        backend.externalSwitch(to: abc.id)
        XCTAssertEqual(changes.count, 2)
        guard case .external(abc.id, _) = changes.last else {
            return XCTFail("a user switch back to the current source must be external, got \(changes)")
        }
    }

    // MARK: - Contract steps 2–4: tokens

    func testOwnSwitchIsOurs() {
        XCTAssertTrue(switcher.select(hebrew.id, reason: .rule))
        XCTAssertEqual(backend.selectCalls, [hebrew.id])
        clock.advance(byMilliseconds: 15)
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [.ours(hebrew.id)])
    }

    func testDuplicateNotificationReportsOnce() {
        switcher.select(hebrew.id, reason: .menu)
        clock.advance(byMilliseconds: 12)
        backend.postSelectedChanged()
        clock.advance(byMilliseconds: 8)
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [.ours(hebrew.id)])
    }

    /// Step 2: the token exists before TISSelectInputSource is called.
    func testTokenIsArmedBeforeSelect() {
        backend.duringSelect = { [unowned self] in backend.postSelectedChanged() }
        switcher.select(hebrew.id, reason: .rule)
        XCTAssertEqual(changes, [.ours(hebrew.id)])
    }

    /// Step 4 (§12 R1): a select that takes 400 ms must not eat the window. The notification comes
    /// 300 ms after the return (700 ms after the first token) and is still ours.
    func testTokenIsReArmedAfterSlowSelect() {
        backend.duringSelect = { [unowned self] in clock.advance(byMilliseconds: 400) }
        switcher.select(hebrew.id, reason: .rule)
        clock.advance(byMilliseconds: 300)
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [.ours(hebrew.id)])
    }

    func testNotificationAfterWindowIsExternal() {
        switcher.select(hebrew.id, reason: .rule)
        clock.advance(byMilliseconds: 500)   // the deadline is exclusive
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [.external(hebrew.id, atNanos: clock.nowNanos)])
    }

    // MARK: - Contract step 3: failure

    func testFailedSelectReturnsFalseAndDropsToken() {
        backend.selectSucceeds = false
        XCTAssertFalse(switcher.select(hebrew.id, reason: .rule))
        XCTAssertEqual(backend.selectCalls, [hebrew.id])
        // The user switches to the same source within 500 ms: it must be learned as theirs.
        clock.advance(byMilliseconds: 50)
        backend.externalSwitch(to: hebrew.id)
        XCTAssertEqual(changes, [.external(hebrew.id, atNanos: clock.nowNanos)])
    }

    func testSelectAfterFailureWorks() {
        backend.selectSucceeds = false
        switcher.select(hebrew.id, reason: .rule)
        backend.selectSucceeds = true
        XCTAssertTrue(switcher.select(hebrew.id, reason: .rule))
        clock.advance(byMilliseconds: 10)
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [.ours(hebrew.id)])
    }

    // MARK: - Step 5: attribution of other changes

    func testExternalSwitchCarriesTime() {
        clock.advance(byMilliseconds: 250)
        backend.externalSwitch(to: hebrew.id)
        XCTAssertEqual(changes, [.external(hebrew.id, atNanos: 1_250_000_000)])
    }

    func testNotificationWithoutChangeAtStartupIsDropped() {
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [])
    }

    func testUserSwitchToOtherSourceWhileTokenPendingIsExternal() {
        switcher.select(hebrew.id, reason: .rule)
        // The notification for our switch never arrives; the user picks another source instead.
        clock.advance(byMilliseconds: 20)
        backend.externalSwitch(to: russian.id)
        XCTAssertEqual(changes, [.external(russian.id, atNanos: clock.nowNanos)])
    }

    func testOursThenUserSwitchBack() {
        switcher.select(hebrew.id, reason: .rule)
        clock.advance(byMilliseconds: 15)
        backend.postSelectedChanged()
        clock.advance(bySeconds: 3)
        backend.externalSwitch(to: abc.id)
        XCTAssertEqual(changes, [.ours(hebrew.id), .external(abc.id, atNanos: clock.nowNanos)])
    }

    func testNilCurrentIsIgnored() {
        backend.currentID = nil
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [])
        XCTAssertEqual(switcher.current, abc.id, "falls back to the last observed source")
    }

    func testNoCallbackAfterOnChangeCleared() {
        switcher.onChange = nil
        backend.externalSwitch(to: hebrew.id)
        XCTAssertEqual(changes, [])
    }

    // MARK: - Races with a user switch whose notification hasn't arrived yet (P2-14 QA)

    /// The user switched ABC → Hebrew; before its notification arrives, a rule asks for Hebrew. Step 1 checks
    /// TIS (already Hebrew), so nothing is selected and the switch stays the user's.
    func testRuleTargetAlreadyPickedByUserIsStillExternal() {
        backend.currentID = hebrew.id   // switched, notification still in flight
        XCTAssertTrue(switcher.select(hebrew.id, reason: .rule))
        XCTAssertEqual(backend.selectCalls, [])
        clock.advance(byMilliseconds: 15)
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [.external(hebrew.id, atNanos: clock.nowNanos)])
    }

    /// The builder's edge case: the user switched ABC → Hebrew, and before that notification arrives Kytkin
    /// selects ABC back. The late notifications both read ABC, the last known source, so nothing is reported
    /// (the user's brief switch is simply never seen). No token is left behind either: a real user switch to
    /// Hebrew and back to ABC right after are both theirs.
    func testSelectBackBeforeUserSwitchNotificationIsHarmless() {
        backend.currentID = hebrew.id
        XCTAssertTrue(switcher.select(abc.id, reason: .rule))
        XCTAssertEqual(backend.selectCalls, [abc.id])
        clock.advance(byMilliseconds: 10)
        backend.postSelectedChanged()   // the user's ABC → Hebrew notification, read after our select
        backend.postSelectedChanged()   // ours
        XCTAssertEqual(changes, [])
        XCTAssertEqual(switcher.current, abc.id)
        clock.advance(byMilliseconds: 50)
        backend.externalSwitch(to: hebrew.id)
        clock.advance(byMilliseconds: 50)
        backend.externalSwitch(to: abc.id)
        XCTAssertEqual(changes, [.external(hebrew.id, atNanos: 1_060_000_000),
                                 .external(abc.id, atNanos: 1_110_000_000)])
    }

    /// Kytkin selects Hebrew, then ABC again before Hebrew's notification arrives (e.g. a quick app switch):
    /// net no change, nothing reported, and the Hebrew token doesn't survive to swallow a user switch.
    func testQuickSelectAndSelectBackReportsNothingAndLeavesNoToken() {
        switcher.select(hebrew.id, reason: .rule)
        switcher.select(abc.id, reason: .rule)
        XCTAssertEqual(backend.selectCalls, [hebrew.id, abc.id])
        clock.advance(byMilliseconds: 15)
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [])
        clock.advance(byMilliseconds: 50)
        backend.externalSwitch(to: hebrew.id)
        XCTAssertEqual(changes, [.external(hebrew.id, atNanos: clock.nowNanos)])
    }

    /// An external notification delivered while our select is still running (the notification for a switch
    /// the user made just before) reads the source TIS reports then, which is already our target: it's ours.
    func testNotificationDeliveredDuringSelectReadsOurTarget() {
        backend.duringSelect = { [unowned self] in
            clock.advance(byMilliseconds: 5)
            backend.postSelectedChanged()
        }
        switcher.select(hebrew.id, reason: .afterConvert)
        clock.advance(byMilliseconds: 15)
        backend.postSelectedChanged()   // the duplicate
        XCTAssertEqual(changes, [.ours(hebrew.id)])
    }

    func testSelectWithNilCurrentStillSelectsAndIsOurs() {
        backend.currentID = nil
        XCTAssertTrue(switcher.select(hebrew.id, reason: .rule))
        XCTAssertEqual(backend.selectCalls, [hebrew.id])
        clock.advance(byMilliseconds: 15)
        backend.postSelectedChanged()
        XCTAssertEqual(changes, [.ours(hebrew.id)])
    }

    func testCurrentIsEmptyWhenTISReportsNoneAndNothingWasSeen() {
        let empty = FakeTISBackend(sources: [abc], current: nil)
        let local = InputSourceSwitcher(backend: empty, clock: clock)
        XCTAssertEqual(local.current, InputSourceID(""))
        XCTAssertNil(local.currentInfo)
    }

    // MARK: - Enabled sources changed

    func testEnabledSourcesChangedCallsOnSourcesListChanged() {
        var calls = 0
        switcher.onSourcesListChanged = { calls += 1 }
        backend.enabledChanged?()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(changes, [])
    }

    // MARK: - Lifetime

    func testBackendCallbacksDoNotRetainSwitcher() {
        weak var weakSwitcher: InputSourceSwitcher?
        do {
            let local = InputSourceSwitcher(backend: backend, clock: clock)
            weakSwitcher = local
        }
        XCTAssertNil(weakSwitcher)
        backend.postSelectedChanged()   // the dangling callback must be harmless
    }
}
