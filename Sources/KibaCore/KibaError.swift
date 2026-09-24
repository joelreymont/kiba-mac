import Foundation

/// Every failure kiba-mac can report. `reason` is the one-line, user-facing text.
public enum KibaError: Error, Equatable, Sendable {
    case noLive(Provider)
    case noAccount(Provider, String)
    case badName(String)
    case locked(URL)
    case badJSON(String)
    case loginFailed(Int32)
    case loginProducedNothing(Provider)
    case noCLI(String)
    case interrupted(Provider)
    case mismatch(Provider, String)
    case mixed
    case capacity(String)
    case unsafePath(URL)
    case io(String)
    case tool(String, Int32, String)
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
        case .locked(let url):
            return "another kiba holds the store lock; remove \(url.path) if it is stale"
        case .badJSON(let what):
            return "a login file is missing an expected field: \(what)"
        case .loginFailed(let status):
            return "the provider login did not complete (exit \(status))"
        case .loginProducedNothing(let p):
            return "the \(p.title) login finished but left no credentials to save"
        case .noCLI(let name):
            return "\(name) is not on PATH"
        case .interrupted(let p):
            return "an earlier \(p.title) switch was interrupted; switch to an account to finish it"
        case .mismatch(let p, let name):
            return "the saved \(p.title) file under \(name) belongs to a different account"
        case .mixed:
            return "the live Claude files name different accounts; switch to an account to repair them"
        case .capacity(let what):
            return "too many: \(what)"
        case .unsafePath(let url):
            return "refusing to write through a symlink chain at \(url.path)"
        case .io(let what):
            return "file operation failed: \(what)"
        case .tool(let name, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(name) failed (exit \(status))" : "\(name) failed (exit \(status)): \(detail)"
        }
    }
}
