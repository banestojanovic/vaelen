import Foundation

public struct ProjectServiceReleaseSummary: Equatable, Sendable {
    public let operations: [ProjectReconciliationOperationResult]
    public let releasedBindingCount: Int
    public let failed: Bool
    public init(operations: [ProjectReconciliationOperationResult], releasedBindingCount: Int, failed: Bool) { self.operations = operations; self.releasedBindingCount = releasedBindingCount; self.failed = failed }
}

public final class ProjectServiceBindings: @unchecked Sendable {
    private struct SingletonRuntime {
        let inspectBody: (ServiceInstanceID) throws -> (ServiceInstanceRecord?, String)
        let startBody: (ServiceInstanceID) throws -> Void
        func status(id: ServiceInstanceID) throws -> (ServiceInstanceRecord?, String) { try inspectBody(id) }
        func start(id: ServiceInstanceID) throws { try startBody(id) }
    }

    private struct IsolatedRuntime {
        let inspectBody: (ServiceInstanceID) throws -> (ServiceInstanceRecord?, String)
        let startBody: (ServiceInstanceID) throws -> Void
        let stopBody: (ServiceInstanceID) throws -> Void
        func status(id: ServiceInstanceID) throws -> (ServiceInstanceRecord?, String) { try inspectBody(id) }
        func start(id: ServiceInstanceID) throws { try startBody(id) }
        func stop(id: ServiceInstanceID) throws { try stopBody(id) }
    }

    private enum Runtime {
        case singleton(SingletonRuntime)
        case isolated(IsolatedRuntime)

        func status(id: ServiceInstanceID) throws -> (ServiceInstanceRecord?, String) {
            switch self { case .singleton(let runtime): try runtime.status(id: id); case .isolated(let runtime): try runtime.status(id: id) }
        }
        func start(id: ServiceInstanceID) throws {
            switch self { case .singleton(let runtime): try runtime.start(id: id); case .isolated(let runtime): try runtime.start(id: id) }
        }
    }

    private let repository: ServiceInstanceRepository?
    private let mysql: MySQLModule?
    private let postgresql: PostgreSQLServiceModule?
    private let valkey: ValkeyServiceModule?
    private let mailpit: MailpitModule?

    public var isAvailable: Bool { repository != nil }

    public init(repository: ServiceInstanceRepository?, mysql: MySQLModule?, postgresql: PostgreSQLServiceModule?, valkey: ValkeyServiceModule?, mailpit: MailpitModule?) {
        self.repository = repository; self.mysql = mysql; self.postgresql = postgresql; self.valkey = valkey; self.mailpit = mailpit
    }

    public func snapshot(for kind: ProjectServiceKind) -> ModuleOwnedServiceSnapshot? {
        return switch kind {
        case .mysql: mysql?.projectBindingSnapshot()
        case .mailpit: mailpit?.projectBindingSnapshot()
        case .postgresql, .redis, .valkey: nil
        }
    }

    public func inventorySnapshot() throws -> ServiceInstanceInventorySnapshot {
        var entries = try repository?.inventorySnapshot().entries ?? []
        for kind in [ProjectServiceKind.mysql, .mailpit] {
            guard let record = snapshot(for: kind)?.record, !entries.contains(where: { $0.record.id == record.id }) else { continue }
            entries.append(.init(record: record, claims: []))
        }
        return .init(entries: entries.sorted { ($0.record.id.kind.rawValue, $0.record.id.name.value) < ($1.record.id.kind.rawValue, $1.record.id.name.value) })
    }

    public func record(for id: ServiceInstanceID) throws -> ServiceInstanceRecord? {
        try repository?.instance(id)
    }

    public func assessedHealth(for record: ServiceInstanceRecord) -> String {
        if (record.id.kind == .postgresql && postgresql == nil) || (record.id.kind == .valkey && valkey == nil) { return "catalog-only" }
        guard let alias = try? ProjectBindingAlias("inventory"),
              let binding = try? ProjectServiceBinding(alias: alias, kind: record.id.kind, instance: record.id.name, version: record.packageIdentifier),
              let kind = ProjectManagedServiceKind(binding: binding), kind.matches(binding, record: record),
              let runtime = runtime(for: binding), let status = try? runtime.status(id: record.id), status.0 == record else { return "identity-unverified" }
        return status.1
    }

