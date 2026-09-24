import Foundation

/// A JSON object whose values are located by byte offset, so a write splices one
/// value and every other byte stays as it was. Values are located, never decoded.
///
/// Construction checks structure at every depth, iteratively: strings end (an
/// escape skips the byte after `\`), brackets match, objects hold `"key": value`
/// members and arrays hold values, both comma-separated. Numbers and literals are
/// checked only as runs of `[0-9A-Za-z+-.]`. Keys of the root object and of every
/// object directly under it, the levels spans are located in, are decoded and must
/// be unique: a repeated key has no single value to splice.
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
        try self.init(scanning: data)
    }

    init(scanning data: Data) throws {
        let bytes = data.startIndex == 0 ? data : Data(data)
        layout = try bytes.withUnsafeBytes { raw in
            var scan = Scan(buf: raw)
            return try scan.run()
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

    /// The document with `span` replaced by `bytes`. The caller splices a span this
    /// document located (or the empty span at `closingBrace`) with bytes that keep the
    /// object well-formed; bytes read from disk are checked with `JSONDoc(_:)` first. A
    /// splice that breaks the object is a programming error and traps. The result is
    /// not held to the 4 MiB limit; the next `JSONDoc(_:)` of its bytes is.
    public func replacing(_ span: Range<Int>, with bytes: Data) -> JSONDoc {
        var out = data
        out.replaceSubrange(span, with: bytes)
        do {
            return try JSONDoc(scanning: out)
        } catch {
            preconditionFailure("splicing bytes \(span) broke the JSON object: \(error)")
        }
    }
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

    /// One pass over a document that checks its structure and builds its `Layout`.
    struct Scan {
        /// What the next token must be.
        enum Want { case value, valueOrEnd, key, keyOrEnd, next }

        /// First and last UTF-16 surrogates of a pair.
        static let highs: ClosedRange<UInt32> = 0xD800 ... 0xDBFF
        static let lows: ClosedRange<UInt32> = 0xDC00 ... 0xDFFF
        /// First code point a surrogate pair spells, and the bits each half carries.
        static let pairBase: UInt32 = 0x10000
        static let pairBits: UInt32 = 10
        /// Hex digits in a `\u` escape, the bits each carries, and the value of `a`.
        static let hexLen = 4
        static let hexBits: UInt32 = 4
        static let hexTen: UInt8 = 10
        /// Generalized UTF-8 of a lone surrogate: lead byte, then two continuation
        /// bytes carrying `contBits` each under `contTag`.
        static let loneLead: UInt8 = 0xED
        static let contTag: UInt8 = 0x80
        static let contBits: UInt32 = 6
        static let contMask: UInt32 = 0x3F

        let buf: UnsafeRawBufferPointer
        var layout = Layout()
        /// Open containers, innermost last; true for an object.
        var nest: [Bool] = []
        /// The root member being read: decoded key, value start, and the value's
        /// members when it is an object.
        var key1: [UInt8] = []
        var start1 = 0
        var kids: [[UInt8]: Range<Int>]?
        /// The member being read one level down: decoded key and value start.
        var key2: [UInt8] = []
        var start2 = 0

        mutating func run() throws -> Layout {
            var i = ws(0)
            guard at(i) == .lbrace else { throw bad("not a JSON object", i) }
            var want = Want.value
            while true {
                i = ws(i)
                let c = at(i)
                switch want {
                case .value, .valueOrEnd:
                    if want == .valueOrEnd, c == .rbracket {
                        i = close(i)
                        want = .next
                        continue
                    }
                    begin(i)
                    switch c {
                    case .lbrace:
                        nest.append(true)
                        i += 1
                        want = .keyOrEnd
                    case .lbracket:
                        nest.append(false)
                        i += 1
                        want = .valueOrEnd
                    case .quote:
                        i = try string(i)
                        end(i)
                        want = .next
                    default:
                        i = try scalar(i)
                        end(i)
                        want = .next
                    }
                case .key, .keyOrEnd:
                    if want == .keyOrEnd, c == .rbrace {
                        i = close(i)
                        want = .next
                        continue
                    }
                    guard c == .quote else { throw bad("expected a key", i) }
                    let stop = try string(i)
                    try name(i + 1 ..< stop - 1)
                    i = ws(stop)
                    guard at(i) == .colon else { throw bad("expected ':'", i) }
                    i += 1
                    want = .value
                case .next:
                    guard let obj = nest.last else {
                        guard i == buf.count else { throw bad("unexpected bytes after the object", i) }
                        return layout
                    }
                    if c == .comma {
                        i += 1
                        want = obj ? .key : .value
                    } else if c == (obj ? .rbrace : .rbracket) {
                        i = close(i)
                    } else {
                        throw bad(obj ? "expected ',' or '}'" : "expected ',' or ']'", i)
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

        /// The offset just past the string opening at `i`.
        func string(_ i: Int) throws -> Int {
            var j = i + 1
            while j < buf.count {
                switch buf[j] {
                case .quote: return j + 1
                case .backslash: j += 2
                default: j += 1
                }
            }
            throw bad("unterminated string", i)
        }

        /// The offset just past the number or literal at `i`.
        func scalar(_ i: Int) throws -> Int {
            var j = i
            while true {
                switch at(j) {
                case .digit0 ... .digit9, .upperA ... .upperZ, .lowerA ... .lowerZ, .plus, .minus, .dot: j += 1
                default:
                    guard j > i else { throw bad("expected a value", i) }
                    return j
                }
            }
        }

        /// Closes the innermost container at `i`, its closing bracket.
        mutating func close(_ i: Int) -> Int {
            nest.removeLast()
            if nest.isEmpty { layout.close = i }
            end(i + 1)
            return i + 1
        }

        /// Notes a value starting at `i` in the innermost container.
        mutating func begin(_ i: Int) {
            switch nest.count {
            case 1:
                start1 = i
                kids = at(i) == .lbrace ? [:] : nil
            case 2 where nest[1]:
                start2 = i
            default:
                break
            }
        }

        /// Records the value in the innermost container that ended before `e`.
        mutating func end(_ e: Int) {
            switch nest.count {
            case 1: layout.root[key1] = Member(span: start1 ..< e, kids: kids)
            case 2 where nest[1]: kids![key2] = start2 ..< e
            default: break
            }
        }

        /// Decodes the key whose body is `body` when it names a located member, and
        /// rejects a repeat within its object.
        mutating func name(_ body: Range<Int>) throws {
            switch nest.count {
            case 1:
                key1 = try decode(body)
                guard layout.root[key1] == nil else { throw bad("duplicate key", body.lowerBound - 1) }
            case 2:
                key2 = try decode(body)
                guard kids![key2] == nil else { throw bad("duplicate key", body.lowerBound - 1) }
            default:
                break
            }
        }

        /// The UTF-8 text of the string body at `body`. A lone surrogate keeps its
        /// generalized UTF-8 form, which no valid UTF-8 contains, so distinct keys
        /// stay distinct and none matches a Swift string.
        func decode(_ body: Range<Int>) throws -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(body.count)
            var i = body.lowerBound
            while i < body.upperBound {
                let c = buf[i]
                guard c == .backslash else {
                    out.append(c)
                    i += 1
                    continue
                }
                let esc = i
                i += 2
                switch buf[esc + 1] {
                case .quote, .backslash, .slash: out.append(buf[esc + 1])
                case .lowerB: out.append(.backspace)
                case .lowerF: out.append(.formFeed)
                case .lowerN: out.append(.lf)
                case .lowerR: out.append(.cr)
                case .lowerT: out.append(.tab)
                case .lowerU:
                    guard var unit = hex(i, body.upperBound) else { throw bad("bad \\u escape", esc) }
                    i += Self.hexLen
                    let next = i + 2
                    if Self.highs.contains(unit), at(i) == .backslash, at(i + 1) == .lowerU,
                       let low = hex(next, body.upperBound), Self.lows.contains(low) {
                        unit = Self.pairBase + ((unit - Self.highs.lowerBound) << Self.pairBits) + (low - Self.lows.lowerBound)
                        i = next + Self.hexLen
                    }
                    Self.append(unit, to: &out)
                default:
                    throw bad("bad escape", esc)
                }
            }
            return out
        }

        /// The code unit spelled by the hex digits at `i`, all before `limit`.
        func hex(_ i: Int, _ limit: Int) -> UInt32? {
            guard i + Self.hexLen <= limit else { return nil }
            var unit: UInt32 = 0
            for j in i ..< i + Self.hexLen {
                let c = buf[j]
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
    static let lowerF = UInt8(ascii: "f")
    static let lowerN = UInt8(ascii: "n")
    static let lowerR = UInt8(ascii: "r")
    static let lowerT = UInt8(ascii: "t")
    static let lowerU = UInt8(ascii: "u")
    static let lowerZ = UInt8(ascii: "z")
    static let upperA = UInt8(ascii: "A")
    static let upperF = UInt8(ascii: "F")
    static let upperZ = UInt8(ascii: "Z")
}
