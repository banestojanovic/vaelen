import Foundation
import SQLite3
import Darwin

public enum SQLiteStateError: Error, Equatable, Sendable {
    case open(String), execute(String), unsupportedSchema(Int), invalidRecord
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStateStore: @unchecked Sendable {
    public static let schemaVersion = 1
    private var database: OpaquePointer?

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: databaseURL.deletingLastPathComponent().path)
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw SQLiteStateError.open(message)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        do { try initialize() } catch { sqlite3_close(database); database = nil; throw error }
    }

    deinit { sqlite3_close(database) }

    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let value = errorMessage.map { String(cString: $0) } ?? message
            sqlite3_free(errorMessage)
            throw SQLiteStateError.execute(value)
        }
    }

    internal func query(_ sql: String, bind: ((OpaquePointer) -> Void) = { _ in }, row: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw SQLiteStateError.execute(message) }
        defer { sqlite3_finalize(statement) }
        bind(statement!)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try row(statement!)
            result = sqlite3_step(statement)
        }
        if result != SQLITE_DONE { throw SQLiteStateError.execute(message) }
    }

    internal func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    internal func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text16(statement, index) else { return nil }
        return String(decodingCString: value.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
    }

    private func initialize() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let version = try pragmaVersion()
            if version > Self.schemaVersion { throw SQLiteStateError.unsupportedSchema(version) }
            if version == 0 {
                try execute("CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, custom_name TEXT NULL, canonical_path TEXT NOT NULL UNIQUE, registration_kind TEXT NOT NULL CHECK (registration_kind = 'linked'))")
                try execute("CREATE TABLE IF NOT EXISTS parked_paths (id TEXT PRIMARY KEY NOT NULL, canonical_path TEXT NOT NULL UNIQUE)")
                try execute("PRAGMA user_version = 1")
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func pragmaVersion() throws -> Int {
        var result = 0
        try query("PRAGMA user_version") { result = Int(sqlite3_column_int($0, 0)) }
        return result
    }

    private var message: String { String(cString: sqlite3_errmsg(database)) }
}
