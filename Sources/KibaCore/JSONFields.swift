import Foundation

/// Field reads on a parsed JSON object: a login document or a provider
/// answer. Absent, null and mistyped members all read as nil, so an answer
/// that lacks a window simply has no such window. The bytes are checked by the
/// same scan as `JSONDoc`, and a document that repeats a key within one
/// object is not read. Keys are their decoded bytes, as `JSONDoc` keeps them,
/// so keys that differ in bytes stay distinct where Swift strings would
/// compare equal (`é` composed and decomposed, lone surrogates); a key the
/// app names is looked up by its UTF-8. Numbers keep their spelling and read
/// as `Decimal`, never through a binary floating-point value. Only for
/// reading: a document that is rewritten is spliced through `JSONDoc`, never
/// re-serialised here.
struct JSONFields {
    private let fields: [Key: Value]

    /// Numbers are spelled with `.` whatever the user's locale.
    static let posix = Locale(identifier: "en_US_POSIX")

    /// Nil unless `data` is a JSON object.
    init?(_ data: Data) {
        guard let fields = try? Tree.parse(data) else { return nil }
        self.fields = fields
    }

    /// `badJSON(what)` unless `data` is a JSON object.
    init(_ data: Data, what: String) throws {
        guard let doc = JSONFields(data) else { throw KibaError.badJSON(what) }
        self = doc
    }

    private init(fields: [Key: Value]) {
        self.fields = fields
    }

    /// The member under `key`, looked up by its UTF-8.
    private func member(_ key: String) -> Value? {
        fields[Array(key.utf8)]
    }

    /// The string under `key`; nil when absent, null, or another kind.
    func str(_ key: String) -> String? {
        guard case .string(let s)? = member(key) else { return nil }
        return s
    }

    /// The object under `key`; nil when absent, null, or another kind.
    func obj(_ key: String) -> JSONFields? {
        guard case .object(let o)? = member(key) else { return nil }
        return JSONFields(fields: o)
    }

    /// The objects in the array under `key`; other elements are skipped.
    func objs(_ key: String) -> [JSONFields] {
        guard case .array(let items)? = member(key) else { return [] }
        return items.compactMap { item in
            guard case .object(let o) = item else { return nil }
            return JSONFields(fields: o)
        }
    }

    /// The number under `key`, decoded from its spelling; nil when absent,
    /// null, another kind, or beyond `Decimal`.
    func num(_ key: String) -> Decimal? {
        guard case .number(let spelling)? = member(key) else { return nil }
        return Decimal(string: spelling, locale: Self.posix)
    }

    /// The integer under `key`; nil when absent, null, another kind, or a
    /// number with no exact `Int` value.
    func int(_ key: String) -> Int? {
        guard let n = num(key), let whole = n.whole, Decimal(whole) == n else { return nil }
        return whole
    }

    /// The boolean under `key`; nil when absent, null, or another kind.
    func bool(_ key: String) -> Bool? {
        guard case .bool(let b)? = member(key) else { return nil }
        return b
    }
}

extension JSONFields {
    /// A member name as its decoded bytes, a lone surrogate as generalized UTF-8.
    typealias Key = [UInt8]

    /// A JSON value; a number is kept as spelled.
    enum Value {
        case object([Key: Value])
        case array([Value])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    /// Builds the values of a document from what a `JSONDoc.Scan` reports,
    /// without recursion.
    struct Tree: JSONSink {
        static let wantsText = true
        /// Open containers, innermost last; true for an object.
        var kinds: [Bool] = []
        /// The members of each open object, and the key its next one goes under.
        var objs: [[Key: Value]] = []
        var keys: [Key] = []
        /// The elements of each open array.
        var arrs: [[Value]] = []
        /// The root object once it closes.
        var root: [Key: Value] = [:]

        /// The root members of `data`; `badJSON` unless it is a JSON object.
        static func parse(_ data: Data) throws -> [Key: Value] {
            var tree = Tree()
            try data.withUnsafeBytes { raw in
                var scan = JSONDoc.Scan(buf: raw)
                try scan.run(&tree)
            }
            return tree.root
        }

        mutating func open(_ obj: Bool, depth: Int) {
            kinds.append(obj)
            if obj {
                objs.append([:])
                keys.append([])
            } else {
                arrs.append([])
            }
        }

        mutating func key(_ text: [UInt8], depth: Int) -> Bool {
            guard objs[objs.count - 1][text] == nil else { return false }
            keys[keys.count - 1] = text
            return true
        }

        mutating func value(_ span: Range<Int>, _ kind: JSONKind, text: [UInt8], depth: Int) {
            let v: Value
            switch kind {
            case .object:
                kinds.removeLast()
                keys.removeLast()
                let members = objs.removeLast()
                guard !kinds.isEmpty else {
                    root = members
                    return
                }
                v = .object(members)
            case .array:
                kinds.removeLast()
                v = .array(arrs.removeLast())
            case .string: v = .string(String(decoding: text, as: UTF8.self))
            case .number: v = .number(String(decoding: text, as: UTF8.self))
            case .bool(let b): v = .bool(b)
            case .null: v = .null
            }
            if kinds[kinds.count - 1] {
                objs[objs.count - 1][keys[keys.count - 1]] = v
            } else {
                arrs[arrs.count - 1].append(v)
            }
        }
    }
}
