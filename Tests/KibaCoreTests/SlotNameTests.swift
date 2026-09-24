import Foundation
import Testing
import KibaCore

private func slot(_ raw: String) throws -> SlotName {
    try #require(SlotName(raw))
}

@Suite struct SlotNameTests {
    @Test func acceptsSafeNames() throws {
        for raw in ["a@x", "a@x #2", "a.b@x", "ü@例え.jp", "x", "~a b#c@x"] {
            #expect(try slot(raw).raw == raw)
        }
    }

    @Test func lengthCountsBytes() {
        #expect(SlotName(String(repeating: "a", count: 127)) != nil)
        #expect(SlotName(String(repeating: "a", count: 128)) == nil)
        #expect(SlotName(String(repeating: "a", count: 125) + "é") != nil)
        #expect(SlotName(String(repeating: "a", count: 126) + "é") == nil)
    }

    @Test func rejectsUnsafeNames() {
        let bad = ["", "a\u{0}b", "a\u{1F}b", "\ta@x", "a@x\n", "a\u{7F}", "a/b", "/a", "a/", ".a", ".", ".."]
        for raw in bad {
            #expect(SlotName(raw) == nil, "\(raw.debugDescription) must be rejected")
        }
    }

    @Test func parsesSuffix() throws {
        let cases: [(String, String, Int)] = [
            ("a@x #2", "a@x", 2), ("a@x #10", "a@x", 10), ("a@x #02", "a@x", 2), ("ü@x #3", "ü@x", 3),
            ("a@x #9223372036854775807", "a@x", Int.max),
        ]
        for (raw, email, n) in cases {
            let name = try slot(raw)
            #expect(name.email == email, "\(raw) email")
            #expect(name.suffix == n, "\(raw) suffix")
        }
    }

    @Test func badSuffixMeansBareEmail() throws {
        let bare = ["a@x", "a@x #0", "a@x #00", "a@x #x", "a@x #", "a@x #+2", "a@x #-2", "a@x #2 ", "a@x #2x",
                    "a@x#2", "a@x  #", "a@x # 2", "a@x x2", "a@x  2", "a@x #٢", "#2", "2", "\"a #2\"@x",
                    "a@x #9223372036854775808", "a@x #99999999999999999999"]
        for raw in bare {
            let n = try slot(raw)
            #expect(n.email == raw, "\(raw) email")
            #expect(n.suffix == nil, "\(raw) suffix")
        }
    }

    /// Only the trailing `" #n"` is a suffix: kiba names further logins
    /// `email + " #" + n`, and a quoted email may hold `" #"` itself.
    @Test func suffixIsTrailing() throws {
        let cases: [(String, String, Int)] = [
            ("\"a #b\"@x #2", "\"a #b\"@x", 2), ("\"a #2\"@x #3", "\"a #2\"@x", 3),
            ("a@x #b #2", "a@x #b", 2), ("a@x #2 #3", "a@x #2", 3), ("a@x # #2", "a@x #", 2),
            ("a b@x #2", "a b@x", 2), ("a@x  #3", "a@x ", 3), ("a#2 #4", "a#2", 4),
        ]
        for (raw, email, n) in cases {
            let name = try slot(raw)
            #expect(name.email == email, "\(raw) email")
            #expect(name.suffix == n, "\(raw) suffix")
        }
    }

    /// Names read through FileManager or JSONSerialization arrive as bridged
    /// NSStrings; they must behave exactly like native ones.
    @Test func bridgedNamesMatchNative() throws {
        for raw in ["a@x #2", "pérson@x #10", "ü@例え.jp"] {
            let bridged = try slot(NSString(string: raw) as String)
            let native = try slot(raw)
            #expect(bridged == native)
            #expect(bridged.hashValue == native.hashValue)
            #expect(bridged.email == native.email)
            #expect(bridged.suffix == native.suffix)
            #expect(!(bridged < native) && !(native < bridged))
        }
    }

    @Test func sortsBySuffixWithinEmail() throws {
        let names = try ["b@x", "a@x #10", "a@x", "a@x #2"].map(slot)
        #expect(names.sorted().map(\.raw) == ["a@x", "a@x #2", "a@x #10", "b@x"])
    }

    /// Every rotation of the input, forwards and backwards, sorts the same.
    @Test func sortIgnoresInputOrder() throws {
        let sorted = ["\"a #2\"@x", "\"a #2\"@x #3", "\"a #b\"@x", "\"a #b\"@x #2", "B@x",
                      "a@x", "a@x #2", "a@x #10", "a@x #2 #3", "b@x"]
        let names = try ["b@x", "a@x #10", "\"a #b\"@x #2", "a@x", "\"a #2\"@x", "a@x #2", "\"a #b\"@x",
                         "\"a #2\"@x #3", "B@x", "a@x #2 #3"].map(slot)
        for k in names.indices {
            let turned = Array(names[k...] + names[..<k])
            #expect(turned.sorted().map(\.raw) == sorted, "rotation \(k)")
            #expect(turned.reversed().sorted().map(\.raw) == sorted, "reversed rotation \(k)")
        }
    }

