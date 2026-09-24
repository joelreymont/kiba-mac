import Foundation

/// One saved login to probe.
public struct ProbeInput: Sendable {
    public var provider: Provider
    public var name: SlotName
    /// The row's login document bytes.
    public var doc: Data
    /// The CLI is using this login; its tokens belong to the CLI and are never refreshed.
    public var live: Bool

    public init(provider: Provider, name: SlotName, doc: Data, live: Bool) {
        self.provider = provider
        self.name = name
        self.doc = doc
        self.live = live
    }
}

/// Labels of the windows both providers report.
enum WindowLabel {
    static let session = "Session (5-hour)"
    static let weekly = "Weekly (7-day)"
}

/// Notes shared by both probes.
enum ProbeNote {
    static let noAccess = "no access token saved"

    static func answered(_ what: String, _ status: Int) -> String { "\(what) answered \(status)" }
    static func unreachable(_ what: String) -> String { "\(what) could not be reached" }
    static func unreadable(_ what: String) -> String { "\(what) sent an answer that is not a JSON object" }

    /// The note for an error thrown while building a refreshed document.
    static func failure(_ error: any Error) -> String {
        (error as? KibaError)?.reason ?? String(describing: error)
    }
}

/// Epoch seconds of `date`, rounded down.
func epochSeconds(_ date: Date) -> Int {
    Int(date.timeIntervalSince1970.rounded(.down))
}

/// Whole percent used for a window's reading: rounded half up, as the design's
/// `NSDecimalRound(.plain)`. Nil when there is no reading, a negative one, or
/// one beyond `Int`.
func usedPercent(_ reading: Decimal?) -> Int? {
    guard let reading, reading >= 0 else { return nil }
    return reading.whole
}

extension Decimal {
    /// Rounded half away from zero to a whole number; nil when outside `Int`.
    var whole: Int? {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return Int(rounded.description)
    }
}

/// A provider answer or login document read for its values. Absent, null and
/// mistyped members all read as nil, so an answer that lacks a window simply
/// has no such window. Numbers read as `Decimal`, never as `Double`.
struct ProbeJSON {
    private let fields: [String: Any]

    /// Nil unless `data` is a JSON object.
    init?(_ data: Data) {
        guard let any = try? JSONSerialization.jsonObject(with: data), let fields = any as? [String: Any] else {
            return nil
        }
        self.fields = fields
    }

    private init(fields: [String: Any]) {
        self.fields = fields
    }

    func obj(_ key: String) -> ProbeJSON? {
        (fields[key] as? [String: Any]).map(ProbeJSON.init(fields:))
    }

    /// The objects in the array under `key`; other elements are skipped.
    func objs(_ key: String) -> [ProbeJSON] {
        (fields[key] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).map(ProbeJSON.init(fields:)) }
    }

    func str(_ key: String) -> String? {
        fields[key] as? String
    }

    /// A JSON number; `true` and `false` are not numbers.
    func num(_ key: String) -> Decimal? {
        guard let n = fields[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.decimalValue
    }

    /// A JSON number with no fraction that fits `Int`.
    func int(_ key: String) -> Int? {
        guard let n = num(key), let whole = n.whole, Decimal(whole) == n else { return nil }
        return whole
    }
}

/// How spending a refresh grant ended.
enum Renewal {
    /// The login document with the new tokens spliced in.
    case fresh(Data)
    /// The token endpoint refused the grant (400 or 401): the saved login is gone.
    case refused
    /// Any other end; the note to record.
    case failed(String)
}

extension HTTPClient {
    /// Posts `grant` to the token endpoint `url`, named `what` in notes, and
    /// hands its 200 answer to `splice`, which returns the refreshed document or
    /// nil when the answer carries no access token.
    func renew(
        _ url: URL, grant: KeyValuePairs<String, String>, what: String, splice: (ProbeJSON) throws -> JSONDoc?
    ) async -> Renewal {
        guard case .response(let r) = await send(.post(url, json: jsonObject(grant))) else {
            return .failed(ProbeNote.unreachable(what))
        }
        if HTTPStatus.refusals.contains(r.status) { return .refused }
        do {
            guard r.status == HTTPStatus.ok, let answer = ProbeJSON(r.body), let doc = try splice(answer) else {
                return .failed(ProbeNote.answered(what, r.status))
            }
            return .fresh(doc.data)
        } catch {
            return .failed(ProbeNote.failure(error))
        }
    }
}

extension JSONDoc {
    /// The document with member `key2` of the object at `key1` set to the JSON
    /// bytes `value`; unchanged when that member is absent (kiba `CFG-REPLACE2`).
    func setting(_ key1: String, _ key2: String, to value: Data) throws -> JSONDoc {
        guard let span = valueSpan(key1, key2) else { return self }
        return try replacing(span, with: value)
    }

    /// The same for the root member `key` (kiba `CFG-REPLACE`).
    func setting(_ key: String, to value: Data) throws -> JSONDoc {
        guard let span = valueSpan(key) else { return self }
        return try replacing(span, with: value)
    }
}

/// `s` as a JSON string literal: `"` and `\` escaped, control characters as `\u00XX`.
func jsonString(_ s: String) -> Data {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case JSONText.controls: out += String(format: JSONText.controlEscape, c.value)
        default: out.unicodeScalars.append(c)
        }
    }
    out += "\""
    return Data(out.utf8)
}

/// A JSON object of string members, in the order given.
func jsonObject(_ members: KeyValuePairs<String, String>) -> Data {
    var out = Data("{".utf8)
    for (i, (key, value)) in members.enumerated() {
        if i > 0 { out += Data(",".utf8) }
        out += jsonString(key) + Data(":".utf8) + jsonString(value)
    }
    return out + Data("}".utf8)
}

/// `n` as a JSON number literal.
func jsonNumber(_ n: Int) -> Data {
    Data(String(n).utf8)
}

private enum JSONText {
    /// Characters a JSON string must escape beyond `"` and `\`.
    static let controls: ClosedRange<Unicode.Scalar> = "\u{0}" ... "\u{1F}"
    static let controlEscape = "\\u%04x"
}
