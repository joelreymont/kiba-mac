/// A saved account's folder name: an email, or `email #n` for further logins
/// under the same email. Equality, hashing and order work on the UTF-8 bytes,
/// which identify the spelling; the file system may still fold case and
/// Unicode normalization, so two unequal names can reach one folder.
public struct SlotName: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let raw: String
    /// `n` when the name ends in `" #n"`, `n` being ASCII digits worth more
    /// than 0 that fit an `Int`; nil for a bare email.
    public let suffix: Int?
    /// End of the email part of `raw`.
    private let cut: String.Index

    /// Nil unless kiba's `NAME-OK?` holds: 1–127 bytes, none below 0x20,
    /// no 0x7F, no `/`, no leading `.`.
    public init?(_ raw: String) {
        guard Self.isSafe(raw.utf8) else { return nil }
        self.raw = raw
        (cut, suffix) = Self.split(raw)
    }

    /// The part before the trailing `" #n"` when the name has a suffix; the whole name otherwise.
    public var email: String { String(raw[..<cut]) }

    public var description: String { raw }

    /// kiba `NAME-FOR-EMAIL?`: the name is `email` itself, or `email #n` with a suffix.
    public func belongs(to email: String) -> Bool {
        raw.utf8.elementsEqual(email.utf8) || (suffix != nil && raw.utf8[..<cut].elementsEqual(email.utf8))
    }

    /// Different emails order bytewise; the same email orders by suffix with
    /// the bare name as 1; equal ranks fall back to the raw bytes.
    public static func < (a: SlotName, b: SlotName) -> Bool {
        let ea = a.raw.utf8[..<a.cut], eb = b.raw.utf8[..<b.cut]
        guard ea.elementsEqual(eb) else { return ea.lexicographicallyPrecedes(eb) }
        let ra = a.suffix ?? Rule.bareRank, rb = b.suffix ?? Rule.bareRank
        guard ra == rb else { return ra < rb }
        return a.raw.utf8.lexicographicallyPrecedes(b.raw.utf8)
    }

    public static func == (a: SlotName, b: SlotName) -> Bool {
        a.raw.utf8.elementsEqual(b.raw.utf8)
    }

    /// The byte count ends each name, so names hashed in sequence cannot run
    /// together (`"ab", "c"` differs from `"a", "bc"`).
    public func hash(into h: inout Hasher) {
        for b in raw.utf8 { h.combine(b) }
        h.combine(raw.utf8.count)
    }

    private static func isSafe(_ bytes: String.UTF8View) -> Bool {
        guard let first = bytes.first, bytes.count <= Rule.maxBytes, first != Rule.dot else { return false }
        return bytes.allSatisfy { $0 >= Rule.minByte && $0 != Rule.del && $0 != Rule.slash }
    }

    /// kiba `NAME-SUFFIX#`: only a trailing `" #"` plus digits marks a suffix,
    /// so an email that itself holds `" #"` keeps it. A tail that is not a
    /// positive `Int` makes the whole name a bare email.
    private static func split(_ raw: String) -> (String.Index, Int?) {
        let bytes = raw.utf8
        guard let mark = bytes.lastIndex(where: { !Rule.digits.contains($0) }), bytes[mark] == Rule.hash,
              mark != bytes.startIndex else { return (raw.endIndex, nil) }
        let space = bytes.index(before: mark), digits = bytes.index(after: mark)
        guard bytes[space] == Rule.space, let n = Int(raw[digits...]), n > 0 else { return (raw.endIndex, nil) }
        return (space, n)
    }

    private enum Rule {
        static let maxBytes = 127
        static let minByte: UInt8 = 0x20
        static let del: UInt8 = 0x7F
        static let slash = UInt8(ascii: "/")
        static let dot = UInt8(ascii: ".")
        static let space = UInt8(ascii: " ")
        static let hash = UInt8(ascii: "#")
        static let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        static let bareRank = 1
    }
}
