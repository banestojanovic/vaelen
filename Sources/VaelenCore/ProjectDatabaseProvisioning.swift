import Foundation
import Security
import CryptoKit
import SQLite3

public enum DatabaseProvisioningError: Error, Equatable, Sendable {
    case invalidName
    case reservedName
    case operationIDReused
    case namespaceReserved
    case invalidTransition
    case secretUnavailable
    case credentialMissing
    case targetMismatch
    case engineFailure
}

public struct DatabaseName: Hashable, Codable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard Self.valid(value) else { throw DatabaseProvisioningError.invalidName }
        guard !["mysql", "information_schema", "performance_schema", "sys"].contains(value) else { throw DatabaseProvisioningError.reservedName }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func valid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...32).contains(bytes.count), let first = bytes.first, (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
}

public struct DatabaseUserName: Hashable, Codable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard DatabaseName.validName(value) else { throw DatabaseProvisioningError.invalidName }
        guard !["root", "mysql", "admin", "administrator"].contains(value) else { throw DatabaseProvisioningError.reservedName }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension DatabaseName {
    fileprivate static func validName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...32).contains(bytes.count), let first = bytes.first, (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
}

public struct DatabaseOperationID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct ProjectDatabaseCreation: Equatable, Codable, Sendable {
    public let operationID: DatabaseOperationID
    public let projectID: ProjectID
    public let binding: ProjectServiceBinding
    public let database: DatabaseName
    public let user: DatabaseUserName

    public init(operationID: DatabaseOperationID = DatabaseOperationID(), projectID: ProjectID, binding: ProjectServiceBinding, database: DatabaseName, user: DatabaseUserName) {
        self.operationID = operationID
        self.projectID = projectID
        self.binding = binding
        self.database = database
        self.user = user
    }
}

public struct VerifiedDatabaseTarget: Equatable, Sendable {
    public let projectID: ProjectID
    public let binding: ProjectServiceBinding
    public let record: ServiceInstanceRecord
    public let clusterIdentity: String

    public init(projectID: ProjectID, binding: ProjectServiceBinding, record: ServiceInstanceRecord, clusterIdentity: String) {
        self.projectID = projectID
        self.binding = binding
        self.record = record
        self.clusterIdentity = clusterIdentity
    }
}

public enum DatabaseProvisionEffect: String, Codable, CaseIterable, Hashable, Sendable {
    case applicationUser, database, privileges, loginEnablement
}

public enum DatabaseProvisionDiagnostic: String, Codable, Sendable {
    case existingDatabase, existingUser, engineResponseLost, engineRejected, authenticationFailed, identityChanged
}

public enum DatabaseProvisionState: String, Codable, Sendable {
    case reserved, prepared, pendingEffect, ready, refused, failedBeforeDDL, needsAttention
}

public struct DatabaseProvisionAttempt: Equatable, Sendable {
    public let receiptID: UUID
    public let request: ProjectDatabaseCreation
    public let target: VerifiedDatabaseTarget
    public let credentialReference: String
    public let state: DatabaseProvisionState
    public let pendingEffect: DatabaseProvisionEffect?
    public let confirmedEffects: Set<DatabaseProvisionEffect>
    public let uncertainEffects: Set<DatabaseProvisionEffect>
    public let diagnostic: DatabaseProvisionDiagnostic?

    fileprivate init(receiptID: UUID, request: ProjectDatabaseCreation, target: VerifiedDatabaseTarget, credentialReference: String, state: DatabaseProvisionState, pendingEffect: DatabaseProvisionEffect?, confirmedEffects: Set<DatabaseProvisionEffect>, uncertainEffects: Set<DatabaseProvisionEffect>, diagnostic: DatabaseProvisionDiagnostic?) {
        self.receiptID = receiptID
        self.request = request
        self.target = target
        self.credentialReference = credentialReference
        self.state = state
        self.pendingEffect = pendingEffect
        self.confirmedEffects = confirmedEffects
        self.uncertainEffects = uncertainEffects
        self.diagnostic = diagnostic
    }
}

