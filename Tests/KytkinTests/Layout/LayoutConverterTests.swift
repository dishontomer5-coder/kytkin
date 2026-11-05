// P2-7: LayoutConverter against R6's conversion table (§6) and key tables (§4), using the real
// UCKeyTranslate fixtures from P2-6. Small hand-made maps cover the ranking rules.

import XCTest

final class LayoutConverterTests: XCTestCase {
    private func fixture(_ name: String) throws -> LayoutMap {
        try JSONDecoder().decode(LayoutMap.self, from: Fixtures.data("layoutmaps/com.apple.keylayout.\(name).json"))
    }

    private var abc: LayoutMap!, he: LayoutMap!, pc: LayoutMap!, qwerty: LayoutMap!, us: LayoutMap!

    override func setUpWithError() throws {
        abc = try fixture("ABC")
        us = try fixture("US")
        he = try fixture("Hebrew")
        pc = try fixture("Hebrew-PC")
        qwerty = try fixture("Hebrew-QWERTY")
    }

    private func convert(_ text: String, _ from: LayoutMap, _ to: LayoutMap) -> String {
        LayoutConverter(from: from, to: to).convert(text).text
    }

    // MARK: - R6 §6 conversion table (ABC ⇄ Apple Hebrew)

    func testAkuoIsShalom() {
        XCTAssertEqual(LayoutConverter(from: abc, to: he).convert("akuo").text, "שלום")
        XCTAssertEqual(LayoutConverter(from: abc, to: he).convert("akuo").unmapped, 0)
        XCTAssertEqual(convert("שלום", he, abc), "akuo")
    }

    func testShiftLettersUseTheCaseRule() {
        // Apple Hebrew Shift+a = שׁ and Shift+k = לֹ, but English capitals are just letters: plain Hebrew.
        XCTAssertEqual(convert("Akuo", abc, he), "שלום")
        XCTAssertEqual(convert("AKUO", abc, he), "שלום")
        // Hebrew has no case, so Hebrew → English is lowercase.
        XCTAssertEqual(convert("שלום", he, abc), "akuo")
    }

    func testSentenceRoundTrips() {
        let hebrew = convert("hi, how are you?", abc, he)
        XCTAssertEqual(hebrew, "יןת ים׳ שרק טםו?")
        XCTAssertEqual(convert(hebrew, he, abc), "hi, how are you?")
    }

    func testPunctuationIsKeyFaithful() {
        // Parentheses and brackets are swapped (bidi mirroring); ' → , ; q → / ; / → . ; w → geresh.
        XCTAssertEqual(convert("(test) [x] 'q' /w/", abc, he), ")אקדא( ]ס[ ,/, .׳.")
        XCTAssertEqual(convert(")אקדא( ]ס[ ,/, .׳.", he, abc), "(test) [x] 'q' /w/")
        XCTAssertEqual(convert("{}<>", abc, he), "}{><")
        XCTAssertEqual(convert(",.;", abc, he), "תץף")
    }

    func testShiftPunctuation() {
        XCTAssertEqual(convert("&", abc, he), "₪")
        XCTAssertEqual(convert("₪", he, abc), "&")
        XCTAssertEqual(convert("\"", abc, he), "\u{05F4}", "gershayim, not ASCII")
        XCTAssertEqual(convert("\u{05F4}", he, abc), "\"")
        XCTAssertEqual(convert(":|~", abc, he), ":|~", "Shift on ; \\ ` types the same")
        // Shared characters type the same on both keys.
        XCTAssertEqual(convert("!@#$%^*-_=+1234567890", abc, he), "!@#$%^*-_=+1234567890")
    }

    func testFinalLettersHaveTheirOwnKeys() {
        XCTAssertEqual(convert("loi;.", abc, he), "ךםןףץ")
        XCTAssertEqual(convert("ךםןףץ", he, abc), "loi;.")
        XCTAssertEqual(convert("fnbpm", abc, he), "כמנפצ")
        XCTAssertEqual(convert("כמנפצ", he, abc), "fnbpm")
        // No automatic final forms: what was pressed is what converts.
        XCTAssertEqual(convert("nkfi", abc, he), "מלכן")
    }

