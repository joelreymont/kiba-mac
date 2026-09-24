import Foundation
import os

/// Where a login's secret bytes live.
public protocol SecretStore: Sendable {
    /// The stored bytes; nil when no item or file exists.
    func read() throws -> Data?
    func write(_ data: Data) throws
    /// Nothing to do when absent.
    func remove() throws
}

/// A secret kept in a private file, written by temp + rename.
public struct FileSecret: SecretStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() throws -> Data? {
        try PrivateFS.read(url)
    }

    public func write(_ data: Data) throws {
        try PrivateFS.ensurePrivateDir(url.deletingLastPathComponent())
        try PrivateFS.writePrivate(data, to: url)
    }

    public func remove() throws {
        guard unlink(url.path) == 0 || errno == ENOENT else { throw KibaError.io(PrivateFS.failure("unlink", url.path)) }
    }
}

/// A secret held in memory, for tests.
public final class MemorySecret: SecretStore {
    private let bytes: OSAllocatedUnfairLock<Data?>

    public init(_ data: Data?) {
        bytes = OSAllocatedUnfairLock(initialState: data)
    }

    public func read() throws -> Data? { bytes.withLock { $0 } }
    public func write(_ data: Data) throws { bytes.withLock { $0 = data } }
    public func remove() throws { bytes.withLock { $0 = nil } }
}

/// A generic password in the login Keychain, driven through `/usr/bin/security`:
/// Claude Code creates its item with that tool, so the tool is on the item's
/// access list and no call ever raises a Keychain prompt.
public struct KeychainItem: SecretStore {
    public let service: String
    public let account: String

    static let tool = URL(fileURLWithPath: "/usr/bin/security", isDirectory: false)
    static let name = "security"
    /// `errSecItemNotFound` as the tool's exit status.
    static let notFound: Int32 = 44
    static let newline = UInt8(ascii: "\n")
    static let brace = UInt8(ascii: "{")
    /// `security -i` reads each command line into a buffer this long; a longer
    /// line is cut, and the cut command still runs with a truncated secret.
    static let lineMax = 4096
    /// Quoting in a `security -i` line: a value goes inside double quotes and
    /// may hold neither a quote, a backslash, nor a control byte.
    static let quote = "\""
    static let unquotable: Set<UInt8> = [UInt8(ascii: "\""), UInt8(ascii: "\\")]
    static let minPrintable: UInt8 = 0x20

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// `find-generic-password -w` prints the data followed by a newline, as is
    /// when every byte is printable and as hex otherwise. A JSON object never
    /// reads as hex, so output that does is decoded.
    public func read() throws -> Data? {
        let r = try Self.run(["find-generic-password", "-a", account, "-s", service, "-w"], stdin: nil)
        if r.status == Self.notFound { return nil }
        guard r.status == 0 else { throw Self.failed(r) }
        var text = r.stdout
        if text.last == Self.newline { text.removeLast() }
        guard text.first != Self.brace, let raw = Self.unhex(text) else { return text }
        return raw
    }

    /// `add-generic-password -U … -X <hex>` as a command line on the stdin of
    /// `security -i`, so the secret stays out of argv. (The `-w` prompt reads
    /// at most 128 bytes, too few for a login.) A secret too long for the
    /// tool's line buffer goes as the same command in argv instead, which is
    /// how Claude Code itself writes a large credential.
    public func write(_ data: Data) throws {
        let hex = Self.hex(data)
        let head = "add-generic-password -U -a \(try Self.quoted(account)) -s \(try Self.quoted(service)) -X "
        let line = Data(head.utf8) + hex + [Self.newline]
        let r = line.count < Self.lineMax
            ? try Self.run(["-i"], stdin: line)
            : try Self.run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", String(decoding: hex, as: UTF8.self)], stdin: nil)
        guard r.status == 0, r.stderr.isEmpty else { throw Self.failed(r) }
    }

    public func remove() throws {
        let r = try Self.run(["delete-generic-password", "-a", account, "-s", service], stdin: nil)
        guard r.status == 0 || r.status == Self.notFound else { throw Self.failed(r) }
    }

    static func run(_ args: [String], stdin: Data?) throws -> Subprocess.Result {
        try Subprocess.run(tool, args, stdin: stdin, env: nil, setsid: true)
    }

    static func failed(_ r: Subprocess.Result) -> KibaError {
        .tool(name, r.status, String(decoding: r.stderr, as: UTF8.self))
    }

    /// `value` inside double quotes; `badName` when it holds a byte that cannot be quoted.
    static func quoted(_ value: String) throws -> String {
        guard value.utf8.allSatisfy({ $0 >= minPrintable && !unquotable.contains($0) }) else {
            throw KibaError.badName(value)
        }
        return quote + value + quote
    }

    /// `data` as lowercase hex digits.
    static func hex(_ data: Data) -> Data {
        var out = Data(capacity: data.count * hexWidth)
        for b in data {
            out.append(hexDigits[Int(b >> hexBits)])
            out.append(hexDigits[Int(b & lowNibble)])
        }
        return out
    }

    static let hexDigits = Array("0123456789abcdef".utf8)
    static let lowNibble: UInt8 = 0x0F

    /// The bytes spelled by `text` as pairs of hex digits; nil when it is not that.
    static func unhex(_ text: Data) -> Data? {
        let digits = text.compactMap(hexValue)
        guard digits.count == text.count, digits.count % hexWidth == 0 else { return nil }
        return Data(stride(from: 0, to: digits.count, by: hexWidth).map { digits[$0] << hexBits | digits[$0 + 1] })
    }

    static let hexWidth = 2
    static let hexBits: UInt8 = 4
    static let hexTen: UInt8 = 10

    static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return c - UInt8(ascii: "a") + hexTen
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return c - UInt8(ascii: "A") + hexTen
        default: return nil
        }
    }
}

/// The live Claude Code credential store, chosen by what exists rather than by
/// platform: a `.credentials.json` in the config dir wins, else the Keychain item.
public enum ClaudeSecrets {
    public static func live(paths: Paths, root: URL?) -> SecretStore {
        let file = paths.claudeCredsFile(root: root)
        guard PrivateFS.exists(file) else {
            return KeychainItem(service: paths.keychainService, account: paths.username)
        }
        return FileSecret(url: file)
    }
}
