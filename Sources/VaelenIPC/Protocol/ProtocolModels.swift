import Foundation
import VaelenCore

public enum ProtocolVersion: Int, Codable, Sendable {
    case v1 = 1
}

public enum IPCCompatibility {
    // Increment when an existing client/Core pair can no longer share command models or semantics.
    public static let schemaVersion = 5
}

public struct ClientIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let schemaCompatibilityVersion: Int?
    public let buildIdentity: String?
    public init(name: String, version: String, schemaCompatibilityVersion: Int? = nil, buildIdentity: String? = nil) {
        self.name = name; self.version = version; self.schemaCompatibilityVersion = schemaCompatibilityVersion; self.buildIdentity = buildIdentity
    }
}

public struct HandshakeParams: Codable, Equatable, Sendable {
    public let client: ClientIdentity
    public init(client: ClientIdentity) { self.client = client }
}

public struct HandshakeResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let coreVersion: String
    public let schemaCompatibilityVersion: Int?
    public let buildIdentity: String?
    public init(protocolVersion: Int, coreVersion: String, schemaCompatibilityVersion: Int? = nil, buildIdentity: String? = nil) {
        self.protocolVersion = protocolVersion; self.coreVersion = coreVersion; self.schemaCompatibilityVersion = schemaCompatibilityVersion; self.buildIdentity = buildIdentity
    }
}

public struct CoreStatusResponse: Codable, Equatable, Sendable {
    public let core: CoreRuntimeStatus
    public let protocolVersion: Int
    public let serviceIssues: [String: String]?
    public let serviceIntents: Set<String>?
    public init(core: CoreRuntimeStatus, protocolVersion: Int, serviceIssues: [String: String]? = nil, serviceIntents: Set<String>? = nil) { self.core = core; self.protocolVersion = protocolVersion; self.serviceIssues = serviceIssues; self.serviceIntents = serviceIntents }
}

public struct CoreShutdownComponentResult: Codable, Equatable, Sendable {
    public let component: String
    public let succeeded: Bool
    public let detail: String
    public init(component: String, succeeded: Bool, detail: String) { self.component = component; self.succeeded = succeeded; self.detail = detail }
}

public struct CoreShutdownResponse: Codable, Equatable, Sendable {
    public let completed: Bool
    public let components: [CoreShutdownComponentResult]
    public init(components: [CoreShutdownComponentResult]) { self.components = components; self.completed = components.allSatisfy(\.succeeded) }
}

public enum CoreMethod: String, Sendable {
    case handshake = "core.handshake"
    case status = "core.status"
    case shutdown = "core.shutdown"
    case projectLink = "project.link"
    case projectUnlink = "project.unlink"
    case projectLinks = "project.links"
    case projectList = "project.list"
    case projectStatus = "project.status"
    case projectInspect = "project.inspect"
    case projectDoctor = "project.doctor"
    case projectPlan = "project.plan"
    case projectActivate = "project.activate"
    case projectPHP = "project.php"
    case pathPark = "path.park"
    case pathUnpark = "path.unpark"
    case pathList = "path.list"
    case phpVersions = "php.versions"
    case phpCatalog = "php.catalog"
    case phpInstall = "php.install"
    case phpUpdate = "php.update"
    case phpRemove = "php.remove"
    case phpOperation = "php.operation"
    case phpDefaultSet = "php.default.set"
    case phpUse = "php.use"
    case phpExec = "php.exec"
    case phpResolve = "php.resolve"
    case phpStart = "php.start"
    case phpStop = "php.stop"
    case phpStatus = "php.status"
    case mysqlVersions = "mysql.versions"
    case mysqlInstall = "mysql.install"
    case mysqlUse = "mysql.use"
    case mysqlInitialize = "mysql.initialize"
    case mysqlStart = "mysql.start"
    case mysqlStop = "mysql.stop"
    case mysqlStatus = "mysql.status"
    case mailpitVersions = "mailpit.versions"
    case mailpitInstall = "mailpit.install"
    case mailpitStart = "mailpit.start"
    case mailpitStop = "mailpit.stop"
    case mailpitStatus = "mailpit.status"
    case routingStatus = "routing.status"
    case routingStart = "routing.start"
    case routingStop = "routing.stop"
    case routeList = "route.list"
    case routeObservedList = "route.observedList"
    case routeAdd = "route.add"
    case routeRemove = "route.remove"
    case routeProjectAssociationAttach = "route.project-association.attach"
    case routePHPTargetUpdate = "route.php-target.update"
    case dnsStatus = "dns.status"
    case dnsInstall = "dns.install"
    case dnsRemove = "dns.remove"
    case tlsStatus = "tls.status"
    case tlsInstall = "tls.install"
    case tlsRemove = "tls.remove"
    case tlsTrustLocalCA = "tls.trustLocalCA"
    case tlsRemoveLocalCATrust = "tls.removeLocalCATrust"
    case portsStatus = "ports.status"
    case portsInstall = "ports.install"
    case portsRemove = "ports.remove"
}

