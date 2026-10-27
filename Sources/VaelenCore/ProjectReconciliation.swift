import Foundation

private func canonicalProjectDocumentRoot(_ declaration: String, projectPath: String) -> String? {
    guard !declaration.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
    let root = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let candidate = root.appendingPathComponent(declaration.isEmpty ? "." : declaration, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = root.path
    guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
    return candidate.path
}

public enum ProjectReconciliationPlanState: String, Codable, Equatable, Sendable {
    case satisfied
    case actionable
    case blocked
}

public enum ProjectReconciliationExecutionState: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case partial
    case blocked
}

public enum ProjectReconciliationOperationResultState: String, Codable, Equatable, Sendable {
    case satisfied
    case succeeded
    case skipped
    case failed
    case blocked
    case pending
}

public enum ProjectReconciliationMutationClass: String, Codable, Equatable, Sendable {
    case observeOnly
    case vaelenInfrastructure
    case privilegedCapability
    case applicationMutation
    case developerDataMutation
    case externalConflict
}

public enum ProjectReconciliationDisposition: String, Codable, Equatable, Sendable {
    case satisfied
    case actionable
    case blocked
    case pending
    case authorizationRequired
    case deferred
    case unsupported
}

public enum ProjectReconciliationResource: String, Codable, Equatable, Sendable {
    case php
    case mysql
    case mailpit
    case route
    case dns
    case tls
    case standardPorts
    case applicationConfiguration
}

public enum ProjectReconciliationAction: String, Codable, Equatable, Sendable {
    case observe
    case start
    case install
    case initialize
    case reconcile
    case review
    case authorize
    case associate
}

public enum ProjectReconciliationOwnership: String, Codable, Equatable, Sendable {
    case vaelen
    case application
    case developer
    case external
    case privilegedCapability
}

public enum ProjectReconciliationResourceState: String, Codable, Equatable, Sendable {
    case satisfied
    case running
    case stopped
    case missing
    case unavailable
    case unhealthy
    case mismatch
    case conflict
    case invalid
    case unknown
}

public enum ProjectManagedServiceKind: Equatable, Sendable {
    case mysql
    case postgresql
    case valkey
    case mailpit

    public init?(binding: ProjectServiceBinding) {
        switch binding.kind {
        case .mysql where binding.version == nil || binding.version == "mysql-\(MySQLModule.defaultVersion)":
            guard binding.instance.value == "default" else { return nil }
            self = .mysql
        case .postgresql where binding.version == nil || binding.version == PostgreSQLServiceModule.packageIdentifier:
            self = .postgresql
        case .valkey where binding.version == ValkeyServiceModule.packageIdentifier:
            self = .valkey
        case .mailpit where binding.version == nil || binding.version == "mailpit-\(MailpitModule.defaultVersion)":
            guard binding.instance.value == "default" else { return nil }
            self = .mailpit
        default:
            return nil
        }
    }

    public var serviceKind: ProjectServiceKind {
        switch self {
        case .mysql: .mysql
        case .postgresql: .postgresql
        case .valkey: .valkey
        case .mailpit: .mailpit
        }
    }

    public var packageIdentifier: String {
        switch self {
        case .mysql: "mysql-\(MySQLModule.defaultVersion)"
        case .postgresql: PostgreSQLServiceModule.packageIdentifier
        case .valkey: ValkeyServiceModule.packageIdentifier
        case .mailpit: "mailpit-\(MailpitModule.defaultVersion)"
        }
    }

    public var endpointKey: String {
        switch self {
        case .mysql: "mysql"
        case .postgresql: "postgresql"
        case .valkey: "valkey"
        case .mailpit: "smtp"
        }
    }

    public func matches(_ binding: ProjectServiceBinding, observation: ProjectServiceBindingObservation) -> Bool {
        guard ProjectManagedServiceKind(binding: binding) == self,
              observation.binding == binding,
              observation.packageIdentifier == packageIdentifier,
              observation.endpoint?.count == endpointCount,
              isExactLoopbackEndpoint(observation.endpoint?[endpointKey]),
              (self != .mailpit || isExactLoopbackEndpoint(observation.endpoint?["smtp"]) && isExactLoopbackEndpoint(observation.endpoint?["http"])),
              observation.dataDirectory?.hasPrefix("/") == true else { return false }
        return true
    }

