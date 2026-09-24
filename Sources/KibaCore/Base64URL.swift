import Foundation

/// Decoder for the base64url text of JWT segments (RFC 4648 section 5): the url
/// alphabet only, then at most two `=` of padding that end the text.
enum Base64URL {
    private static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    private static let pad = UInt8(ascii: "=")
    private static let maxPad = 2
    private static let sextet = 6
    private static let octet = 8

    /// Sextet value of every alphabet byte; nil for all others.
    private static let table: [UInt8?] = {
        var t = [UInt8?](repeating: nil, count: Int(UInt8.max) + 1)
        for (v, c) in alphabet.utf8.enumerated() { t[Int(c)] = UInt8(v) }
        return t
    }()

    /// The bytes `text` encodes; `badJSON(what)` for any byte outside the
    /// alphabet, padding that is not trailing or runs past two, or a length
    /// no byte count encodes to.
    static func decode(_ text: some StringProtocol, what: String) throws -> Data {
        let bytes = text.utf8
        let body = bytes.prefix { $0 != pad }
        let pads = bytes.count - body.count
        guard pads <= maxPad, bytes.dropFirst(body.count).allSatisfy({ $0 == pad }) else {
            throw KibaError.badJSON(what)
        }
        var out = Data()
        out.reserveCapacity(body.count * sextet / octet)
        var acc: UInt32 = 0   // the low `bits` bits are pending output
        var bits = 0
        for c in body {
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
