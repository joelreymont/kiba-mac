import Foundation

/// Decoder for the base64url text of JWT segments (RFC 4648 section 5).
/// Padding is optional and ends the text; the standard `+` `/` pair is read
/// as `-` `_`. Anything else is `badJSON`.
public enum Base64URL {
    private static let alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    private static let std = alnum + "+/"
    private static let url = alnum + "-_"
    private static let pad = UInt8(ascii: "=")
    private static let sextet = 6
    private static let octet = 8
    private static let what = "base64url text"

    /// Sextet value of every byte of either alphabet; nil for all others.
    private static let table: [UInt8?] = {
        var t = [UInt8?](repeating: nil, count: Int(UInt8.max) + 1)
        for alphabet in [std, url] {
            for (v, c) in alphabet.utf8.enumerated() { t[Int(c)] = UInt8(v) }
        }
        return t
    }()

    static func decode(_ text: some StringProtocol) throws -> Data {
        var out = Data()
        out.reserveCapacity(text.utf8.count * sextet / octet)
        var acc: UInt32 = 0   // the low `bits` bits are pending output
        var bits = 0
        for c in text.utf8 {
            if c == pad { break }
            guard let v = table[Int(c)] else { throw KibaError.badJSON(what) }
            acc = acc << sextet | UInt32(v)
            bits += sextet
            if bits >= octet {
                bits -= octet
                out.append(UInt8(truncatingIfNeeded: acc >> bits))
                acc &= (1 << bits) - 1
            }
        }
        // Six pending bits are a lone trailing character: no byte count encodes to that.
        guard bits < sextet else { throw KibaError.badJSON(what) }
        return out
    }
}
