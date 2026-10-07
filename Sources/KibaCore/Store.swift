import Foundation
import SQLite3

/// A saved login: one row of the `account` table.
public struct SavedLogin: Equatable, Sendable {
    public var name: SlotName
    /// Email, org, and plan; the plan is the `plan` column.
    public var identity: Identity
    /// Claude: the `credentials.json` bytes; Codex: the `auth.json` bytes.
    public var login: Data
    /// Claude: the exact `oauthAccount` object bytes; Codex: nil.
    public var profile: Data?
    /// Nil until the account is probed.
    public var usage: UsageRecord?

    public init(name: SlotName, identity: Identity, login: Data, profile: Data?, usage: UsageRecord?) {
        self.name = name
        self.identity = identity
        self.login = login
        self.profile = profile
        self.usage = usage
    }
}

/// A live Keychain item's bytes at one moment, and the service it is filed
/// under then; nil bytes when there was no item.
public struct LiveItem: Equatable, Sendable {
    public var bytes: Data?
    public var service: String

    public init(bytes: Data?, service: String) {
        self.bytes = bytes
        self.service = service
    }
}

/// Every saved account, in one SQLite database. The value holds only the
/// database URL and every call opens its own connection, so it is `Sendable`
/// without a mutex; a write transaction is the cross-process mutex of rows.
public struct Store: Sendable {
    let db: URL

    /// Most logins saved under one email: the bare email, then `email #2` … `email #9`.
    static let nameTries = 9
    static let firstSuffix = 2
    static let suffixMark = " #"
    static let columns = "name, email, org, plan, login, profile, usage"
    static let schema = """
        PRAGMA user_version = 4;
        CREATE TABLE IF NOT EXISTS account (
          provider TEXT NOT NULL,
          name     TEXT NOT NULL,
          email    TEXT NOT NULL,
          org      TEXT NOT NULL,
          plan     TEXT NOT NULL,
          login    BLOB NOT NULL,
          profile  BLOB,
          usage    TEXT,
          PRIMARY KEY (provider, name)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS live (
          provider     TEXT PRIMARY KEY,
          installed    TEXT NOT NULL,
          installed_at INTEGER
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS pending (
          provider TEXT PRIMARY KEY,
          name     TEXT NOT NULL,
          owner    TEXT
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS adding (
          provider TEXT PRIMARY KEY,
          live     BLOB,
          service  TEXT NOT NULL
        ) WITHOUT ROWID;
        """
    /// A version 1 store's `pending` table lacks the owner column. Its marker
    /// is owned by no install, so it stays until an install replaces it.
    static let ownerColumn = "SELECT 1 FROM pragma_table_info('pending') WHERE name = 'owner'"
    static let addOwner = "ALTER TABLE pending ADD COLUMN owner TEXT"
    /// A version 1 or 2 store's `adding` table lacks the service column. Its
    /// build always put the item back under the launch's live service, so
    /// that is what a record it left meant.
    static let serviceColumn = "SELECT 1 FROM pragma_table_info('adding') WHERE name = 'service'"
    static let addService = "ALTER TABLE adding ADD COLUMN service TEXT NOT NULL DEFAULT ''"
    static let fillService = "UPDATE adding SET service = ?"
    /// A version 1 to 3 store's `live` table lacks the install time. Its row
    /// keeps none until the next install notes one.
    static let installedAtColumn = "SELECT 1 FROM pragma_table_info('live') WHERE name = 'installed_at'"
    static let addInstalledAt = "ALTER TABLE live ADD COLUMN installed_at INTEGER"

    /// Creates the store directory (0700) and the database (0600) when missing,
    /// and applies the schema in one transaction, adding what an older store lacks.
    public init(paths: Paths) throws {
        db = paths.db
        try PrivateFS.ensurePrivateDir(paths.store)
        try write { tx in
            try tx.conn.exec(Self.schema, "schema")
            if try !Self.found(tx, Self.ownerColumn) { try tx.conn.exec(Self.addOwner, "schema") }
            if try !Self.found(tx, Self.serviceColumn) {
                try tx.conn.exec(Self.addService, "schema")
                try tx.run(Self.fillService, "schema", [.text(paths.keychainService)])
            }
            if try !Self.found(tx, Self.installedAtColumn) { try tx.conn.exec(Self.addInstalledAt, "schema") }
        }
    }

    /// Whether `sql` selects a row in `tx`.
    static func found(_ tx: Tx, _ sql: String) throws -> Bool {
        var hit = false
        try tx.query(sql, "schema", []) { _ in hit = true }
        return hit
    }

