import Foundation

/// Field reads on a parsed JSON object: a login document or a provider
/// answer. Absent, null and mistyped members all read as nil, so an answer
/// that lacks a window simply has no such window. Numbers read as `Decimal`,
/// never as `Double`. Only for reading: a document that is rewritten is
/// spliced through `JSONDoc`, never re-serialised from here.
struct JSONFields {
    private let fields: [String: Any]

    /// Nil unless `data` is a JSON object.
    init?(_ data: Data) {
        guard let any = try? JSONSerialization.jsonObject(with: data), let fields = any as? [String: Any] else {
            return nil
        }
        self.fields = fields
    }

    /// `badJSON(what)` unless `data` is a JSON object.
    init(_ data: Data, what: String) throws {
        guard let doc = JSONFields(data) else { throw KibaError.badJSON(what) }
        self = doc
    }

    private init(fields: [String: Any]) {
        self.fields = fields
    }

    /// The string under `key`; nil when absent, null, or another kind.
    func str(_ key: String) -> String? {
        fields[key] as? String
    }

    /// The object under `key`; nil when absent, null, or another kind.
    func obj(_ key: String) -> JSONFields? {
        (fields[key] as? [String: Any]).map(JSONFields.init(fields:))
    }

    /// The objects in the array under `key`; other elements are skipped.
    func objs(_ key: String) -> [JSONFields] {
        (fields[key] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).map(JSONFields.init(fields:)) }
    }

    /// The number under `key`; nil when absent, null, a boolean, or another kind.
    func num(_ key: String) -> Decimal? {
        number(key)?.decimalValue
    }

    /// The integer under `key`; nil when absent, null, a boolean, another
    /// kind, or a number with no exact `Int` value.
    func int(_ key: String) -> Int? {
        number(key).flatMap { Int(exactly: $0) }
    }

    /// A JSON number; `true` and `false` are not numbers.
    private func number(_ key: String) -> NSNumber? {
        guard let num = fields[key] as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() else { return nil }
        return num
    }
}
