// P6-0h (QA): the late focus clears in Settings never take the focus from the user's own click or Tab.

import XCTest

final class InitialFocusPolicyTests: XCTestCase {
    func testAnAutoPickedFocusWithNoUserInputIsCleared() {
        XCTAssertTrue(InitialFocusPolicy.shouldClear(hasFocus: true, editingText: false,
                                                     inputsWhenScheduled: 3, inputsNow: 3))
    }

    func testAClickOrTabSinceSchedulingKeepsTheFocus() {
        // e.g. a click into the empty Rules search 0.2 s after the tab opened.
        XCTAssertFalse(InitialFocusPolicy.shouldClear(hasFocus: true, editingText: false,
                                                      inputsWhenScheduled: 3, inputsNow: 4))
    }

    func testAFieldHoldingTextIsNeverCleared() {
        XCTAssertFalse(InitialFocusPolicy.shouldClear(hasFocus: true, editingText: true,
                                                      inputsWhenScheduled: 0, inputsNow: 0))
    }

    func testNothingFocusedNeedsNoClear() {
        XCTAssertFalse(InitialFocusPolicy.shouldClear(hasFocus: false, editingText: false,
                                                      inputsWhenScheduled: 0, inputsNow: 0))
    }

    func testTheLateClearsEndWithinASecond() {
        XCTAssertEqual(InitialFocusPolicy.lateClearDelays.max() ?? 0, 0.35, accuracy: 0.001)
    }
}