public enum RequestParams: Codable, Equatable, Sendable {
    case handshake(HandshakeParams)
    case link(LinkProjectRequest)
    case unlink(UnlinkProjectRequest)
    case listProjects(ListProjectsRequest)
    case projectEnvironment(ProjectEnvironmentRequest)
    case projectPHP(ProjectPHPRequest)
    case park(ParkPathRequest)
    case unpark(UnparkPathRequest)
    case phpVersion(PHPVersionRequest)
    case phpExec(PHPExecRequest)
    case phpResolve(PHPResolveRequest)
    case route(RouteIntent)
    case routeRemove(RouteRemoveRequest)
    case routeAssociation(RouteProjectAssociationRequest)
    case routePHPTargetUpdate(RoutePHPTargetUpdateRequest)
    case dnsInstall(DNSInstallRequest)
    case empty
    case raw(JSONValue)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .handshake(let value): try value.encode(to: encoder)
        case .link(let value): try value.encode(to: encoder)
        case .unlink(let value): try value.encode(to: encoder)
        case .listProjects(let value): try value.encode(to: encoder)
        case .projectEnvironment(let value): try value.encode(to: encoder)
        case .projectPHP(let value): try value.encode(to: encoder)
        case .park(let value): try value.encode(to: encoder)
        case .unpark(let value): try value.encode(to: encoder)
        case .phpVersion(let value): try value.encode(to: encoder)
        case .phpExec(let value): try value.encode(to: encoder)
        case .phpResolve(let value): try value.encode(to: encoder)
        case .route(let value): try value.encode(to: encoder)
        case .routeRemove(let value): try value.encode(to: encoder)
        case .routeAssociation(let value): try value.encode(to: encoder)
        case .routePHPTargetUpdate(let value): try value.encode(to: encoder)
        case .dnsInstall(let value): try value.encode(to: encoder)
        case .empty: try EmptyParams().encode(to: encoder)
        case .raw(let value): try value.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        if case .object(let fields) = value {
            if fields["client"] != nil, let params = try? IPCCodec.decode(HandshakeParams.self, from: IPCCodec.encode(value)) {
                self = .handshake(params); return
            }
            if fields["version"] != nil, fields.count == 1, let params = try? IPCCodec.decode(PHPVersionRequest.self, from: IPCCodec.encode(value)) {
                self = .phpVersion(params); return
            }
            if fields["workingDirectory"] != nil, fields["selector"] != nil, let params = try? IPCCodec.decode(ProjectPHPRequest.self, from: IPCCodec.encode(value)) { self = .projectPHP(params); return }
            if fields["workingDirectory"] != nil, fields.count == 1, let params = try? IPCCodec.decode(PHPResolveRequest.self, from: IPCCodec.encode(value)) { self = .phpResolve(params); return }
            if fields["takeover"] != nil, let params = try? IPCCodec.decode(DNSInstallRequest.self, from: IPCCodec.encode(value)) { self = .dnsInstall(params); return }
            if fields["routeID"] != nil, fields["projectID"] != nil, let params = try? IPCCodec.decode(RouteProjectAssociationRequest.self, from: IPCCodec.encode(value)) { self = .routeAssociation(params); return }
            if fields["routeID"] != nil, fields["projectID"] != nil, fields["expectedCurrentSocket"] != nil, let params = try? IPCCodec.decode(RoutePHPTargetUpdateRequest.self, from: IPCCodec.encode(value)) { self = .routePHPTargetUpdate(params); return }
        }
        self = .raw(value)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try IPCCodec.decode(type, from: IPCCodec.encode(self))
    }
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let protocolVersion: Int
    public let method: String
    public let params: RequestParams?

    public init(id: UUID = UUID(), method: CoreMethod, params: RequestParams? = nil, protocolVersion: Int = ProtocolVersion.v1.rawValue) {
        self.id = id; self.protocolVersion = protocolVersion; self.method = method.rawValue; self.params = params
    }

    public init(id: UUID = UUID(), rawMethod: String, params: RequestParams? = nil, protocolVersion: Int = ProtocolVersion.v1.rawValue) {
        self.id = id; self.protocolVersion = protocolVersion; self.method = rawMethod; self.params = params
    }

    public var knownMethod: CoreMethod? { CoreMethod(rawValue: method) }
}