    public func matches(_ binding: ProjectServiceBinding, record: ServiceInstanceRecord) -> Bool {
        guard ProjectManagedServiceKind(binding: binding) == self,
              record.id == ServiceInstanceID(kind: serviceKind, name: binding.instance),
              record.packageIdentifier == packageIdentifier,
              record.endpoint.kind == serviceKind,
              record.endpoint.loopbackEndpoints.count == endpointCount,
              isExactLoopbackEndpoint(record.endpoint.loopbackEndpoints[endpointKey]),
              (self != .mailpit || isExactLoopbackEndpoint(record.endpoint.loopbackEndpoints["smtp"]) && isExactLoopbackEndpoint(record.endpoint.loopbackEndpoints["http"])),
              record.dataDirectory.hasPrefix("/") else { return false }
        return true
    }

    private func isExactLoopbackEndpoint(_ endpoint: String?) -> Bool {
        guard let endpoint, endpoint.hasPrefix("127.0.0.1:"),
              let port = Int(endpoint.dropFirst("127.0.0.1:".count)), (1...65535).contains(port) else { return false }
        return true
    }

    private var endpointCount: Int { self == .mailpit ? 2 : 1 }
}

public struct ProjectReconciliationOperation: Codable, Equatable, Sendable {
    public let id: String
    public let resource: ProjectReconciliationResource
    public let action: ProjectReconciliationAction
    public let currentState: ProjectReconciliationResourceState
    public let targetState: ProjectReconciliationResourceState
    public let ownership: ProjectReconciliationOwnership
    public let mutationClass: ProjectReconciliationMutationClass
    public let disposition: ProjectReconciliationDisposition
    public let reason: String?
    public let dependencies: [String]
    public let preconditions: [String]
    public let requiresPrivilege: Bool
    public let requiresNetwork: Bool
    public let destructive: Bool
    public let applicationMutation: Bool

    public init(id: String, resource: ProjectReconciliationResource, action: ProjectReconciliationAction, currentState: ProjectReconciliationResourceState, targetState: ProjectReconciliationResourceState, ownership: ProjectReconciliationOwnership, mutationClass: ProjectReconciliationMutationClass, disposition: ProjectReconciliationDisposition, reason: String? = nil, dependencies: [String] = [], preconditions: [String] = [], requiresPrivilege: Bool = false, requiresNetwork: Bool = false, destructive: Bool = false, applicationMutation: Bool = false) {
        self.id = id
        self.resource = resource
        self.action = action
        self.currentState = currentState
        self.targetState = targetState
        self.ownership = ownership
        self.mutationClass = mutationClass
        self.disposition = disposition
        self.reason = reason
        self.dependencies = dependencies
        self.preconditions = preconditions
        self.requiresPrivilege = requiresPrivilege
        self.requiresNetwork = requiresNetwork
        self.destructive = destructive
        self.applicationMutation = applicationMutation
    }
}

public struct ProjectReconciliationPlan: Codable, Equatable, Sendable {
    public let identity: ProjectEnvironmentIdentity
    public let desired: ProjectDesiredEnvironment
    public let observedAt: Date
    public let operations: [ProjectReconciliationOperation]
    public let state: ProjectReconciliationPlanState

    public init(identity: ProjectEnvironmentIdentity, desired: ProjectDesiredEnvironment, observedAt: Date, operations: [ProjectReconciliationOperation], state: ProjectReconciliationPlanState) {
        self.identity = identity
        self.desired = desired
        self.observedAt = observedAt
        self.operations = operations
        self.state = state
    }
}

public struct ProjectReconciliationOperationResult: Codable, Equatable, Sendable {
    public let operationID: String
    public let state: ProjectReconciliationOperationResultState
    public let message: String
    public let verified: Bool

    public init(operationID: String, state: ProjectReconciliationOperationResultState, message: String, verified: Bool) {
        self.operationID = operationID
        self.state = state
        self.message = message
        self.verified = verified
    }
}

public struct ProjectReconciliationExecutionResult: Codable, Equatable, Sendable {
    public let initialPlan: ProjectReconciliationPlan
    public let operations: [ProjectReconciliationOperationResult]
    public let finalPlan: ProjectReconciliationPlan
    public let state: ProjectReconciliationExecutionState

    public init(initialPlan: ProjectReconciliationPlan, operations: [ProjectReconciliationOperationResult], finalPlan: ProjectReconciliationPlan, state: ProjectReconciliationExecutionState) {
        self.initialPlan = initialPlan
        self.operations = operations
        self.finalPlan = finalPlan
        self.state = state
    }
}

