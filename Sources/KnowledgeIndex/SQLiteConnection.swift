import CSQLite
import Foundation

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// A thin, single-threaded wrapper over one SQLite connection.
///
/// Uses the vendored SQLite (with FTS5 and sqlite-vec compiled in), not the system
/// library, so behaviour is identical on macOS and Linux. Not Sendable: own it from
/// one actor.
public final class SQLiteConnection {
    let handle: OpaquePointer

    /// Opens (or creates) a database. Pass ":memory:" for an in-memory database.
    public init(path: String) throws {
        let registered = jeeves_register_sqlite_vec()
        guard registered == SQLITE_OK else { throw SQLiteError(code: registered, message: "registering sqlite-vec failed") }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit { sqlite3_close_v2(handle) }

    public static var sqliteVersion: String { String(cString: sqlite3_libversion()) }
    public static var sqliteVecVersion: String { String(cString: jeeves_sqlite_vec_version()) }

    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw SQLiteError(code: rc, message: message)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw SQLiteError(code: rc, message: lastErrorMessage) }
        return Statement(handle: statement, connection: self)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

public final class Statement {
    let handle: OpaquePointer
    private let connection: SQLiteConnection

    init(handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit { sqlite3_finalize(handle) }

    public func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: connection.lastErrorMessage) }
    }

    public func bind(_ index: Int32, _ value: String) throws {
        try check(sqlite3_bind_text(handle, index, value, -1, jeeves_sqlite_transient()))
    }

    public func bind(_ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    public func bind(_ index: Int32, _ value: Double) throws {
        try check(sqlite3_bind_double(handle, index, value))
    }

    public func bindNull(_ index: Int32) throws {
        try check(sqlite3_bind_null(handle, index))
    }

    /// Binds a float32 vector as a little-endian BLOB, the format sqlite-vec expects.
    public func bind(_ index: Int32, vector: [Float]) throws {
        let rc = vector.withUnsafeBytes { bytes in
            sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), jeeves_sqlite_transient())
        }
        try check(rc)
    }

    /// Advances one row. Returns false when the statement is done.
    public func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: rc, message: connection.lastErrorMessage)
        }
    }

    /// Runs a statement that returns no rows, then resets it for reuse.
    public func run() throws {
        defer { reset() }
        while try step() {}
    }

    public func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    public func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    public func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: text)
    }
}