public enum IPCErrorCode: String, Codable, Sendable {
    case protocolIncompatible = "PROTOCOL_INCOMPATIBLE"
    case coreIncompatible = "CORE_INCOMPATIBLE"
    case invalidRequest = "INVALID_REQUEST"
    case internalError = "INTERNAL_ERROR"
    case projectNotFound = "PROJECT_NOT_FOUND"
    case projectNameAmbiguous = "PROJECT_NAME_AMBIGUOUS"
    case projectNameConflict = "PROJECT_NAME_CONFLICT"
    case pathNotFound = "PATH_NOT_FOUND"
    case pathNotDirectory = "PATH_NOT_DIRECTORY"
    case pathUnreadable = "PATH_UNREADABLE"
    case parkedPathNotFound = "PARKED_PATH_NOT_FOUND"
    case tlsOwnershipUnavailable = "TLS_OWNERSHIP_UNAVAILABLE"
    case tlsIdentityMismatch = "TLS_IDENTITY_MISMATCH"
    case tlsKeyCertificateMismatch = "TLS_KEY_CERTIFICATE_MISMATCH"
    case tlsTrustSettingsUnsupported = "TLS_TRUST_SETTINGS_UNSUPPORTED"
    case tlsTrustOperationFailed = "TLS_TRUST_OPERATION_FAILED"
    case tlsRemovalBlocked = "TLS_REMOVAL_BLOCKED"
    case tlsObservationFailed = "TLS_OBSERVATION_FAILED"
}

public struct IPCErrorPayload: Codable, Equatable, Sendable, Error {
    public let code: IPCErrorCode
    public let message: String
    public let details: [String: String]?
    public init(code: IPCErrorCode, message: String, details: [String: String]? = nil) { self.code = code; self.message = message; self.details = details }
}

public struct ProjectWire: Codable, Equatable, Sendable {
    public let id: UUID?
    public let name: String
    public let path: String
    public let registration: String
    public let availability: String
    public let detectedFramework: String?
    public let sources: [String]?
    public init(id: UUID?, name: String, path: String, registration: String, availability: String, detectedFramework: String? = nil, sources: [String]? = nil) { self.id = id; self.name = name; self.path = path; self.registration = registration; self.availability = availability; self.detectedFramework = detectedFramework; self.sources = sources }
    public init(_ project: Project) { self.init(id: project.id?.rawValue, name: project.name, path: project.rootPath.string, registration: project.registrationKind.rawValue, availability: project.availability.rawValue, detectedFramework: project.detectedFramework, sources: project.visibilitySources?.map(\.rawValue)) }
}

public struct ProjectPHPRequest: Codable, Equatable, Sendable {
    public let selector: String?
    public let workingDirectory: String
    public let version: String?
    public let useDefault: Bool
    public init(selector: String?, workingDirectory: String, version: String? = nil, useDefault: Bool = false) { self.selector = selector; self.workingDirectory = workingDirectory; self.version = version; self.useDefault = useDefault }
}

public struct ProjectPHPSelection: Codable, Equatable, Sendable {
    public let project: ProjectWire
    public let overrideVersion: String?
    public let defaultVersion: String?
    public let effectiveVersion: String?
    public let observedVersion: String?
    public let available: Bool
    public init(project: ProjectWire, overrideVersion: String?, defaultVersion: String?, effectiveVersion: String?, observedVersion: String?, available: Bool) { self.project = project; self.overrideVersion = overrideVersion; self.defaultVersion = defaultVersion; self.effectiveVersion = effectiveVersion; self.observedVersion = observedVersion; self.available = available }
}

