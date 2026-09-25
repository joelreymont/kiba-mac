import Foundation

/// A JSON object whose values are located by byte offset, so a write splices one
/// value and every other byte stays as it was. Values are located, never decoded.
///
/// Construction checks the whole document as RFC 8259 JSON, iteratively at every
/// depth (`Scan`). Keys of the root object and of every object directly under it,
/// the levels spans are located in, are decoded and must be unique: a repeated key
/// has no single value to splice.
public struct JSONDoc: Sendable {
    /// Bytes in a MiB.
    static let mib = 1 << 20
    /// Largest document accepted, in MiB and in bytes.
    static let maxMiB = 4
    static let maxSize = maxMiB * mib

    /// The document bytes; spans are offsets into them.
    public private(set) var data: Data
    let layout: Layout

    public init(_ data: Data) throws {
        guard data.count <= Self.maxSize else {
            throw KibaError.capacity("bytes in a JSON document (limit \(Self.maxMiB) MiB)")
        }
        let bytes = data.startIndex == 0 ? data : Data(data)
        layout = try bytes.withUnsafeBytes { raw in
            var spans = Locator()
            var scan = Scan(buf: raw)
            try scan.run(&spans)
            return spans.layout
        }
        self.data = bytes
    }

    /// The value bytes of the root member `key`.
    public func valueSpan(_ key: String) -> Range<Int>? { layout.root[Array(key.utf8)]?.span }

    /// The value bytes of the root member `key` when that value is an object.
    public func objectSpan(_ key: String) -> Range<Int>? {
        guard let member = layout.root[Array(key.utf8)], member.kids != nil else { return nil }
        return member.span
    }

    /// The value bytes of member `key2` of the object held by root member `key1`.
    public func valueSpan(_ key1: String, _ key2: String) -> Range<Int>? {
        layout.root[Array(key1.utf8)]?.kids?[Array(key2.utf8)]
    }

    /// The offset of the root object's `}` and whether the object has members.
    public func closingBrace() -> (index: Int, hasMembers: Bool) { (layout.close, !layout.root.isEmpty) }

    /// The offset of the `}` of the object held by root member `key` and whether
    /// that object has members; nil when `key` is absent or holds another kind.
    public func closingBrace(_ key: String) -> (index: Int, hasMembers: Bool)? {
        guard let member = layout.root[Array(key.utf8)], let kids = member.kids else { return nil }
        return (member.span.upperBound - 1, !kids.isEmpty)
    }

    /// The document with `span` replaced by `bytes`, checked like `JSONDoc(_:)`:
    /// `badJSON` when the result does not scan, `capacity` over 4 MiB.
    public func replacing(_ span: Range<Int>, with bytes: Data) throws -> JSONDoc {
        var out = data
        out.replaceSubrange(span, with: bytes)
        return try JSONDoc(out)
    }
}

/// The kind of a value a `JSONDoc.Scan` reports.
enum JSONKind: Equatable {
    case object, array, string, number, bool(Bool), null
}

/// What a `JSONDoc.Scan` reports as it checks a document. `depth` counts the
/// containers around the token: 0 for the root object itself, 1 for its members.
protocol JSONSink {
    /// Whether `value` gets the UTF-8 of a string and the spelling of a number;
    /// keys always come decoded.
    static var wantsText: Bool { get }
    /// A container opens; `obj` for an object.
    mutating func open(_ obj: Bool, depth: Int)
    /// A key, decoded; false when its object already holds it.
    mutating func key(_ text: [UInt8], depth: Int) -> Bool
    /// A value ends: a scalar, or a container through its closing bracket.
    mutating func value(_ span: Range<Int>, _ kind: JSONKind, text: [UInt8], depth: Int)
}

extension JSONDoc {
    /// Where the root object's members sit.
    struct Layout: Sendable {
        /// Root members by decoded key.
        var root: [[UInt8]: Member] = [:]
        /// Offset of the root object's closing brace.
        var close = 0
    }

    /// A root member: its value's span and, when the value is an object, the value
    /// spans of that object's members by decoded key.
    struct Member: Sendable {
        let span: Range<Int>
        let kids: [[UInt8]: Range<Int>]?
    }