    @Test func differentEmailsSortBytewise() throws {
        #expect(try slot("B@x") < slot("a@x"))
        #expect(try slot("a@x #9") < slot("a@xb"))
        #expect(try slot("z@x") < slot("ä@x"))
        #expect(try slot("a@x #2") < slot("a@x #x"))
    }

    @Test func bareRanksAsOne() throws {
        #expect(try slot("a@x") < slot("a@x #2"))
        #expect(try !(slot("a@x #2") < slot("a@x")))
    }

    private static let mixed = ["a@x", "a@x #1", "a@x #2", "a@x #02", "a@x #10", "a@x #0", "a@x #x", "a@xb",
                                "a@x #2 #3", "\"a #b\"@x", "\"a #b\"@x #2", "\"a #2\"@x", "\"a #2\"@x #3",
                                "b@x", "B@x", "e\u{301}@x", "\u{E9}@x"]

    /// `<` is a strict total order consistent with `==`, even where suffixes tie.
    @Test func orderIsTotal() throws {
        let names = try Self.mixed.map(slot)
        for a in names {
            for b in names {
                let holds = [a < b, a == b, b < a].filter { $0 }.count
                #expect(holds == 1, "\(a) vs \(b)")
            }
        }
    }

    @Test func orderIsTransitive() throws {
        let names = try Self.mixed.map(slot)
        for a in names {
            for b in names where a < b {
                for c in names where b < c {
                    #expect(a < c, "\(a) < \(b) < \(c)")
                }
            }
        }
    }

    /// Names hashed in sequence must not run together.
    @Test func hashSeparatesNames() throws {
        func digest(_ raws: [String]) throws -> Int {
            var h = Hasher()
            for raw in raws { h.combine(try slot(raw)) }
            return h.finalize()
        }
        #expect(try digest(["ab", "c"]) != digest(["a", "bc"]))
        #expect(try digest(["ab", "c"]) == digest(["ab", "c"]))
    }

    /// Bytes identify the spelling: canonically equivalent names stay unequal,
    /// though the file system may fold them into one folder.
    @Test func equalityIsBytewise() throws {
        let nfc = try slot("\u{E9}@x"), nfd = try slot("e\u{301}@x")
        #expect("\u{E9}@x" == "e\u{301}@x")
        #expect(nfc != nfd)
        #expect(Set([nfc, nfd]).count == 2)
        #expect(Set([nfc, try slot("\u{E9}@x")]).count == 1)
        #expect(!nfc.belongs(to: "e\u{301}@x"))
    }

    @Test func belongsToItsEmail() throws {
        #expect(try slot("a@x").belongs(to: "a@x"))
        #expect(try slot("a@x #2").belongs(to: "a@x"))
        #expect(try slot("a@x #10").belongs(to: "a@x"))
        #expect(try slot("a@x #2").belongs(to: "a@x #2"))
        #expect(try slot("a@x #0").belongs(to: "a@x #0"))
    }

    @Test func belongsRejectsOthers() throws {
        #expect(try !slot("a@x").belongs(to: "b@x"))
        #expect(try !slot("a@xy").belongs(to: "a@x"))
        #expect(try !slot("a@x").belongs(to: "a@xy"))
        #expect(try !slot("b@x #3").belongs(to: "a@x"))
        #expect(try !slot("a@x #0").belongs(to: "a@x"))
        #expect(try !slot("a@x #x").belongs(to: "a@x"))
        #expect(try !slot("a@x #2").belongs(to: "a@x #"))
        #expect(try !slot("a@x #2").belongs(to: ""))
        #expect(try !slot("a@x #2 #3").belongs(to: "a@x"))
        #expect(try !slot("a@x #99999999999999999999").belongs(to: "a@x"))
    }

    @Test func belongsKeepsQuotedEmails() throws {
        #expect(try slot("\"a #b\"@x #2").belongs(to: "\"a #b\"@x"))
        #expect(try slot("\"a #b\"@x").belongs(to: "\"a #b\"@x"))
        #expect(try slot("\"a #2\"@x").belongs(to: "\"a #2\"@x"))
        #expect(try slot("\"a #2\"@x #3").belongs(to: "\"a #2\"@x"))
        #expect(try slot("a@x #2 #3").belongs(to: "a@x #2"))
        #expect(try !slot("\"a #b\"@x #2").belongs(to: "\"a"))
        #expect(try !slot("\"a #2\"@x").belongs(to: "\"a"))
        #expect(try !slot("\"a #2\"@x #3").belongs(to: "\"a"))
        #expect(try !slot("\"a #2\"@x #3").belongs(to: "\"a #2\"@x #"))
    }

    @Test func describesAsRaw() throws {
        let n = try slot("a@x #2")
        #expect(n.description == "a@x #2")
        #expect("\(n)" == "a@x #2")
    }
}
