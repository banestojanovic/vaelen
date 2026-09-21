import Foundation
import SQLite3
import Darwin
import CryptoKit
import Security

public enum SQLiteStateError: Error, Equatable, Sendable {
    case open(String), execute(String), unsupportedSchema(Int), invalidRecord
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStateStore: @unchecked Sendable {
    // Kept at the public lifecycle schema epoch for compatibility with the
    // existing store contract; bootstrap_receipts is an additive table in the
    // v7 migration and is safe for stores already reporting v7.
    public static let schemaVersion = 13
    private var database: OpaquePointer?
    public let databaseURL: URL
    internal var databasePointer: OpaquePointer? { database }

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        try FileManager.default.createDirectory(at: self.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: databaseURL.deletingLastPathComponent().path)
        guard sqlite3_open_v2(self.databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
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
                try execute("CREATE TABLE IF NOT EXISTS lifecycle_intent (id INTEGER PRIMARY KEY CHECK (id = 1), intent TEXT NOT NULL CHECK (intent IN ('on','off')), generation INTEGER NOT NULL, operation_id TEXT NOT NULL, actor TEXT NOT NULL, bundle_id TEXT NOT NULL, agent_label TEXT NOT NULL, bundle_program TEXT NOT NULL, endpoint TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS lifecycle_operations (operation_id TEXT PRIMARY KEY NOT NULL, generation INTEGER NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('register','unregister')), state TEXT NOT NULL CHECK (state IN ('pending','in-flight','succeeded','failed','unknown/recovery-required')), pre_observation_json TEXT NOT NULL, post_observation_json TEXT NULL, error TEXT NULL, created_at TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS lifecycle_ownership (id INTEGER PRIMARY KEY CHECK (id = 1), bundle_id TEXT NOT NULL, agent_label TEXT NOT NULL, bundle_program TEXT NOT NULL, endpoint TEXT NOT NULL, signing_team TEXT NULL, designated_requirement TEXT NULL, artifact_hash TEXT NULL, operation_id TEXT NOT NULL, generation INTEGER NOT NULL)")
                try execute("PRAGMA user_version = 7")
            }
             if version <= 7 {
                 // v7 briefly stored the URL bearer in bootstrap_receipts.  Do
                 // not retain that secret when opening such a store: rebuild
                 // the table and carry only its one-way digest forward.
                 try execute("CREATE TABLE IF NOT EXISTS bootstrap_receipts (id INTEGER PRIMARY KEY CHECK (id = 1), bundle_id TEXT NOT NULL, agent_label TEXT NOT NULL, bundle_program TEXT NOT NULL, endpoint TEXT NOT NULL, epoch TEXT NOT NULL, operation_id TEXT NOT NULL, nonce TEXT NOT NULL, invocation_token TEXT NOT NULL, invocation_user TEXT NOT NULL, expires_at TEXT NOT NULL, phase TEXT NOT NULL CHECK (phase IN ('reserved','succeeded','failed','unknown/recovery-required','promoted')), executor_state TEXT NULL, executor_detail TEXT NULL, post_observation_json TEXT NULL, integrity_digest TEXT NOT NULL)")
                 try execute("CREATE TABLE IF NOT EXISTS bootstrap_invocations (token_hash TEXT PRIMARY KEY NOT NULL, bundle_id TEXT NOT NULL, agent_label TEXT NOT NULL, bundle_program TEXT NOT NULL, endpoint TEXT NOT NULL, operation TEXT NOT NULL, invocation_user TEXT NOT NULL, invocation_uid INTEGER NOT NULL, expires_at TEXT NOT NULL, consumed_at TEXT NULL, controller_path TEXT NOT NULL DEFAULT '/Applications/Vaelen.app')")
                 try? execute("ALTER TABLE bootstrap_invocations ADD COLUMN controller_path TEXT NOT NULL DEFAULT '/Applications/Vaelen.app'")
                // Additive provenance columns. Ignore duplicate-column errors
                // so both newly-created and pre-existing v7 stores work.
                 try? execute("ALTER TABLE bootstrap_receipts ADD COLUMN invocation_uid INTEGER NOT NULL DEFAULT 0")
                 try? execute("ALTER TABLE bootstrap_receipts ADD COLUMN preflight_provenance_json TEXT NOT NULL DEFAULT ''")
                 try execute("CREATE TABLE IF NOT EXISTS lifecycle_diagnostics (id INTEGER PRIMARY KEY AUTOINCREMENT, correlation_id TEXT NOT NULL, phase TEXT NOT NULL, outcome TEXT NOT NULL, detail TEXT NOT NULL, database_path TEXT NOT NULL, invocation_id TEXT NULL, token_hash TEXT NULL, operation_id TEXT NULL, user TEXT NOT NULL, uid INTEGER NOT NULL, schema_version INTEGER NOT NULL, build_identity TEXT NOT NULL, created_at TEXT NOT NULL)")
                 try? execute("ALTER TABLE bootstrap_invocations ADD COLUMN invocation_id TEXT NOT NULL DEFAULT ''")
                 var legacy: [String]? = nil
                 try query("SELECT bundle_id,agent_label,bundle_program,endpoint,epoch,operation_id,nonce,invocation_token,invocation_user,invocation_uid,preflight_provenance_json,expires_at,phase,executor_state,executor_detail,post_observation_json,integrity_digest FROM bootstrap_receipts WHERE id=1") { s in
                     legacy = (0..<17).map { columnString(s, Int32($0)) ?? "" }
                 }
                 try execute("CREATE TABLE bootstrap_receipts_v8 (id INTEGER PRIMARY KEY CHECK (id = 1), bundle_id TEXT NOT NULL, agent_label TEXT NOT NULL, bundle_program TEXT NOT NULL, endpoint TEXT NOT NULL, epoch TEXT NOT NULL, operation_id TEXT NOT NULL, nonce TEXT NOT NULL, invocation_token_hash TEXT NOT NULL, invocation_token TEXT NOT NULL, invocation_user TEXT NOT NULL, invocation_uid INTEGER NOT NULL DEFAULT 0, preflight_provenance_json TEXT NOT NULL DEFAULT '', expires_at TEXT NOT NULL, phase TEXT NOT NULL CHECK (phase IN ('reserved','succeeded','failed','unknown/recovery-required','promoted')), executor_state TEXT NULL, executor_detail TEXT NULL, post_observation_json TEXT NULL, integrity_digest TEXT NOT NULL)")
                 if let row = legacy {
                     let q: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
                     let hash = Self.bootstrapInvocationHash(row[7])
                     let state = row[13].isEmpty ? "NULL" : "'\(q(row[13]))'"
                     let detail = row[14].isEmpty ? "NULL" : "'\(q(row[14]))'"
                     let post = row[15].isEmpty ? "NULL" : "'\(q(row[15]))'"
                     try execute("INSERT INTO bootstrap_receipts_v8 (id,bundle_id,agent_label,bundle_program,endpoint,epoch,operation_id,nonce,invocation_token_hash,invocation_token,invocation_user,invocation_uid,preflight_provenance_json,expires_at,phase,executor_state,executor_detail,post_observation_json,integrity_digest) VALUES (1,'\(q(row[0]))','\(q(row[1]))','\(q(row[2]))','\(q(row[3]))','\(q(row[4]))','\(q(row[5]))','\(q(row[6]))','\(hash)','\(hash)','\(q(row[8]))',\(Int(row[9]) ?? 0),'\(q(row[10]))','\(q(row[11]))','\(q(row[12]))',\(state),\(detail),\(post),'\(q(row[16]))')")
                 }
                 try execute("DROP TABLE bootstrap_receipts")
                 try execute("ALTER TABLE bootstrap_receipts_v8 RENAME TO bootstrap_receipts")
                 try execute("PRAGMA user_version = 8")
             }
               if version <= 8 {
                 try? execute("ALTER TABLE bootstrap_receipts ADD COLUMN invocation_id TEXT NOT NULL DEFAULT ''")
                 try? execute("ALTER TABLE bootstrap_receipts ADD COLUMN generation INTEGER NOT NULL DEFAULT 0")
                 try? execute("ALTER TABLE bootstrap_receipts ADD COLUMN registration_evidence_json TEXT NULL")
                  try execute("PRAGMA user_version = 9")
               }
               // Recovery is an additive historical record.  It never rewrites
              // the bootstrap receipt and is intentionally not lifecycle truth.
               try execute("CREATE TABLE IF NOT EXISTS bootstrap_recovery (id INTEGER PRIMARY KEY CHECK (id = 1), epoch TEXT NOT NULL, operation_id TEXT NOT NULL, invocation_id TEXT NOT NULL, bundle_id TEXT NOT NULL, agent_label TEXT NOT NULL, bundle_program TEXT NOT NULL, endpoint TEXT NOT NULL, state TEXT NOT NULL, detail TEXT NOT NULL, observed_at TEXT NOT NULL, source TEXT NOT NULL DEFAULT 'MODERN RECOVERY')")
               if version <= 9 {
                  // Existing v9 stores already have the table; new stores use
                  // the source-bearing definition above. Duplicate-column
                  // failure is intentionally ignored for the latter case.
                  try? execute("ALTER TABLE bootstrap_recovery ADD COLUMN source TEXT NOT NULL DEFAULT 'MODERN RECOVERY'")
                  try execute("PRAGMA user_version = 10")
               }
               if version <= 10 {
                  try execute("CREATE TABLE IF NOT EXISTS bootstrap_receipt_history (id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, epoch TEXT NOT NULL, operation_id TEXT NOT NULL, receipt_json TEXT NOT NULL, archived_at TEXT NOT NULL)")
                  try execute("CREATE UNIQUE INDEX IF NOT EXISTS bootstrap_receipt_history_identity ON bootstrap_receipt_history(source, epoch, operation_id)")
                  try execute("PRAGMA user_version = 11")
               }
                if version <= 11 {
                  try execute("CREATE TABLE IF NOT EXISTS bootstrap_recovery_history (id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, epoch TEXT NOT NULL, operation_id TEXT NOT NULL, invocation_id TEXT NOT NULL, state TEXT NOT NULL, detail TEXT NOT NULL, observed_at TEXT NOT NULL, archived_at TEXT NOT NULL)")
                  try execute("CREATE UNIQUE INDEX IF NOT EXISTS bootstrap_recovery_history_identity ON bootstrap_recovery_history(source, epoch, operation_id, invocation_id, state)")
                   try execute("PRAGMA user_version = 12")
                 }
                if version <= 12 {
                   // Lifecycle executor credentials and the destructive process
                   // fence must survive the interval between Core's journal
                   // write and the platform call. They are operation evidence,
                   // not caller-selectable lifecycle state.
                   try? execute("ALTER TABLE lifecycle_operations ADD COLUMN nonce TEXT NULL")
                   try? execute("ALTER TABLE lifecycle_operations ADD COLUMN session_binding TEXT NULL")
                   try? execute("ALTER TABLE lifecycle_operations ADD COLUMN process_identity_json TEXT NULL")
                   try execute("PRAGMA user_version = 13")
                }
                 try execute("CREATE TABLE IF NOT EXISTS lifecycle_development_cleanup_history (id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, target_json TEXT NOT NULL, intent_json TEXT NOT NULL, ownership_json TEXT NOT NULL, operations_json TEXT NOT NULL, evidence TEXT NOT NULL, created_at TEXT NOT NULL)")
             // A process restart is an explicit loss of the in-memory executor
            // boundary.  An operation which was dispatched but not durably
            // completed must never be replayed or presented as still active.
            // Do this while the initialization transaction is held so the
            // recovery classification itself is durable before Core serves a
            // request.
            try execute("UPDATE lifecycle_operations SET state='unknown/recovery-required', error='Core restarted while lifecycle operation was in-flight' WHERE state='in-flight'")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    internal func pragmaVersion() throws -> Int {
        var result = 0
        try query("PRAGMA user_version") { result = Int(sqlite3_column_int($0, 0)) }
        return result
    }

    private var message: String { String(cString: sqlite3_errmsg(database)) }
}

public enum LifecycleDiagnosticPhase: String, Codable, Sendable {
    case mint, preflight, urlConstruction, urlOpen, urlReceipt, consume
    case reserve, platform, admission, endpoint, handshake, readiness, reconnect, promotion, lifecycle
}
public struct LifecycleDiagnostic: Codable, Equatable, Sendable {
    public let correlationID: UUID; public let phase: LifecycleDiagnosticPhase
    public let outcome: String; public let detail: String; public let databasePath: String
    public let invocationID: UUID?; public let tokenHash: String?; public let operationID: UUID?
    public let user: String; public let uid: UInt32; public let schemaVersion: Int; public let buildIdentity: String
    public init(correlationID: UUID, phase: LifecycleDiagnosticPhase, outcome: String, detail: String, databasePath: String, invocationID: UUID? = nil, tokenHash: String? = nil, operationID: UUID? = nil, user: String = NSUserName(), uid: UInt32 = getuid(), schemaVersion: Int = SQLiteStateStore.schemaVersion, buildIdentity: String = "m14-core-daemon-lifecycle-schema-7") {
        self.correlationID=correlationID; self.phase=phase; self.outcome=outcome; self.detail=detail; self.databasePath=databasePath; self.invocationID=invocationID; self.tokenHash=tokenHash; self.operationID=operationID; self.user=user; self.uid=uid; self.schemaVersion=schemaVersion; self.buildIdentity=buildIdentity
    }
}

public struct BootstrapInvocationAuthorization: Sendable, Equatable {
    public let token: String
    public let target: LifecycleTargetIdentity
    public let operation: String
    public let user: String
    public let uid: UInt32
    public let expiresAt: Date
    public let correlationID: UUID
    public init(token: String, target: LifecycleTargetIdentity = LifecycleCanonicalIdentity.target,
                operation: String = "register", user: String = NSUserName(), uid: UInt32 = getuid(),
                 expiresAt: Date, correlationID: UUID = UUID()) {
        self.token = token; self.target = target; self.operation = operation
        self.user = user; self.uid = uid; self.expiresAt = expiresAt; self.correlationID = correlationID
    }
}

public extension SQLiteStateStore {
    static let bootstrapInvocationOperation = "register"

