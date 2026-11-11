// P2-12: What the user typed since the last reset, as strokes (key code + layer), never as text (design.md privacy).
// P3-33 (owner 2026-11-11): no word limit any more. It holds everything typed since the last Return/Enter, Tab,
// Option-Space, click, focus change or other reset (the processor ends it there), so a double-Shift in an app whose
// text box can't be read converts the whole wrong-language run, not just the last 3 words.
// Bounded: at most `maxStrokes` keys in all, letters plus the spaces between words (so the key path never backspaces
// more than that many characters). When full, the oldest word (and the spaces after it) is dropped first, so the
// buffer always starts on a word boundary and a convert turns as much of the tail as fits.
// Storage is reserved up front, so appending on the per-key path never allocates (B1). Typing appends in O(1); only
// dropping the oldest word when full moves the (≤ 512) kept strokes, a bounded copy of a few hundred bytes.

import Foundation

struct WordBuffer: Sendable, Equatable {
    /// P3-33: keys held at most, letters and spaces together (was 64 strokes / 3 words). 512 is several long chat
    /// messages or a long shell command; retyping it posts ≤ 512 Backspaces + ≤ 512 / 16 text events, which stays far
    /// inside the 400 ms convert budget (B5) and the 1 s hold-back cap (B3). See 001 §12.3 X2 (P3-33).
    static let maxStrokes = 512

    /// Every kept word, oldest first, with no separators.
    private var storage: [Stroke] = []
    /// Start index in `storage` of each word. The last one is the current word. Never empty.
    private var wordStarts: [Int] = [0]
    /// gaps[i] = whitespace keys typed between word i and word i + 1 (so Backspace can rejoin them).
    private var gaps: [Int] = []
    /// P3-33: `gaps`' sum, so the letters-plus-spaces bound is checked in O(1).
    private var spaceCount = 0
    /// The current word grew past `maxStrokes`; ignore strokes until the next boundary.
    private var overflowed = false

    init() {
        storage.reserveCapacity(Self.maxStrokes)
        wordStarts.reserveCapacity(Self.maxStrokes + 2)
        gaps.reserveCapacity(Self.maxStrokes + 1)
    }

    // MARK: - Reading

    var isEmpty: Bool { storage.isEmpty && !overflowed }
    var strokeCount: Int { storage.count }
    /// P3-33: letters plus the spaces between words, what a key-path convert backspaces over (≤ `maxStrokes`).
    var keyCount: Int { storage.count + spaceCount }
    /// Words held, counting a non-empty current word.
    var wordCount: Int { wordStarts.count - (currentWordIsEmpty ? 1 : 0) }
    var currentWord: ArraySlice<Stroke> { storage[currentStart...] }
    private var currentStart: Int { wordStarts[wordStarts.count - 1] }
    private var currentWordIsEmpty: Bool { currentStart == storage.count }

    /// Copies the buffer for a worker. Allocates, so call it only on a trigger.
    /// P2-59 (001 §12.3 X5): with the spaces after each earlier word (`gaps`), so the whole buffer can be rendered.
    func snapshot(renderedIn: InputSourceID?, epoch: UInt64 = 0, crossedFocus: Bool = false) -> WordSnapshot {
        var previous: [[Stroke]] = []
        previous.reserveCapacity(wordStarts.count - 1)
        for i in 0..<(wordStarts.count - 1) {
            previous.append(Array(storage[wordStarts[i]..<wordStarts[i + 1]]))
        }
        let current = Array(storage[currentStart...])
        return WordSnapshot(strokes: current, previousWords: previous, renderedIn: renderedIn,
                            isValid: !current.isEmpty && !overflowed, gaps: gaps, epoch: epoch,
                            crossedFocus: crossedFocus)
    }

    // MARK: - Writing

    mutating func append(_ s: Stroke) {
        if overflowed { return }
        // P3-33: make room by dropping whole old words; one word longer than the cap can't be converted exactly.
        guard makeRoom() else {
            invalidate()
            overflowed = true
            return
        }
        storage.append(s)
    }

    /// Whitespace was typed. Returns true when it ended a non-empty word.
    @discardableResult
    mutating func boundary() -> Bool {
        if overflowed {
            invalidate()
            return false
        }
        if currentWordIsEmpty {
            // More whitespace after a word. With nothing before it we know nothing, so record nothing.
            guard !gaps.isEmpty else { return false }
            // P3-33: room for one more space. Dropping the only earlier word leaves nothing known before the caret.
            guard makeRoom() else { return false }
            if gaps.isEmpty { return false }
            gaps[gaps.count - 1] += 1
            spaceCount += 1
            return false
        }
        if !makeRoom() {
            // The current word alone fills the buffer: the space can't be counted, so forget it all.
            invalidate()
            return true
        }
        wordStarts.append(storage.count)
        gaps.append(1)
        spaceCount += 1
        return true
    }

    /// Backspace: remove the last stroke, or one whitespace key between words.
    mutating func backspace() {
        if overflowed {
            invalidate()
            return
        }
        if !currentWordIsEmpty {
            storage.removeLast()
            return
        }
        guard !gaps.isEmpty else { return } // nothing known before the caret
        spaceCount -= 1
        if gaps[gaps.count - 1] > 1 {
            gaps[gaps.count - 1] -= 1
        } else {
            // The only space after the previous word was deleted: that word is current again.
            gaps.removeLast()
            wordStarts.removeLast()
        }
    }

    /// Forget everything (mouse, navigation, shortcut, context change, Secure Input, tap re-enable, Return…).
    mutating func invalidate() {
        storage.removeAll(keepingCapacity: true)
        wordStarts.removeAll(keepingCapacity: true)
        wordStarts.append(0)
        gaps.removeAll(keepingCapacity: true)
        spaceCount = 0
        overflowed = false
    }

    /// After a replacement: the current word is now these strokes (e.g. the same strokes, rendered in the
    /// other layout). Earlier words are kept while they fit.
    mutating func replaceCurrentWord(with strokes: [Stroke]) {
        guard strokes.count <= Self.maxStrokes else {
            invalidate()
            return
        }
        overflowed = false
        storage.removeSubrange(currentStart...)
        while keyCount + strokes.count > Self.maxStrokes, wordStarts.count > 1 { dropOldestWord() }
        storage.append(contentsOf: strokes)
    }

    /// P3-33: room for one more key (letter or space), dropping the oldest words first. False when the current word
    /// alone fills the buffer.
    private mutating func makeRoom() -> Bool {
        while keyCount >= Self.maxStrokes {
            guard wordStarts.count > 1 else { return false }
            dropOldestWord()
        }
        return true
    }

    private mutating func dropOldestWord() {
        let n = wordStarts[1]
        storage.removeFirst(n)
        wordStarts.removeFirst()
        for i in wordStarts.indices { wordStarts[i] -= n }
        spaceCount -= gaps.removeFirst()
    }
}
