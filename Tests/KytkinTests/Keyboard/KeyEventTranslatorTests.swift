// P2-17: CGEvent → KeyEvent translation and timestamp units. CGEvents are created in memory only, never posted.

import CoreGraphics
import XCTest

final class KeyEventTranslatorTests: XCTestCase {
    private typealias T = TapEventFactory

    // MARK: - Kinds

    func testEventTypesMapToCoreKinds() {
        XCTAssertEqual(KeyEventTranslator.kind(for: .keyDown), .keyDown)
        XCTAssertEqual(KeyEventTranslator.kind(for: .keyUp), .keyUp)
        XCTAssertEqual(KeyEventTranslator.kind(for: .flagsChanged), .flagsChanged)
        XCTAssertEqual(KeyEventTranslator.kind(for: .leftMouseDown), .pointerDown)
        XCTAssertEqual(KeyEventTranslator.kind(for: .rightMouseDown), .pointerDown)
        XCTAssertEqual(KeyEventTranslator.kind(for: .otherMouseDown), .pointerDown)
        XCTAssertNil(KeyEventTranslator.kind(for: .mouseMoved))
        XCTAssertNil(KeyEventTranslator.kind(for: .leftMouseUp))
        XCTAssertNil(KeyEventTranslator.kind(for: .tapDisabledByTimeout), "handled by the watchdog, not the processor")
    }

    func testDisabledNoticesAreRecognized() {
        XCTAssertTrue(KeyEventTranslator.isTapDisabledNotice(.tapDisabledByTimeout))
        XCTAssertTrue(KeyEventTranslator.isTapDisabledNotice(.tapDisabledByUserInput))
        XCTAssertFalse(KeyEventTranslator.isTapDisabledNotice(.keyDown))
    }

    func testTheTapAsksOnlyForKeysModifiersAndClicks() {
        let mask = KeyEventTranslator.eventsOfInterest
        func has(_ t: CGEventType) -> Bool { mask & (CGEventMask(1) << CGEventMask(t.rawValue)) != 0 }
        for t: CGEventType in [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            XCTAssertTrue(has(t), "missing \(t.rawValue)")
        }
        for t: CGEventType in [.mouseMoved, .leftMouseUp, .scrollWheel, .leftMouseDragged] {
            XCTAssertFalse(has(t), "a mouse move per pixel would be wasted callbacks: \(t.rawValue)")
        }
    }

    // MARK: - Fields

    func testKeyDownCarriesCodeFlagsAndTimestamp() {
        let flags = KeyEvent.shiftMask | KeyEvent.leftShiftDeviceBit
        let e = T.key(0, flags: flags, at: 7)
        let k = KeyEventTranslator.keyEvent(.keyDown, from: e, origin: .user, timestampNanos: 7 * T.ms)
        XCTAssertEqual(k.kind, .keyDown)
        XCTAssertEqual(k.keyCode, 0)
        XCTAssertEqual(k.deviceFlags, flags, "raw flags, including the device Shift bits")
        XCTAssertTrue(k.leftShiftDown)
        XCTAssertEqual(k.layer, .shift)
        XCTAssertEqual(k.timestampNanos, 7 * T.ms)
        XCTAssertFalse(k.commandOrControl)
        XCTAssertFalse(k.capsLock)
        XCTAssertFalse(k.isAutoRepeat)
        XCTAssertEqual(k.origin, .user)
    }

    func testRightShiftDeviceBitSurvives() {
        let e = T.flagsChanged(KeyCode.rightShift, KeyEvent.shiftMask | KeyEvent.rightShiftDeviceBit, at: 1)
        let k = KeyEventTranslator.keyEvent(.flagsChanged, from: e, origin: .user, timestampNanos: 1)
        XCTAssertEqual(k.keyCode, KeyCode.rightShift)
        XCTAssertTrue(k.rightShiftDown)
        XCTAssertFalse(k.leftShiftDown)
    }

    func testCommandControlAndCapsLock() {
        let cmd = KeyEventTranslator.keyEvent(.keyDown, from: T.key(8, flags: CGEventFlags.maskCommand.rawValue),
                                              origin: .user, timestampNanos: 1)
        XCTAssertTrue(cmd.commandOrControl)
        let ctrl = KeyEventTranslator.keyEvent(.keyDown, from: T.key(8, flags: CGEventFlags.maskControl.rawValue),
                                               origin: .user, timestampNanos: 1)
        XCTAssertTrue(ctrl.commandOrControl)
        let option = KeyEventTranslator.keyEvent(.keyDown, from: T.key(8, flags: CGEventFlags.maskAlternate.rawValue),
                                                 origin: .user, timestampNanos: 1)
        XCTAssertFalse(option.commandOrControl)
        XCTAssertEqual(option.layer, .option)
        let caps = KeyEventTranslator.keyEvent(.keyDown, from: T.key(8, flags: CGEventFlags.maskAlphaShift.rawValue),
                                               origin: .user, timestampNanos: 1)
        XCTAssertTrue(caps.capsLock)
        XCTAssertEqual(caps.layer, .capsLock)
    }

