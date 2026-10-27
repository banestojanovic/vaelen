import Foundation
import SQLite3

public struct ServiceInstanceID: Hashable, Sendable {
    public let kind: ProjectServiceKind
    public let name: ProjectInstanceName

    public init(kind: ProjectServiceKind, name: ProjectInstanceName) {
        self.kind = kind
        self.name = name
    }
}

public struct ServiceInstanceEndpoint: Equatable, Sendable {
    private enum Value: Equatable, Sendable {
        case mysql(Int), postgresql(Int), redis(Int), valkey(Int), mailpit(Int, Int)
    }

    private let value: Value

    private init(_ value: Value) { self.value = value }

    public static func mysql(port: Int) throws -> Self { try single(.mysql(port), port: port) }
    public static func postgresql(port: Int) throws -> Self { try single(.postgresql(port), port: port) }
    public static func redis(port: Int) throws -> Self { try single(.redis(port), port: port) }
    public static func valkey(port: Int) throws -> Self { try single(.valkey(port), port: port) }
    public static func mailpit(smtpPort: Int, httpPort: Int) throws -> Self {
        guard (1...65535).contains(smtpPort), (1...65535).contains(httpPort), smtpPort != httpPort else { throw SQLiteStateError.invalidRecord }
        return Self(.mailpit(smtpPort, httpPort))
    }

    private static func single(_ value: Value, port: Int) throws -> Self {
        guard (1...65535).contains(port) else { throw SQLiteStateError.invalidRecord }
        return Self(value)
    }

    public var kind: ProjectServiceKind {
        switch value {
        case .mysql: .mysql
        case .postgresql: .postgresql
        case .redis: .redis
        case .valkey: .valkey
        case .mailpit: .mailpit
        }
    }

    fileprivate var storage: (String, Int, Int?) {
        switch value {
        case .mysql(let port): ("mysql", port, nil)
        case .postgresql(let port): ("postgresql", port, nil)
        case .redis(let port): ("redis", port, nil)
        case .valkey(let port): ("valkey", port, nil)
        case .mailpit(let smtp, let http): ("mailpit", smtp, http)
        }
    }

    fileprivate init(kind: ProjectServiceKind, endpointKind: String, first: Int, second: Int?) throws {
        guard endpointKind == kind.rawValue else { throw SQLiteStateError.invalidRecord }
        switch kind {
        case .mysql: self = try .mysql(port: first)
        case .postgresql: self = try .postgresql(port: first)
        case .redis: self = try .redis(port: first)
        case .valkey: self = try .valkey(port: first)
        case .mailpit:
            guard let second else { throw SQLiteStateError.invalidRecord }
            self = try .mailpit(smtpPort: first, httpPort: second)
        }
    }

    public var loopbackEndpoints: [String: String] {
        switch value {
        case .mysql(let port): ["mysql": "127.0.0.1:\(port)"]
        case .postgresql(let port): ["postgresql": "127.0.0.1:\(port)"]
        case .redis(let port): ["redis": "127.0.0.1:\(port)"]
        case .valkey(let port): ["valkey": "127.0.0.1:\(port)"]
        case .mailpit(let smtp, let http): ["smtp": "127.0.0.1:\(smtp)", "http": "127.0.0.1:\(http)"]
        }
    }

    public var portNumbers: (first: Int, second: Int?) {
        switch value {
        case .mysql(let port), .postgresql(let port), .redis(let port), .valkey(let port): (port, nil)
        case .mailpit(let smtp, let http): (smtp, http)
        }
    }
}

public struct ServiceInstanceRecord: Equatable, Sendable {
    public let id: ServiceInstanceID
    public let packageIdentifier: String
    public let endpoint: ServiceInstanceEndpoint
    public let dataDirectory: String

    public init(id: ServiceInstanceID, packageIdentifier: String, endpoint: ServiceInstanceEndpoint, dataDirectory: String) throws {
        let hasControlCharacters = { (value: String) in value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
        guard !packageIdentifier.isEmpty, !hasControlCharacters(packageIdentifier), dataDirectory.hasPrefix("/"), !hasControlCharacters(dataDirectory), endpoint.kind == id.kind else { throw SQLiteStateError.invalidRecord }
        let values = endpoint.storage
        _ = try ServiceInstanceEndpoint(kind: id.kind, endpointKind: values.0, first: values.1, second: values.2)
        self.id = id
        self.packageIdentifier = packageIdentifier
        self.endpoint = endpoint
        self.dataDirectory = dataDirectory
    }
}

public enum ServiceInstanceClaim: Equatable, Hashable, Sendable {
    case manual(instance: ServiceInstanceID)
    case project(projectID: ProjectID, binding: ProjectServiceBinding)

