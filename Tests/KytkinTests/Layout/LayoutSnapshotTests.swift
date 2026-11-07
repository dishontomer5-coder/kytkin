// P2-21: LayoutSnapshot over the real ABC / Apple Hebrew fixtures: per-direction converters, the on-screen text of
// buffered strokes (unknown for dead keys), rendering, and layout guessing mapped to the pair's ids.

import XCTest

final class LayoutSnapshotTests: XCTestCase {
    private let s = ConvertFixtures.layouts
    private let akuo = ConvertFixtures.strokes("akuo")

    func testTypedAndRenderedBothWays() {
        XCTAssertEqual(s.typed(akuo, in: IDs.abc), "akuo")
        XCTAssertEqual(s.typed(akuo, in: IDs.hebrew), "שלום")
        XCTAssertEqual(s.render(akuo, from: IDs.abc)?.target, IDs.hebrew)
        XCTAssertEqual(s.render(akuo, from: IDs.abc)?.text, "שלום")
        XCTAssertEqual(s.render(akuo, from: IDs.hebrew)?.target, IDs.abc)
        XCTAssertEqual(s.render(akuo, from: IDs.hebrew)?.text, "akuo")
    }

    func testOutsideThePairIsNil() {
        XCTAssertNil(s.typed(akuo, in: IDs.russian))
        XCTAssertNil(s.render(akuo, from: IDs.russian))
        XCTAssertNil(s.converter(from: IDs.russian))
    }

    func testADeadKeyMakesTheScreenUnknown() {
        XCTAssertNil(s.typed([Stroke(keyCode: 14, layer: .option)] + akuo, in: IDs.abc))   // ⌥E
        XCTAssertEqual(s.typed([Stroke(keyCode: 0, layer: .option)], in: IDs.abc), "å", "not dead: counted")
    }

    func testGuessAndConvert() {
        XCTAssertEqual(s.guessSource(of: "akuo"), IDs.abc)
        XCTAssertEqual(s.guessSource(of: "שלום"), IDs.hebrew)
        XCTAssertNil(s.guessSource(of: "123"))
        XCTAssertEqual(s.convertGuessing("akuo")?.text, "שלום")
        XCTAssertEqual(s.convertGuessing("akuo")?.target, IDs.hebrew)
        XCTAssertEqual(s.convertGuessing("שלום")?.text, "akuo")
        XCTAssertNil(s.convertGuessing("123"), "nothing would change")
        XCTAssertNil(s.convertGuessing(""))
    }

    func testGuessUsesThePairIdsEvenForAnImportedMapWithAnotherId() {
        var imported = ConvertFixtures.hebrew
        imported.id = InputSourceID("user.my-hebrew")
        let pair = LanguagePair(a: IDs.abc, b: IDs.hebrew)
        let snap = LayoutSnapshot(pair: pair, a: ConvertFixtures.abc, b: imported)
        XCTAssertEqual(snap?.guessSource(of: "שלום"), IDs.hebrew)
        XCTAssertEqual(snap?.convertGuessing("akuo")?.target, IDs.hebrew)
    }

    func testAPairOfOneLayoutIsNoSnapshot() {
        XCTAssertNil(LayoutSnapshot(pair: LanguagePair(a: IDs.abc, b: IDs.abc), a: ConvertFixtures.abc,
                                    b: ConvertFixtures.abc))
    }
}
