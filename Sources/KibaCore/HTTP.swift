import Foundation
import os

/// One request to a provider endpoint.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// What an endpoint answered.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// An answer, or the one-line reason none arrived.
public enum HTTPOutcome: Sendable {
    case response(HTTPResponse)
    case unreachable(String)
}

/// Sends requests: `URLSessionClient` over the network, `StubHTTP` in tests.
public protocol HTTPClient: Sendable {
    func send(_ r: HTTPRequest) async -> HTTPOutcome
}

/// The status codes the probes tell apart.
enum HTTPStatus {
    static let ok = 200
    static let badRequest = 400
    static let unauthorized = 401
    static let forbidden = 403
    static let tooManyRequests = 429
    /// A token endpoint's refusal of the grant: the only proof a saved login is gone
    /// (Claude reads an on-hold body first).
    static let refusals = [badRequest, unauthorized]
}

extension HTTPRequest {
    /// User-Agent of every request except the ChatGPT backend calls.
    static let kibaAgent = "kiba"

    /// A GET carrying `token` as its bearer, plus `extra` headers.
    static func get(
        _ url: URL, bearer token: String, agent: String = kibaAgent, extra: [String: String] = [:]
    ) -> HTTPRequest {
        HTTPRequest(method: Method.get, url: url, headers: authorized(token, agent, extra), body: nil)
    }

    /// A POST of the JSON document `json` carrying `token` as its bearer, plus `extra` headers.
    static func post(
        _ url: URL, json: Data, bearer token: String, agent: String = kibaAgent, extra: [String: String] = [:]
    ) -> HTTPRequest {
        var headers = authorized(token, agent, extra)
        headers[Header.contentType] = Header.json
        return HTTPRequest(method: Method.post, url: url, headers: headers, body: json)
    }

    /// A POST of the JSON document `json` with no bearer: a token grant.
    static func post(_ url: URL, json: Data) -> HTTPRequest {
        var headers = common(kibaAgent)
        headers[Header.contentType] = Header.json
        return HTTPRequest(method: Method.post, url: url, headers: headers, body: json)
    }

    private static func common(_ agent: String) -> [String: String] {
        [Header.accept: Header.json, Header.agent: agent]
    }

    private static func authorized(_ token: String, _ agent: String, _ extra: [String: String]) -> [String: String] {
        var headers = common(agent)
        headers[Header.auth] = Header.bearer + token
        headers.merge(extra) { _, added in added }
        return headers
    }

    private enum Method {
        static let get = "GET"
        static let post = "POST"
    }

    private enum Header {
        static let accept = "Accept"
        static let agent = "User-Agent"
        static let auth = "Authorization"
        static let contentType = "Content-Type"
        static let json = "application/json"
        static let bearer = "Bearer "
    }
}

/// The production client: an ephemeral session that keeps no cookies, cache or
/// credentials, and follows a redirect only to the same origin, so a bearer
/// token never reaches another server; a refused redirect is answered as is.
public struct URLSessionClient: HTTPClient {
    /// Seconds a request may take in all, as kiba's `curl -m`.
    public static let defaultTimeout: TimeInterval = 20

    private let session: URLSession

    public init(timeout: TimeInterval = defaultTimeout) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config, delegate: SameOrigin(), delegateQueue: nil)
    }

    public func send(_ r: HTTPRequest) async -> HTTPOutcome {
        var req = URLRequest(url: r.url)
        req.httpMethod = r.method
        req.httpBody = r.body
        for (name, value) in r.headers {
            req.setValue(value, forHTTPHeaderField: name)
        }
        let body: Data
        let answer: URLResponse
        do {
            (body, answer) = try await session.data(for: req)
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard let http = answer as? HTTPURLResponse else {
            return .unreachable("\(r.url.absoluteString) did not answer over HTTP")
        }
        return .response(HTTPResponse(status: http.statusCode, body: body))
    }
}

/// Follows a redirect only when scheme, host and port stay those of the request.
/// URLSession drops `Authorization` on every redirect, so a same-origin hop gets
/// the original headers back and the bearer still reaches the server that asked.
private final class SameOrigin: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let first = task.originalRequest, let from = first.url, let to = request.url,
              to.scheme == from.scheme, to.host == from.host, to.port == from.port
        else { return nil }
        var next = request
        for (name, value) in first.allHTTPHeaderFields ?? [:] where next.value(forHTTPHeaderField: name) == nil {
            next.setValue(value, forHTTPHeaderField: name)
        }
        return next
    }
}

/// A client for tests: answers from its script in order and records every
/// request. A request past the end of the script is unreachable.
public final class StubHTTP: HTTPClient {
    /// The reason a request past the end of the script gets.
    public static let unscripted = "no scripted answer left"

    private let state: OSAllocatedUnfairLock<State>

    public init(_ script: [HTTPOutcome]) {
        state = OSAllocatedUnfairLock(initialState: State(script: script[...], sent: []))
    }

    /// Every request sent so far, oldest first.
    public var requests: [HTTPRequest] { state.withLock { $0.sent } }

    public func send(_ r: HTTPRequest) async -> HTTPOutcome {
        state.withLock { s in
            s.sent.append(r)
            return s.script.popFirst() ?? .unreachable(Self.unscripted)
        }
    }

    private struct State {
        var script: ArraySlice<HTTPOutcome>
        var sent: [HTTPRequest]
    }
}
