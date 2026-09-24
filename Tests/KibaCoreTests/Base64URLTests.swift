import Foundation
import Testing
@testable import KibaCore

@Suite struct Base64URLTests {
    static let bad = KibaError.badJSON("base64url text")

    /// Unpadded base64url built with Foundation's encoder, so the decoder
    /// under test is never its own oracle.
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test func rfcVectorsUnpadded() throws {
        // RFC 4648 section 10, padding stripped: lengths mod 4 of 0, 2, 3.
        let vectors = ["": "", "Zg": "f", "Zm8": "fo", "Zm9v": "foo",
                       "Zm9vYg": "foob", "Zm9vYmE": "fooba", "Zm9vYmFy": "foobar"]
        for (text, plain) in vectors {
            #expect(try Base64URL.decode(text) == Data(plain.utf8), "\(text)")
        }
    }

    @Test func paddingEndsTheText() throws {
        #expect(try Base64URL.decode("Zg==") == Data("f".utf8))
        #expect(try Base64URL.decode("Zm8=") == Data("fo".utf8))
        #expect(try Base64URL.decode("Zm9vYg==") == Data("foob".utf8))
        // Decoding stops at the first '=': nothing after it is read.
        #expect(try Base64URL.decode("Zg==Zm9v") == Data("f".utf8))
        #expect(try Base64URL.decode("Zg=!") == Data("f".utf8))
        #expect(try Base64URL.decode("=") == Data())
    }

    @Test func urlAndStandardAlphabets() throws {
        let bytes = Data([0xFB, 0xFF])   // standard "+/8=", url "-_8"
        #expect(try Base64URL.decode("-_8") == bytes)
        #expect(try Base64URL.decode("+/8") == bytes)
        #expect(try Base64URL.decode("-/8=") == bytes)
        #expect(try Base64URL.decode("____") == Data([0xFF, 0xFF, 0xFF]))
        #expect(try Base64URL.decode("----") == Data([0xFB, 0xEF, 0xBE]))
    }

    @Test func roundTripsEveryLengthAndByte() throws {
        let all = Data((0...UInt8.max).map { $0 })
        #expect(try Base64URL.decode(Self.encode(all)) == all)
        let stride = 97   // coprime with 256: each length sees varied bytes
        for len in 0...all.count {
            let data = Data((0..<len).map { UInt8(truncatingIfNeeded: $0 * stride + len) })
            let text = Self.encode(data)
            #expect(try Base64URL.decode(text) == data, "len \(len)")
            #expect(try Base64URL.decode(data.base64EncodedString()) == data, "padded len \(len)")
        }
    }

    @Test func acceptsSubstring() throws {
        let jwt = "eyJ.Zm9vYmE.sig"
        let seg = jwt.split(separator: ".")[1]
        #expect(try Base64URL.decode(seg) == Data("fooba".utf8))
    }

    @Test func rejectsBytesOutsideTheAlphabet() {
        for text in ["Zm9v!", "Zm 9v", "Zm9v\n", "Zm9v.", "Zm9vé", "Zm\u{0}9v", "Zm9v*", "Zm9v\"", "\u{FEFF}Zm9v"] {
            #expect(throws: Self.bad, "\(text.debugDescription)") { try Base64URL.decode(text) }
        }
    }

    @Test func rejectsDanglingSextet() {
        // Length mod 4 == 1 leaves six bits: no byte group has that length.
        for text in ["Z", "Zm9vY", "Zm9vYmFyZ", "Z=", "Zm9vY===", "-"] {
            #expect(throws: Self.bad, "\(text)") { try Base64URL.decode(text) }
        }
    }
}
