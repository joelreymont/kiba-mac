import Foundation

/// Field reads on a parsed JSON object. Only for reading: a document that is
/// rewritten is spliced through `JSONDoc`, never re-serialised from here.
struct JSONFields {
    private let fields: [String: Any]

    /// `badJSON(what)` unless `data` is a JSON object.
    init(_ data: Data, what: String) throws {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw KibaError.badJSON(what)
        }
        guard let fields = any as? [String: Any] else { throw KibaError.badJSON(what) }
        self.fields = fields
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

    /// The integer under `key`; nil when absent, null, a boolean, another
    /// kind, or a number with no exact `Int` value.
    func int(_ key: String) -> Int? {
        guard let num = fields[key] as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: num)
    }
}
