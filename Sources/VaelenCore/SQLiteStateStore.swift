import Foundation
import SQLite3
import Darwin

public enum SQLiteStateError: Error, Equatable, Sendable {
    case open(String), execute(String), unsupportedSchema(Int), invalidRecord
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStateStore: @unchecked Sendable {
    public static let schemaVersion = 6
    private var database: OpaquePointer?
    internal var databasePointer: OpaquePointer? { database }

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

    internal func execute(_ sql: String, bind: ((OpaquePointer) -> Void)) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw SQLiteStateError.execute(message) }
        defer { sqlite3_finalize(statement) }
        bind(statement!)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteStateError.execute(message) }
    }

    internal func transaction<T>(_ body: () throws -> T) throws -> T {
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

    internal func bind(_ value: Data, to statement: OpaquePointer, index: Int32) {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), sqliteTransient)
        }
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
            if version <= 1 {
                try execute("CREATE TABLE IF NOT EXISTS route_intents (id TEXT PRIMARY KEY NOT NULL, route_json BLOB NOT NULL, project_id TEXT NULL, project_path TEXT NULL)")
                try execute("PRAGMA user_version = 2")
            }
            if version <= 2 {
                try execute("CREATE TABLE IF NOT EXISTS system_modifications (capability TEXT PRIMARY KEY NOT NULL, installed_content TEXT NOT NULL, previous_content TEXT NULL, active INTEGER NOT NULL)")
                try execute("PRAGMA user_version = 3")
            }
            if version <= 3 {
                try execute("CREATE TABLE IF NOT EXISTS tls_capability (id INTEGER PRIMARY KEY CHECK (id = 1), ca_fingerprint TEXT NOT NULL, ca_certificate_path TEXT NOT NULL, active INTEGER NOT NULL)")
                try execute("PRAGMA user_version = 4")
            }
            if version <= 4 {
                try execute("CREATE TABLE IF NOT EXISTS route_target_transitions (route_id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL, previous_route_json BLOB NOT NULL, desired_route_json BLOB NOT NULL, previous_provider_json BLOB NOT NULL, desired_provider_json BLOB NOT NULL, previous_socket TEXT NOT NULL, desired_socket TEXT NOT NULL, state TEXT NOT NULL CHECK (state = 'providerPending'))")
                try execute("PRAGMA user_version = 5")
            }
            if version <= 5 {
                try execute("ALTER TABLE tls_capability RENAME TO tls_capability_legacy")
                try execute("CREATE TABLE tls_capability (id INTEGER PRIMARY KEY CHECK (id = 1), ca_fingerprint TEXT NOT NULL, ca_certificate_path TEXT NOT NULL, key_application_tag TEXT NOT NULL, public_key_fingerprint TEXT NULL, ca_ownership_state TEXT NOT NULL CHECK (ca_ownership_state IN ('unverified', 'owned', 'mismatch')), trust_domain TEXT NOT NULL CHECK (trust_domain = 'user'), trust_provenance TEXT NOT NULL CHECK (trust_provenance IN ('none', 'confirmedByVaelen')), trust_settings_fingerprint TEXT NULL)")
                try execute("INSERT INTO tls_capability (id, ca_fingerprint, ca_certificate_path, key_application_tag, public_key_fingerprint, ca_ownership_state, trust_domain, trust_provenance, trust_settings_fingerprint) SELECT id, ca_fingerprint, ca_certificate_path, 'dev.vaelen.local-ca', NULL, 'unverified', 'user', 'none', NULL FROM tls_capability_legacy")
                try execute("DROP TABLE tls_capability_legacy")
                try execute("PRAGMA user_version = 6")
            }
            if version <= 6 {
                if try !tableHasColumn("projects", column: "php_override_version") {
                    try execute("ALTER TABLE projects ADD COLUMN php_override_version TEXT NULL")
                }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    internal func pragmaVersion() throws -> Int {
        var result = 0
        try query("PRAGMA user_version") { result = Int(sqlite3_column_int($0, 0)) }
        return result
    }

    private func tableHasColumn(_ table: String, column: String) throws -> Bool {
        var found = false
        try query("PRAGMA table_info(\(table))") { statement in
            if columnString(statement, 1) == column { found = true }
        }
        return found
    }

    private var message: String { String(cString: sqlite3_errmsg(database)) }
}

internal enum TLSDurableOwnershipState: String, Sendable {
    case unverified, owned, mismatch
}

internal enum TLSDurableTrustProvenance: String, Sendable {
    case none, confirmedByVaelen
}

internal struct TLSDurableRecord: Equatable, Sendable {
    let fingerprint: String
    let certificatePath: String
    let keyApplicationTag: String
    let publicKeyFingerprint: String?
    let ownership: TLSDurableOwnershipState
    let trustDomain: String
    let trustProvenance: TLSDurableTrustProvenance
    let trustSettingsFingerprint: String?
}

extension SQLiteStateStore {
    internal func tlsRecord() throws -> TLSDurableRecord? {
        var record: TLSDurableRecord?
        try query("SELECT ca_fingerprint, ca_certificate_path, key_application_tag, public_key_fingerprint, ca_ownership_state, trust_domain, trust_provenance, trust_settings_fingerprint FROM tls_capability WHERE id = 1") { statement in
            guard let fingerprint = columnString(statement, 0), let path = columnString(statement, 1), let tag = columnString(statement, 2), let ownership = columnString(statement, 4).flatMap(TLSDurableOwnershipState.init(rawValue:)), let domain = columnString(statement, 5), let provenance = columnString(statement, 6).flatMap(TLSDurableTrustProvenance.init(rawValue:)) else { throw SQLiteStateError.invalidRecord }
            record = TLSDurableRecord(fingerprint: fingerprint, certificatePath: path, keyApplicationTag: tag, publicKeyFingerprint: columnString(statement, 3), ownership: ownership, trustDomain: domain, trustProvenance: provenance, trustSettingsFingerprint: columnString(statement, 7))
        }
        return record
    }

    internal func saveTLSRecord(_ record: TLSDurableRecord) throws {
        let publicKey = record.publicKeyFingerprint.map { "'\(sqlQuote($0))'" } ?? "NULL"
        let settings = record.trustSettingsFingerprint.map { "'\(sqlQuote($0))'" } ?? "NULL"
        let sql = "INSERT OR REPLACE INTO tls_capability (id, ca_fingerprint, ca_certificate_path, key_application_tag, public_key_fingerprint, ca_ownership_state, trust_domain, trust_provenance, trust_settings_fingerprint) VALUES (1, '\(sqlQuote(record.fingerprint))', '\(sqlQuote(record.certificatePath))', '\(sqlQuote(record.keyApplicationTag))', \(publicKey), '\(record.ownership.rawValue)', '\(record.trustDomain)', '\(record.trustProvenance.rawValue)', \(settings))"
        try execute(sql)
    }

    private func sqlQuote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
}