    /// The provider's saved logins, sorted by name.
    public func list(_ p: Provider) throws -> [SavedLogin] {
        var rows: [SavedLogin] = []
        try Connection(db).query("SELECT \(Self.columns) FROM account WHERE provider = ?", "list", [.text(p.rawValue)]) {
            rows.append(try Self.saved($0))
        }
        return rows.sorted { $0.name < $1.name }
    }

    public func fetch(_ p: Provider, _ n: SlotName) throws -> SavedLogin? {
        var row: SavedLogin?
        try Connection(db).query(
            "SELECT \(Self.columns) FROM account WHERE provider = ? AND name = ?", "fetch",
            [.text(p.rawValue), .text(n.raw)]
        ) { row = try Self.saved($0) }
        return row
    }

    /// kiba `LIVE-NAME`: the candidate row holding the live org (both empty
    /// counts as equal, one empty does not), else the first candidate with no
    /// row; `capacity` when every candidate holds another org.
    public func liveName(_ p: Provider, live: Identity) throws -> SlotName {
        guard let bare = SlotName(live.email) else { throw KibaError.badName(live.email) }
        var orgs: [SlotName: String] = [:]
        for row in try list(p) { orgs[row.name] = row.identity.org }
        let more = (Self.firstSuffix ... Self.nameTries).compactMap { SlotName("\(live.email)\(Self.suffixMark)\($0)") }
        var free: SlotName?
        for name in [bare] + more {
            guard let org = orgs[name] else {
                free = free ?? name
                continue
            }
            if org == live.org { return name }
        }
        guard let free else { throw KibaError.capacity("logins saved under \(live.email) (limit \(Self.nameTries))") }
        return free
    }

    /// The name whose login was installed last; nil before the first install.
    public func installed(_ p: Provider) throws -> SlotName? {
        try name("SELECT installed FROM live WHERE provider = ?", "installed", p)
    }

    /// Epoch seconds of the last install; nil before the first one noted a time.
    public func installedAt(_ p: Provider) throws -> Int? {
        var at: Int?
        try Connection(db).query("SELECT installed_at FROM live WHERE provider = ?", "installed at", [.text(p.rawValue)]) {
            at = $0.int(0)
        }
        return at
    }

    /// The name whose install began and has not finished; nil when none is in flight.
    public func pending(_ p: Provider) throws -> SlotName? {
        try name("SELECT name FROM pending WHERE provider = ?", "pending", p)
    }

    /// The live item an add's login may overwrite, as it was before that login
    /// ran; nil when no add is in flight.
    public func adding(_ p: Provider) throws -> LiveItem? {
        var item: LiveItem?
        try Connection(db).query("SELECT live, service FROM adding WHERE provider = ?", "adding", [.text(p.rawValue)]) {
            item = LiveItem(bytes: $0.blob(0), service: $0.text(1) ?? "")
        }
        return item
    }

    /// Runs `body` in one `BEGIN IMMEDIATE` transaction and commits; any throw
    /// rolls back and rethrows. The body may do file and Keychain work: the
    /// transaction holds off every other writer until it ends. The `Tx` ends
    /// with it: kept past `body`, it refuses every call.
    public func write<T>(_ body: (Tx) throws -> T) throws -> T {
        let conn = try Connection(db)
        try conn.exec("BEGIN IMMEDIATE", "begin")
        let tx = Tx(conn: conn)
        defer { tx.open = false }
        do {
            let result = try body(tx)
            try conn.exec("COMMIT", "commit")
            return result
        } catch {
            if conn.inTransaction { try conn.exec("ROLLBACK", "rollback") }
            throw error
        }
    }

    /// The name `sql` selects for `p`; nil when there is no row.
    func name(_ sql: String, _ op: String, _ p: Provider) throws -> SlotName? {
        var raw: String?
        try Connection(db).query(sql, op, [.text(p.rawValue)]) { raw = $0.text(0) }
        guard let raw else { return nil }
        guard let name = SlotName(raw) else { throw KibaError.badName(raw) }
        return name
    }

    /// A row decoded; a name that fails `NAME-OK?` was written by hand and is `badName`.
    static func saved(_ r: Row) throws -> SavedLogin {
        let raw = r.text(0) ?? ""
        guard let name = SlotName(raw) else { throw KibaError.badName(raw) }
        return SavedLogin(
            name: name,
            identity: Identity(email: r.text(1) ?? "", plan: r.text(3) ?? "", org: r.text(2) ?? ""),
            login: r.blob(4) ?? Data(),
            profile: r.blob(5),
            usage: r.text(6).map { usageDecode(Data($0.utf8)) })
    }
}