public struct ParkedPathWire: Codable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let availability: String
    public init(id: UUID, path: String, availability: String) { self.id = id; self.path = path; self.availability = availability }
    public init(_ path: ParkedPath) { self.init(id: path.id.rawValue, path: path.rootPath.string, availability: path.availability.rawValue) }
}

public struct LinkProjectRequest: Codable, Equatable, Sendable {
    public let path: String
    public let workingDirectory: String
    public let name: String?
    public init(path: String? = nil, workingDirectory: String, name: String? = nil) { self.path = path ?? workingDirectory; self.workingDirectory = workingDirectory; self.name = name }
}

public struct UnlinkProjectRequest: Codable, Equatable, Sendable {
    public let path: String?
    public let name: String?
    public let workingDirectory: String
    public init(path: String? = nil, name: String? = nil, workingDirectory: String) { self.path = path; self.name = name; self.workingDirectory = workingDirectory }
}

public struct ListProjectsRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct ParkPathRequest: Codable, Equatable, Sendable {
    public let path: String
    public let workingDirectory: String
    public init(path: String? = nil, workingDirectory: String) { self.path = path ?? workingDirectory; self.workingDirectory = workingDirectory }
}

public struct UnparkPathRequest: Codable, Equatable, Sendable {
    public let path: String
    public let workingDirectory: String
    public init(path: String? = nil, workingDirectory: String) { self.path = path ?? workingDirectory; self.workingDirectory = workingDirectory }
}

public struct ProjectMutationResult: Codable, Equatable, Sendable {
    public let project: ProjectWire?
    public let created: Bool
    public init(project: ProjectWire?, created: Bool) { self.project = project; self.created = created }
    private enum CodingKeys: String, CodingKey { case project, created }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(project, forKey: .project)
        if project == nil { try container.encodeNil(forKey: .project) }
        try container.encode(created, forKey: .created)
    }
}

public struct ParkedPathMutationResult: Codable, Equatable, Sendable {
    public let path: ParkedPathWire?
    public let created: Bool
    public let reconciliation: ParkRouteReconciliationSummary?
    public init(path: ParkedPathWire?, created: Bool, reconciliation: ParkRouteReconciliationSummary? = nil) { self.path = path; self.created = created; self.reconciliation = reconciliation }
    private enum CodingKeys: String, CodingKey { case path, created, reconciliation }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(path, forKey: .path)
        if path == nil { try container.encodeNil(forKey: .path) }
        try container.encode(created, forKey: .created)
        try container.encodeIfPresent(reconciliation, forKey: .reconciliation)
    }
}

public struct ParkRouteReconciliationSummary: Codable, Equatable, Sendable {
    public let added: [String]
    public let removed: [String]
    public let conflicts: [String]
    public let issues: [String]
    public init(added: [String] = [], removed: [String] = [], conflicts: [String] = [], issues: [String] = []) {
        self.added = added; self.removed = removed; self.conflicts = conflicts; self.issues = issues
    }
}

public struct ProjectListResult: Codable, Equatable, Sendable {
    public let projects: [ProjectWire]
    public init(projects: [ProjectWire]) { self.projects = projects }
}

public struct ProjectEnvironmentResult: Codable, Equatable, Sendable {
    public let report: ProjectEnvironmentReport
    public init(report: ProjectEnvironmentReport) { self.report = report }
}

public struct ProjectReconciliationPlanResult: Codable, Equatable, Sendable {
    public let plan: ProjectReconciliationPlan
    public init(plan: ProjectReconciliationPlan) { self.plan = plan }
}

public struct ProjectReconciliationExecutionResponse: Codable, Equatable, Sendable {
    public let execution: ProjectReconciliationExecutionResult
    public init(execution: ProjectReconciliationExecutionResult) { self.execution = execution }
}

public struct ParkedPathListResult: Codable, Equatable, Sendable {
    public let paths: [ParkedPathWire]
    public init(paths: [ParkedPathWire]) { self.paths = paths }
}

