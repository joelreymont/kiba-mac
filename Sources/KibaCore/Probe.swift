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
    static func unknown(_ what: String, _ word: String) -> String { "\(what) sent an unknown result \"\(word)\"" }

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

/// A login document ready to send, or why it is not.
enum Fresh {
    /// The document, refreshed when its token had to be renewed.
    case ready(Data)
    /// No usable token: the state and note to record. `revoked` means a later
    /// login revoked this one.
    case stale(UsageState, String)
}

/// What spending one limit reset produced.
struct Redemption {
    /// The login document, refreshed when its token had to be renewed; stored
    /// whatever the result, since a refresh spends the old grant.
    var doc: Data
    var result: Result<ResetOutcome, KibaError>
}

/// A provider's reset endpoint: the member of its 200 answer that holds the
/// result word, what each word means, and the notes for its failures.
struct ResetReply {
    let field: String
    let words: [String: ResetOutcome]
    /// The endpoint as notes name it.
    let what: String
    /// The note for a 401 once the token cannot be renewed.
    let rejected: String
    let throttled: String

    /// The outcome `got` names; `remote` with a note for any other answer.
    func outcome(_ got: HTTPOutcome) -> Result<ResetOutcome, KibaError> {
        guard case .response(let r) = got else { return .failure(.remote(ProbeNote.unreachable(what))) }
        switch r.status {
        case HTTPStatus.ok:
            guard let body = JSONFields(r.body) else { return .failure(.remote(ProbeNote.unreadable(what))) }
            let word = body.str(field) ?? ""
            guard let outcome = words[word] else { return .failure(.remote(ProbeNote.unknown(what, word))) }
            return .success(outcome)
        case HTTPStatus.unauthorized:
            return .failure(.remote(rejected))
        case HTTPStatus.tooManyRequests:
            return .failure(.remote(throttled))
        default:
            return .failure(.remote(ProbeNote.answered(what, r.status)))
        }
    }
}

/// How spending a refresh grant ended.
enum Renewal {
    /// The login document with the new tokens spliced in.
    case fresh(Data)
    /// The token endpoint answered without a token: its answer, for the probe to read.
    case denied(HTTPResponse)
    /// Unreachable, a 200 without a token, or a splice error: the note to record.
    case failed(String)
}

extension HTTPResponse {
    /// A token endpoint's 400 or 401: the only statuses that prove a saved login gone.
    var refused: Bool { HTTPStatus.refusals.contains(status) }
}

extension HTTPClient {
    /// Posts `grant` to the token endpoint `url`, named `what` in notes, and
    /// hands its 200 answer to `splice`, which returns the refreshed document or
    /// nil when the answer carries no access token.
    func renew(
        _ url: URL, grant: KeyValuePairs<String, String>, what: String, splice: (JSONFields) throws -> JSONDoc?
    ) async -> Renewal {
        guard case .response(let r) = await send(.post(url, json: jsonObject(grant))) else {
            return .failed(ProbeNote.unreachable(what))
        }
        guard r.status == HTTPStatus.ok else { return .denied(r) }
        do {
            guard let answer = JSONFields(r.body), let doc = try splice(answer) else {
                return .failed(ProbeNote.answered(what, r.status))
            }
            return .fresh(doc.data)
        } catch {
            return .failed(ProbeNote.failure(error))
        }
    }
}

extension JSONDoc {
    /// The document with member `key2` of the object at root member `key1` set
    /// to the JSON bytes `value`, added at the end of that object when absent;
    /// `badJSON` when `key1` holds no object.
    func setting(_ key1: String, _ key2: String, to value: Data) throws -> JSONDoc {
        if let span = valueSpan(key1, key2) { return try replacing(span, with: value) }
        guard let brace = closingBrace(key1) else { throw KibaError.badJSON(key1) }
        return try adding(key2, value, at: brace.index, after: brace.hasMembers)
    }

    /// The same for the root member `key`.
    func setting(_ key: String, to value: Data) throws -> JSONDoc {
        if let span = valueSpan(key) { return try replacing(span, with: value) }
        let brace = closingBrace()
        return try adding(key, value, at: brace.index, after: brace.hasMembers)
    }

    /// The document with the member `"key":value` inserted at the closing brace
    /// `brace`, after a comma when its object already has members.
    private func adding(_ key: String, _ value: Data, at brace: Int, after members: Bool) throws -> JSONDoc {
        try replacing(brace ..< brace, with: (members ? Data(",".utf8) : Data()) + jsonString(key) + Data(":".utf8) + value)
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
