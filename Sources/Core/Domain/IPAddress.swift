// P3-2: IP-literal check for site keys (R3 §5 step 2). An IP host has no registrable domain; the host itself is
// the site key. Deliberately broad, like the URL Standard's "ends in a number" rule: any host whose last label is
// all digits (or 0x-hex) is treated as IPv4-like, since no real TLD is numeric. Anything with a ':' (or brackets)
// is IPv6. Works on UTF-8 bytes in one pass (it runs once per lookup on the hot path).

enum IPAddress {
    /// `host` already normalized (lowercase, no trailing dot).
    static func isIPLiteral(_ host: String) -> Bool {
        var lastLabelLength = 0
        var allDigits = true, hexTail = true   // hexTail: every byte after the "0x" is 0-9 / a-f
        var secondByte: UInt8 = 0, firstByte: UInt8 = 0
        for b in host.utf8 {
            if b == UInt8(ascii: ":") || b == UInt8(ascii: "[") { return true }
            if b == UInt8(ascii: ".") {
                lastLabelLength = 0; allDigits = true; hexTail = true
                continue
            }
            let isDigit = b >= 48 && b <= 57
            if lastLabelLength == 0 { firstByte = b } else if lastLabelLength == 1 { secondByte = b }
            if !isDigit { allDigits = false }
            if lastLabelLength >= 2, !(isDigit || (b >= 97 && b <= 102)) { hexTail = false }
            lastLabelLength += 1
        }
        guard lastLabelLength > 0 else { return false }
        if allDigits { return true }
        return lastLabelLength > 2 && firstByte == UInt8(ascii: "0") && secondByte == UInt8(ascii: "x") && hexTail
    }

    /// Exactly four decimal parts, each 0–255 ("192.168.1.1"). Used for scheme-less address-bar text, where the
    /// broad rule above would also take a typed number like "3.5".
    static func isDottedQuadIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.utf8.count <= 3 && p.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && Int(p).map { $0 <= 255 } == true
        }
    }
}
