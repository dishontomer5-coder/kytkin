// P2-21: Fakes for ConvertController / ConvertDispatcher. Nothing here touches AX, CGEvent, TIS or a real app:
// the replacer is scripted, the key watcher records calls, the language switch and the beep are closures.

import Foundation

/// Everything the convert flow did, in order, across all fakes (so tests can check claim-before-write and
/// switch-before-finish).
final class ConvertLog: @unchecked Sendable { // @unchecked: guarded by `lock`
    enum Entry: Equatable {
        case focus
        case perform(ReplacementStep)
        case end
        case claim(gen: UInt64)
        case switchTo(InputSourceID, keepsBuffer: Bool)
        /// P2-59c: `renderedIn` is the finish's `bufferRenderedIn` (defaults to nil in expectations).
        case finish(gen: UInt64, newRendering: InputSourceID?, bufferAfter: [Stroke]?, renderedIn: InputSourceID? = nil)
        case beep
        /// P3-37: the fake pasteboard put the user's clipboard back.
        case clipboardRestored
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func add(_ e: Entry) { lock.withLock { storage.append(e) } }
    var entries: [Entry] { lock.withLock { storage } }
    func clear() { lock.withLock { storage = [] } }

    var finishes: [Entry] { entries.filter { if case .finish = $0 { true } else { false } } }
    var claims: [UInt64] { entries.compactMap { if case .claim(let g) = $0 { g } else { nil } } }
    var switches: [Entry] { entries.filter { if case .switchTo = $0 { true } else { false } } }
    var performs: [ReplacementStep] { entries.compactMap { if case .perform(let s) = $0 { s } else { nil } } }
    var beeps: Int { entries.filter { $0 == .beep }.count }
    var focusReads: Int { entries.filter { $0 == .focus }.count }
}

/// Thread-safe KeyWatching for the worker side (claim + finish). The main-only members are never used here.
final class ConvertKeyWatcher: KeyWatching, @unchecked Sendable { // @unchecked: `log` is locked, `claimAnswer` set before use
    let log: ConvertLog
    var claimAnswer = true

    init(log: ConvertLog) { self.log = log }

    func start(mode: TapMode) -> TapMode { preconditionFailure("not used by ConvertController") }
    func stop() { preconditionFailure("not used by ConvertController") }
    func perform(_ operation: KeyWatcherOperation) { preconditionFailure("not used by ConvertController") }
    func checkSecureInputNow() { preconditionFailure("not used by ConvertController") }

    func claimPosting(gen: UInt64) -> Bool {
        log.add(.claim(gen: gen))
        return claimAnswer
    }

    func finishReplacement(gen: UInt64, newRendering: InputSourceID?, bufferAfter: [Stroke]?,
                           bufferRenderedIn: InputSourceID?) {
        log.add(.finish(gen: gen, newRendering: newRendering, bufferAfter: bufferAfter, renderedIn: bufferRenderedIn))
    }
}

/// A scripted text field. `results` answers each step kind; anything unset is `.done`.
@TextActor final class ScriptedReplacer: TextReplacing {
    enum StepKind: Hashable { case axWrite, typeOver, backspace, read, paste, keyCodes }

    let log: ConvertLog
    var focus: FocusInfo?
    var results: [StepKind: StepOutcome] = [:]
    /// What `axReadRunBeforeCaret` finds when it succeeds.
    var foundWord: String?
    /// P2-59c: the read hands this window to the caller's `locate` (as the executor does) and the run it names
    /// becomes `wordBeforeCaret`. Unset: `foundWord` alone, as a window at the field start.
    var window: BeforeCaretWindow?
    /// P3-35: `readField` hands this window to the caller's `locate`. Unset: `foundWord` as the whole field, the caret
    /// at its end.
    var fieldWindow: FieldWindow?
    /// P3-35: what `readRangeEndsAtCaret` reports after a read.
    private(set) var readRangeEndsAtCaret = true
    /// P2-59c: the focused element's identity (the undo record's same-element check).
    var element: (any FocusedElementIdentity)?
    /// Runs inside every `perform` (e.g. to move a fake clock past the budget).
    var onPerform: (() -> Void)?

    /// Text the fake holds for the current replacement (to prove `endReplacement` drops it).
    private(set) var heldOld: String?
    private(set) var heldNew: String?
    private(set) var wordBeforeCaret: String?
    /// Every (old, new) pair a write step was given, for content checks.
    private(set) var writes: [(step: ReplacementStep, old: String, new: String)] = []

    nonisolated init(log: ConvertLog) { self.log = log }

    func focusInfo(timeout: Double) -> FocusInfo? {
        log.add(.focus)
        heldOld = focus?.selection
        return focus
    }

    func perform(_ step: ReplacementStep, old: String, new: String) -> StepOutcome {
        log.add(.perform(step))
        onPerform?()
        heldOld = old
        heldNew = new
        let kind = Self.kind(step)
        let outcome = results[kind] ?? .done
        if kind == .read {
            if outcome.verdict == .done { wordBeforeCaret = foundWord }
        } else {
            writes.append((step, old, new))
        }
        return outcome
    }