    public func isEligible(record: ServiceInstanceRecord, health: String) -> Bool {
        if health == "catalog-only" {
            guard let binding = try? ProjectServiceBinding(alias: ProjectBindingAlias("inventory"), kind: record.id.kind, instance: record.id.name, version: record.packageIdentifier),
                  let kind = ProjectManagedServiceKind(binding: binding) else { return false }
            return kind.matches(binding, record: record)
        }
        guard health == "healthy" || health == "stopped" || (record.id.kind == .mailpit && health == "installed"),
              let binding = try? ProjectServiceBinding(alias: ProjectBindingAlias("inventory"), kind: record.id.kind, instance: record.id.name, version: record.packageIdentifier),
              let kind = ProjectManagedServiceKind(binding: binding) else { return false }
        return kind.matches(binding, record: record)
    }

    public func observation(_ binding: ProjectServiceBinding, projectID: ProjectID?) throws -> ProjectServiceBindingObservation {
        let id = ServiceInstanceID(kind: binding.kind, name: binding.instance)
        let persisted = try repository?.instance(id)
        let candidate = persisted ?? snapshot(for: binding.kind)?.record
        let health: String
        let claims: [ServiceInstanceClaim]
        if let candidate, let runtime = runtime(for: binding) {
            let current = try runtime.status(id: id)
            health = current.0 == candidate ? current.1 : "identity-unverified"
            claims = try repository?.claims(for: id) ?? []
        } else if candidate == nil {
            health = "missing"
            claims = []
        } else {
            health = "unsupported"
            claims = try repository?.claims(for: id) ?? []
        }
        return .init(binding: binding, packageIdentifier: candidate?.packageIdentifier, endpoint: candidate?.endpoint.loopbackEndpoints, dataDirectory: candidate?.dataDirectory, health: health, claimed: claims.contains(.project(projectID: projectID ?? ProjectID(rawValue: UUID()), binding: binding)), catalogPersisted: persisted != nil)
    }

    public func prepareActivation(projectID: ProjectID, desired: [ProjectServiceBinding], observations: [ProjectServiceBindingObservation]) throws {
        guard let repository else { throw SQLiteStateError.invalidRecord }
        var prospective = [ServiceInstanceID: ServiceInstanceRecord]()
        for binding in desired {
            guard let kind = ProjectManagedServiceKind(binding: binding), let runtime = runtime(for: binding),
                  let observation = observations.first(where: { $0.binding.alias == binding.alias }),
                  kind.matches(binding, observation: observation),
                  let record = try repository.instance(.init(kind: binding.kind, name: binding.instance)) ?? snapshot(for: binding.kind)?.record,
                  kind.matches(binding, record: record), binding.version == nil || binding.version == record.packageIdentifier,
                  observation.packageIdentifier == record.packageIdentifier, observation.endpoint == record.endpoint.loopbackEndpoints,
                  observation.dataDirectory == record.dataDirectory else { throw SQLiteStateError.invalidRecord }
            if binding.version == nil, try repository.instance(record.id) != record { throw SQLiteStateError.invalidRecord }
            let status = try runtime.status(id: record.id)
            guard status.0 == record, status.1 == observation.health,
                  status.1 == "healthy" || status.1 == "stopped" || (binding.kind == .mailpit && status.1 == "installed") else { throw SQLiteStateError.invalidRecord }
            if try repository.instance(record.id) == nil { prospective[record.id] = record }
        }
        let desiredIDs = Set(desired.map { ServiceInstanceID(kind: $0.kind, name: $0.instance) })
        let retired = try repository.projectClaims(for: projectID).filter { !desiredIDs.contains(.init(kind: $0.kind, name: $0.instance)) }
        for (id, claims) in Dictionary(grouping: retired, by: { ServiceInstanceID(kind: $0.kind, name: $0.instance) }) {
            guard let binding = claims.first, binding.kind == .postgresql || binding.kind == .valkey else { continue }
            let owners = try repository.claims(for: id).filter { if case .project(let owner, _) = $0 { return owner != projectID }; return true }
            guard owners.isEmpty else { continue }
            guard let kind = ProjectManagedServiceKind(binding: binding), claims.allSatisfy({ ProjectManagedServiceKind(binding: $0) == kind }),
                  let runtime = runtime(for: binding), let record = try repository.instance(id), kind.matches(binding, record: record) else { throw SQLiteStateError.invalidRecord }
            let current = try runtime.status(id: id)
            guard current.0 == record, current.1 == "healthy" || current.1 == "stopped" else { throw SQLiteStateError.invalidRecord }
            if current.1 == "healthy" { try stopIsolated(binding: binding, id: id) }
            let stopped = try runtime.status(id: id)
            guard stopped.0 == record, stopped.1 == "stopped" else { throw SQLiteStateError.invalidRecord }
        }
        try repository.replaceProjectClaims(desired, materializing: Array(prospective.values), for: projectID)
    }

