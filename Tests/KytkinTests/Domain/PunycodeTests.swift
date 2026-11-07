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

    func testOverlongInputIsRejectedNotSlow() {
        var distinct = ""
        for v in 0x4E00..<(0x4E00 + 20_000) { distinct.unicodeScalars.append(Unicode.Scalar(v)!) }
        XCTAssertNil(Punycode.encode(distinct))
        XCTAssertNil(Punycode.decode(String(repeating: "a", count: 100_000) + "-ba"))
        XCTAssertNotNil(Punycode.encode(String(distinct.prefix(63))))
    }

    func testNormalizeLeavesImpossibleLabelsInUnicode() {
        // Not Punycoded, so every ASCII-only host check rejects them (QA P3-2).
        XCTAssertEqual(HostNormalizer.normalize("\u{202E}abc.com"), "\u{202E}abc.com")
        XCTAssertEqual(HostNormalizer.normalize("a\u{FFFD}.com"), "a\u{FFFD}.com")
        let long = String(repeating: "ש", count: 64)
        XCTAssertEqual(HostNormalizer.normalize(long + ".co.il"), long + ".co.il")
        XCTAssertTrue(HostNormalizer.normalize(String(repeating: "ש", count: 63) + ".co.il").hasPrefix("xn--"))
        // ZWNJ is allowed in IDN labels (Persian).
        XCTAssertTrue(HostNormalizer.normalize("می\u{200C}خواهم.ir").hasPrefix("xn--"))
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
