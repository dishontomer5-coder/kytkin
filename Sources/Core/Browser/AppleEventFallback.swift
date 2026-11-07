// P3-7: The Automation (Apple Events) fallback's decisions (001 §14.7, D9). Pure Core: which property to ask for per
// dialect, when a send is allowed, the rate limit, and how a reply becomes a `SiteRead` or a private flag. The one
// live sender is System/Browser/AppleEventAddressReader (never compiled into tests).
//
// When an Apple Event is sent, exactly (all of):
//   - the browser is the attached frontmost pid, and main still allows it (`AppleEventSendGate`: BrowserWatcher sets
//     the pid on attach with an opted-in-and-granted request, clears it on detach, so a paused/off Kytkin, another
//     app in front, or Kytkin's own window means no send even if a read was already queued on the AX thread);
//   - the request carries a dialect (`request.appleScript`), which SitePolicy sets only when the user turned
//     Automation on for that browser AND it is granted AND Kytkin is on (FeatureAvailability.appleEventsBrowsers);
//   - one of:
//       1. address: this read came back `.unknown` and saw a window (no web area, or an AX timeout). Never for
//          `.editingAddress`, `.notWebPage` or `.page`, and never for a detected private window the user ignores
//          (D12). The reply goes through `SiteReader` with source `.appleEvent`;
//       2. private flag: Chromium/Arc dialect, the AX probe gave nil, once per window (cached per window). Safari's
//          dictionary has no such property, so never.
//   - at most one per second (`AppleEventRateLimiter`), for all browsers together (one AX thread).
// A permission failure (-1743 / -1744) stops sends to that pid until the next attach (a new grant re-attaches).
//
// The reply text is handed straight to `SiteReader` and dropped (001 §14.3.6). No logging (Browser/ folder).

import Foundation

/// What Kytkin asks a browser for. Each is one raw `core/getd` event on a property of the front window.
enum AppleEventQuery: Sendable, Equatable {
    case activeTabAddress   // `URL of active tab of front window` (Safari: `URL of current tab of front window`)
    case frontWindowPrivate // Chromium: `mode of front window`; Arc: `incognito of front window`; Safari: none
}

/// The object path of one query, as four-char codes read from each browser's scripting dictionary (sdef, read from
/// disk on 2026-11-07: Chrome `scripting.sdef`, Arc `Arc.sdef`, Safari `Safari.sdef` + CocoaStandard). The live
/// sender builds `property <property> of [property <tabProperty> of] window 1` from it.
struct AppleEventObjectPath: Sendable, Equatable {
    /// The window class: `cwin` (Chrome, Safari) or `WiND` (Arc's own window class).
    let windowClass: String
    /// The tab property of the window (`acTa` active tab, `cTab` current tab); nil = a property of the window itself.
    let tabProperty: String?
    /// The property read: `URL ` (Chromium/Arc), `pURL` (Safari), `mode` (Chromium), `inco` (Arc).
    let property: String