/// An install's hold on its provider's pending marker: the owner it noted.
public struct Claim: Equatable, Sendable {
    let owner: String
}

/// Writes inside one `Store.write` transaction. Once that transaction has
/// ended, committed or rolled back, every call throws
/// `db("<op>: transaction is closed")`.
public final class Tx {
    let conn: Connection
    /// False once the transaction has ended.
    var open = true

    static let closed = "transaction is closed"

    init(conn: Connection) {
        self.conn = conn
    }

    /// Inserts or replaces the row; an existing row keeps its usage when `s.usage` is nil.
    public func put(_ p: Provider, _ s: SavedLogin) throws {
        try run(
            """
            INSERT INTO account (provider, name, email, org, plan, login, profile, usage)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (provider, name) DO UPDATE SET
              email = excluded.email, org = excluded.org, plan = excluded.plan,
              login = excluded.login, profile = excluded.profile,
              usage = coalesce(excluded.usage, account.usage)
            """, "put",
            [.text(p.rawValue), .text(s.name.raw), .text(s.identity.email), .text(s.identity.org),
             .text(s.identity.plan), .blob(s.login), .blob(s.profile), .text(s.usage.map(Self.usageText))])
    }

    /// `noAccount` when there is no such row.
    public func setLogin(_ p: Provider, _ n: SlotName, _ doc: Data) throws {
        let changed = try run(
            "UPDATE account SET login = ? WHERE provider = ? AND name = ?", "set login",
            [.blob(doc), .text(p.rawValue), .text(n.raw)])
        guard changed > 0 else { throw KibaError.noAccount(p, n.raw) }
    }

    /// `noAccount` when there is no such row.
    public func setUsage(_ p: Provider, _ n: SlotName, _ u: UsageRecord) throws {
        let changed = try run(
            "UPDATE account SET usage = ? WHERE provider = ? AND name = ?", "set usage",
            [.text(Self.usageText(u)), .text(p.rawValue), .text(n.raw)])
        guard changed > 0 else { throw KibaError.noAccount(p, n.raw) }
    }

    /// Nothing to do when there is no such row.
    public func remove(_ p: Provider, _ n: SlotName) throws {
        try run("DELETE FROM account WHERE provider = ? AND name = ?", "remove", [.text(p.rawValue), .text(n.raw)])
    }

    /// Notes `n` as the installed name, installed at `at` (epoch seconds);
    /// nil keeps the time already noted.
    public func noteInstalled(_ p: Provider, _ n: SlotName, at: Int?) throws {
        try run(
            """
            INSERT INTO live (provider, installed, installed_at) VALUES (?, ?, ?)
            ON CONFLICT (provider) DO UPDATE SET
              installed = excluded.installed, installed_at = coalesce(excluded.installed_at, live.installed_at)
            """, "note installed", [.text(p.rawValue), .text(n.raw), .int(at)])
    }

    /// Records an install of `n` as begun under a new claim, replacing any
    /// earlier marker; committed before any live file changes.
    public func notePending(_ p: Provider, _ n: SlotName) throws -> Claim {
        let claim = Claim(owner: UUID().uuidString)
        try run(
            """
            INSERT INTO pending (provider, name, owner) VALUES (?, ?, ?)
            ON CONFLICT (provider) DO UPDATE SET name = excluded.name, owner = excluded.owner
            """, "note pending", [.text(p.rawValue), .text(n.raw), .text(claim.owner)])
        return claim
    }

    /// Whether the pending marker is still the one `c` noted.
    public func owns(_ p: Provider, _ c: Claim) throws -> Bool {
        var owned = false
        try query(
            "SELECT 1 FROM pending WHERE provider = ? AND owner = ?", "owns pending",
            [.text(p.rawValue), .text(c.owner)]
        ) { _ in owned = true }
        return owned
    }

    /// Clears the marker `c` noted; nothing to do once another install has replaced it.
    public func clearPending(_ p: Provider, _ c: Claim) throws {
        try run("DELETE FROM pending WHERE provider = ? AND owner = ?", "clear pending", [.text(p.rawValue), .text(c.owner)])
    }