    /// Builds the `Layout` from what a `Scan` reports.
    struct Locator: JSONSink {
        static let wantsText = false
        var layout = Layout()
        /// The root member being read: its key and, when its value is an object,
        /// that object's members.
        var key1: [UInt8] = []
        var kids: [[UInt8]: Range<Int>]?
        /// The key of the member being read one level down.
        var key2: [UInt8] = []

        mutating func open(_ obj: Bool, depth: Int) {
            if depth == 1 { kids = obj ? [:] : nil }
        }

        mutating func key(_ text: [UInt8], depth: Int) -> Bool {
            switch depth {
            case 1:
                key1 = text
                return layout.root[text] == nil
            case 2:
                key2 = text
                return kids?[text] == nil
            default:
                return true
            }
        }

        mutating func value(_ span: Range<Int>, _ kind: JSONKind, text: [UInt8], depth: Int) {
            switch depth {
            case 0: layout.close = span.upperBound - 1
            case 1: layout.root[key1] = Member(span: span, kids: kind == .object ? kids : nil)
            case 2: kids?[key2] = span
            default: break
            }
        }
    }

    /// One pass over a document that checks it as RFC 8259 JSON and reports its
    /// tokens to a `JSONSink`: valid UTF-8; matched brackets; objects of
    /// `"key": value` members and arrays of values, both comma-separated; strings
    /// with only JSON's escapes and no raw control byte; numbers in JSON's grammar,
    /// however large; `true`, `false` and `null` spelled out. An escaped lone
    /// surrogate is valid JSON and passes. Iterative, so depth costs no stack.
    struct Scan {
        /// What the next token must be.
        enum Want { case value, valueOrEnd, key, keyOrEnd, next }

        /// First and last UTF-16 surrogates of a pair.
        static let highs: ClosedRange<UInt32> = 0xD800 ... 0xDBFF
        static let lows: ClosedRange<UInt32> = 0xDC00 ... 0xDFFF
        /// First code point a surrogate pair spells, and the bits each half carries.
        static let pairBase: UInt32 = 0x10000
        static let pairBits: UInt32 = 10
        /// Bytes of `\u`, hex digits after it, the bits each carries, and the value of `a`.
        static let uLen = 2
        static let hexLen = 4
        static let hexBits: UInt32 = 4
        static let hexTen: UInt8 = 10
        /// Generalized UTF-8 of a lone surrogate: lead byte, then two continuation
        /// bytes carrying `contBits` each under `contTag`.
        static let loneLead: UInt8 = 0xED
        static let contTag: UInt8 = 0x80
        static let contBits: UInt32 = 6
        static let contMask: UInt32 = 0x3F
        /// The literals and the kinds they spell.
        static let literals: [([UInt8], JSONKind)] = [
            (Array("true".utf8), .bool(true)), (Array("false".utf8), .bool(false)), (Array("null".utf8), .null),
        ]

        let buf: UnsafeRawBufferPointer
        /// Open containers, innermost last: whether each is an object, and where it opens.
        var nest: [(obj: Bool, start: Int)] = []
        /// The decoded key or string being read.
        var text: [UInt8] = []

        mutating func run<S: JSONSink>(_ sink: inout S) throws {
            try utf8()
            var i = ws(0)
            guard at(i) == .lbrace else { throw bad("not a JSON object", i) }
            var want = Want.value
            while true {
                i = ws(i)
                let c = at(i)
                switch want {
                case .value, .valueOrEnd:
                    if want == .valueOrEnd, c == .rbracket {
                        i = close(i, &sink)
                        want = .next
                    } else if c == .lbrace || c == .lbracket {
                        sink.open(c == .lbrace, depth: nest.count)
                        nest.append((c == .lbrace, i))
                        i += 1
                        want = c == .lbrace ? .keyOrEnd : .valueOrEnd
                    } else {
                        let (kind, end) = try scalar(i, keep: S.wantsText)
                        sink.value(i ..< end, kind, text: text, depth: nest.count)
                        i = end
                        want = .next
                    }
                case .key, .keyOrEnd:
                    if want == .keyOrEnd, c == .rbrace {
                        i = close(i, &sink)
                        want = .next
                        continue
                    }
                    guard c == .quote else { throw bad("expected a key", i) }
                    text.removeAll(keepingCapacity: true)
                    let stop = try string(i, keep: true)
                    guard sink.key(text, depth: nest.count) else { throw bad("duplicate key", i) }
                    i = ws(stop)
                    guard at(i) == .colon else { throw bad("expected ':'", i) }
                    i += 1
                    want = .value
                case .next:
                    guard let top = nest.last else {
                        guard i == buf.count else { throw bad("unexpected bytes after the object", i) }
                        return
                    }
                    if c == .comma {
                        i += 1
                        want = top.obj ? .key : .value
                    } else if c == (top.obj ? .rbrace : .rbracket) {
                        i = close(i, &sink)
                    } else {
                        throw bad(top.obj ? "expected ',' or '}'" : "expected ',' or ']'", i)
                    }
                }
            }
        }