public struct ProjectReconciliationPlanner: Sendable {
    public init() {}

    public func plan(report: ProjectEnvironmentReport, observedAt: Date = Date()) -> ProjectReconciliationPlan {
        var operations = [ProjectReconciliationOperation]()
        if let requirement = report.projectSpec?.php {
            let exactVersion = PHPVersion(requirement.value)
            let desiredFamily = exactVersion?.family ?? PHPFamily(requirement.value)?.description
            let matchesRequirement: (String?) -> Bool = { resolved in
                guard let resolved else { return false }
                if let exactVersion { return PHPVersion(resolved) == exactVersion }
                return PHPVersion(resolved)?.family == desiredFamily
            }
            let available = requirement.resolveInstalledVersion(from: report.observed.php.installedVersions) != nil
            if !available || !matchesRequirement(report.observed.php.resolvedVersion) {
                operations.append(.init(id: "requirement.php.select", resource: .php, action: available ? .associate : .review, currentState: available ? .mismatch : .unavailable, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: available ? .actionable : .blocked, reason: available ? "Select the exact installed PHP version declared by the project." : "The exact PHP version \(requirement.value) is not installed as an eligible managed runtime."))
            }
        }
        appendPHP(report: report, to: &operations)
        appendMySQL(report: report, to: &operations)
        appendMailpit(report: report, to: &operations)
        appendWeb(report: report, to: &operations)
        appendUnsupportedV2Requirements(report: report, to: &operations)
        appendEndpointBlockers(report: report, to: &operations)
        let state: ProjectReconciliationPlanState
        if operations.contains(where: { [.blocked, .authorizationRequired, .deferred, .unsupported, .pending].contains($0.disposition) }) {
            state = .blocked
        } else if operations.contains(where: { $0.disposition == .actionable }) {
            state = .actionable
        } else {
            state = .satisfied
        }
        return .init(identity: report.identity, desired: report.desired, observedAt: observedAt, operations: operations, state: state)
    }