public struct PHPVersionRequest: Codable, Equatable, Sendable { public let version: String; public init(version: String) { self.version = version } }
public struct PHPExecRequest: Codable, Equatable, Sendable { public let version: String?; public let workingDirectory: String; public let arguments: [String]; public init(version: String? = nil, workingDirectory: String, arguments: [String]) { self.version = version; self.workingDirectory = workingDirectory; self.arguments = arguments } }
public struct PHPResolveRequest: Codable, Equatable, Sendable { public let workingDirectory: String; public init(workingDirectory: String) { self.workingDirectory = workingDirectory } }
public struct PHPResolveResult: Codable, Equatable, Sendable { public let version: String; public let cliPath: String; public let projectName: String?; public init(version: String, cliPath: String, projectName: String?) { self.version = version; self.cliPath = cliPath; self.projectName = projectName } }
public struct PHPPackageWire: Codable, Equatable, Sendable { public let version: String; public let architecture: String; public init(_ package: PHPPackage) { version = package.version; architecture = package.architecture } }
public struct PHPVersionsResult: Codable, Equatable, Sendable { public let available: [String]; public let installed: [PHPPackageWire]; public let `default`: String?; public init(available: [String], installed: [PHPPackageWire], default: String?) { self.available = available; self.installed = installed; self.default = `default` } }
public struct PHPRuntimeCatalogResult: Codable, Equatable, Sendable { public let catalog: PHPRuntimeCatalog; public init(catalog: PHPRuntimeCatalog) { self.catalog = catalog } }
public struct PHPOperationResult: Codable, Equatable, Sendable {
    public let operation: PHPOperationState?
    public init(operation: PHPOperationState?) { self.operation = operation }
    private enum CodingKeys: String, CodingKey { case operation }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let operation { try container.encode(operation, forKey: .operation) } else { try container.encodeNil(forKey: .operation) }
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operation = try container.decodeIfPresent(PHPOperationState.self, forKey: .operation)
    }
}
public struct PHPStatusResult: Codable, Equatable, Sendable { public let status: PHPStatus; public init(status: PHPStatus) { self.status = status } }
public struct MySQLPackageWire: Codable, Equatable, Sendable { public let version: String; public let architecture: String; public init(_ package: MySQLPackage) { version = package.version; architecture = package.architecture } }
public struct MySQLVersionsPayload: Codable, Equatable, Sendable { public let available: [String]; public let installed: [MySQLPackageWire]; public let `default`: String?; public init(available: [String], installed: [MySQLPackageWire], default: String?) { self.available = available; self.installed = installed; self.default = `default` } }
public struct MySQLVersionsResult: Codable, Equatable, Sendable { public let mysql: MySQLVersionsPayload; public init(mysql: MySQLVersionsPayload) { self.mysql = mysql } }
public struct MySQLStatusResult: Codable, Equatable, Sendable { public let mysql: MySQLStatus; public init(mysql: MySQLStatus) { self.mysql = mysql } }
public struct MailpitPackageWire: Codable, Equatable, Sendable { public let version: String; public let architecture: String; public init(_ package: MailpitPackage) { version = package.version; architecture = package.architecture } }
public struct MailpitVersionsPayload: Codable, Equatable, Sendable { public let available: [String]; public let installed: [MailpitPackageWire]; public init(available: [String], installed: [MailpitPackageWire]) { self.available = available; self.installed = installed } }
public struct MailpitVersionsResult: Codable, Equatable, Sendable { public let mailpit: MailpitVersionsPayload; public init(mailpit: MailpitVersionsPayload) { self.mailpit = mailpit } }
public struct MailpitStatusResult: Codable, Equatable, Sendable { public let mailpit: MailpitStatus; public init(mailpit: MailpitStatus) { self.mailpit = mailpit } }
public struct PHPExecResult: Codable, Equatable, Sendable { public let exitStatus: Int32; public let output: String; public init(exitStatus: Int32, output: String) { self.exitStatus = exitStatus; self.output = output } }
public struct RouterStatusResult: Codable, Equatable, Sendable { public let router: RouterStatus; public init(router: RouterStatus) { self.router = router } }
public struct RouteRemoveRequest: Codable, Equatable, Sendable { public let id: RouteID; public init(id: RouteID) { self.id = id } }
public struct RouteProjectAssociationRequest: Codable, Equatable, Sendable { public let routeID: RouteID; public let projectID: ProjectID; public init(routeID: RouteID, projectID: ProjectID) { self.routeID = routeID; self.projectID = projectID } }
public struct RoutePHPTargetUpdateRequest: Codable, Equatable, Sendable { public let routeID: RouteID; public let projectID: ProjectID; public let expectedCurrentSocket: String; public init(routeID: RouteID, projectID: ProjectID, expectedCurrentSocket: String) { self.routeID = routeID; self.projectID = projectID; self.expectedCurrentSocket = expectedCurrentSocket } }
public enum RouteAssociationMutationState: String, Codable, Equatable, Sendable { case associated, satisfied }
public struct RouteProjectAssociationResult: Codable, Equatable, Sendable { public let route: RouteIntent; public let state: RouteAssociationMutationState; public init(route: RouteIntent, state: RouteAssociationMutationState) { self.route = route; self.state = state } }
public enum RoutePHPTargetMutationState: String, Codable, Equatable, Sendable { case satisfied, updated, pending }
public struct RoutePHPTargetUpdateResult: Codable, Equatable, Sendable { public let observation: ProjectPHPRouteTargetObservation; public let state: RoutePHPTargetMutationState; public init(observation: ProjectPHPRouteTargetObservation, state: RoutePHPTargetMutationState) { self.observation = observation; self.state = state } }
public struct RouteListResult: Codable, Equatable, Sendable { public let routes: [RouteIntent]; public init(routes: [RouteIntent]) { self.routes = routes } }
public struct RouteObservedListResult: Codable, Equatable, Sendable {
    public let observedRoutes: [Route]?
    public let unavailableReason: String?
    public init(observedRoutes: [Route]?, unavailableReason: String? = nil) { self.observedRoutes = observedRoutes; self.unavailableReason = unavailableReason }
}
public struct DNSInstallRequest: Codable, Equatable, Sendable { public let takeover: Bool; public init(takeover: Bool = false) { self.takeover = takeover } }
public struct DNSStatusResult: Codable, Equatable, Sendable { public let dns: DNSStatus; public init(dns: DNSStatus) { self.dns = dns } }
public struct TLSStatusResult: Codable, Equatable, Sendable { public let tls: TLSStatus; public init(tls: TLSStatus) { self.tls = tls } }
public struct TLSTrustResultWire: Codable, Equatable, Sendable { public let result: TLSTrustResult; public init(result: TLSTrustResult) { self.result = result } }
public struct PortsStatusResult: Codable, Equatable, Sendable { public let ports: StandardPortsStatus; public init(ports: StandardPortsStatus) { self.ports = ports } }

