import Foundation

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
        appendPHP(report: report, to: &operations)
        appendMySQL(report: report, to: &operations)
        appendMailpit(report: report, to: &operations)
        appendWeb(report: report, to: &operations)
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
        guard report.desired.secureWeb == true else { return }
        if report.observed.route.associationState == .safelyAssociable {
            operations.append(.init(id: "route.project-association.attach", resource: .route, action: .associate, currentState: .mismatch, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: .actionable, reason: "A unique legacy route has corroborated project evidence; explicit route association is required before route mutation."))
        }
        if !report.routeTargets.isEmpty {
            for target in report.routeTargets.sorted(by: { $0.routeID.description < $1.routeID.description }) {
                let operationID = "route.php-target.update.\(target.routeID.description)"
                let dependencies = target.disposition == .deferred ? ["php.fpm.start"] : []
                operations.append(.init(id: operationID, resource: .route, action: .reconcile, currentState: target.disposition == .satisfied ? .satisfied : target.disposition == .actionable ? .mismatch : .unknown, targetState: .satisfied, ownership: .vaelen, mutationClass: .vaelenInfrastructure, disposition: target.disposition, reason: target.reason, dependencies: dependencies, preconditions: ["Durable ProjectID association", "Persisted and live Caddy route semantics agree", "Current and desired PHP targets are Vaelen-owned" ]))
            }
        } else if !report.observed.route.intentExists {
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
