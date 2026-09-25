import Foundation

/// Every failure kiba-mac can report. `reason` is the one-line, user-facing text.
public enum KibaError: Error, Equatable, Sendable {
    case noLive(Provider)
    case noAccount(Provider, String)
    case badName(String)
    case badJSON(String)
    case loginFailed(Int32)
    case loginProducedNothing(Provider)
    case loginRunning(Provider)
    case noCLI(String)
    case mismatch(Provider, String)
    case mixed
    case superseded
    case unrepaired(Provider, String)
    case orphanLive(URL)
    case capacity(String)
    case unsafePath(URL)
    case io(String)
    case db(String)
    case tool(String, Int32, String)
    case noResets(Provider, String)
    case remote(String)
    case loginItem(String)
}

extension KibaError {
    public var reason: String {
        switch self {
        case .noLive(let p):
            return "\(p.title) has no live login to save"
        case .noAccount(let p, let name):
            return "\(p.title) has no saved account named \(name)"
        case .badName(let name):
            return "account name has unsafe characters: \(name)"
        case .badJSON(let what):
            return "a login document lacks a field or is not valid JSON: \(what)"
        case .loginFailed(let status):
            return "the provider login did not complete (exit \(status))"
        case .loginProducedNothing(let p):
            return "the \(p.title) login finished but left no credentials to save"
        case .loginRunning(let p):
            return "a \(p.title) login is already running"
        case .noCLI(let name):
            return "\(name) is not on PATH"
        case .mismatch(let p, let name):
            return "the saved \(p.title) login \(name) belongs to a different account"
        case .mixed:
            return "the live Claude files name different accounts; switch to an account to repair them"
        case .superseded:
            return "another Claude switch began before this one wrote anything; this one changed nothing"
        case .unrepaired(let p, let name):
            return "the \(p.title) switch to \(name) did not finish; nothing is probed or refreshed until a switch completes"
        case .orphanLive(let url):
            return "Claude credentials exist but \(url.path) is missing: nothing is probed or switched until it names their account"
        case .capacity(let what):
            return "too many: \(what)"
        case .unsafePath(let url):
            return "refusing to write through a symlink chain at \(url.path)"
        case .io(let what):
            return "file operation failed: \(what)"
        case .db(let what):
            return "the account database refused: \(what)"
        case .tool(let name, let status, let stderr):
            let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let detail = lines.first(where: { !$0.isEmpty }) else { return "\(name) failed (exit \(status))" }
            return "\(name) failed (exit \(status)): \(detail)"
        case .noResets(_, let name):
            return "no limit resets are available for \(name)"
        case .remote(let note):
            return note
        case .loginItem(let what):
            return "Start at login: \(what)"
        }
    }
}