    func testAutoRepeatOnlyOnKeyDown() {
        let down = T.key(0)
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertTrue(KeyEventTranslator.keyEvent(.keyDown, from: down, origin: .user, timestampNanos: 1).isAutoRepeat)
        let up = T.key(0, down: false)
        up.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertFalse(KeyEventTranslator.keyEvent(.keyUp, from: up, origin: .user, timestampNanos: 1).isAutoRepeat)
    }

    func testMouseDownHasNoKeyCode() {
        let k = KeyEventTranslator.keyEvent(.pointerDown, from: T.mouseDown(), origin: .user, timestampNanos: 1)
        XCTAssertEqual(k.kind, .pointerDown)
        XCTAssertEqual(k.keyCode, 0)
    }

    // MARK: - Markers

    func testMarkerIsReadFromEventSourceUserData() {
        XCTAssertEqual(KeyEventTranslator.origin(of: T.key(0)), .user)
        XCTAssertEqual(KeyEventTranslator.origin(of: T.key(0, marker: EventOrigin.oursMarker)), .ours)
        XCTAssertEqual(KeyEventTranslator.origin(of: T.key(0, marker: EventOrigin.replayMarker)), .replay)
        XCTAssertEqual(KeyEventTranslator.origin(of: T.key(0, marker: 12345)), .user, "someone else's marker is the user")
    }

    // MARK: - Timestamp units

    /// Apple Silicon: timebase 125/3. A timestamp near mach_absolute_time is in ticks and gets converted.
    func testTickTimestampsAreConvertedToNanoseconds() {
        var n = EventTimestampNormalizer(numer: 125, denom: 3)
        XCTAssertEqual(n.unit, .undecided)
        let machNow: UInt64 = 1_000_000, uptimeNow: UInt64 = 1_000_000 * 125 / 3
        XCTAssertEqual(n.nanos(fromEventTimestamp: 990_000, machNow: machNow, uptimeNanosNow: uptimeNow),
                       990_000 * 125 / 3)
        XCTAssertEqual(n.unit, .machTicks)
        // Decided once: later events convert without reading the clocks.
        XCTAssertEqual(n.nanos(fromEventTimestamp: 3, machNow: 0, uptimeNanosNow: 0), 125)
    }

    func testNanosecondTimestampsPassThrough() {
        var n = EventTimestampNormalizer(numer: 125, denom: 3)
        let machNow: UInt64 = 1_000_000, uptimeNow: UInt64 = 1_000_000 * 125 / 3
        XCTAssertEqual(n.nanos(fromEventTimestamp: uptimeNow - 500, machNow: machNow, uptimeNanosNow: uptimeNow),
                       uptimeNow - 500)
        XCTAssertEqual(n.unit, .nanoseconds)
    }

    func testIntelTimebaseNeedsNoDecision() {
        var n = EventTimestampNormalizer(numer: 1, denom: 1)
        XCTAssertEqual(n.unit, .nanoseconds)
        XCTAssertEqual(n.nanos(fromEventTimestamp: 42, machNow: 0, uptimeNanosNow: 0), 42)
    }

    func testZeroTimestampMeansNowAndDecidesNothing() {
        var n = EventTimestampNormalizer(numer: 125, denom: 3)
        XCTAssertEqual(n.nanos(fromEventTimestamp: 0, machNow: 5, uptimeNanosNow: 777), 777)
        XCTAssertEqual(n.unit, .undecided)
    }

    func testHugeTickValuesSaturateInsteadOfTrapping() {
        var n = EventTimestampNormalizer(numer: 125, denom: 3)
        XCTAssertEqual(n.nanos(fromEventTimestamp: .max, machNow: .max, uptimeNanosNow: 0), .max)
    }

    func testResetForgetsTheDecision() {
        var n = EventTimestampNormalizer(numer: 125, denom: 3)
        _ = n.nanos(fromEventTimestamp: 10, machNow: 10, uptimeNanosNow: 400)
        XCTAssertEqual(n.unit, .machTicks)
        n.reset()
        XCTAssertEqual(n.unit, .undecided)
    }
}