    public var instance: ServiceInstanceID {
        switch self {
        case .manual(let instance): instance
        case .project(_, let binding): ServiceInstanceID(kind: binding.kind, name: binding.instance)
        }
    }
}

public struct ServiceInstanceInventoryEntry: Equatable, Sendable {
    public let record: ServiceInstanceRecord
    public let claims: [ServiceInstanceClaim]
    public init(record: ServiceInstanceRecord, claims: [ServiceInstanceClaim]) { self.record = record; self.claims = claims }
}

public struct ServiceInstanceInventorySnapshot: Equatable, Sendable {
    public let entries: [ServiceInstanceInventoryEntry]
    public init(entries: [ServiceInstanceInventoryEntry]) { self.entries = entries }
}

public struct ModuleOwnedServiceSnapshot: Equatable, Sendable {
    public let record: ServiceInstanceRecord?
    public let health: String
    public init(record: ServiceInstanceRecord?, health: String) { self.record = record; self.health = health }
}

public final class ServiceInstanceRepository: @unchecked Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) { self.store = store }

    public func saveInstance(_ record: ServiceInstanceRecord) throws {
        let endpoint = record.endpoint.storage
        try store.transaction {
            if let existing = try instance(record.id) {
                guard existing == record else { throw SQLiteStateError.invalidRecord }
                return
            }
            try store.execute("INSERT INTO service_instances (kind,name,package_identifier,endpoint_kind,endpoint_port1,endpoint_port2,data_directory) VALUES (?,?,?,?,?,?,?)", bind: { statement in
                store.bind(record.id.kind.rawValue, to: statement, index: 1)
                store.bind(record.id.name.value, to: statement, index: 2)
                store.bind(record.packageIdentifier, to: statement, index: 3)
                store.bind(endpoint.0, to: statement, index: 4)
                sqlite3_bind_int(statement, 5, Int32(endpoint.1))
                if let second = endpoint.2 { sqlite3_bind_int(statement, 6, Int32(second)) }
                store.bind(record.dataDirectory, to: statement, index: 7)
            })
        }
    }

    public func saveManuallyClaimedInstance(_ record: ServiceInstanceRecord) throws {
        let endpoint = record.endpoint.storage
        try store.transaction {
            if let existing = try instance(record.id) {
                guard existing == record else { throw SQLiteStateError.invalidRecord }
            } else {
                try store.execute("INSERT INTO service_instances (kind,name,package_identifier,endpoint_kind,endpoint_port1,endpoint_port2,data_directory) VALUES (?,?,?,?,?,?,?)", bind: { statement in
                    store.bind(record.id.kind.rawValue, to: statement, index: 1)
                    store.bind(record.id.name.value, to: statement, index: 2)
                    store.bind(record.packageIdentifier, to: statement, index: 3)
                    store.bind(endpoint.0, to: statement, index: 4)
                    sqlite3_bind_int(statement, 5, Int32(endpoint.1))
                    if let second = endpoint.2 { sqlite3_bind_int(statement, 6, Int32(second)) }
                    store.bind(record.dataDirectory, to: statement, index: 7)
                })
            }
            try setManualClaim(for: record.id, claimed: true)
        }
    }

    public func removeStoppedInstance(_ id: ServiceInstanceID) throws {
        try store.transaction {
            try store.execute("DELETE FROM manual_service_claims WHERE kind=? AND instance_name=?", bind: { statement in
                store.bind(id.kind.rawValue, to: statement, index: 1)
                store.bind(id.name.value, to: statement, index: 2)
            })
            var hasProjectClaim = false
            try store.query("SELECT 1 FROM project_service_claims WHERE kind=? AND instance_name=? LIMIT 1", bind: { statement in
                store.bind(id.kind.rawValue, to: statement, index: 1)
                store.bind(id.name.value, to: statement, index: 2)
            }) { _ in hasProjectClaim = true }
            guard !hasProjectClaim else { throw SQLiteStateError.invalidRecord }
            try store.execute("DELETE FROM service_instances WHERE kind=? AND name=?", bind: { statement in
                store.bind(id.kind.rawValue, to: statement, index: 1)
                store.bind(id.name.value, to: statement, index: 2)
            })
        }
    }

    public func withNoProjectClaims<T>(for id: ServiceInstanceID, _ boundedSynchronousAction: () throws -> T) throws -> T {
        try store.transaction {
            var claimed = false
            try store.query("SELECT 1 FROM project_service_claims WHERE kind=? AND instance_name=? LIMIT 1", bind: { statement in
                store.bind(id.kind.rawValue, to: statement, index: 1)
                store.bind(id.name.value, to: statement, index: 2)
            }) { _ in claimed = true }
            guard !claimed else { throw SQLiteStateError.invalidRecord }
            return try boundedSynchronousAction()
        }
    }

    public func removeSingletonAfterSuccessfulAction<T>(id: ServiceInstanceID, packageIdentifier: String, _ boundedSynchronousAction: () throws -> T) throws -> T {
        guard (id.kind == .mysql || id.kind == .mailpit), id.name.value == "default" else { throw SQLiteStateError.invalidRecord }
        return try store.transaction {
            var claimed = false
            try store.query("SELECT 1 FROM project_service_claims WHERE kind=? AND instance_name=? LIMIT 1", bind: { statement in
                store.bind(id.kind.rawValue, to: statement, index: 1)
                store.bind(id.name.value, to: statement, index: 2)
            }) { _ in claimed = true }
            guard !claimed else { throw SQLiteStateError.invalidRecord }
            let result = try boundedSynchronousAction()
            try store.execute("DELETE FROM manual_service_claims WHERE kind=? AND instance_name=?", bind: { statement in
                store.bind(id.kind.rawValue, to: statement, index: 1)
                store.bind(id.name.value, to: statement, index: 2)
            })
            if let existing = try instance(id), existing.packageIdentifier == packageIdentifier {
                try store.execute("DELETE FROM service_instances WHERE kind=? AND name=?", bind: { statement in
                    store.bind(id.kind.rawValue, to: statement, index: 1)
                    store.bind(id.name.value, to: statement, index: 2)
                })
            }
            return result
        }
    }

    public func instance(_ id: ServiceInstanceID) throws -> ServiceInstanceRecord? {
        var result: ServiceInstanceRecord?
        try store.query("SELECT package_identifier,endpoint_kind,endpoint_port1,endpoint_port2,data_directory FROM service_instances WHERE kind=? AND name=?", bind: { statement in
            store.bind(id.kind.rawValue, to: statement, index: 1)
            store.bind(id.name.value, to: statement, index: 2)
        }) { statement in
            guard let package = store.columnString(statement, 0), let endpointKind = store.columnString(statement, 1), let directory = store.columnString(statement, 4) else { throw SQLiteStateError.invalidRecord }
            let second = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 3))
            let endpoint = try ServiceInstanceEndpoint(kind: id.kind, endpointKind: endpointKind, first: Int(sqlite3_column_int(statement, 2)), second: second)
            result = try ServiceInstanceRecord(id: id, packageIdentifier: package, endpoint: endpoint, dataDirectory: directory)
        }
        return result
    }

    public func instances() throws -> [ServiceInstanceRecord] {
        var result = [ServiceInstanceRecord]()
        try store.query("SELECT kind,name,package_identifier,endpoint_kind,endpoint_port1,endpoint_port2,data_directory FROM service_instances ORDER BY kind,name") { statement in
            guard let kindString = store.columnString(statement, 0), let kind = ProjectServiceKind(rawValue: kindString), let nameString = store.columnString(statement, 1), let package = store.columnString(statement, 2), let endpointKind = store.columnString(statement, 3), let directory = store.columnString(statement, 6) else { throw SQLiteStateError.invalidRecord }
            let id: ServiceInstanceID
            do { id = ServiceInstanceID(kind: kind, name: try ProjectInstanceName(nameString)) }
            catch { throw SQLiteStateError.invalidRecord }
            let second = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 5))
            let endpoint = try ServiceInstanceEndpoint(kind: kind, endpointKind: endpointKind, first: Int(sqlite3_column_int(statement, 4)), second: second)
            result.append(try ServiceInstanceRecord(id: id, packageIdentifier: package, endpoint: endpoint, dataDirectory: directory))
        }
        return result
    }

    public func inventorySnapshot() throws -> ServiceInstanceInventorySnapshot {
        ServiceInstanceInventorySnapshot(entries: try instances().map { ServiceInstanceInventoryEntry(record: $0, claims: try claims(for: $0.id)) })
    }

    public func replaceProjectClaims(_ bindings: [ProjectServiceBinding], for projectID: ProjectID) throws {
        try store.transaction {
            var projectExists = false
            try store.query("SELECT 1 FROM projects WHERE id=?", bind: { store.bind(projectID.description, to: $0, index: 1) }) { _ in projectExists = true }
            guard projectExists else { throw SQLiteStateError.invalidRecord }
            try store.execute("DELETE FROM project_service_claims WHERE project_id=?", bind: { store.bind(projectID.description, to: $0, index: 1) })
            for binding in bindings {
                try store.execute("INSERT INTO project_service_claims (project_id,alias,kind,instance_name,version) VALUES (?,?,?,?,?)", bind: { statement in
                    store.bind(projectID.description, to: statement, index: 1)
                    store.bind(binding.alias.value, to: statement, index: 2)
                    store.bind(binding.kind.rawValue, to: statement, index: 3)
                    store.bind(binding.instance.value, to: statement, index: 4)
                    if let version = binding.version { store.bind(version, to: statement, index: 5) }
                })
            }
        }
    }

    public func replaceProjectClaims(_ bindings: [ProjectServiceBinding], materializing records: [ServiceInstanceRecord], for projectID: ProjectID) throws {
        try store.transaction {
            var projectExists = false
            try store.query("SELECT 1 FROM projects WHERE id=?", bind: { store.bind(projectID.description, to: $0, index: 1) }) { _ in projectExists = true }
            guard projectExists else { throw SQLiteStateError.invalidRecord }
            for record in records {
                let endpoint = record.endpoint.storage
                if let existing = try instance(record.id) {
                    guard existing == record else { throw SQLiteStateError.invalidRecord }
                } else {
                    try insert(record, endpoint: endpoint)
                }
            }
            try store.execute("DELETE FROM project_service_claims WHERE project_id=?", bind: { store.bind(projectID.description, to: $0, index: 1) })
            for binding in bindings {
                guard try instance(.init(kind: binding.kind, name: binding.instance)) != nil else { throw SQLiteStateError.invalidRecord }
                try insertClaim(binding, projectID: projectID)
            }
        }
    }

    public func addProjectClaim(_ binding: ProjectServiceBinding, materializing record: ServiceInstanceRecord, for projectID: ProjectID) throws {
        try store.transaction {
            if let existing = try instance(record.id) {
                guard existing == record else { throw SQLiteStateError.invalidRecord }
            } else {
                try insert(record, endpoint: record.endpoint.storage)
            }
            var projectExists = false
            try store.query("SELECT 1 FROM projects WHERE id=?", bind: { store.bind(projectID.description, to: $0, index: 1) }) { _ in projectExists = true }
            guard projectExists else { throw SQLiteStateError.invalidRecord }
            try insertClaim(binding, projectID: projectID, upsert: true)
        }
    }

    private func insert(_ record: ServiceInstanceRecord, endpoint: (String, Int, Int?)) throws {
        try store.execute("INSERT INTO service_instances (kind,name,package_identifier,endpoint_kind,endpoint_port1,endpoint_port2,data_directory) VALUES (?,?,?,?,?,?,?)", bind: { statement in
            store.bind(record.id.kind.rawValue, to: statement, index: 1)
            store.bind(record.id.name.value, to: statement, index: 2)
            store.bind(record.packageIdentifier, to: statement, index: 3)
            store.bind(endpoint.0, to: statement, index: 4)
            sqlite3_bind_int(statement, 5, Int32(endpoint.1))
            if let second = endpoint.2 { sqlite3_bind_int(statement, 6, Int32(second)) }
            store.bind(record.dataDirectory, to: statement, index: 7)
        })
    }

    private func insertClaim(_ binding: ProjectServiceBinding, projectID: ProjectID, upsert: Bool = false) throws {
        try store.execute("INSERT INTO project_service_claims (project_id,alias,kind,instance_name,version) VALUES (?,?,?,?,?)\(upsert ? " ON CONFLICT(project_id,alias) DO UPDATE SET kind=excluded.kind,instance_name=excluded.instance_name,version=excluded.version" : "")", bind: { statement in
            store.bind(projectID.description, to: statement, index: 1)
            store.bind(binding.alias.value, to: statement, index: 2)
            store.bind(binding.kind.rawValue, to: statement, index: 3)
            store.bind(binding.instance.value, to: statement, index: 4)
            if let version = binding.version { store.bind(version, to: statement, index: 5) }
        })
    }

    public func addProjectClaim(_ binding: ProjectServiceBinding, for projectID: ProjectID) throws {
        try store.execute("INSERT INTO project_service_claims (project_id,alias,kind,instance_name,version) VALUES (?,?,?,?,?) ON CONFLICT(project_id,alias) DO UPDATE SET kind=excluded.kind,instance_name=excluded.instance_name,version=excluded.version", bind: { statement in
            store.bind(projectID.description, to: statement, index: 1)
            store.bind(binding.alias.value, to: statement, index: 2)
            store.bind(binding.kind.rawValue, to: statement, index: 3)
            store.bind(binding.instance.value, to: statement, index: 4)
            if let version = binding.version { store.bind(version, to: statement, index: 5) }
        })
    }

    public func removeProjectClaims(for projectID: ProjectID) throws {
        try store.execute("DELETE FROM project_service_claims WHERE project_id=?", bind: { store.bind(projectID.description, to: $0, index: 1) })
    }

    public func removeProjectClaim(_ binding: ProjectServiceBinding, for projectID: ProjectID) throws {
        try store.execute("DELETE FROM project_service_claims WHERE project_id=? AND alias=?", bind: { statement in
            store.bind(projectID.description, to: statement, index: 1)
            store.bind(binding.alias.value, to: statement, index: 2)
        })
    }

    public func removeProjectClaims(_ bindings: [ProjectServiceBinding], for projectID: ProjectID) throws {
        try store.transaction {
            for binding in bindings {
                try store.execute("DELETE FROM project_service_claims WHERE project_id=? AND alias=?", bind: { statement in
                    store.bind(projectID.description, to: statement, index: 1)
                    store.bind(binding.alias.value, to: statement, index: 2)
                })
            }
        }
    }

    public func setManualClaim(for id: ServiceInstanceID, claimed: Bool) throws {
        if claimed {
            try store.execute("INSERT INTO manual_service_claims (kind,instance_name) VALUES (?,?) ON CONFLICT(kind,instance_name) DO NOTHING", bind: { statement in
                store.bind(id.kind.rawValue, to: statement, index: 1)
                store.bind(id.name.value, to: statement, index: 2)
            })
        } else {
            try store.execute("DELETE FROM manual_service_claims WHERE kind=? AND instance_name=?", bind: { statement in
                store.bind(id.kind.rawValue, to: statement, index: 1)
                store.bind(id.name.value, to: statement, index: 2)
            })
        }
    }

    public func isManuallyClaimed(_ id: ServiceInstanceID) throws -> Bool {
        var found = false
        try store.query("SELECT 1 FROM manual_service_claims WHERE kind=? AND instance_name=?", bind: { statement in
            store.bind(id.kind.rawValue, to: statement, index: 1)
            store.bind(id.name.value, to: statement, index: 2)
        }) { _ in found = true }
        return found
    }

    public func projectClaims(for projectID: ProjectID) throws -> [ProjectServiceBinding] {
        var result = [ProjectServiceBinding]()
        try store.query("SELECT alias,kind,instance_name,version FROM project_service_claims WHERE project_id=? ORDER BY alias", bind: { store.bind(projectID.description, to: $0, index: 1) }) { statement in
            guard let aliasString = store.columnString(statement, 0), let kindString = store.columnString(statement, 1), let kind = ProjectServiceKind(rawValue: kindString), let nameString = store.columnString(statement, 2) else { throw SQLiteStateError.invalidRecord }
            let alias: ProjectBindingAlias
            let name: ProjectInstanceName
            do { alias = try ProjectBindingAlias(aliasString); name = try ProjectInstanceName(nameString) }
            catch { throw SQLiteStateError.invalidRecord }
            result.append(try ProjectServiceBinding(alias: alias, kind: kind, instance: name, version: store.columnString(statement, 3)))
        }
        return result
    }

    public func claims(for id: ServiceInstanceID) throws -> [ServiceInstanceClaim] {
        var claims = [ServiceInstanceClaim]()
        if try isManuallyClaimed(id) { claims.append(.manual(instance: id)) }
        try store.query("SELECT project_id,alias,version FROM project_service_claims WHERE kind=? AND instance_name=? ORDER BY project_id,alias", bind: { statement in
            store.bind(id.kind.rawValue, to: statement, index: 1)
            store.bind(id.name.value, to: statement, index: 2)
        }) { statement in
            guard let rawID = store.columnString(statement, 0), let uuid = UUID(uuidString: rawID), let aliasValue = store.columnString(statement, 1) else { throw SQLiteStateError.invalidRecord }
            let alias: ProjectBindingAlias
            do { alias = try ProjectBindingAlias(aliasValue) }
            catch { throw SQLiteStateError.invalidRecord }
            let binding = try ProjectServiceBinding(alias: alias, kind: id.kind, instance: id.name, version: store.columnString(statement, 2))
            let projectID = ProjectID(rawValue: uuid)
            claims.append(.project(projectID: projectID, binding: binding))
        }
        return claims
    }
}