enum DatabaseProvisionEvent: Sendable {
    case prepared
    case effectPending(DatabaseProvisionEffect)
    case effectConfirmed(DatabaseProvisionEffect)
    case refused(DatabaseProvisionDiagnostic)
    case failedBeforeDDL
    case needsAttention(DatabaseProvisionEffect, diagnostic: DatabaseProvisionDiagnostic)
    case attentionWithoutPending(DatabaseProvisionDiagnostic)
    case ready
}

public final class ProjectDatabaseReceiptRepository: @unchecked Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) { self.store = store }

    func begin(_ request: ProjectDatabaseCreation, target: VerifiedDatabaseTarget, credentialReference: String) throws -> DatabaseProvisionAttempt {
        guard request.projectID == target.projectID, request.binding == target.binding,
              (request.binding.kind == .mysql || request.binding.kind == .postgresql),
              request.binding.kind == target.record.id.kind,
              request.binding.instance == target.record.id.name,
              request.binding.version == nil || request.binding.version == target.record.packageIdentifier,
              Self.supportedPackage(target.record.packageIdentifier, for: target.record.id.kind),
              target.record.endpoint.kind == target.record.id.kind,
              !target.clusterIdentity.isEmpty else {
            throw DatabaseProvisioningError.targetMismatch
        }
        return try store.transaction {
            if let existing = try attempt(request.operationID) {
                guard existing.request == request, existing.target == target else { throw DatabaseProvisioningError.operationIDReused }
                return existing
            }
            guard try !isReserved("project_database_name_reservations", column: "database_name", value: request.database.value, binding: request.binding),
                  try !isReserved("project_database_user_reservations", column: "username", value: request.user.value, binding: request.binding) else {
                throw DatabaseProvisioningError.namespaceReserved
            }
            let receipt = UUID()
            let port = target.record.endpoint.portNumbers.first
            try store.execute("INSERT INTO project_database_attempts (operation_id,receipt_id,project_id,binding_alias,binding_version,instance_kind,instance_name,package_identifier,endpoint_port,data_directory,cluster_identity,database_name,username,credential_reference,state,pending_effect,confirmed_effects,uncertain_effects,diagnostic) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,'reserved',NULL,0,0,NULL)", bind: { statement in
                store.bind(request.operationID.rawValue.uuidString, to: statement, index: 1)
                store.bind(receipt.uuidString, to: statement, index: 2)
                store.bind(request.projectID.description, to: statement, index: 3)
                store.bind(request.binding.alias.value, to: statement, index: 4)
                if let version = request.binding.version { store.bind(version, to: statement, index: 5) } else { sqlite3_bind_null(statement, 5) }
                store.bind(request.binding.kind.rawValue, to: statement, index: 6)
                store.bind(request.binding.instance.value, to: statement, index: 7)
                store.bind(target.record.packageIdentifier, to: statement, index: 8)
                sqlite3_bind_int(statement, 9, Int32(port))
                store.bind(target.record.dataDirectory, to: statement, index: 10)
                store.bind(target.clusterIdentity, to: statement, index: 11)
                store.bind(request.database.value, to: statement, index: 12)
                store.bind(request.user.value, to: statement, index: 13)
                store.bind(credentialReference, to: statement, index: 14)
            })
            try store.execute("INSERT INTO project_database_name_reservations (instance_kind,instance_name,database_name,operation_id) VALUES (?,?,?,?)", bind: { statement in
                store.bind(request.binding.kind.rawValue, to: statement, index: 1)
                store.bind(request.binding.instance.value, to: statement, index: 2)
                store.bind(request.database.value, to: statement, index: 3)
                store.bind(request.operationID.rawValue.uuidString, to: statement, index: 4)
            })
            try store.execute("INSERT INTO project_database_user_reservations (instance_kind,instance_name,username,operation_id) VALUES (?,?,?,?)", bind: { statement in
                store.bind(request.binding.kind.rawValue, to: statement, index: 1)
                store.bind(request.binding.instance.value, to: statement, index: 2)
                store.bind(request.user.value, to: statement, index: 3)
                store.bind(request.operationID.rawValue.uuidString, to: statement, index: 4)
            })
            return try attempt(request.operationID) ?? { throw SQLiteStateError.invalidRecord }()
        }
    }

    func record(_ event: DatabaseProvisionEvent, operationID: DatabaseOperationID) throws {
        try store.transaction {
        guard let current = try attempt(operationID) else { throw DatabaseProvisioningError.invalidTransition }
        var state = current.state
        var pending = current.pendingEffect
        var confirmed = current.confirmedEffects
        var uncertain = current.uncertainEffects
        var diagnostic = current.diagnostic
        switch event {
        case .prepared:
            guard state == .reserved || state == .failedBeforeDDL else { throw DatabaseProvisioningError.invalidTransition }
            state = .prepared
        case .effectPending(let effect):
            guard state == .prepared || state == .pendingEffect, pending == nil,
                  let index = DatabaseProvisionEffect.allCases.firstIndex(of: effect),
                  confirmed == Set(DatabaseProvisionEffect.allCases.prefix(index)) else { throw DatabaseProvisioningError.invalidTransition }
            state = .pendingEffect; pending = effect
        case .effectConfirmed(let effect):
            guard state == .pendingEffect, pending == effect else { throw DatabaseProvisioningError.invalidTransition }
            confirmed.insert(effect); pending = nil; state = .pendingEffect
        case .refused(let reason):
            guard state == .reserved || state == .prepared || state == .failedBeforeDDL else { throw DatabaseProvisioningError.invalidTransition }
            state = .refused; diagnostic = reason
        case .failedBeforeDDL:
            guard state == .reserved || state == .prepared || state == .failedBeforeDDL else { throw DatabaseProvisioningError.invalidTransition }
            state = .failedBeforeDDL
        case .needsAttention(let effect, let reason):
            guard state == .pendingEffect, pending == effect else { throw DatabaseProvisioningError.invalidTransition }
            state = .needsAttention; uncertain.insert(effect); diagnostic = reason
        case .attentionWithoutPending(let reason):
            guard state == .pendingEffect, pending == nil else { throw DatabaseProvisioningError.invalidTransition }
            state = .needsAttention; diagnostic = reason
        case .ready:
            guard state == .pendingEffect, pending == nil, confirmed.count == DatabaseProvisionEffect.allCases.count else { throw DatabaseProvisioningError.invalidTransition }
            state = .ready
        }
        let mask = Self.mask(confirmed)
        let uncertainMask = Self.mask(uncertain)
        try store.execute("UPDATE project_database_attempts SET state=?,pending_effect=?,confirmed_effects=?,uncertain_effects=?,diagnostic=? WHERE operation_id=?", bind: { statement in
            store.bind(state.rawValue, to: statement, index: 1)
            if let pending { store.bind(pending.rawValue, to: statement, index: 2) }
            store.bind(String(mask), to: statement, index: 3)
            store.bind(String(uncertainMask), to: statement, index: 4)
            if let diagnostic { store.bind(diagnostic.rawValue, to: statement, index: 5) }
            store.bind(operationID.rawValue.uuidString, to: statement, index: 6)
        })
        if state == .refused {
            try store.execute("DELETE FROM project_database_name_reservations WHERE operation_id=?", bind: { store.bind(operationID.rawValue.uuidString, to: $0, index: 1) })
            try store.execute("DELETE FROM project_database_user_reservations WHERE operation_id=?", bind: { store.bind(operationID.rawValue.uuidString, to: $0, index: 1) })
        }
        }
    }

    public func attempt(_ operationID: DatabaseOperationID) throws -> DatabaseProvisionAttempt? {
        var value: DatabaseProvisionAttempt?
        try store.query("SELECT receipt_id,project_id,binding_alias,binding_version,instance_kind,instance_name,package_identifier,endpoint_port,data_directory,cluster_identity,database_name,username,credential_reference,state,pending_effect,confirmed_effects,uncertain_effects,diagnostic FROM project_database_attempts WHERE operation_id=?", bind: { store.bind(operationID.rawValue.uuidString, to: $0, index: 1) }) { statement in
            guard let receiptText = store.columnString(statement, 0), let receipt = UUID(uuidString: receiptText),
                  let projectText = store.columnString(statement, 1), let projectUUID = UUID(uuidString: projectText),
                  let aliasText = store.columnString(statement, 2), let alias = try? ProjectBindingAlias(aliasText),
                  let kindText = store.columnString(statement, 4), let kind = ProjectServiceKind(rawValue: kindText),
                  let instanceText = store.columnString(statement, 5), let instance = try? ProjectInstanceName(instanceText),
                  let package = store.columnString(statement, 6), let directory = store.columnString(statement, 8),
                  let cluster = store.columnString(statement, 9), let databaseText = store.columnString(statement, 10), let database = try? DatabaseName(databaseText),
                  let userText = store.columnString(statement, 11), let user = try? DatabaseUserName(userText),
                  let credential = store.columnString(statement, 12), let stateText = store.columnString(statement, 13), let state = DatabaseProvisionState(rawValue: stateText) else { throw SQLiteStateError.invalidRecord }
            let port = Int(sqlite3_column_int(statement, 7))
            let binding = try ProjectServiceBinding(alias: alias, kind: kind, instance: instance, version: store.columnString(statement, 3))
            let endpoint: ServiceInstanceEndpoint
            switch kind {
            case .mysql: endpoint = try .mysql(port: port)
            case .postgresql: endpoint = try .postgresql(port: port)
            default: throw SQLiteStateError.invalidRecord
            }
            let target = VerifiedDatabaseTarget(projectID: ProjectID(rawValue: projectUUID), binding: binding, record: try ServiceInstanceRecord(id: ServiceInstanceID(kind: kind, name: instance), packageIdentifier: package, endpoint: endpoint, dataDirectory: directory), clusterIdentity: cluster)
            let request = ProjectDatabaseCreation(operationID: operationID, projectID: ProjectID(rawValue: projectUUID), binding: binding, database: database, user: user)
            let pending = store.columnString(statement, 14).flatMap(DatabaseProvisionEffect.init(rawValue:))
            let confirmed = Self.effects(Int(sqlite3_column_int64(statement, 15)))
            let uncertain = Self.effects(Int(sqlite3_column_int64(statement, 16)))
            let diagnostic = store.columnString(statement, 17).flatMap(DatabaseProvisionDiagnostic.init(rawValue:))
            value = DatabaseProvisionAttempt(receiptID: receipt, request: request, target: target, credentialReference: credential, state: state, pendingEffect: pending, confirmedEffects: confirmed, uncertainEffects: uncertain, diagnostic: diagnostic)
        }
        return value
    }


    private static func mask(_ effects: Set<DatabaseProvisionEffect>) -> Int { effects.reduce(0) { $0 | (1 << DatabaseProvisionEffect.allCases.firstIndex(of: $1)!) } }
    private static func effects(_ mask: Int) -> Set<DatabaseProvisionEffect> { Set(DatabaseProvisionEffect.allCases.enumerated().compactMap { mask & (1 << $0.offset) == 0 ? nil : $0.element }) }

    private static func supportedPackage(_ package: String, for kind: ProjectServiceKind) -> Bool {
        switch kind {
        case .mysql: package.hasPrefix("mysql-")
        case .postgresql: package == PostgreSQLServiceModule.packageIdentifier
        default: false
        }
    }

    private func isReserved(_ table: String, column: String, value: String, binding: ProjectServiceBinding) throws -> Bool {
        var found = false
        try store.query("SELECT 1 FROM \(table) WHERE instance_kind=? AND instance_name=? AND \(column)=? LIMIT 1", bind: { statement in
            store.bind(binding.kind.rawValue, to: statement, index: 1)
            store.bind(binding.instance.value, to: statement, index: 2)
            store.bind(value, to: statement, index: 3)
        }) { _ in found = true }
        return found
    }
}