        /// The byte at `i`, or 0 past the end; 0 is never valid outside a string.
        func at(_ i: Int) -> UInt8 { i < buf.count ? buf[i] : 0 }

        /// The first offset from `i` that is not JSON whitespace.
        func ws(_ i: Int) -> Int {
            var i = i
            while true {
                switch at(i) {
                case .space, .tab, .lf, .cr: i += 1
                default: return i
                }
            }
        }

        /// Throws unless every byte is part of valid UTF-8. Outside strings JSON
        /// is ASCII, so this checks the text of every string.
        func utf8() throws {
            var parser = Unicode.UTF8.ForwardParser()
            var bytes = buf.makeIterator()
            var i = 0
            while true {
                switch parser.parseScalar(from: &bytes) {
                case .valid(let scalar): i += scalar.count
                case .emptyInput: return
                case .error: throw bad("invalid UTF-8", i)
                }
            }
        }

        /// The kind of the string, number or literal at `i` and the offset just
        /// past it. With `keep`, `text` holds a string's UTF-8 or a number's spelling.
        mutating func scalar(_ i: Int, keep: Bool) throws -> (JSONKind, Int) {
            text.removeAll(keepingCapacity: true)
            switch at(i) {
            case .quote:
                return (.string, try string(i, keep: keep))
            case .minus, .digit0 ... .digit9:
                let end = try number(i)
                if keep { text.append(contentsOf: buf[i ..< end]) }
                return (.number, end)
            default:
                for (word, kind) in Self.literals where i + word.count <= buf.count {
                    if buf[i ..< i + word.count].elementsEqual(word) { return (kind, i + word.count) }
                }
                throw bad("expected a value", i)
            }
        }

        /// The offset just past the string opening at `i`. With `keep`, its UTF-8
        /// is appended to `text`, a lone surrogate as generalized UTF-8, which no
        /// valid UTF-8 contains, so distinct keys stay distinct and none matches
        /// a Swift string.
        mutating func string(_ i: Int, keep: Bool) throws -> Int {
            var j = i + 1
            while j < buf.count {
                let c = buf[j]
                switch c {
                case .quote:
                    return j + 1
                case .backslash:
                    let (unit, next) = try escape(j)
                    if keep { Self.append(unit, to: &text) }
                    j = next
                case ..<UInt8.space:
                    throw bad("control byte in a string", j)
                default:
                    if keep { text.append(c) }
                    j += 1
                }
            }
            throw bad("unterminated string", i)
        }

        /// The code point, or lone surrogate, the escape at `i` spells, and the
        /// offset just past it. A `\u` high surrogate followed by a `\u` low one
        /// spells a single code point.
        func escape(_ i: Int) throws -> (UInt32, Int) {
            let e = at(i + 1)
            if let byte = Self.unescaped(e) { return (UInt32(byte), i + Self.uLen) }
            guard e == .lowerU, var unit = hex(i + Self.uLen) else { throw bad("bad escape", i) }
            var next = i + Self.uLen + Self.hexLen
            if Self.highs.contains(unit), at(next) == .backslash, at(next + 1) == .lowerU,
               let low = hex(next + Self.uLen), Self.lows.contains(low) {
                unit = Self.pairBase + ((unit - Self.highs.lowerBound) << Self.pairBits) + (low - Self.lows.lowerBound)
                next += Self.uLen + Self.hexLen
            }
            return (unit, next)
        }