    /// Mints and durably records a one-time handoff authorization. This is
    /// coordination evidence only; it is neither lifecycle intent nor ownership.
    func mintBootstrapInvocation(target: LifecycleTargetIdentity = LifecycleCanonicalIdentity.target,
                                 controllerPath: String = LifecycleCanonicalIdentity.installedControllerURL.path,
                                 operation: String = SQLiteStateStore.bootstrapInvocationOperation,
                                 user: String = NSUserName(), uid: UInt32 = getuid(),
                                 expiresAt: Date = Date().addingTimeInterval(60)) throws -> BootstrapInvocationAuthorization {
        guard target == LifecycleCanonicalIdentity.target, operation == Self.bootstrapInvocationOperation,
              !user.isEmpty, expiresAt > Date() else { throw BootstrapError.refused("Invalid bootstrap invocation authorization.") }
        var bytes = Data(count: 32)
        let byteCount = bytes.count
        guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!) }) == errSecSuccess else { throw BootstrapError.refused("Unable to mint bootstrap invocation authorization.") }
        let token = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let authorization = BootstrapInvocationAuthorization(token: token, target: target, operation: operation, user: user, uid: uid, expiresAt: expiresAt)
        let hash = Self.bootstrapInvocationHash(token)
        let q: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
        let expiry = String(format: "%.17g", expiresAt.timeIntervalSince1970)
        guard controllerPath == LifecycleCanonicalIdentity.installedControllerURL.path || controllerPath == LifecycleCanonicalIdentity.validationControllerURL.path else { throw BootstrapError.refused("Invalid bootstrap controller path.") }
        try execute("INSERT INTO bootstrap_invocations (token_hash,bundle_id,agent_label,bundle_program,endpoint,operation,invocation_user,invocation_uid,expires_at,consumed_at,controller_path,invocation_id) VALUES ('\(q(hash))','\(q(target.bundleID))','\(q(target.agentLabel))','\(q(target.bundleProgram))','\(q(target.endpoint))','\(q(operation))','\(q(user))',\(uid),'\(q(expiry))',NULL,'\(q(controllerPath))','\(authorization.correlationID.uuidString)')")
        try? recordDiagnostic(.init(correlationID: authorization.correlationID, phase: .mint, outcome: "success", detail: "authorization minted; token persisted as hash only", databasePath: databaseURL.path, invocationID: authorization.correlationID, tokenHash: hash))
        return authorization
    }

    /// Atomically consumes the authorization. Every binding is checked in the
    /// UPDATE predicate so forged, replayed, wrong-user, and wrong-target
    /// invocations all fail closed without becoming durable lifecycle state.
    func consumeBootstrapInvocation(token: String, target: LifecycleTargetIdentity = LifecycleCanonicalIdentity.target,
                                    controllerPath: String = LifecycleCanonicalIdentity.installedControllerURL.path,
                                    operation: String = SQLiteStateStore.bootstrapInvocationOperation,
                                    user: String = NSUserName(), uid: UInt32 = getuid(), now: Date = Date()) throws {
        guard !token.isEmpty, target == LifecycleCanonicalIdentity.target, operation == Self.bootstrapInvocationOperation,
              controllerPath == LifecycleCanonicalIdentity.installedControllerURL.path || controllerPath == LifecycleCanonicalIdentity.validationControllerURL.path else { throw BootstrapError.refused("Invalid bootstrap invocation authorization.") }
        let q: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
        let timestamp = String(format: "%.17g", now.timeIntervalSince1970)
        let statementSQL = "UPDATE bootstrap_invocations SET consumed_at='\(q(timestamp))' WHERE token_hash='\(q(Self.bootstrapInvocationHash(token)))' AND bundle_id='\(q(target.bundleID))' AND agent_label='\(q(target.agentLabel))' AND bundle_program='\(q(target.bundleProgram))' AND endpoint='\(q(target.endpoint))' AND operation='\(q(operation))' AND invocation_user='\(q(user))' AND invocation_uid=\(uid) AND controller_path='\(q(controllerPath))' AND consumed_at IS NULL AND expires_at > '\(q(timestamp))'"
        try transaction {
            try execute(statementSQL)
            var changed = false
            try query("SELECT changes()") { changed = sqlite3_column_int($0, 0) > 0 }
            guard changed else { throw BootstrapError.refused("Bootstrap invocation authorization was invalid, expired, or already consumed.") }
        }
    }

    private static func bootstrapInvocationHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public extension SQLiteStateStore {
    static func safeTokenHash(_ token: String) -> String {
        let isDigest = token.count == 64 && token.allSatisfy { $0.isHexDigit }
        return isDigest ? token.lowercased() : bootstrapInvocationHash(token)
    }
    /// Diagnostics are bounded breadcrumbs only; they are never read by the
    /// lifecycle state machine and contain no plaintext authorization token.
    func recordDiagnostic(_ d: LifecycleDiagnostic) throws {
        let q: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
        let uuid: (UUID?) -> String = { $0.map { "'\($0.uuidString)'" } ?? "NULL" }
        try execute("INSERT INTO lifecycle_diagnostics (correlation_id,phase,outcome,detail,database_path,invocation_id,token_hash,operation_id,user,uid,schema_version,build_identity,created_at) VALUES ('\(q(d.correlationID.uuidString))','\(d.phase.rawValue)','\(q(d.outcome))','\(q(String(d.detail.prefix(512))))','\(q(databaseURL.path))',\(uuid(d.invocationID)),\(d.tokenHash.map { "'\(q($0))'" } ?? "NULL"),\(uuid(d.operationID)),'\(q(d.user))',\(d.uid),\(d.schemaVersion),'\(q(d.buildIdentity))',CURRENT_TIMESTAMP)")
        try execute("DELETE FROM lifecycle_diagnostics WHERE id NOT IN (SELECT id FROM lifecycle_diagnostics ORDER BY id DESC LIMIT 256)")
    }
    func diagnostics(limit: Int = 256) throws -> [LifecycleDiagnostic] {
        var result = [LifecycleDiagnostic](); let n = max(1, min(limit, 256))
        try query("SELECT correlation_id,phase,outcome,detail,database_path,invocation_id,token_hash,operation_id,user,uid,schema_version,build_identity FROM lifecycle_diagnostics ORDER BY id DESC LIMIT \(n)") { s in
            guard let c=columnString(s,0).flatMap(UUID.init(uuidString:)), let p=columnString(s,1).flatMap({ LifecycleDiagnosticPhase(rawValue: $0) }), let o=columnString(s,2), let detail=columnString(s,3), let path=columnString(s,4), let user=columnString(s,8), let build=columnString(s,11) else { throw SQLiteStateError.invalidRecord }
            result.append(.init(correlationID:c, phase:p, outcome:o, detail:detail, databasePath:path, invocationID:columnString(s,5).flatMap(UUID.init(uuidString:)), tokenHash:columnString(s,6), operationID:columnString(s,7).flatMap(UUID.init(uuidString:)), user:user, uid:UInt32(sqlite3_column_int64(s,9)), schemaVersion:Int(sqlite3_column_int64(s,10)), buildIdentity:build))
        }; return result
    }
    func bootstrapInvocationID(token: String) throws -> UUID? {
        var value: UUID?
        try query("SELECT invocation_id FROM bootstrap_invocations WHERE token_hash='\(Self.quote(Self.bootstrapInvocationHash(token)))'") { value = columnString($0, 0).flatMap(UUID.init(uuidString:)) }
        return value
    }
    func bootstrapInvocationIDHash(_ tokenHash: String) throws -> UUID? {
        var value: UUID?
        try query("SELECT invocation_id FROM bootstrap_invocations WHERE token_hash='\(Self.quote(tokenHash))'") { value = columnString($0, 0).flatMap(UUID.init(uuidString:)) }
        return value
    }
    private static func quote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
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