    /// Records an add's login as begun, with the live item it must leave as
    /// it found and the service that item is filed under; committed before
    /// the login is launched.
    public func noteAdding(_ p: Provider, _ item: LiveItem) throws {
        try run(
            """
            INSERT INTO adding (provider, live, service) VALUES (?, ?, ?)
            ON CONFLICT (provider) DO UPDATE SET live = excluded.live, service = excluded.service
            """, "note adding", [.text(p.rawValue), .blob(item.bytes), .text(item.service)])
    }

    /// Nothing to do when no add is in flight.
    public func clearAdding(_ p: Provider) throws {
        try run("DELETE FROM adding WHERE provider = ?", "clear adding", [.text(p.rawValue)])
    }

    /// Runs one statement of this transaction; the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ op: String, _ args: [Value]) throws -> Int {
        try checked(op).run(sql, op, args)
    }

    /// Runs one query of this transaction, handing each result row to `row`.
    func query(_ sql: String, _ op: String, _ args: [Value], row: (Row) throws -> Void) throws {
        try checked(op).query(sql, op, args, row: row)
    }

    /// The connection while the transaction is open.
    func checked(_ op: String) throws -> Connection {
        guard open else { throw KibaError.db("\(op): \(Self.closed)") }
        return conn
    }

    static func usageText(_ u: UsageRecord) -> String {
        String(decoding: usageEncode(u), as: UTF8.self)
    }
}

/// One SQLite connection, open from `init` until it is released.
final class Connection {
    let handle: OpaquePointer

    static let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW
    /// How long a call waits for another writer before failing, in milliseconds.
    static let busyMillis: Int32 = 5000

    /// Opens `url`, creating it 0600 when missing, in WAL mode.
    init(_ url: URL) throws {
        let path = url.path
        let fresh = try !PrivateFS.isFile(url)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, Self.flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(rc))
            // A handle that failed to open holds nothing to flush.
            sqlite3_close_v2(db)
            throw KibaError.db("open \(path): \(msg)")
        }
        handle = db
        // Before WAL mode creates -wal and -shm, which copy the database's mode.
        if fresh, chmod(path, PrivateFS.fileMode) != 0 { throw KibaError.io(PrivateFS.failure("chmod", path)) }
        guard sqlite3_busy_timeout(handle, Self.busyMillis) == SQLITE_OK else { throw fail("busy timeout") }
        try exec("PRAGMA journal_mode = WAL", "journal mode")
    }

    /// Every statement is finalized before its call returns, so closing cannot
    /// fail; an open transaction is rolled back.
    deinit { sqlite3_close_v2(handle) }

    /// Whether a transaction is open.
    var inTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }

    func exec(_ sql: String, _ op: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw fail(op) }
    }

    /// Runs one statement with `args` bound in order, handing each result row to `row`.
    func query(_ sql: String, _ op: String, _ args: [Value], row: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw fail(op) }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            guard arg.bind(stmt, Int32(i + 1)) == SQLITE_OK else { throw fail(op) }
        }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: try row(Row(stmt: stmt))
            case SQLITE_DONE: return
            default: throw fail(op)
            }
        }
    }

    /// Runs one statement that returns no rows; the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ op: String, _ args: [Value]) throws -> Int {
        try query(sql, op, args) { _ in }
        return Int(sqlite3_changes(handle))
    }

    func fail(_ op: String) -> KibaError {
        .db("\(op): \(String(cString: sqlite3_errmsg(handle)))")
    }
}

/// A statement parameter.
enum Value {
    case text(String?)
    case blob(Data?)
    case int(Int?)

    /// SQLite copies every bound value before the call returns.
    static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    func bind(_ stmt: OpaquePointer, _ i: Int32) -> Int32 {
        switch self {
        case .text(nil), .blob(nil), .int(nil):
            return sqlite3_bind_null(stmt, i)
        case .text(let s?):
            return sqlite3_bind_text(stmt, i, s, Int32(s.utf8.count), Self.transient)
        case .blob(let d?):
            // An empty buffer may have no address, which would bind NULL.
            guard !d.isEmpty else { return sqlite3_bind_zeroblob(stmt, i, 0) }
            return d.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), Self.transient) }
        case .int(let n?):
            return sqlite3_bind_int64(stmt, i, sqlite3_int64(n))
        }
    }
}

/// The current result row of a statement.
struct Row {
    let stmt: OpaquePointer

    func text(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(sqlite3_column_bytes(stmt, i))), as: UTF8.self)
    }

    func int(_ i: Int32) -> Int? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, i))
    }

    func blob(_ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}
