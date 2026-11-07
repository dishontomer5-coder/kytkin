// P3-2: Punycode (RFC 3492), pure Swift, so Core stays Foundation-only (lint) and the result never depends on
// how a given macOS version's URL parser treats IDN hosts. Used to turn Unicode host labels ("שלום") into their
// ASCII form ("xn--...") so hosts, PSL rules and saved site rules are all compared as ASCII.
// Written from the RFC's algorithm description (https://www.rfc-editor.org/rfc/rfc3492), §6.

enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 0x80
    /// Generous: a DNS label is at most 63 bytes. Longer input → nil (no real host needs it).
    static let maxLabelLength = 1_024

    /// Encodes one label's code points (no "xn--" prefix). nil on overflow or input over `maxLabelLength`.
    static func encode(_ label: String) -> String? {
        let input = label.unicodeScalars.map { Int($0.value) }
        // QA P3-2: the loop below is quadratic in the label length; real labels are ≤ 63 code points.
        guard input.count <= maxLabelLength else { return nil }
        var output = input.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }

        var n = initialN, delta = 0, bias = initialBias
        while handled < input.count {
            // The smallest code point not handled yet.
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            let (step, o1) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !o1 else { return nil }
            let (d, o2) = delta.addingReportingOverflow(step)
            guard !o2 else { return nil }
            delta = d
            n = m
            for c in input {
                if c < n {
                    delta += 1
                    guard delta < Int(Int32.max) else { return nil }
                }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, numPoints: handled + 1, first: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    /// Decodes one label's Punycode (no "xn--" prefix). nil when it isn't valid Punycode.
    static func decode(_ encoded: String) -> String? {
        let scalars = Array(encoded.unicodeScalars)
        guard scalars.count <= maxLabelLength else { return nil }   // QA P3-2: bounds the quadratic insert loop
        var output: [Int] = []
        var start = 0
        if let dash = scalars.lastIndex(of: "-") {
            for s in scalars[..<dash] {
                guard s.isASCII else { return nil }
                output.append(Int(s.value))
            }
            start = dash + 1
        }
        var n = initialN, i = 0, bias = initialBias
        var pos = start
        while pos < scalars.count {
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard pos < scalars.count, let d = digitValue(scalars[pos]) else { return nil }
                pos += 1
                let (dw, o1) = d.multipliedReportingOverflow(by: w)
                let (ni, o2) = i.addingReportingOverflow(dw)
                guard !o1, !o2, ni < Int(Int32.max) else { return nil }
                i = ni
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if d < t { break }
                let (nw, o3) = w.multipliedReportingOverflow(by: base - t)
                guard !o3, nw < Int(Int32.max) else { return nil }
                w = nw
                k += base
            }
            bias = adapt(i - oldI, numPoints: output.count + 1, first: oldI == 0)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard n <= 0x10FFFF, Unicode.Scalar(UInt32(n)) != nil else { return nil }
            output.insert(n, at: i)
            i += 1
        }
        var result = String.UnicodeScalarView()
        for c in output {
            guard let s = Unicode.Scalar(UInt32(c)) else { return nil }
            result.append(s)
        }
        return String(result)
    }

    private static func adapt(_ delta: Int, numPoints: Int, first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    /// 0–25 → a–z, 26–35 → 0–9.
    private static func digit(_ d: Int) -> Character {
        Character(Unicode.Scalar(UInt8(d < 26 ? 97 + d : 22 + d)))
    }

    private static func digitValue(_ s: Unicode.Scalar) -> Int? {
        switch s.value {
        case 48...57: return Int(s.value) - 22     // 0–9 → 26–35
        case 65...90: return Int(s.value) - 65     // A–Z
        case 97...122: return Int(s.value) - 97    // a–z
        default: return nil
        }
    }
}