    public func activate(_ binding: ProjectServiceBinding, projectID: ProjectID, record: ServiceInstanceRecord, action: ProjectReconciliationAction, expected: ProjectServiceBindingObservation) throws {
        guard let repository, let kind = ProjectManagedServiceKind(binding: binding), kind.matches(binding, record: record),
              let runtime = runtime(for: binding), kind.matches(binding, observation: expected),
              expected.packageIdentifier == record.packageIdentifier, expected.endpoint == record.endpoint.loopbackEndpoints,
              expected.dataDirectory == record.dataDirectory else { throw SQLiteStateError.invalidRecord }
        let current = try runtime.status(id: record.id)
        let priorClaims = try repository.claims(for: record.id)
        let alreadyStartedForThisProject = current.0 == record && current.1 == "healthy" && (expected.health == "stopped" || binding.kind == .mailpit && expected.health == "installed") && priorClaims.contains { claim in
            if case .project(let owner, let existing) = claim { return owner == projectID && existing.kind == binding.kind && existing.instance == binding.instance }
            return false
        }
        guard current.0 == record, current.1 == expected.health || alreadyStartedForThisProject,
              (action == .start && (current.1 == "healthy" || current.1 == "stopped" || binding.kind == .mailpit && current.1 == "installed" || alreadyStartedForThisProject)) || (action == .associate && current.1 == "healthy") else { throw SQLiteStateError.invalidRecord }
        try repository.addProjectClaim(binding, materializing: record, for: projectID)
        if action == .start && current.1 != "healthy" { try runtime.start(id: record.id) }
        let verified = try runtime.status(id: record.id)
        guard verified.0 == record, verified.1 == "healthy" else { throw SQLiteStateError.invalidRecord }
    }

    public func adopt(_ bindings: [ProjectServiceBinding], projectID: ProjectID) throws {
        guard let repository else { throw SQLiteStateError.invalidRecord }
        let inventory = try inventorySnapshot()
        let entries = Dictionary(uniqueKeysWithValues: inventory.entries.map { ($0.record.id, $0.record) })
        for binding in bindings {
            let id = ServiceInstanceID(kind: binding.kind, name: binding.instance)
            guard let record = entries[id], let kind = ProjectManagedServiceKind(binding: binding), kind.matches(binding, record: record),
                  binding.version == nil || binding.version == record.packageIdentifier,
                  isEligible(record: record, health: assessedHealth(for: record)) else { throw SQLiteStateError.invalidRecord }
            if binding.version == nil, try repository.instance(id) != record { throw SQLiteStateError.invalidRecord }
        }
        let prior = try repository.projectClaims(for: projectID)
        var byAlias = Dictionary(uniqueKeysWithValues: prior.map { ($0.alias.value, $0) })
        for binding in bindings { byAlias[binding.alias.value] = binding }
        let merged = byAlias.values.sorted { $0.alias.value < $1.alias.value }
        let records = try bindings.compactMap { binding -> ServiceInstanceRecord? in
            let id = ServiceInstanceID(kind: binding.kind, name: binding.instance)
            return try repository.instance(id) == nil ? entries[id] : nil
        }
        let uniqueRecords = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        try repository.replaceProjectClaims(merged, materializing: Array(uniqueRecords), for: projectID)
    }