    private func appendUnsupportedV2Requirements(report: ProjectEnvironmentReport, to operations: inout [ProjectReconciliationOperation]) {
        guard let spec = report.projectSpec, spec.version == 2 else { return }
        let declarations = [spec.node.map { ("Node", $0.value) }].compactMap { $0 }
        for (runtime, requirement) in declarations {
            if runtime == "Node", requirement.range(of: "^[0-9]+(?:\\.[0-9]+\\.[0-9]+)?$", options: .regularExpression) != nil {
                let state = report.nodeRequirementState
                let disposition: ProjectReconciliationDisposition = state == "selected" ? .satisfied : state == "available" ? .actionable : .blocked
                operations.append(.init(id: "requirement.node", resource: .applicationConfiguration, action: state == "available" ? .associate : .observe, currentState: state == "selected" ? .satisfied : state == "available" ? .stopped : .unavailable, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: disposition, reason: state == "selected" ? nil : state == "available" ? "Select exact installed Node \(report.nodeRequirementVersion ?? requirement) for this project." : "No eligible installed Node package satisfies requirement \(requirement)."))
            } else {
                operations.append(.init(id: "requirement.\(runtime.lowercased())", resource: .applicationConfiguration, action: .observe, currentState: .unknown, targetState: .satisfied, ownership: .developer, mutationClass: .observeOnly, disposition: .unsupported, reason: "The project requires \(runtime) \(requirement), but the declaration is not an exact verifiable selector."))
            }
        }
        if let web = spec.web {
            let fields = [("host", web.host.map { "host \($0)" }), ("document-root", web.documentRoot.map { "document root \($0.isEmpty ? "<project root>" : $0)" })]
            for (id, field) in fields {
                guard let field else { continue }
                let expectedRoot = URL(fileURLWithPath: report.identity.path, isDirectory: true).appendingPathComponent(web.documentRoot ?? ".").standardizedFileURL.resolvingSymlinksInPath().path
                let matches = report.routeTargets.filter { target in
                    (web.host == nil || target.hostname.lowercased() == web.host?.lowercased()) && (web.documentRoot == nil || target.persistedDocumentRoot == expectedRoot)
                }
                let selectedRoute = report.observed.route
                let singleObservedMatch = report.routeTargets.isEmpty && selectedRoute.intentExists && selectedRoute.associatedRouteCount == 1
                    && (web.host == nil || selectedRoute.hostname?.lowercased() == web.host?.lowercased())
                    && (web.documentRoot == nil || selectedRoute.documentRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path == expectedRoot } == true)
                let satisfied = singleObservedMatch || (!report.routeTargets.isEmpty && matches.count == report.routeTargets.count)
                operations.append(.init(id: "requirement.web.\(id)", resource: .route, action: .observe, currentState: satisfied ? .satisfied : .mismatch, targetState: .satisfied, ownership: .vaelen, mutationClass: .observeOnly, disposition: satisfied ? .satisfied : .blocked, reason: satisfied ? nil : "The declared web \(field) does not match every durable project route."))
            }
        }
        for binding in spec.services {
            let id = "service.\(binding.alias.value)"
            guard let managedKind = ProjectManagedServiceKind(binding: binding),
                  let observation = report.serviceBindings?.first(where: { $0.binding.alias == binding.alias }) else {
                operations.append(.init(id: id, resource: .applicationConfiguration, action: .observe, currentState: .unknown, targetState: .running, ownership: .developer, mutationClass: .observeOnly, disposition: .unsupported, reason: "Service \(binding.alias.value) of kind \(binding.kind.rawValue) and version \(binding.version ?? "unspecified") requires an unsupported service type, version, or unavailable exact catalog observation."))
                continue
            }
            guard managedKind.matches(binding, observation: observation) else {
                operations.append(.init(id: id, resource: .applicationConfiguration, action: .observe, currentState: .mismatch, targetState: .running, ownership: .developer, mutationClass: .observeOnly, disposition: .blocked, reason: "The \(binding.kind.rawValue) service catalog record does not match the exact manifest binding and supported package."))
                continue
            }
            if binding.version == nil && observation.catalogPersisted != true {
                operations.append(.init(id: id, resource: .applicationConfiguration, action: .review, currentState: .unknown, targetState: .running, ownership: .developer, mutationClass: .observeOnly, disposition: .blocked, reason: "An omitted service version requires an exact identity already persisted in the local catalog; this prospective package identity is not yet selectable."))
                continue
            }
            if observation.health == "healthy", observation.claimed {
                operations.append(satisfied(id: id, resource: .applicationConfiguration, state: .running, ownership: .vaelen))
            } else if observation.health == "stopped", observation.claimed {
                operations.append(.init(id: id, resource: .applicationConfiguration, action: .start, currentState: .stopped, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .actionable, reason: "The exact claimed \(binding.kind.rawValue) instance is stopped."))
            } else if observation.health == "healthy" {
                operations.append(.init(id: id, resource: .applicationConfiguration, action: .associate, currentState: .running, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .actionable, reason: "Restore this project's claim on the exact healthy \(binding.kind.rawValue) instance."))
            } else if observation.health == "stopped" {
                operations.append(.init(id: id, resource: .applicationConfiguration, action: .start, currentState: .stopped, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .actionable, reason: "Claim and start the exact stopped \(binding.kind.rawValue) instance."))
            } else if binding.kind == .mailpit && observation.health == "installed" {
                operations.append(.init(id: id, resource: .applicationConfiguration, action: .start, currentState: .missing, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .actionable, reason: "Start the exact installed Mailpit singleton and create its default message store."))
            } else {
                operations.append(.init(id: id, resource: .applicationConfiguration, action: .review, currentState: observation.health == "identity-unverified" ? .mismatch : .unhealthy, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "The exact \(binding.kind.rawValue) instance is not healthy and identity-verified (health: \(observation.health))."))
            }
        }
    }

    private func appendPHP(report: ProjectEnvironmentReport, to operations: inout [ProjectReconciliationOperation]) {
        guard let desired = report.observed.php.resolvedVersion ?? report.desired.php else { return }
        if report.observed.php.resolutionState == .unavailable {
            operations.append(.init(id: "php.fpm.start", resource: .php, action: .start, currentState: .unavailable, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "PHP_FAMILY_UNAVAILABLE: desired family \(desired) has no eligible installed PHP package; installation is not performed by project activation."))
            return
        }
        if report.observed.php.resolutionState == .invalid {
            operations.append(.init(id: "php.fpm.start", resource: .php, action: .start, currentState: .invalid, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "The desired PHP family has installed package material, but no package passed eligibility validation."))
            return
        }
        if report.observed.php.resolutionState != .resolved {
            operations.append(.init(id: "php.fpm.start", resource: .php, action: .start, currentState: .unknown, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "The desired PHP family could not be resolved safely."))
        } else if report.observed.php.resolvedState == PHPFPMState.running.rawValue && report.observed.php.fpmHealth == "healthy" {
            operations.append(satisfied(id: "php.fpm.start", resource: .php, state: .running, ownership: .vaelen))
        } else if report.observed.php.resolvedState == PHPFPMState.stopped.rawValue || report.observed.php.fpmHealth == "stopped" || report.observed.php.fpmHealth == "not-running" {
            operations.append(.init(id: "php.fpm.start", resource: .php, action: .start, currentState: .stopped, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .actionable, reason: "The eligible Vaelen PHP-FPM runtime \(report.observed.php.resolvedVersion ?? desired) is stopped.", preconditions: ["PHP family resolves to an eligible exact package", "FPM executable belongs to that package", "No process or socket ownership conflict exists", "FPM socket is verified after start"]))
        } else {
            operations.append(.init(id: "php.fpm.start", resource: .php, action: .start, currentState: .unhealthy, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "The eligible PHP-FPM runtime is not healthy or safely startable."))
        }
    }

    private func appendMySQL(report: ProjectEnvironmentReport, to operations: inout [ProjectReconciliationOperation]) {
        guard report.desired.mysql == true else { return }
        guard let mysql = report.observed.mysql else {
            operations.append(.init(id: "mysql.start", resource: .mysql, action: .start, currentState: .missing, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "Vaelen MySQL observation is unavailable."))
            return
        }
        switch mysql.state {
        case .running where mysql.health == "healthy": operations.append(satisfied(id: "mysql.start", resource: .mysql, state: .running, ownership: .vaelen))
        case .stopped: operations.append(.init(id: "mysql.start", resource: .mysql, action: .start, currentState: .stopped, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .deferred, reason: "MySQL start is deferred in M8 Slice 1."))
        case .notInstalled, .installed: operations.append(.init(id: "mysql.install", resource: .mysql, action: .install, currentState: .missing, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .deferred, reason: "MySQL package or initialized instance is unavailable; installation and initialization are deferred."))
        case .conflict: operations.append(.init(id: "mysql.start", resource: .mysql, action: .start, currentState: .conflict, targetState: .running, ownership: .external, mutationClass: .externalConflict, disposition: .blocked, reason: "An external process conflicts with the Vaelen MySQL endpoint; Vaelen will not kill or adopt it."))
        default: operations.append(.init(id: "mysql.start", resource: .mysql, action: .start, currentState: .unhealthy, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "Vaelen MySQL is not healthy enough for project activation."))
        }
    }

    private func appendMailpit(report: ProjectEnvironmentReport, to operations: inout [ProjectReconciliationOperation]) {
        guard report.desired.mailpit == true else { return }
        guard let mailpit = report.observed.mailpit else {
            operations.append(.init(id: "mailpit.start", resource: .mailpit, action: .start, currentState: .missing, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .deferred, reason: "Mailpit observation is unavailable."))
            return
        }
        switch mailpit.state {
        case .running where mailpit.health == "healthy": operations.append(satisfied(id: "mailpit.start", resource: .mailpit, state: .running, ownership: .vaelen))
        case .stopped: operations.append(.init(id: "mailpit.start", resource: .mailpit, action: .start, currentState: .stopped, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .actionable, reason: "The installed Vaelen Mailpit default instance is stopped.", preconditions: ["Mailpit package is installed", "Mailpit default instance exists", "SMTP and UI ports are available", "Process identity is owned by Vaelen"]))
        case .notInstalled: operations.append(.init(id: "mailpit.install", resource: .mailpit, action: .install, currentState: .missing, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .deferred, reason: "Mailpit package installation is deferred in M8 Slice 1.", requiresNetwork: true))
        case .installed: operations.append(.init(id: "mailpit.initialize", resource: .mailpit, action: .initialize, currentState: .missing, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .deferred, reason: "Mailpit default instance initialization is deferred in M8 Slice 1."))
        case .conflict: operations.append(.init(id: "mailpit.start", resource: .mailpit, action: .start, currentState: .conflict, targetState: .running, ownership: .external, mutationClass: .externalConflict, disposition: .blocked, reason: "An external process conflicts with the Vaelen Mailpit endpoint; Vaelen will not kill or adopt it."))
        default: operations.append(.init(id: "mailpit.start", resource: .mailpit, action: .start, currentState: .unhealthy, targetState: .running, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "Mailpit process identity or readiness is not verified."))
        }
    }

    private func appendWeb(report: ProjectEnvironmentReport, to operations: inout [ProjectReconciliationOperation]) {
        if report.routeTargets.count == 1, let spec = report.projectSpec, spec.version == 2,
           let web = spec.web, web.createRoute, let host = web.host, let root = web.documentRoot, let secure = web.secure,
           let target = report.routeTargets.first,
           target.hostname.lowercased() == host.lowercased(),
           target.persistedDocumentRoot == canonicalProjectDocumentRoot(root, projectPath: report.identity.path),
           target.persistedTLS == (secure ? .local : .disabled),
           target.associationAuthority == .allowed,
           target.providerAgreement == .missing,
           report.derived.routeDocumentRootMatches == true,
           report.observed.route.routerState == .running, report.observed.route.routerHealth == .healthy,
           host.lowercased().hasSuffix(".test"), report.observed.dns.health == "healthy",
           report.observed.standardPorts.state == .healthy,
           !secure || (report.observed.tls.state == .trusted && report.observed.tls.trustObserved) {
            operations.append(.init(id: "route.create", resource: .route, action: .reconcile, currentState: .mismatch, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .actionable, reason: "Retry reconciliation of the same explicitly reviewed and durably owned project route."))
        }
        if report.routeTargets.isEmpty, let spec = report.projectSpec, spec.version == 2, let web = spec.web {
            if report.observed.route.intentExists {
                operations.append(.init(id: "route.reconcile", resource: .route, action: .reconcile, currentState: .mismatch, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "A route already exists for this project but is not durably associated; resolve its ownership before creating or changing a route."))
            } else if web.host == nil || web.documentRoot == nil || web.secure == nil {
                operations.append(.init(id: "route.create", resource: .route, action: .review, currentState: .missing, targetState: .satisfied, ownership: .developer, mutationClass: .observeOnly, disposition: .blocked, reason: "Route creation requires explicit web.host, web.documentRoot, and web.secure values; Vaelen will not invent a hostname or document root."))
            } else if !web.createRoute {
                operations.append(.init(id: "route.create", resource: .route, action: .review, currentState: .missing, targetState: .satisfied, ownership: .developer, mutationClass: .observeOnly, disposition: .blocked, reason: "The declaration does not record explicit route creation review; rerun adoption with --create-route."))
            } else if let host = web.host, let root = web.documentRoot, let secure = web.secure {
                let capabilityBlocker: String? = {
                    guard report.observed.route.routerState == .running, report.observed.route.routerHealth == .healthy else { return "The router must be healthy before a project route can be created." }
                    guard host.lowercased().hasSuffix(".test") else { return "Local project routes support only the local .test host namespace." }
                    guard canonicalProjectDocumentRoot(root, projectPath: report.identity.path) != nil else { return "The declared document root must resolve to a directory inside the linked project." }
                    guard report.observed.dns.health == "healthy" else { return "Local project routes require healthy DNS; route creation is blocked until DNS is available." }
                    guard report.observed.standardPorts.state == .healthy else { return "Local project routes require healthy standard ports; route creation is blocked." }
                    guard secure else { return nil }
                    guard report.observed.tls.state == .trusted, report.observed.tls.trustObserved else { return "Local HTTPS requires an existing trusted Local CA; route creation will not change trust." }
                    return nil
                }()
                operations.append(.init(id: "route.create", resource: .route, action: capabilityBlocker == nil ? .reconcile : .review, currentState: .missing, targetState: .satisfied, ownership: capabilityBlocker == nil ? .vaelen : .privilegedCapability, mutationClass: capabilityBlocker == nil ? .vaelenInfrastructure : .observeOnly, disposition: capabilityBlocker == nil ? .actionable : .blocked, reason: capabilityBlocker ?? "Create the explicitly declared project route for \(host), rooted at \(root.isEmpty ? "." : root), with \(secure ? "local HTTPS" : "HTTP").", dependencies: ["php.fpm.start"], preconditions: ["Host is available", "Document root resolves within the linked project", "PHP-FPM socket is healthy", "Required local capabilities are healthy"]))
            } else {
                operations.append(.init(id: "route.create", resource: .route, action: .review, currentState: .missing, targetState: .satisfied, ownership: .developer, mutationClass: .observeOnly, disposition: .blocked, reason: "Route creation requires explicit web.host, web.documentRoot, and web.secure values; Vaelen will not invent a hostname or document root."))
            }
        }
        if !report.routeTargets.isEmpty {
            for target in report.routeTargets.sorted(by: { $0.routeID.description < $1.routeID.description }) {
                let operationID = "route.php-target.update.\(target.routeID.description)"
                let dependencies = target.disposition == .deferred ? ["php.fpm.start"] : []
                operations.append(.init(id: operationID, resource: .route, action: .reconcile, currentState: target.disposition == .satisfied ? .satisfied : target.disposition == .actionable ? .mismatch : .unknown, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: target.disposition, reason: target.reason, dependencies: dependencies, preconditions: ["Durable ProjectID association", "Persisted and live Caddy route semantics agree", "Current and desired PHP targets are Vaelen-owned" ]))
            }
        }

        if report.observed.route.associationState == .safelyAssociable {
            operations.append(.init(id: "route.project-association.attach", resource: .route, action: .associate, currentState: .mismatch, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .actionable, reason: "A unique legacy route has corroborated project evidence; attach durable project ownership before checking web declarations."))
        }

        guard report.desired.secureWeb == true else { return }
        let selectedRouteMatch: Bool? = {
            guard report.observed.route.intentExists, let tls = report.observed.route.tls else { return nil }
            if tls == .disabled { return false }
            if report.observed.route.runtimeRouteObserved == false { return false }
            return report.observed.route.runtimeRouteObserved == true ? true : nil
        }()
        let targetRouteMatches = report.routeTargets.map { target -> Bool? in
            if target.persistedTLS == .disabled || target.observedTLS == .disabled { return false }
            guard target.persistedTLS == .local, target.observedTLS == .local else { return nil }
            return true
        }
        let secureRoutesMatch: Bool?
        let routeCount = report.observed.route.associatedRouteCount
        let completeFastCGICoverage = routeCount.map { count in
            count > 1 && report.routeTargets.count == count && Set(report.routeTargets.map(\.routeID)).count == count
                && report.identity.id.map { projectID in report.routeTargets.allSatisfy { $0.projectID == projectID.rawValue } } == true
        } ?? false
        if selectedRouteMatch == false || targetRouteMatches.contains(false) {
            secureRoutesMatch = false
        } else if routeCount == 1, selectedRouteMatch == true,
                  targetRouteMatches.allSatisfy({ $0 == true }) {
            secureRoutesMatch = true
        } else if completeFastCGICoverage,
                  targetRouteMatches.allSatisfy({ $0 == true }) {
            secureRoutesMatch = true
        } else {
            secureRoutesMatch = nil
        }
        if secureRoutesMatch == true {
            operations.append(satisfied(id: "route.secure", resource: .route, state: .satisfied, ownership: .vaelen))
        } else {
            let reason = secureRoutesMatch == false
                ? "The project requires HTTPS, but at least one relevant route is not configured and observed with local TLS; Vaelen will not mutate or downgrade routes."
                : "The project requires HTTPS, but route TLS could not be proven from complete persisted and live route observations."
            operations.append(.init(id: "route.secure", resource: .route, action: .review, currentState: secureRoutesMatch == false ? .mismatch : .unknown, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: reason))
        }
        if report.routeTargets.isEmpty, report.projectSpec?.version != 2 || report.projectSpec?.web == nil {
            if !report.observed.route.intentExists {
                operations.append(.init(id: "route.reconcile", resource: .route, action: .reconcile, currentState: .missing, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .deferred, reason: "Route creation is deferred; M8 Slice 1 does not invent a hostname or mutate route_intents."))
            } else if report.derived.routeDocumentRootMatches == false {
                operations.append(.init(id: "route.reconcile", resource: .route, action: .reconcile, currentState: .mismatch, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "The existing route document root does not match the framework-derived document root."))
            } else if report.derived.routeTargetMatchesPHP == false {
                operations.append(.init(id: "route.reconcile", resource: .route, action: .reconcile, currentState: .mismatch, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .blocked, reason: "The existing route targets a different PHP socket; M9 observes this mismatch but does not mutate routes."))
            } else if report.observed.route.routerState == .running && report.observed.route.routerHealth == .healthy {
                operations.append(satisfied(id: "route.reconcile", resource: .route, state: .satisfied, ownership: .vaelen))
            } else {
                operations.append(.init(id: "route.reconcile", resource: .route, action: .reconcile, currentState: .unhealthy, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .deferred, reason: "Router reconciliation is deferred in M8 Slice 1."))
            }
        }
        appendCapability(id: "dns.install", resource: .dns, healthy: report.observed.dns.health == "healthy", ownership: report.observed.dns.ownership == .vaelen ? .vaelen : .external, externalConflict: report.observed.dns.ownership == .external || report.observed.dns.state == .conflict, reason: "DNS installation or takeover requires explicit authorization.", operations: &operations)
        appendCapability(id: "tls.install", resource: .tls, healthy: report.observed.tls.trustObserved, ownership: .privilegedCapability, externalConflict: report.observed.tls.state == .ownershipMismatch, reason: "TLS trust mutation requires explicit authorization.", operations: &operations)
        appendCapability(id: "ports.install", resource: .standardPorts, healthy: report.observed.standardPorts.state.rawValue == "healthy", ownership: .privilegedCapability, externalConflict: ["conflict", "ownershipMismatch"].contains(report.observed.standardPorts.state.rawValue), reason: "Standard Ports mutation requires explicit authorization.", operations: &operations)
    }

    private func appendCapability(id: String, resource: ProjectReconciliationResource, healthy: Bool, ownership: ProjectReconciliationOwnership, externalConflict: Bool, reason: String, operations: inout [ProjectReconciliationOperation]) {
        if healthy { operations.append(satisfied(id: id, resource: resource, state: .satisfied, ownership: ownership)) }
        else if externalConflict { operations.append(.init(id: id, resource: resource, action: .authorize, currentState: .conflict, targetState: .satisfied, ownership: .external, mutationClass: .externalConflict, disposition: .blocked, reason: "An external capability conflict prevents reconciliation; Vaelen will not kill or adopt the owner.")) }
        else { operations.append(.init(id: id, resource: resource, action: .authorize, currentState: .unavailable, targetState: .satisfied, ownership: ownership, mutationClass: .privilegedCapability, disposition: .authorizationRequired, reason: reason, requiresPrivilege: true)) }
    }

    private func appendEndpointBlockers(report: ProjectEnvironmentReport, to operations: inout [ProjectReconciliationOperation]) {
        if report.derived.dbEndpoint.matches == false {
            operations.append(.init(id: "application.db-endpoint", resource: .applicationConfiguration, action: .review, currentState: .mismatch, targetState: .satisfied, ownership: .application, mutationClass: .applicationMutation, disposition: .blocked, reason: endpointReason(name: "database", configuredHost: report.derived.dbEndpoint.configuredHost, configuredPort: report.derived.dbEndpoint.configuredPort, expectedHost: report.derived.dbEndpoint.expectedHost, expectedPort: report.derived.dbEndpoint.expectedPort)))
        }
        if report.derived.mailEndpoint.matches == false {
            operations.append(.init(id: "application.mail-endpoint", resource: .applicationConfiguration, action: .review, currentState: .mismatch, targetState: .satisfied, ownership: .application, mutationClass: .applicationMutation, disposition: .blocked, reason: endpointReason(name: "SMTP mail", configuredHost: report.derived.mailEndpoint.configuredHost, configuredPort: report.derived.mailEndpoint.configuredPort, expectedHost: report.derived.mailEndpoint.expectedHost, expectedPort: report.derived.mailEndpoint.expectedPort)))
        }
    }

    private func endpointReason(name: String, configuredHost: String?, configuredPort: String?, expectedHost: String?, expectedPort: Int?) -> String {
        "The application \(name) endpoint (\(configuredHost ?? "unknown"): \(configuredPort ?? "unknown")) does not match the observed Vaelen endpoint (\(expectedHost ?? "unknown"): \(expectedPort.map(String.init) ?? "unknown")). This is application-owned configuration; Vaelen will not edit it. Effective application connectivity was not tested."
            .replacingOccurrences(of: ": ", with: ":")
    }

    private func satisfied(id: String, resource: ProjectReconciliationResource, state: ProjectReconciliationResourceState, ownership: ProjectReconciliationOwnership) -> ProjectReconciliationOperation {
        .init(id: id, resource: resource, action: .observe, currentState: state, targetState: .satisfied, ownership: ownership, mutationClass: .observeOnly, disposition: .satisfied)
    }
}