    func readRunBeforeCaret(maxChars: Int, locate: (BeforeCaretWindow) -> RunLocation?) -> StepOutcome {
        let step = ReplacementStep.axReadRunBeforeCaret(maxChars: maxChars)
        log.add(.perform(step))
        onPerform?()
        let outcome = results[.read] ?? .done
        guard outcome.verdict == .done else { return outcome }
        let w = window ?? foundWord.map { BeforeCaretWindow(text: $0, location: 0, reachesFieldStart: true) }
        wordBeforeCaret = w.flatMap { w in
            locate(w).map { run in
                let units = Array(w.text.utf16)
                return String(decoding: units[run.offset..<(run.offset + run.length)], as: UTF16.self)
            }
        }
        return outcome
    }

    func readField(maxChars: Int, locate: (FieldWindow) -> FieldEdit?) -> StepOutcome {
        let step = ReplacementStep.axReadField(maxChars: maxChars)
        log.add(.perform(step))
        onPerform?()
        readRangeEndsAtCaret = true
        let outcome = results[.read] ?? .done
        guard outcome.verdict == .done else { return outcome }
        let w = fieldWindow ?? foundWord.map {
            FieldWindow(text: $0, location: 0, caret: $0.utf16.count, reachesFieldStart: true, reachesFieldEnd: true)
        }
        wordBeforeCaret = w.flatMap { w in
            locate(w).map { edit in
                let units = Array(w.text.utf16)
                readRangeEndsAtCaret = w.location + edit.offset + edit.length == w.caret
                return String(decoding: units[edit.offset..<(edit.offset + edit.length)], as: UTF16.self)
            }
        }
        return outcome
    }

    var focusedElement: (any FocusedElementIdentity)? { focus == nil ? nil : element }

    /// P3-37: what `currentFocusedElement` answers (the clipboard's focus re-check, the terminal anchor). Unset: the
    /// focused element while there is a focus.
    var nowFocused: (any FocusedElementIdentity)?
    var nowFocusedIsUnset = true
    private(set) var focusChecks = 0
    func currentFocusedElement(timeout: Double) -> (any FocusedElementIdentity)? {
        focusChecks += 1
        return nowFocusedIsUnset ? focusedElement : nowFocused
    }
    /// P3-41: what `postTerminalKeys` answers; every call is logged as a `.backspaceAndType` perform and a write.
    var terminalKeysResult = StepOutcome.done
    private(set) var terminalKeyPosts = 0
    func postTerminalKeys(count: Int, new: String) -> StepOutcome {
        let step = ReplacementStep.backspaceAndType(count: count)
        log.add(.perform(step))
        terminalKeyPosts += 1
        writes.append((step, "", new))
        return terminalKeysResult
    }

    func setNowFocused(_ e: (any FocusedElementIdentity)?) {
        nowFocused = e
        nowFocusedIsUnset = false
    }

    func endReplacement() {
        log.add(.end)
        heldOld = nil
        heldNew = nil
        wordBeforeCaret = nil
    }

    var holdsText: Bool { heldOld != nil || heldNew != nil || wordBeforeCaret != nil }

    func clearWrites() { writes = [] }

    private static func kind(_ s: ReplacementStep) -> StepKind {
        switch s {
        case .axWriteSelection: .axWrite
        case .typeOverSelection: .typeOver
        case .backspaceAndType: .backspace
        case .axReadRunBeforeCaret, .axReadField: .read
        case .pasteboard: .paste
        case .keyCodesAfterSwitch: .keyCodes
        }
    }
}

/// The main-actor switch hook, as AppController answers it.
final class SwitchRecorder: @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private let log: ConvertLog
    private var answer = true

    init(log: ConvertLog) { self.log = log }

    func setAnswer(_ a: Bool) { lock.withLock { answer = a } }

    var hook: ConvertController.SwitchLanguage {
        { [self] target, keeps in
            log.add(.switchTo(target, keepsBuffer: keeps))
            return lock.withLock { answer }
        }
    }
}

@MainActor final class FakeLayoutMaps: LayoutMapProviding {
    var maps: [InputSourceID: LayoutMap] = [:]
    private(set) var lookups = 0

    func convertibleLayouts(includeDisabled: Bool) -> [InputSourceInfo] { [] }
    func map(for id: InputSourceID) -> LayoutMap? {
        lookups += 1
        return maps[id]
    }
}

enum ConvertFixtures {
    static func map(_ name: String) -> LayoutMap {
        // swiftlint-free force: fixtures are checked in and decoded by other tests too.
        try! JSONDecoder().decode(LayoutMap.self, from: Fixtures.data("layoutmaps/com.apple.keylayout.\(name).json"))
    }

    static let abc = map("ABC")
    static let hebrew = map("Hebrew")
    static let pair = LanguagePair(a: IDs.abc, b: IDs.hebrew)
    static let layouts = LayoutSnapshot(pair: pair, a: abc, b: hebrew)!

    /// The plain-layer strokes that type `text` on ABC. QA: the lowest key code wins, so `.` and digits are the main
    /// keys, not the keypad's (a dictionary's order changes between runs).
    static func strokes(_ text: String) -> [Stroke] {
        text.map { ch in
            let code = abc.keys.filter { $0.value.plain == String(ch) }.map(\.key).min()!
            return Stroke(keyCode: code, layer: .plain)
        }
    }
}
