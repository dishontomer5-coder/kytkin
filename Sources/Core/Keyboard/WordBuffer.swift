// P2-12: The last few words the user typed, as strokes (key code + layer), never as text (design.md privacy).
// Bounded: at most 64 strokes and 3 words (the current word + 2 before it). The oldest word is dropped first.
// Storage is reserved up front, so appending on the per-key path never allocates (B1). Every operation touches
// at most 64 strokes, so it is O(1) per event.

import Foundation

struct WordBuffer: Sendable, Equatable {
    static let maxStrokes = 64
    static let maxWords = 3

    /// Every kept word, oldest first, with no separators.
    private var storage: [Stroke] = []
    /// Start index in `storage` of each word. The last one is the current word. Always 1...maxWords entries.
    private var wordStarts: [Int] = [0]
    /// gaps[i] = whitespace keys typed between word i and word i + 1 (so Backspace can rejoin them).
    private var gaps: [Int] = []
    /// The current word grew past `maxStrokes`; ignore strokes until the next boundary.
    private var overflowed = false

    init() {
        storage.reserveCapacity(Self.maxStrokes)
        wordStarts.reserveCapacity(Self.maxWords + 1)
        gaps.reserveCapacity(Self.maxWords)
    }

    // MARK: - Reading

    var isEmpty: Bool { storage.isEmpty && !overflowed }
    var strokeCount: Int { storage.count }
    /// Words held, counting a non-empty current word.
    var wordCount: Int { wordStarts.count - (currentWordIsEmpty ? 1 : 0) }
    var currentWord: ArraySlice<Stroke> { storage[currentStart...] }
    private var currentStart: Int { wordStarts[wordStarts.count - 1] }
    private var currentWordIsEmpty: Bool { currentStart == storage.count }

    /// Copies the buffer for a worker. Allocates, so call it only on a trigger.
    func snapshot(renderedIn: InputSourceID?) -> WordSnapshot {
        var previous: [[Stroke]] = []
        for i in 0..<(wordStarts.count - 1) {
            previous.append(Array(storage[wordStarts[i]..<wordStarts[i + 1]]))
        }
        let current = Array(storage[currentStart...])
        return WordSnapshot(strokes: current, previousWords: previous, renderedIn: renderedIn,
                            isValid: !current.isEmpty && !overflowed)
    }

    // MARK: - Writing

    mutating func append(_ s: Stroke) {
        if overflowed { return }
        while storage.count >= Self.maxStrokes {
            if wordStarts.count > 1 {
                dropOldestWord()
            } else {
                // P2-12: one word longer than 64 strokes can't be converted exactly; forget it until whitespace.
                invalidate()
                overflowed = true
                return
            }
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
            if !gaps.isEmpty { gaps[gaps.count - 1] += 1 }
            return false
        }
        wordStarts.append(storage.count)
        gaps.append(1)
        if wordStarts.count > Self.maxWords { dropOldestWord() }
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
        if gaps[gaps.count - 1] > 1 {
            gaps[gaps.count - 1] -= 1
        } else {
            // The only space after the previous word was deleted: that word is current again.
            gaps.removeLast()
            wordStarts.removeLast()
        }
    }

    /// Forget everything (mouse, navigation, shortcut, context change, Secure Input, tap re-enable).
    mutating func invalidate() {
        storage.removeAll(keepingCapacity: true)
        wordStarts.removeAll(keepingCapacity: true)
        wordStarts.append(0)
        gaps.removeAll(keepingCapacity: true)
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
        while storage.count + strokes.count > Self.maxStrokes, wordStarts.count > 1 { dropOldestWord() }
        storage.append(contentsOf: strokes)
    }

    private mutating func dropOldestWord() {
        let n = wordStarts[1]
        storage.removeFirst(n)
        wordStarts.removeFirst()
        for i in wordStarts.indices { wordStarts[i] -= n }
        gaps.removeFirst()
    }
}