    func testMixedTextConvertsOnlyWhatTheSourceTypes() {
        let r = LayoutConverter(from: he, to: abc).convert("hello שלום")
        XCTAssertEqual(r.text, "hello akuo", "Latin isn't on Apple Hebrew's plain/shift layers")
        XCTAssertEqual(r.unmapped, 5, "space isn't counted")
        let r2 = LayoutConverter(from: abc, to: he).convert("שלום akuo")
        XCTAssertEqual(r2.text, "שלום שלום")
        XCTAssertEqual(r2.unmapped, 4)
    }

    func testUnmappedCharactersPassThrough() {
        let r = LayoutConverter(from: abc, to: he).convert("café ö")
        XCTAssertEqual(r.text, "בשכé ö")
        XCTAssertEqual(r.unmapped, 2)
        let emoji = LayoutConverter(from: abc, to: he).convert("a🙂b")
        XCTAssertEqual(emoji.text, "ש🙂נ")
        XCTAssertEqual(emoji.unmapped, 1)
        let empty = LayoutConverter(from: abc, to: he).convert("")
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.unmapped, 0)
        XCTAssertEqual(convert("a\nb\tc", abc, he), "ש\nנ\tב", "whitespace passes through")
    }

    func testZWJEmojiAndRTLMarksPassThroughWhole() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let r = LayoutConverter(from: abc, to: he).convert("a\(family)b")
        XCTAssertEqual(r.text, "ש\(family)נ")
        XCTAssertEqual(r.text.unicodeScalars.count, 7, "no scalar dropped")
        // RLM / LRM / ALM around Hebrew: the marks stay where they were.
        XCTAssertEqual(convert("\u{200F}שלום\u{200E}\u{061C}", he, abc), "\u{200F}akuo\u{200E}\u{061C}")
        // ZWNJ / ZWJ between letters attach to the previous grapheme; the letter still converts.
        XCTAssertEqual(convert("a\u{200C}k", abc, he), "ש\u{200C}ל")
    }

    func testDecomposedAccentSplitsIntoLetterAndAccent() {
        // NFC é has no key and passes through; NFD e + U+0301 converts the e and keeps the accent.
        XCTAssertEqual(convert("\u{E9}", abc, he), "\u{E9}")
        let r = LayoutConverter(from: abc, to: he).convert("e\u{301}")
        XCTAssertEqual(r.text.unicodeScalars.map(\.value), [0x05E7, 0x0301])
        XCTAssertEqual(r.unmapped, 1)
    }

    func testEmptyTargetTextCountsAsNothing() {
        // A hand-built map can hold "" (the JSON codec rejects it): the original passes through, never dropped.
        let from = map("from", [0: KeyCell(plain: "a")])
        let to = map("to", [0: KeyCell(plain: "")])
        let c = LayoutConverter(from: from, to: to)
        XCTAssertEqual(c.convert("a").text, "a")
        XCTAssertEqual(c.convert("a").unmapped, 1)
        XCTAssertEqual(c.render([Stroke(keyCode: 0, layer: .plain)]), "a")
    }

    func testKeyMissingInTargetPassesThrough() {
        // ABC key 10 types §; Apple Hebrew on ANSI has no key 10.
        let r = LayoutConverter(from: abc, to: he).convert("§")
        XCTAssertEqual(r.text, "§")
        XCTAssertEqual(r.unmapped, 1)
    }

    func testCapsLockAndOptionLayersAreNotIndexed() {
        // Apple Hebrew's Caps Lock layer types a–z; it must not "convert" English inside Hebrew text.
        XCTAssertEqual(convert("hello", he, abc), "hello")
        // Option layers: ABC Option+a = å, Apple Hebrew Option+s = LRM.
        XCTAssertEqual(convert("å", abc, he), "å")
        XCTAssertEqual(convert("\u{200E}", he, abc), "\u{200E}")
    }

    func testPointedGraphemesAreWholeUnits() {
        XCTAssertEqual(convert("שׁ", he, abc), "A", "Shift+a")
        XCTAssertEqual(convert("וֹ", he, abc), "U", "Shift+u")
        XCTAssertEqual(convert("לֹ", he, abc), "C", "Shift+c (8) and Shift+k (40): lowest key code wins")
    }

    func testNiqqudTheLayoutCantTypePassesThroughOnItsBaseLetter() {
        // שָׁ = shin + qamats + shin dot: no key types it, so each scalar is looked up on its own.
        let r = LayoutConverter(from: he, to: abc).convert("שָׁ")
        XCTAssertEqual(r.text, "a\u{05B8}\u{05C1}")
        XCTAssertEqual(r.unmapped, 2)
    }

    func testEveryPlainABCMainKeyRoundTripsThroughHebrew() {
        let toHe = LayoutConverter(from: abc, to: he), toABC = LayoutConverter(from: he, to: abc)
        var all = ""
        for (code, cell) in abc.keys where code != 49 && LayoutReverseIndex.keyRank(code) == 0 {
            guard let plain = cell.plain else { continue }
            XCTAssertEqual(toABC.convert(toHe.convert(plain).text).text, plain, "key \(code)")
            all += plain
        }
        // Joined too: Hebrew rafe (from `\`) combines with its neighbour into one grapheme.
        XCTAssertEqual(toABC.convert(toHe.convert(all).text).text, all)
    }

    func testUSBehavesLikeABC() {
        XCTAssertEqual(convert("akuo", us, he), "שלום")
        XCTAssertEqual(convert("שלום", he, us), "akuo")
    }

    // MARK: - Hebrew-PC (R6 §4)

    func testHebrewPC() {
        XCTAssertEqual(convert("akuo", abc, pc), "שלום")
        XCTAssertEqual(convert("Akuo", abc, pc), "שלום", "PC Shift+a = A, but the case rule picks plain ש")
        XCTAssertEqual(convert("שלום", pc, abc), "akuo")
        XCTAssertEqual(convert("w", abc, pc), "'", "ASCII apostrophe, not geresh")
        XCTAssertEqual(convert("&\"", abc, pc), "&\"", "PC keeps & and \"")
        XCTAssertEqual(convert("hi, how are you?", abc, pc), "יןת ים' שרק טםו?")
        XCTAssertEqual(convert("יןת ים' שרק טםו?", pc, abc), "hi, how are you?")
    }

    func testHebrewPCUppercaseLatinIsOnItsShiftLayer() {
        // PC Shift+letter types uppercase Latin, so capitals convert to themselves; lowercase passes through.
        let r = LayoutConverter(from: pc, to: abc).convert("Hello")
        XCTAssertEqual(r.text, "Hello")
        XCTAssertEqual(r.unmapped, 4)
    }

    func testHebrewPCBackslashIsOnTwoKeys() {
        // R6 ambiguity 1: PC types `\` on 42 and 50. ABC ` (50) → `\`, which maps back to 42 (`\`).
        XCTAssertEqual(convert("`", abc, pc), "\\")
        XCTAssertEqual(convert("\\", pc, abc), "\\")
    }

    // MARK: - Hebrew-QWERTY (phonetic, R6 §4)

    func testHebrewQWERTYIsPhonetic() {
        XCTAssertEqual(convert("hello world", abc, qwerty), "העללו שורלד")
    }

    func testHebrewQWERTYReverseIsDeterministicAndRoundTripsOnTheHebrewSide() {
        // ו sits on 9 (v), 31 (o) and 32 (u): the lowest key code wins, so "hello" doesn't come back.
        XCTAssertEqual(convert("העללו שורלד", qwerty, abc), "hellv wvrld")
        // Hebrew → ABC → Hebrew is always exact for indexed text.
        let hebrew = "העללו שורלד"
        XCTAssertEqual(convert(convert(hebrew, qwerty, abc), abc, qwerty), hebrew)
        // ת is plain t (17) and Shift+y (16): plain ranks first.
        XCTAssertEqual(convert("ת", qwerty, abc), "t")
    }

    func testHebrewQWERTYShiftLettersUseTheirShiftLetter() {
        // Refined case rule: QWERTY Shift+s types a bare ש (a distinct letter), so "S" → ש, not plain ס.
        XCTAssertEqual(convert("S", abc, qwerty), "ש")
        XCTAssertEqual(convert("sS", abc, qwerty), "סש")
        XCTAssertEqual(convert("FHK", abc, qwerty), "ףחך")
        // Shift+a is a bare qamats (a mark, not a letter) and Shift+w is שׁ (has a mark): plain letter.
        XCTAssertEqual(convert("A", abc, qwerty), "א")
        XCTAssertEqual(convert("W", abc, qwerty), "ש")
        // Shift+d is „ (not a letter): plain ד.
        XCTAssertEqual(convert("D", abc, qwerty), "ד")
        // render: Caps Lock strokes get the same rule.
        let c = LayoutConverter(from: abc, to: qwerty)
        XCTAssertEqual(c.render([Stroke(keyCode: 1, layer: .capsLock)]), "ש")
        XCTAssertEqual(c.render([Stroke(keyCode: 0, layer: .capsLock)]), "א")
    }

    func testCaseRuleRefinementChangesNoAppleHebrewOrPCResult() {
        // On Apple Hebrew and Hebrew-PC, every Shift / Caps Lock letter stroke renders as the plain letter.
        for target in [he!, pc!] {
            let c = LayoutConverter(from: abc, to: target)
            for (code, cell) in abc.keys {
                guard let plain = cell.plain, plain.allSatisfy(\.isLetter),
                      let hebrew = target.keys[code]?.plain, hebrew.allSatisfy({ $0.isLetter && !$0.isCased })
                else { continue }
                for layer in [KeyLayer.shift, .capsLock] {
                    XCTAssertEqual(c.render([Stroke(keyCode: code, layer: layer)]), hebrew, "\(target.name) \(code) \(layer)")
                }
                XCTAssertEqual(c.convert(plain.uppercased()).text, hebrew, "\(target.name) \(code)")
            }
        }
    }

    // MARK: - render (strokes → text)

    private func strokes(_ codes: [UInt16], _ layer: KeyLayer = .plain) -> [Stroke] {
        codes.map { Stroke(keyCode: $0, layer: layer) }
    }

    func testRenderStrokes() {
        let akuo = strokes([0, 40, 32, 31])
        XCTAssertEqual(LayoutConverter(from: abc, to: he).render(akuo), "שלום")
        XCTAssertEqual(LayoutConverter(from: he, to: abc).render(akuo), "akuo")
    }

    func testRenderKeepsCaseInTheStrokesSoConvertBackIsExact() {
        let shifted = [Stroke(keyCode: 0, layer: .shift)] + strokes([40, 32, 31])
        XCTAssertEqual(LayoutConverter(from: abc, to: he).render(shifted), "שלום")
        XCTAssertEqual(LayoutConverter(from: he, to: abc).render(shifted), "Akuo")
        XCTAssertEqual(LayoutConverter(from: abc, to: abc).render(shifted), "Akuo")
    }

    func testRenderFallbacks() {
        // Apple Hebrew Shift+s types nothing; in ABC it's S.
        XCTAssertEqual(LayoutConverter(from: he, to: abc).render([Stroke(keyCode: 1, layer: .shift)]), "S")
        // ABC § (10) has no key in Apple Hebrew: keep what was typed.
        XCTAssertEqual(LayoutConverter(from: abc, to: he).render(strokes([10])), "§")
        // A key that types nothing in either adds nothing (Esc = 53).
        XCTAssertEqual(LayoutConverter(from: abc, to: he).render(strokes([53, 0])), "ש")
        // Space renders normally (only the reverse index leaves it out).
        XCTAssertEqual(LayoutConverter(from: abc, to: he).render(strokes([4, 49, 4])), "י י")
    }

    func testRenderMatchesConvertOfTheTypedText() {
        let codes: [UInt16] = [4, 34, 43, 49, 4, 31, 13, 49, 0, 15, 14]
        let typed = LayoutConverter(from: abc, to: abc).render(strokes(codes))
        XCTAssertEqual(typed, "hi, how are")
        XCTAssertEqual(LayoutConverter(from: abc, to: he).render(strokes(codes)), convert(typed, abc, he))
    }

    // MARK: - guessSource

    func testGuessSource() {
        XCTAssertEqual(LayoutConverter.guessSource(of: "akuo", among: (abc, he)), abc.id)
        XCTAssertEqual(LayoutConverter.guessSource(of: "שלום", among: (abc, he)), he.id)
        XCTAssertEqual(LayoutConverter.guessSource(of: "שלום", among: (he, abc)), he.id)
        XCTAssertEqual(LayoutConverter.guessSource(of: "Akuo", among: (abc, pc)), abc.id, "PC covers only the A")
        XCTAssertEqual(LayoutConverter.guessSource(of: "hello שלום", among: (abc, he)), abc.id)
        XCTAssertNil(LayoutConverter.guessSource(of: "123 !?", among: (abc, he)), "shared characters: a tie")
        XCTAssertNil(LayoutConverter.guessSource(of: "", among: (abc, he)))
        XCTAssertNil(LayoutConverter.guessSource(of: "🙂", among: (abc, he)))
    }

    func testInstanceGuessSourceMatchesStatic() {
        let c = LayoutConverter(from: abc, to: he)
        for text in ["akuo", "שלום", "hello שלום", "123", ""] {
            XCTAssertEqual(c.guessSource(of: text), LayoutConverter.guessSource(of: text, among: (abc, he)), text)
        }
    }

    // MARK: - Reverse-index ranking (hand-made maps)

    private func map(_ id: String, _ keys: [UInt16: KeyCell]) -> LayoutMap {
        LayoutMap(id: InputSourceID("user.\(id)"), name: id, language: "xx", source: .imported, keys: keys)
    }

    func testMainKeysRankBelowKeypadBelowJIS() {
        let from = map("from", [83: KeyCell(plain: "1"), 18: KeyCell(plain: "1"),
                                93: KeyCell(plain: "x"), 75: KeyCell(plain: "x")])
        let to = map("to", [18: KeyCell(plain: "main"), 83: KeyCell(plain: "pad"),
                            75: KeyCell(plain: "pad"), 93: KeyCell(plain: "jis")])
        let c = LayoutConverter(from: from, to: to)
        XCTAssertEqual(c.convert("1").text, "main")
        XCTAssertEqual(c.convert("x").text, "pad")
        XCTAssertEqual(LayoutReverseIndex(from).stroke(for: "1"), Stroke(keyCode: 18, layer: .plain))
    }

    func testPlainRanksBelowShiftThenLowerKeyCode() {
        let from = map("from", [5: KeyCell(shift: "q"), 9: KeyCell(plain: "q"),
                                7: KeyCell(plain: "z"), 3: KeyCell(plain: "z")])
        let index = LayoutReverseIndex(from)
        XCTAssertEqual(index.stroke(for: "q"), Stroke(keyCode: 9, layer: .plain), "plain beats a lower key code")
        XCTAssertEqual(index.stroke(for: "z"), Stroke(keyCode: 3, layer: .plain))
    }

    func testSpaceKeyIsNotIndexed() {
        let from = map("from", [49: KeyCell(plain: " ")])
        let to = map("to", [49: KeyCell(plain: "_")])
        let r = LayoutConverter(from: from, to: to).convert("a b")
        XCTAssertEqual(r.text, "a b")
        XCTAssertEqual(r.unmapped, 2)
    }
}
