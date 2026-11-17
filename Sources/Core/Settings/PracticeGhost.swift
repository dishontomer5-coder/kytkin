// P6-0i (owner): the setup window's practice word. The word in the second language ("שלום") is shown as faded "ghost"
// letters of what the same keys type on the other keyboard ("akuo"); the user types it, each letter filling in, then
// presses Shift twice and it becomes the real word. Pure: the sample comes from the user's pair (`LayoutSnapshot`),
// and the typing rules decide what is accepted, so the view only draws.
//
// Privacy: the practice text is typed in Kytkin's own window and lives only in the setup model's memory (P6-0c).

import Foundation

enum PracticeGhost {
    struct Sample: Equatable, Sendable {
        /// What to type, on the keyboard of `typingSide` ("akuo").
        let typed: String
        /// The word it becomes after a double-Shift ("שלום").
        let target: String
        /// The pair side whose keyboard types `typed` (the step switches to it when it opens).
        let typingSide: PairSide

        var letters: [Character] { Array(typed) }
    }

    /// Short, friendly words per language (the side that isn't Latin). Hebrew first: it's Kytkin's default pair.
    static let words: [String: String] = [
        "he": "שלום", "ru": "привет", "uk": "привіт", "bg": "здравей", "el": "γεια", "ar": "مرحبا", "fa": "سلام",
    ]

    /// The sample for the pair: a side whose language has a word above, converted to the other side's keys. nil = no
    /// sensible sample (e.g. two Latin keyboards): the setup keeps the plain practice box.
    static func sample(layouts: LayoutSnapshot?) -> Sample? {
        guard let layouts else { return nil }
        // Prefer the second language as the word (the first is typed), like English ⇄ Hebrew.
        for wordSide in [PairSide.b, .a] {
            let source = layouts.source(of: wordSide)
            guard let map = layouts.converter(from: source)?.from,
                  let word = words[baseLanguage(map.language)],
                  let back = layouts.converter(from: source) else { continue }
            let typed = back.convert(word).text
            guard !typed.isEmpty, typed != word, typed.count == word.count,
                  typed.allSatisfy({ !$0.isWhitespace }) else { continue }
            return Sample(typed: typed, target: word, typingSide: wordSide.other)
        }
        return nil
    }

    static func baseLanguage(_ code: String) -> String {
        code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? ""
    }

    /// Where the practice stands for a box holding `text`.
    enum Phase: Equatable, Sendable {
        /// `filled` letters typed so far (0...count-1).
        case typing(filled: Int)
        /// Every letter typed: "Oops — wrong language!", press Shift twice.
        case wrongLanguage
        /// Converted to the target word.
        case converted
    }

    static func phase(of text: String, sample: Sample) -> Phase {
        if text == sample.target { return .converted }
        let filled = matchingPrefix(text, sample)
        return filled == sample.typed.count ? .wrongLanguage : .typing(filled: filled)
    }

    /// What the box keeps after an edit (forgiving: case doesn't matter; a letter that isn't the next one is turned
    /// away, `rejected`, and the box keeps what was right; Backspace just works). The converted word, and a box
    /// emptied by hand, are kept as they are.
    struct Edit: Equatable, Sendable {
        let text: String
        let rejected: Character?
    }

    static func accept(old: String, new: String, sample: Sample) -> Edit {
        if new == sample.target || new.isEmpty { return Edit(text: new, rejected: nil) }
        // QA (P6-0i): a key typed after the word was converted keeps the word (it used to empty the box and flash the
        // word's first letter as the "wrong" key).
        if old == sample.target, new.count > old.count {
            let same = zip(old, new).prefix { $0 == $1 }.count
            return Edit(text: old, rejected: Array(new)[same])
        }
        let lowered = new.lowercased()
        let filled = matchingPrefix(lowered, sample)
        if filled == lowered.count { return Edit(text: lowered, rejected: nil) }
        // Something that isn't the next letter: keep the right part; report the first wrong character if one was
        // added (not when the user deleted from a converted word, say).
        let kept = String(sample.typed.prefix(filled))
        let added = lowered.count > old.count ? Array(lowered)[filled] : nil
        return Edit(text: kept, rejected: added)
    }

    private static func matchingPrefix(_ text: String, _ sample: Sample) -> Int {
        var n = 0
        for (a, b) in zip(text.lowercased(), sample.typed) {
            guard a == b else { break }
            n += 1
        }
        return min(n, text.count)
    }

    /// VoiceOver: "a, k typed" while typing.
    static func progressAnnouncement(filled: Int, sample: Sample) -> String {
        let letters = sample.letters.prefix(filled).map(String.init).joined(separator: ", ")
        return letters.isEmpty ? "" : "\(letters) typed"
    }
}