    /// The 32-bit code of a four-character string (`"cwin"` → 0x6377696E).
    static func code(_ fourChars: String) -> UInt32 {
        fourChars.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

extension AppleScriptDialect {
    /// The object path for `query`; nil = this dialect can't answer it (Safari has no private-window property).
    func path(for query: AppleEventQuery) -> AppleEventObjectPath? {
        switch (self, query) {
        case (.chromium, .activeTabAddress):
            AppleEventObjectPath(windowClass: "cwin", tabProperty: "acTa", property: "URL ")
        case (.chromium, .frontWindowPrivate):
            AppleEventObjectPath(windowClass: "cwin", tabProperty: nil, property: "mode")
        case (.arc, .activeTabAddress):
            AppleEventObjectPath(windowClass: "WiND", tabProperty: "acTa", property: "URL ")
        case (.arc, .frontWindowPrivate):
            AppleEventObjectPath(windowClass: "WiND", tabProperty: nil, property: "inco")
        case (.safari, .activeTabAddress):
            AppleEventObjectPath(windowClass: "cwin", tabProperty: "cTab", property: "pURL")
        case (.safari, .frontWindowPrivate):
            nil
        }
    }

    /// The dialect has a private-window property (§14.4: Chromium `mode`, Arc `incognito`).
    var hasPrivateFlag: Bool { path(for: .frontWindowPrivate) != nil }
}

/// Why a send gave no answer. Raw OSStatus codes (MacErrors.h) mapped by `init(status:)`.
enum AppleEventFailure: Sendable, Equatable {
    case notPermitted        // errAEEventNotPermitted -1743: the user denied Automation for this browser
    case needsConsent        // errAEEventWouldRequireUserConsent -1744: never asked (Kytkin never asks here)
    case notRunning          // procNotFound -600: the pid quit (nothing is launched: the target is a pid)
    case timedOut            // errAETimeout -1712: the browser didn't answer in 0.5 s
    case noSuchObject        // errAENoSuchObject -1728: no window / no tab
    case other(Int32)

    init(status: Int32) {
        switch status {
        case -1743: self = .notPermitted
        case -1744: self = .needsConsent
        case -600: self = .notRunning
        case -1712: self = .timedOut
        case -1728: self = .noSuchObject
        default: self = .other(status)
        }
    }

    /// A permission problem: stop sending to this pid until the next attach.
    var isPermissionProblem: Bool { self == .notPermitted || self == .needsConsent }
}

/// One reply, reduced to what the mapping needs. The text is used once and dropped.
enum AppleEventReply: Sendable, Equatable {
    case text(String)
    case flag(Bool)
    case failed(AppleEventFailure)
}

/// The live sender (System/Browser/AppleEventAddressReader). AX thread only. It must target the pid (never a bundle
/// ID, never `tell application`), wait at most `timeoutSeconds`, and never interact or prompt: it checks the grant
/// silently first and answers `.failed(.needsConsent / .notPermitted)` without sending when it isn't there.
protocol AppleEventSending: AnyObject {
    func send(_ path: AppleEventObjectPath, to pid: Int32, timeoutSeconds: Double) -> AppleEventReply
}

/// Main's say on whether the AX thread may send at all: the one pid that is frontmost, attached, opted in and granted
/// while Kytkin is on. Set by BrowserWatcher on main (never waits: a lock around one Int32), read on the AX thread.
final class AppleEventSendGate: @unchecked Sendable { // @unchecked: `allowedPid` is guarded by `lock`
    private let lock = NSLock()
    private var allowedPid: Int32?

    init() {}

    /// nil = no sends anywhere.
    func allow(pid: Int32?) {
        lock.withLock { allowedPid = pid }
    }

    func allows(_ pid: Int32) -> Bool {
        lock.withLock { allowedPid == pid }
    }
}

/// ≤ 1 Apple Event per second (001 §14.7; R3: "one event per browser-frontmost interval of ≥ 1 s is tolerable").
struct AppleEventRateLimiter: Sendable, Equatable {
    static let minGapNanos: UInt64 = 1_000_000_000

    private(set) var lastSentAt: UInt64?

    init() {}

    /// The earliest time the next send is allowed; nil = now.
    func nextAllowedAt(now: UInt64) -> UInt64? {
        guard let last = lastSentAt, now < last &+ Self.minGapNanos else { return nil }
        return last &+ Self.minGapNanos
    }

    /// true = send now (and the send is counted).
    mutating func take(now: UInt64) -> Bool {
        guard nextAllowedAt(now: now) == nil else { return false }
        lastSentAt = now
        return true
    }
}

/// The result of asking the fallback for something.
enum AppleEventAttempt<Value: Sendable & Equatable>: Sendable, Equatable {
    /// Not sent: the rate limit (retry at `retryAt`), or not allowed (gate closed, permission problem: `retryAt` nil).
    case notSent(retryAt: UInt64?)
    /// Sent; `nil` = no usable answer (a failure, or a reply that says nothing).
    case answered(Value?)
}

/// Owns the sender, the gate, the rate limit and the per-pid permission stop. One per process, AX thread only.
final class AppleEventFallback: @unchecked Sendable { // @unchecked: confined to the AX thread (tests: test thread)
    static let timeoutSeconds = 0.5

    private let sender: any AppleEventSending
    private let gate: AppleEventSendGate
    private var limiter = AppleEventRateLimiter()
    private var blockedPids: Set<Int32> = []

    /// Sends done (for tests).
    private(set) var sendCount = 0

    init(sender: any AppleEventSending, gate: AppleEventSendGate) {
        self.sender = sender
        self.gate = gate
    }

    /// A fresh attach to `pid` (a new request, possibly after a new grant): permission stops are forgotten.
    func attached(pid: Int32) {
        blockedPids.remove(pid)
    }

    /// One send, if every rule allows it.
    func send(_ query: AppleEventQuery, dialect: AppleScriptDialect, pid: Int32,
              now: UInt64) -> AppleEventAttempt<AppleEventReply> {
        guard let path = dialect.path(for: query), gate.allows(pid), !blockedPids.contains(pid) else {
            return .notSent(retryAt: nil)
        }
        guard limiter.take(now: now) else { return .notSent(retryAt: limiter.nextAllowedAt(now: now)) }
        sendCount += 1
        let reply = sender.send(path, to: pid, timeoutSeconds: Self.timeoutSeconds)
        if case .failed(let f) = reply, f.isPermissionProblem { blockedPids.insert(pid) }
        return .answered(reply)
    }

    // MARK: - Pure mapping

    /// The address reply → a `SiteRead` (THE `SiteReader`, source `.appleEvent`). A failure → `.unreadable`.
    static func siteRead(from reply: AppleEventReply, siteReader: SiteReader) -> SiteRead {
        guard case .text(let text) = reply else { return .unreadable }
        return siteReader.read(text, from: .appleEvent)
    }

    /// The private-flag reply → true/false; nil = can't tell (§14.4: nil counts as not private).
    static func privateFlag(from reply: AppleEventReply, dialect: AppleScriptDialect) -> Bool? {
        switch (dialect, reply) {
        case (.chromium, .text(let mode)):
            switch mode.lowercased() {
            case "incognito": true
            case "normal": false
            default: nil
            }
        case (.arc, .flag(let incognito)):
            incognito
        default:
            nil
        }
    }

    /// D9: ask for the address only when this read couldn't tell and saw a window.
    static func wantsAddress(pageState: BrowserPageState, sawWindow: Bool) -> Bool {
        pageState == .unknown && sawWindow
    }
}

/// The fallback bound to one attach (one pid, one dialect). Lives in `BrowserAddressReader`.
struct AppleEventSession {
    let pid: Int32
    let dialect: AppleScriptDialect
    let fallback: AppleEventFallback

    func readAddress(siteReader: SiteReader, now: UInt64) -> AppleEventAttempt<SiteRead> {
        switch fallback.send(.activeTabAddress, dialect: dialect, pid: pid, now: now) {
        case .notSent(let retryAt): .notSent(retryAt: retryAt)
        case .answered(let reply): .answered(reply.map { AppleEventFallback.siteRead(from: $0, siteReader: siteReader) })
        }
    }

    /// `.answered(nil)` = asked, can't tell (cached as such for the window).
    func readPrivateFlag(now: UInt64) -> AppleEventAttempt<Bool> {
        guard dialect.hasPrivateFlag else { return .notSent(retryAt: nil) }
        switch fallback.send(.frontWindowPrivate, dialect: dialect, pid: pid, now: now) {
        case .notSent(let retryAt): return .notSent(retryAt: retryAt)
        case .answered(let reply): return .answered(reply.flatMap { AppleEventFallback.privateFlag(from: $0, dialect: dialect) })
        }
    }
}