public struct SecretPassword: Sendable {
    private let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    public func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T { try bytes.withUnsafeBytes(body) }
}

public protocol ProjectDatabasePasswordStore: Sendable {
    func create(for operationID: DatabaseOperationID) throws -> SecretPassword
    func load(for operationID: DatabaseOperationID) throws -> SecretPassword
}

protocol ProjectDatabaseProvisioningEngine: Sendable {
    func clusterIdentity(for target: VerifiedDatabaseTarget) throws -> String
    func checkAbsent(database: DatabaseName, user: DatabaseUserName) throws -> DatabaseProvisionDiagnostic?
    func createLockedUser(_ user: DatabaseUserName, password: SecretPassword) throws
    func createDatabase(_ database: DatabaseName) throws
    func createDatabase(_ database: DatabaseName, owner: DatabaseUserName) throws
    func grantApplicationAccess(database: DatabaseName, user: DatabaseUserName) throws
    func enableLogin(user: DatabaseUserName) throws
    func enableLogin(user: DatabaseUserName, database: DatabaseName, password: SecretPassword) throws
    func authenticate(database: DatabaseName, user: DatabaseUserName, password: SecretPassword) throws
}

extension ProjectDatabaseProvisioningEngine {
    func createDatabase(_ database: DatabaseName, owner: DatabaseUserName) throws { try createDatabase(database) }
    func enableLogin(user: DatabaseUserName, database: DatabaseName, password: SecretPassword) throws { try enableLogin(user: user) }
}

