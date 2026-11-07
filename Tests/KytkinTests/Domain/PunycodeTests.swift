// P3-2: Punycode encode/decode against RFC 3492 §7.1 samples and the IDN labels the PSL tests and Israeli
// addresses use, plus HostNormalizer (the normalization shared with RuleEngine and ContextAssembler).

import XCTest

final class PunycodeTests: XCTestCase {
    private let samples: [(String, String)] = [
        ("bücher", "bcher-kva"),
        ("שלום", "9dbne9b"),
        ("ישראל", "4dbrk0ce"),
        ("דוגמה", "6dbbec0c"),
        ("食狮", "85x722f"),
        ("公司", "55qx5d"),
        ("中国", "fiqs8s"),
        ("ü", "tda"),
        // RFC 3492 §7.1 (A) Arabic and (L) mixed.
        ("ليهمابتكلموشعربي؟", "egbpdaj6bu4bxfgehfvwxn"),
        ("3年b組金八先生", "3b-ww4c5e180e575a65lsy2b"),
    ]

    func testEncodeMatchesKnownValues() {
        for (unicode, ascii) in samples {
            XCTAssertEqual(Punycode.encode(unicode), ascii, unicode)
        }
    }

    func testDecodeRoundTrips() {
        for (unicode, ascii) in samples {
            XCTAssertEqual(Punycode.decode(ascii), unicode, ascii)
        }
    }

    func testPureASCIILabelEncodesWithTrailingDash() {
        XCTAssertEqual(Punycode.encode("abc"), "abc-")
        XCTAssertEqual(Punycode.decode("abc-"), "abc")
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(Punycode.decode("ab!c"))
        XCTAssertNil(Punycode.decode("99999999999999999999"))
        XCTAssertNil(Punycode.decode("-ä"))
    }

    // MARK: - HostNormalizer

    func testNormalizeLowercasesAndDropsOneTrailingDot() {
        XCTAssertEqual(HostNormalizer.normalize("WWW.Ynet.CO.IL."), "www.ynet.co.il")
        XCTAssertEqual(HostNormalizer.normalize("a.com.."), "a.com.")
        XCTAssertEqual(HostNormalizer.normalize("."), "")
        XCTAssertNil(HostNormalizer.normalized("."))
        XCTAssertNil(HostNormalizer.normalized(nil))
        XCTAssertEqual(HostNormalizer.normalized("Docs.Google.com."), "docs.google.com")
    }

    func testNormalizePunycodesUnicodeLabelsOnly() {
        XCTAssertEqual(HostNormalizer.normalize("שלום.co.il"), "xn--9dbne9b.co.il")
        XCTAssertEqual(HostNormalizer.normalize("דוגמה.ישראל."), "xn--6dbbec0c.xn--4dbrk0ce")
        XCTAssertEqual(HostNormalizer.normalize("WWW.Bücher.DE"), "www.xn--bcher-kva.de")
        // Uppercase Unicode is lowercased first; a decomposed ü (u + U+0308) is composed first (NFC).
        XCTAssertEqual(HostNormalizer.normalize("BÜCHER.de"), "xn--bcher-kva.de")
        XCTAssertEqual(HostNormalizer.normalize("bu\u{308}cher.de"), "xn--bcher-kva.de")
        // Already-Punycode input is just lowercased.
        XCTAssertEqual(HostNormalizer.normalize("XN--9DBNE9B.co.il"), "xn--9dbne9b.co.il")
    }

    func testUnicodeFormForDisplay() {
        XCTAssertEqual(HostNormalizer.unicodeForm("xn--9dbne9b.co.il"), "שלום.co.il")
        XCTAssertEqual(HostNormalizer.unicodeForm("www.ynet.co.il"), "www.ynet.co.il")
        XCTAssertEqual(HostNormalizer.unicodeForm("xn--!!.com"), "xn--!!.com")
    }
}