    public func releaseProjectClaims(projectID: ProjectID) throws -> ProjectServiceReleaseSummary {
        guard let repository else { throw SQLiteStateError.invalidRecord }
        let bindings = try repository.projectClaims(for: projectID)
        let byInstance = Dictionary(grouping: bindings) { ServiceInstanceID(kind: $0.kind, name: $0.instance) }
        var operations = [ProjectReconciliationOperationResult]()
        var released = 0
        var failed = false
        for (id, grouped) in byInstance {
            guard let binding = grouped.first else { continue }
            let operationID = "service.\(grouped.map(\.alias.value).sorted().joined(separator: ",")).release"
            do {
                if id.kind != .postgresql && id.kind != .valkey {
                    try repository.removeProjectClaims(grouped, for: projectID)
                    released += grouped.count
                    let message = id.kind == .mysql || id.kind == .mailpit
                        ? "The singleton service claim was released and its runtime was left running."
                        : "The unsupported service claim was released without a runtime transition."
                    operations.append(.init(operationID: operationID, state: .succeeded, message: message, verified: true))
                    continue
                }
                let otherOwners = try repository.claims(for: id).filter { if case .project(let owner, _) = $0 { return owner != projectID }; return true }
                if !otherOwners.isEmpty {
                    try repository.removeProjectClaims(grouped, for: projectID)
                    released += grouped.count
                    operations.append(.init(operationID: operationID, state: .succeeded, message: "Another project or manual owner remains; the shared instance was left running.", verified: true))
                    continue
                }
                guard let kind = ProjectManagedServiceKind(binding: binding), grouped.allSatisfy({ ProjectManagedServiceKind(binding: $0) == kind }),
                      let runtime = runtime(for: binding), let record = try repository.instance(id), kind.matches(binding, record: record) else { throw SQLiteStateError.invalidRecord }
                let status = try runtime.status(id: id)
                guard status.0 == record, status.1 == "healthy" || status.1 == "stopped" else { throw SQLiteStateError.invalidRecord }
                if status.1 == "healthy" { try stopIsolated(binding: binding, id: id) }
                let stopped = try runtime.status(id: id)
                guard stopped.0 == record, stopped.1 == "stopped" else { throw SQLiteStateError.invalidRecord }
                try repository.removeProjectClaims(grouped, for: projectID)
                released += grouped.count
                operations.append(.init(operationID: operationID, state: .succeeded, message: "The exact \(binding.kind.rawValue) instance was stopped and verified before releasing the final project claim.", verified: true))
            } catch {
                failed = true
                operations.append(.init(operationID: operationID, state: .failed, message: "The \(binding.kind.rawValue) stop, verification, or claim release failed; the project claim was retained: \(error.localizedDescription)", verified: false))
            }
        }
        if operations.isEmpty { operations.append(.init(operationID: "project.down", state: .satisfied, message: "No project service claims remain.", verified: true)) }
        return .init(operations: operations, releasedBindingCount: released, failed: failed)
    }

    public func withNoProjectClaims<T>(for id: ServiceInstanceID, _ action: () throws -> T) throws -> T {
        guard let repository else { throw SQLiteStateError.invalidRecord }
        return try repository.withNoProjectClaims(for: id, action)
    }

    public func removeSingletonAfterSuccessfulAction<T>(for id: ServiceInstanceID, packageIdentifier: String, _ action: () throws -> T) throws -> T {
        guard let repository else { throw SQLiteStateError.invalidRecord }
        return try repository.removeSingletonAfterSuccessfulAction(id: id, packageIdentifier: packageIdentifier, action)
    }

    private func runtime(for binding: ProjectServiceBinding) -> Runtime? {
        guard let kind = ProjectManagedServiceKind(binding: binding) else { return nil }
        switch kind {
        case .mysql:
            guard let mysql else { return nil }
            return .singleton(SingletonRuntime(inspectBody: { _ in let value = mysql.projectBindingSnapshot(); return (value.record, value.health) }, startBody: { _ in _ = try mysql.start() }))
        case .mailpit:
            guard let mailpit else { return nil }
            return .singleton(SingletonRuntime(inspectBody: { _ in let value = mailpit.projectBindingSnapshot(); return (value.record, value.health) }, startBody: { _ in _ = try mailpit.start() }))
        case .postgresql:
            guard let postgresql else { return nil }
            return .isolated(IsolatedRuntime(inspectBody: { try postgresql.status(id: $0).recordAndHealth }, startBody: { try postgresql.start(id: $0) }, stopBody: { try postgresql.stop(id: $0) }))
        case .valkey:
            guard let valkey else { return nil }
            return .isolated(IsolatedRuntime(inspectBody: { try valkey.status(id: $0).recordAndHealth }, startBody: { try valkey.start(id: $0) }, stopBody: { try valkey.stop(id: $0) }))
        }
    }

    private func isolatedRuntime(for binding: ProjectServiceBinding) -> IsolatedRuntime? {
        guard case .isolated(let runtime)? = runtime(for: binding) else { return nil }
        return runtime
    }

    private func stopIsolated(binding: ProjectServiceBinding, id: ServiceInstanceID) throws {
        guard let runtime = isolatedRuntime(for: binding) else { throw SQLiteStateError.invalidRecord }
        try runtime.stop(id: id)
    }
}

private extension PostgreSQLServiceStatus {
    var recordAndHealth: (ServiceInstanceRecord?, String) { (record, health) }
}

private extension ValkeyServiceStatus {
    var recordAndHealth: (ServiceInstanceRecord?, String) { (record, health) }
}