protocol MySQLDatabaseProvisioningEngine: ProjectDatabaseProvisioningEngine {}

public final class ProjectDatabaseProvisioner: @unchecked Sendable {
    private let receipts: ProjectDatabaseReceiptRepository
    private let passwords: any ProjectDatabasePasswordStore
    private let engine: any ProjectDatabaseProvisioningEngine

    init(receipts: ProjectDatabaseReceiptRepository, passwords: any ProjectDatabasePasswordStore, engine: any ProjectDatabaseProvisioningEngine) {
        self.receipts = receipts
        self.passwords = passwords
        self.engine = engine
    }

    func create(_ request: ProjectDatabaseCreation, target: VerifiedDatabaseTarget) throws -> DatabaseProvisionAttempt {
        try execute(request, target: target, retrying: false)
    }

    func retry(_ request: ProjectDatabaseCreation, target: VerifiedDatabaseTarget) throws -> DatabaseProvisionAttempt {
        try execute(request, target: target, retrying: true)
    }

    private func execute(_ request: ProjectDatabaseCreation, target: VerifiedDatabaseTarget, retrying: Bool) throws -> DatabaseProvisionAttempt {
        let reference = "project-database:\(request.operationID.rawValue.uuidString)"
        var attempt = try receipts.begin(request, target: target, credentialReference: reference)
        if retrying {
            guard attempt.state == .failedBeforeDDL, attempt.pendingEffect == nil,
                  attempt.confirmedEffects.isEmpty, attempt.uncertainEffects.isEmpty else { throw DatabaseProvisioningError.invalidTransition }
        } else if attempt.state == .failedBeforeDDL {
            return attempt
        }
        if attempt.state == .ready || attempt.state == .refused || attempt.state == .needsAttention { return attempt }
        if attempt.state == .pendingEffect {
            if let pending = attempt.pendingEffect {
                try receipts.record(.needsAttention(pending, diagnostic: .engineResponseLost), operationID: request.operationID)
            } else {
                try receipts.record(.attentionWithoutPending(.engineResponseLost), operationID: request.operationID)
            }
            return try loadAttempt(request.operationID)
        }
        guard try engine.clusterIdentity(for: target) == target.clusterIdentity else {
            if attempt.state == .reserved { try receipts.record(.failedBeforeDDL, operationID: request.operationID) }
            return try loadAttempt(request.operationID)
        }
        guard attempt.state == .reserved || attempt.state == .prepared || attempt.state == .failedBeforeDDL else { return attempt }
        if attempt.state == .reserved || attempt.state == .prepared || attempt.state == .failedBeforeDDL {
            if let conflict = try engine.checkAbsent(database: request.database, user: request.user) {
                try receipts.record(.refused(conflict), operationID: request.operationID)
                return try loadAttempt(request.operationID)
            }
        }
        let password: SecretPassword
        do {
            if attempt.state == .prepared {
                password = try passwords.load(for: request.operationID)
            } else {
                do { password = try passwords.create(for: request.operationID) }
                catch DatabaseProvisioningError.secretUnavailable {
                    password = try passwords.load(for: request.operationID)
                }
            }
        } catch {
            try receipts.record(.failedBeforeDDL, operationID: request.operationID)
            return try loadAttempt(request.operationID)
        }
        if attempt.state == .reserved || attempt.state == .failedBeforeDDL { try receipts.record(.prepared, operationID: request.operationID) }
        attempt = try loadAttempt(request.operationID)
        let stages: [(DatabaseProvisionEffect, () throws -> Void)] = [
            (.applicationUser, { try self.engine.createLockedUser(request.user, password: password) }),
            (.database, { try self.engine.createDatabase(request.database, owner: request.user) }),
            (.privileges, { try self.engine.grantApplicationAccess(database: request.database, user: request.user) }),
            (.loginEnablement, { try self.engine.enableLogin(user: request.user, database: request.database, password: password) })
        ]
        for (effect, action) in stages {
            try receipts.record(.effectPending(effect), operationID: request.operationID)
            do {
                try action()
                try receipts.record(.effectConfirmed(effect), operationID: request.operationID)
            } catch {
                try receipts.record(.needsAttention(effect, diagnostic: .engineResponseLost), operationID: request.operationID)
                return try loadAttempt(request.operationID)
            }
        }
        do {
            try engine.authenticate(database: request.database, user: request.user, password: password)
            try receipts.record(.ready, operationID: request.operationID)
        } catch {
            try receipts.record(.attentionWithoutPending(.authenticationFailed), operationID: request.operationID)
        }
        return try loadAttempt(request.operationID)
    }

    private func loadAttempt(_ operationID: DatabaseOperationID) throws -> DatabaseProvisionAttempt {
        guard let attempt = try receipts.attempt(operationID) else { throw DatabaseProvisioningError.invalidTransition }
        return attempt
    }
}

public final class KeychainProjectDatabasePasswordStore: ProjectDatabasePasswordStore, @unchecked Sendable {
    private let namespace: String

    public init(namespace: String = "dev.vaelen.project-database") { self.namespace = namespace }

    public func create(for operationID: DatabaseOperationID) throws -> SecretPassword {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DatabaseProvisioningError.secretUnavailable }
        let password = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let data = Data(password.utf8)
        var attributes: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: namespace, kSecAttrAccount: operationID.rawValue.uuidString, kSecValueData: data, kSecAttrSynchronizable: false, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        attributes[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw DatabaseProvisioningError.secretUnavailable }
        return SecretPassword(bytes: data)
    }

    public func load(for operationID: DatabaseOperationID) throws -> SecretPassword {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: namespace, kSecAttrAccount: operationID.rawValue.uuidString, kSecAttrSynchronizable: false, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { throw DatabaseProvisioningError.secretUnavailable }
        return SecretPassword(bytes: data)
    }
}