public enum ResponseResult: Codable, Equatable, Sendable {
    case handshake(HandshakeResult)
    case status(CoreStatusResponse)
    case shutdown(CoreShutdownResponse)
    case projectMutation(ProjectMutationResult)
    case projectList(ProjectListResult)
    case projectEnvironment(ProjectEnvironmentResult)
    case projectPlan(ProjectReconciliationPlanResult)
    case projectActivation(ProjectReconciliationExecutionResponse)
    case projectPHP(ProjectPHPSelection)
    case parkedPathMutation(ParkedPathMutationResult)
    case parkedPathList(ParkedPathListResult)
    case phpVersions(PHPVersionsResult)
    case phpCatalog(PHPRuntimeCatalogResult)
    case phpOperation(PHPOperationResult)
    case phpStatus(PHPStatusResult)
    case mysqlVersions(MySQLVersionsResult)
    case mysqlStatus(MySQLStatusResult)
    case mailpitVersions(MailpitVersionsResult)
    case mailpitStatus(MailpitStatusResult)
    case phpExec(PHPExecResult)
    case phpResolve(PHPResolveResult)
    case routingStatus(RouterStatusResult)
    case routeList(RouteListResult)
    case routeObservedList(RouteObservedListResult)
    case routeMutation(RouteIntent)
    case routeAssociation(RouteProjectAssociationResult)
    case routePHPTargetUpdate(RoutePHPTargetUpdateResult)
    case dnsStatus(DNSStatusResult)
    case tlsStatus(TLSStatusResult)
    case tlsTrust(TLSTrustResultWire)
    case portsStatus(PortsStatusResult)
    case raw(JSONValue)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .handshake(let value): try value.encode(to: encoder)
        case .status(let value): try value.encode(to: encoder)
        case .shutdown(let value): try value.encode(to: encoder)
        case .projectMutation(let value): try value.encode(to: encoder)
        case .projectList(let value): try value.encode(to: encoder)
        case .projectEnvironment(let value): try value.encode(to: encoder)
        case .projectPlan(let value): try value.encode(to: encoder)
        case .projectActivation(let value): try value.encode(to: encoder)
        case .projectPHP(let value): try value.encode(to: encoder)
        case .parkedPathMutation(let value): try value.encode(to: encoder)
        case .parkedPathList(let value): try value.encode(to: encoder)
        case .phpVersions(let value): try value.encode(to: encoder)
        case .phpCatalog(let value): try value.encode(to: encoder)
        case .phpOperation(let value): try value.encode(to: encoder)
        case .phpStatus(let value): try value.encode(to: encoder)
        case .mysqlVersions(let value): try value.encode(to: encoder)
        case .mysqlStatus(let value): try value.encode(to: encoder)
        case .mailpitVersions(let value): try value.encode(to: encoder)
        case .mailpitStatus(let value): try value.encode(to: encoder)
        case .phpExec(let value): try value.encode(to: encoder)
        case .phpResolve(let value): try value.encode(to: encoder)
        case .routingStatus(let value): try value.encode(to: encoder)
        case .routeList(let value): try value.encode(to: encoder)
        case .routeObservedList(let value): try value.encode(to: encoder)
        case .routeMutation(let value): try value.encode(to: encoder)
        case .routeAssociation(let value): try value.encode(to: encoder)
        case .routePHPTargetUpdate(let value): try value.encode(to: encoder)
        case .dnsStatus(let value): try value.encode(to: encoder)
        case .tlsStatus(let value): try value.encode(to: encoder)
        case .tlsTrust(let value): try value.encode(to: encoder)
        case .portsStatus(let value): try value.encode(to: encoder)
        case .raw(let value): try value.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        let data = try IPCCodec.encode(value)
        guard case .object(let fields) = value else { self = .raw(value); return }
        if fields["components"] != nil, let result = try? IPCCodec.decode(CoreShutdownResponse.self, from: data) { self = .shutdown(result) }
        else if fields["core"] != nil, let result = try? IPCCodec.decode(CoreStatusResponse.self, from: data) { self = .status(result) }
        else if fields["coreVersion"] != nil, let result = try? IPCCodec.decode(HandshakeResult.self, from: data) { self = .handshake(result) }
        else if fields["projects"] != nil, let result = try? IPCCodec.decode(ProjectListResult.self, from: data) { self = .projectList(result) }
        else if fields["report"] != nil, let result = try? IPCCodec.decode(ProjectEnvironmentResult.self, from: data) { self = .projectEnvironment(result) }
        else if fields["plan"] != nil, let result = try? IPCCodec.decode(ProjectReconciliationPlanResult.self, from: data) { self = .projectPlan(result) }
        else if fields["execution"] != nil, let result = try? IPCCodec.decode(ProjectReconciliationExecutionResponse.self, from: data) { self = .projectActivation(result) }
        else if fields["overrideVersion"] != nil || fields["effectiveVersion"] != nil, let result = try? IPCCodec.decode(ProjectPHPSelection.self, from: data) { self = .projectPHP(result) }
        else if fields["project"] != nil, let result = try? IPCCodec.decode(ProjectMutationResult.self, from: data) { self = .projectMutation(result) }
        else if fields["paths"] != nil, let result = try? IPCCodec.decode(ParkedPathListResult.self, from: data) { self = .parkedPathList(result) }
        else if fields["path"] != nil, let result = try? IPCCodec.decode(ParkedPathMutationResult.self, from: data) { self = .parkedPathMutation(result) }
        else if fields["mysql"] != nil, let result = try? IPCCodec.decode(MySQLVersionsResult.self, from: data) { self = .mysqlVersions(result) }
        else if fields["mysql"] != nil, let result = try? IPCCodec.decode(MySQLStatusResult.self, from: data) { self = .mysqlStatus(result) }
        else if fields["mailpit"] != nil, let result = try? IPCCodec.decode(MailpitVersionsResult.self, from: data) { self = .mailpitVersions(result) }
        else if fields["mailpit"] != nil, let result = try? IPCCodec.decode(MailpitStatusResult.self, from: data) { self = .mailpitStatus(result) }
        else if fields["catalog"] != nil, let result = try? IPCCodec.decode(PHPRuntimeCatalogResult.self, from: data) { self = .phpCatalog(result) }
        else if fields["operation"] != nil, let result = try? IPCCodec.decode(PHPOperationResult.self, from: data) { self = .phpOperation(result) }
        else if fields["available"] != nil, let result = try? IPCCodec.decode(PHPVersionsResult.self, from: data) { self = .phpVersions(result) }
        else if fields["status"] != nil, let result = try? IPCCodec.decode(PHPStatusResult.self, from: data) { self = .phpStatus(result) }
        else if fields["exitStatus"] != nil, let result = try? IPCCodec.decode(PHPExecResult.self, from: data) { self = .phpExec(result) }
        else if fields["cliPath"] != nil, let result = try? IPCCodec.decode(PHPResolveResult.self, from: data) { self = .phpResolve(result) }
        else if fields["router"] != nil, let result = try? IPCCodec.decode(RouterStatusResult.self, from: data) { self = .routingStatus(result) }
        else if fields["routes"] != nil, let result = try? IPCCodec.decode(RouteListResult.self, from: data) { self = .routeList(result) }
        else if fields["observedRoutes"] != nil || fields["unavailableReason"] != nil, let result = try? IPCCodec.decode(RouteObservedListResult.self, from: data) { self = .routeObservedList(result) }
        else if fields["route"] != nil, fields["state"] != nil, let result = try? IPCCodec.decode(RouteProjectAssociationResult.self, from: data) { self = .routeAssociation(result) }
        else if fields["observation"] != nil, let result = try? IPCCodec.decode(RoutePHPTargetUpdateResult.self, from: data) { self = .routePHPTargetUpdate(result) }
        else if fields["route"] != nil, let result = try? IPCCodec.decode(RouteIntent.self, from: data) { self = .routeMutation(result) }
        else if fields["dns"] != nil, let result = try? IPCCodec.decode(DNSStatusResult.self, from: data) { self = .dnsStatus(result) }
         else if fields["result"] != nil, let result = try? IPCCodec.decode(TLSTrustResultWire.self, from: data) { self = .tlsTrust(result) }
         else if fields["tls"] != nil, let result = try? IPCCodec.decode(TLSStatusResult.self, from: data) { self = .tlsStatus(result) }
        else if fields["ports"] != nil, let result = try? IPCCodec.decode(PortsStatusResult.self, from: data) { self = .portsStatus(result) }
        else { self = .raw(value) }
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public let id: UUID
    public let protocolVersion: Int
    public let result: ResponseResult?
    public let error: IPCErrorPayload?

    public init(id: UUID, result: ResponseResult, protocolVersion: Int = ProtocolVersion.v1.rawValue) { self.id = id; self.protocolVersion = protocolVersion; self.result = result; self.error = nil }
    public init(id: UUID, error: IPCErrorPayload, protocolVersion: Int = ProtocolVersion.v1.rawValue) { self.id = id; self.protocolVersion = protocolVersion; self.result = nil; self.error = error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        result = try container.decodeIfPresent(ResponseResult.self, forKey: .result)
        error = try container.decodeIfPresent(IPCErrorPayload.self, forKey: .error)
        guard (result != nil) != (error != nil) else { throw IPCModelError.invalidResponseShape }
    }
    private enum CodingKeys: String, CodingKey { case id, protocolVersion, result, error }
}

public enum IPCModelError: Error, Equatable, Sendable { case invalidResponseShape }

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .string(let v): try container.encode(v); case .number(let v): try container.encode(v); case .bool(let v): try container.encode(v); case .object(let v): try container.encode(v); case .array(let v): try container.encode(v); case .null: try container.encodeNil() }
    }
}

private struct EmptyParams: Codable {}

public enum IPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
}