        /// The byte a one-letter escape `\e` stands for; nil for any other `e`.
        static func unescaped(_ e: UInt8) -> UInt8? {
            switch e {
            case .quote, .backslash, .slash: e
            case .lowerB: .backspace
            case .lowerF: .formFeed
            case .lowerN: .lf
            case .lowerR: .cr
            case .lowerT: .tab
            default: nil
            }
        }

        /// The code unit spelled by the four hex digits at `i`; nil when they are not that.
        func hex(_ i: Int) -> UInt32? {
            var unit: UInt32 = 0
            for j in i ..< i + Self.hexLen {
                let c = at(j)
                let digit: UInt8
                switch c {
                case .digit0 ... .digit9: digit = c - .digit0
                case .lowerA ... .lowerF: digit = c - .lowerA + Self.hexTen
                case .upperA ... .upperF: digit = c - .upperA + Self.hexTen
                default: return nil
                }
                unit = unit << Self.hexBits | UInt32(digit)
            }
            return unit
        }

        /// The offset just past the number at `i`: `-` optional; `0` or digits
        /// not led by `0`; then optionally `.` and digits; then optionally `e` or
        /// `E`, a sign or none, and digits.
        func number(_ i: Int) throws -> Int {
            var j = i
            if at(j) == .minus { j += 1 }
            j = at(j) == .digit0 ? j + 1 : try digits(j, of: i)
            if at(j) == .dot { j = try digits(j + 1, of: i) }
            if at(j) == .lowerE || at(j) == .upperE {
                j += 1
                if at(j) == .plus || at(j) == .minus { j += 1 }
                j = try digits(j, of: i)
            }
            return j
        }

        /// The offset past the run of digits at `j`, which must hold one; the
        /// number at `start` is bad otherwise.
        func digits(_ j: Int, of start: Int) throws -> Int {
            var k = j
            while (UInt8.digit0 ... .digit9).contains(at(k)) { k += 1 }
            guard k > j else { throw bad("bad number", start) }
            return k
        }

        /// Closes the innermost container at `i`, its closing bracket.
        mutating func close<S: JSONSink>(_ i: Int, _ sink: inout S) -> Int {
            let top = nest.removeLast()
            text.removeAll(keepingCapacity: true)
            sink.value(top.start ..< i + 1, top.obj ? .object : .array, text: text, depth: nest.count)
            return i + 1
        }

        /// Appends code point `v` as UTF-8, or a lone surrogate as generalized UTF-8.
        static func append(_ v: UInt32, to out: inout [UInt8]) {
            guard let scalar = Unicode.Scalar(v) else {
                out.append(loneLead)
                out.append(contTag | UInt8((v >> contBits) & contMask))
                out.append(contTag | UInt8(v & contMask))
                return
            }
            out.append(contentsOf: scalar.utf8)
        }

        func bad(_ what: String, _ i: Int) -> KibaError {
            .badJSON(i < buf.count ? "\(what) at byte \(i)" : "document ends early")
        }
    }
}

private extension UInt8 {
    static let tab = UInt8(ascii: "\t")
    static let lf = UInt8(ascii: "\n")
    static let cr = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let backspace: UInt8 = 0x08
    static let formFeed: UInt8 = 0x0C
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let slash = UInt8(ascii: "/")
    static let comma = UInt8(ascii: ",")
    static let colon = UInt8(ascii: ":")
    static let lbrace = UInt8(ascii: "{")
    static let rbrace = UInt8(ascii: "}")
    static let lbracket = UInt8(ascii: "[")
    static let rbracket = UInt8(ascii: "]")
    static let plus = UInt8(ascii: "+")
    static let minus = UInt8(ascii: "-")
    static let dot = UInt8(ascii: ".")
    static let digit0 = UInt8(ascii: "0")
    static let digit9 = UInt8(ascii: "9")
    static let lowerA = UInt8(ascii: "a")
    static let lowerB = UInt8(ascii: "b")
    static let lowerE = UInt8(ascii: "e")
    static let lowerF = UInt8(ascii: "f")
    static let lowerN = UInt8(ascii: "n")
    static let lowerR = UInt8(ascii: "r")
    static let lowerT = UInt8(ascii: "t")
    static let lowerU = UInt8(ascii: "u")
    static let upperA = UInt8(ascii: "A")
    static let upperE = UInt8(ascii: "E")
    static let upperF = UInt8(ascii: "F")
}
