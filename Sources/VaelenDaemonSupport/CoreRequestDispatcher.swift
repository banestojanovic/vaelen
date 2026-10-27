import Foundation
import OSLog
import VaelenCore
import VaelenIPC

private func adoptionDocumentRoot(_ path: String, projectRoot: String) -> String? {
    guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
    let root = URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let candidate: URL
    if path.hasPrefix("/") {
        candidate = URL(fileURLWithPath: path, isDirectory: true)
    } else {
        candidate = root.appendingPathComponent(path.isEmpty ? "." : path, isDirectory: true)
    }
    let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = root.path
    let resolvedPath = resolved.path
    guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
    return resolvedPath
}

private func routeDocumentRoot(_ route: Route) -> String? {
    switch route.target {
    case .fastCGI(_, let root), .staticFiles(let root): root
    case .http: nil
    }
}

private func routeTargetDescription(_ target: RouteTarget) -> String {
    switch target {
    case .fastCGI(let socket, _): "fastcgi \(socket)"
    case .staticFiles: "static"
    case .http(let host, let port): "http \(host):\(port)"
    }
}

private final class LocalProxyProbeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct ParkedProjectCandidate {
    let parentPath: String
    let project: Project
    let framework: ProjectFrameworkInspection
    var childPath: String { project.rootPath.string }
    var hostname: String { project.name + ".test" }
}

private struct ProjectReportObservations {
    let phpObservations: [PHPInstalledPackageObservation]
    let phpStatuses: [PHPStatus]
    let phpDefault: String?
    let routes: [RouteIntent]
    let router: RouterStatus
    let runtimeRoutes: [Route]?
    let linkedProjects: [Project]
    let phpOverrides: [ProjectID: String]
    let pendingTransitions: [RouteTargetTransition]
    let mysql: MySQLStatus?
    let mailpit: MailpitStatus?
    let dns: DNSStatus
    let tls: TLSStatus
    let ports: StandardPortsStatus
}

struct ProjectReadinessTestOverride: Sendable {
    let phpPackage: PHPPackage
    let phpStatus: PHPStatus
    let dns: DNSStatus
    let ports: StandardPortsStatus
}

enum ProjectObservationSnapshotFreshness {
    static let lifetime: TimeInterval = 30
    static func isFresh(createdAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= 0 && now.timeIntervalSince(createdAt) < lifetime
    }
}

public actor CoreRequestDispatcher {
    private struct ProjectAdoptionSession {
        let createdAt: Date
        let project: ProjectEnvironmentIdentity
        let preview: ProjectAdoptionPreview
        let routes: [RouteIntent]
        let instances: ServiceInstanceInventorySnapshot
    }
    private let runtime: CoreRuntime
    private let registry: ProjectRegistry
    private let php: PHPModule?
    private let node: NodePackageManager
    private var nodeInstallInFlight = false
    private let mysql: MySQLModule?
    private let mailpit: MailpitModule?
    private let router: any Router
    private let routeRepository: RouteIntentRepository?
    private let localProxyRepository: LocalProxyRepository?
    private let dns: DNSCapability
    private let tls: TLSCapability
    private let ports: StandardPortsCapability
    private let logs: CoreLogCatalog
    private let serviceIntents: ServiceIntentStore
    private let serviceInstances: ServiceInstanceRepository?
    private let projectServiceBindings: ProjectServiceBindings
    private let postgresql: PostgreSQLServiceModule?
    private let valkey: ValkeyServiceModule?
    private let shutdownTimingLogger = Logger(subsystem: "dev.vaelen.daemon", category: "shutdown-timing")
    private var restorationStarted = false
    private var restorationTask: Task<Void, Never>?
    private var routeIntents: [RouteID: RouteIntent]
    private var parkRouteMonitorTask: Task<Void, Never>?
    private var shutdownBegun = false
    private var shutdownTask: Task<CoreShutdownResponse, Never>?
    private var shutdownRunInFlight = false
    private var phpPackageOperationsInFlight = 0
    private var projectObservationSnapshots: [UUID: (createdAt: Date, observations: ProjectReportObservations)] = [:]
    private var projectAdoptionSessions: [UUID: ProjectAdoptionSession] = [:]
    private var projectReadinessTestOverride: ProjectReadinessTestOverride?
    func setProjectReadinessTestOverride(_ value: ProjectReadinessTestOverride?) { projectReadinessTestOverride = value }
    private let logger = Logger(subsystem: "dev.vaelen.daemon", category: "registry")
    private let standardPortsLogger = Logger(subsystem: "dev.vaelen.daemon", category: "standard-ports")

    public init(runtime: CoreRuntime, registry: ProjectRegistry, php: PHPModule? = nil, node: NodePackageManager = .init(), mysql: MySQLModule? = nil, mailpit: MailpitModule? = nil, postgresql: PostgreSQLServiceModule? = nil, valkey: ValkeyServiceModule? = nil, router: any Router = InMemoryRouter(), routeRepository: RouteIntentRepository? = nil, localProxyRepository: LocalProxyRepository? = nil, dns: DNSCapability = DNSCapability(), tls: TLSCapability = TLSCapability(), ports: StandardPortsCapability = StandardPortsCapability(), serviceIntents: ServiceIntentStore? = nil, serviceInstances: ServiceInstanceRepository? = nil, logs: CoreLogCatalog = CoreLogCatalog(layout: VaelenFilesystemLayout())) throws {
        self.node = node
        self.runtime = runtime; self.registry = registry; self.php = php; self.mysql = mysql; self.mailpit = mailpit; self.postgresql = postgresql; self.valkey = valkey; self.router = router; self.routeRepository = routeRepository; self.localProxyRepository = localProxyRepository; self.dns = dns; self.tls = tls; self.ports = ports; self.logs = logs; self.serviceIntents = serviceIntents ?? ServiceIntentStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-service-intents-\(UUID().uuidString).json")); self.serviceInstances = serviceInstances
        self.projectServiceBindings = ProjectServiceBindings(repository: serviceInstances, mysql: mysql, postgresql: postgresql, valkey: valkey, mailpit: mailpit)
        var persistedRoutes = try routeRepository?.all() ?? []
        if let localProxyRepository {
            guard let routeRepository else { throw LocalProxyError.persistence("Proxy ownership requires the durable Core route repository.") }
            for record in try localProxyRepository.list() {
                let current = persistedRoutes.first { $0.route.id == record.routeID }
                switch record.phase {
                case .active:
                    guard current?.route == record.route, current?.projectID == nil, current?.projectPath == nil else { throw LocalProxyError.recordMismatch }
                case .prepared:
                    if let current {
                        guard current.route == record.route, current.projectID == nil, current.projectPath == nil else { throw LocalProxyError.recordMismatch }
                        try localProxyRepository.activate(routeID: record.routeID, expectedRoute: record.route)
                    } else {
                        try localProxyRepository.markDeleting(routeID: record.routeID, expectedRoute: record.route)
                        try localProxyRepository.removeRecord(routeID: record.routeID, expectedRoute: record.route)
                    }
                case .deleting:
                    if let current {
                        guard current.route == record.route, current.projectID == nil, current.projectPath == nil else { throw LocalProxyError.recordMismatch }
                        try routeRepository.remove(id: record.routeID)
                        persistedRoutes.removeAll { $0.route.id == record.routeID }
                    }
                }
            }
        }
        _ = try routeRepository?.pendingTransitions()
        self.routeIntents = Dictionary(uniqueKeysWithValues: persistedRoutes.map { ($0.route.id, $0) })
    }

    public func dispatch(_ request: IPCRequest, handshaken: Bool) async -> (response: IPCResponse, handshaken: Bool) {
        if request.knownMethod == .shutdown {
            guard handshaken else {
                return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Handshake is required before shutdown.")), false)
            }
            shutdownBegun = true
            return (.init(id: request.id, result: .shutdown(await performShutdownOnce())), true)
        }
        if shutdownBegun && request.knownMethod != .status && request.knownMethod != .handshake && request.knownMethod != .phpOperation {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Core shutdown is in progress. Retry after cleanup completes.")), handshaken)
        }
        return await dispatchRequest(request, handshaken: handshaken)
    }

    /// Used by the Core's parent-liveness monitor when the GUI disappears
    /// without completing its normal IPC Quit handshake.
    public func shutdownForParentExit() async -> CoreShutdownResponse {
        shutdownBegun = true
        return await performShutdownOnce()
    }

    private func performShutdownOnce() async -> CoreShutdownResponse {
        if shutdownTask == nil || (!shutdownRunInFlight && lastShutdownResponse?.completed == false) {
            shutdownRunInFlight = true
            shutdownTask = Task { await self.performShutdown() }
        }
        let task = shutdownTask!
        return await task.value
    }

    private func dispatchRequest(_ request: IPCRequest, handshaken: Bool) async -> (response: IPCResponse, handshaken: Bool) {
        guard request.protocolVersion == ProtocolVersion.v1.rawValue else {
            return (.init(id: request.id, error: .init(code: .protocolIncompatible, message: "Client and Core protocol versions are incompatible.", details: ["clientProtocolVersion": "\(request.protocolVersion)", "coreProtocolVersion": "1"])), handshaken)
        }
        guard let method = request.knownMethod else {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Unknown Core method: \(request.method).")), handshaken)
        }
        if method == .handshake {
            guard let params = request.params, let handshake = try? params.decode(HandshakeParams.self), let schema = handshake.client.schemaCompatibilityVersion else {
                return (.init(id: request.id, error: .init(code: .coreIncompatible, message: "The client does not provide the required Core compatibility identity.")), false)
            }
            guard schema == VaelenBuildInfo.schemaCompatibilityVersion else {
                return (.init(id: request.id, error: .init(code: .coreIncompatible, message: "The client uses an incompatible command schema.", details: ["clientSchemaCompatibilityVersion": "\(schema)", "coreSchemaCompatibilityVersion": "\(VaelenBuildInfo.schemaCompatibilityVersion)"])), false)
            }
            return (.init(id: request.id, result: .handshake(.init(protocolVersion: VaelenBuildInfo.protocolVersion.rawValue, coreVersion: runtime.status.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))), true)
        }
        guard handshaken else {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Handshake is required before other requests.")), false)
        }
        if requiresStartupRecoveryBarrier(method, params: request.params), let restorationTask {
            await restorationTask.value
        }
        if shutdownBegun && method != .status && method != .handshake && method != .phpOperation {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Core shutdown is in progress. Retry after cleanup completes.")), handshaken)
        }
        do {
            switch method {
            case .nodeCommand:
                let params = try request.params?.decode(NodeCommandParams.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Node parameters are required.") }()
                return (.init(id: request.id, result: .nodeCommand(.init(try await nodeCommand(params.nodeRequest)))), true)
            case .status:
                // The GUI uses this response to leave its bootstrap/loading
                // presentation. Do not publish saved desired state before the
                // one-shot autostart pass has settled, or the immediately
                // following service probes can be cached as a false Retry.
                if let restorationTask { await restorationTask.value }
                let savedIntents = try? serviceIntents.enabledServices()
                let issues = serviceIntents.failures()
                return (.init(id: request.id, result: .status(.init(core: runtime.status, protocolVersion: 1, serviceIssues: issues, serviceIntents: savedIntents))), true)
            case .shutdown:
                fatalError("shutdown is handled before provider dispatch")
            case .serviceInstances:
                guard projectServiceBindings.isAvailable else { throw IPCErrorPayload(code: .internalError, message: "Service instance inventory is unavailable.") }
                let entries = try assessedServiceInstanceInventory().entries.map { entry in
                    let health = assessedHealth(for: entry.record)
                    let eligible = bindingEligible(record: entry.record, health: health)
                    return ServiceInstanceInventoryEntryWire(entry, assessedHealth: health, eligibleForProjectBinding: eligible)
                }
                return (.init(id: request.id, result: .serviceInstances(.init(entries: entries))), true)
            case .serviceInstanceLifecycle:
                let params = try request.params?.decode(ServiceInstanceLifecycleRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Service instance lifecycle parameters are required.") }()
                let name = try ProjectInstanceName(params.name)
                if params.kind == .valkey {
                    guard let valkey else { throw IPCErrorPayload(code: .internalError, message: "Valkey lifecycle is unavailable because no verified package root was injected.") }
                    let id = ServiceInstanceID(kind: .valkey, name: name)
                    switch params.action {
                    case .create: try valkey.create(id: id, port: params.port ?? (try serviceInstances?.instance(id))?.endpoint.portNumbers.first ?? ValkeyServiceModule.availableLoopbackPort())
                    case .status: break
                    case .start: try valkey.start(id: id)
                    case .stop: try valkey.stop(id: id)
                    case .remove:
                        try valkey.remove(id: id)
                        return (.init(id: request.id, result: .serviceInstanceLifecycle(.init(instance: nil, health: "removed", pid: nil))), true)
                    }
                    let observed = try valkey.status(id: id)
                    return (.init(id: request.id, result: .serviceInstanceLifecycle(.init(instance: observed.record.map(ServiceInstanceRecordWire.init), health: observed.health, pid: observed.pid))), true)
                }
                guard params.kind == .postgresql, let postgresql else { throw IPCErrorPayload(code: .internalError, message: "PostgreSQL lifecycle is unavailable because no verified package root was injected.") }
                let id = ServiceInstanceID(kind: .postgresql, name: name)
                switch params.action {
                case .create:
                    try postgresql.create(id: id, port: params.port ?? PostgreSQLServiceModule.availableLoopbackPort())
                case .status: break
                case .start: try postgresql.start(id: id)
                case .stop: try postgresql.stop(id: id)
                case .remove:
                    try postgresql.remove(id: id)
                    return (.init(id: request.id, result: .serviceInstanceLifecycle(.init(instance: nil, health: "removed", pid: nil))), true)
                }
                let observed = try postgresql.status(id: id)
                return (.init(id: request.id, result: .serviceInstanceLifecycle(.init(instance: observed.record.map(ServiceInstanceRecordWire.init), health: observed.health, pid: observed.pid))), true)
            case .projectLink:
                let params = try request.params?.decode(LinkProjectRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Link parameters are required.") }()
                let mutation = try await registry.linkWithCreation(path: params.path, workingDirectory: params.workingDirectory, name: params.name)
                let project = mutation.project
                if let routeRepository, let projectID = project.id?.rawValue {
                    let parkedIDs = Set(try routeRepository.parkRouteOwnerships().filter { $0.childPath == project.rootPath.string }.map(\.routeID))
                    let projectRoutes = Array(routeIntents.filter { $0.value.projectPath == project.rootPath.string || parkedIDs.contains($0.key) })
                    for (routeID, intent) in projectRoutes {
                        try routeRepository.associateMetadata(id: routeID, projectID: projectID, projectPath: project.rootPath.string)
                        routeIntents[routeID] = RouteIntent(route: intent.route, projectID: projectID, projectPath: project.rootPath.string)
                    }
                }
                logger.info("Project linked: \(project.rootPath.string, privacy: .public)")
                return (.init(id: request.id, result: .projectMutation(.init(project: .init(project), created: mutation.created))), true)
            case .projectUnlink:
                let params = try request.params?.decode(UnlinkProjectRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Unlink parameters are required.") }()
                let linkedBeforeUnlink: Project?
                if let name = params.name {
                    let matches = try await registry.linkedProjects().filter { $0.name == name }
                    linkedBeforeUnlink = matches.count == 1 ? matches[0] : nil
                } else {
                    let path = params.path ?? params.workingDirectory
                    let canonical = CanonicalPathService().canonicalize(path, relativeTo: params.workingDirectory).string
                    let linkedProjects = try await registry.linkedProjects()
                    let routeProjectIDs = Set(routeIntents.values.filter { $0.projectPath == canonical || $0.projectPath == path }.compactMap(\.projectID))
                    linkedBeforeUnlink = linkedProjects.first { project in
                        (project.rootPath.string == canonical || project.rootPath.string == path)
                            || project.id.map { routeProjectIDs.contains($0.rawValue) } == true
                    }
                }
                if let name = params.name { try await registry.unlink(name: name) }
                else { try await registry.unlink(path: params.path ?? params.workingDirectory, workingDirectory: params.workingDirectory) }
                if let projectID = linkedBeforeUnlink?.id?.rawValue, let routeRepository {
                    try routeRepository.disassociateProject(projectID: projectID)
                    for (routeID, intent) in Array(routeIntents) where intent.projectID == projectID {
                        routeIntents[routeID] = RouteIntent(route: intent.route, projectPath: intent.projectPath)
                    }
                }
                logger.info("Project unlinked")
                return (.init(id: request.id, result: .projectMutation(.init(project: nil, created: false))), true)
            case .projectLinks:
                return (.init(id: request.id, result: .projectList(.init(projects: try await registry.linkedProjects().map(ProjectWire.init)))), true)
            case .projectList:
                return (.init(id: request.id, result: .projectList(.init(projects: try await registry.projectsList().map(ProjectWire.init)))), true)
            case .projectObservationSnapshot:
                let observations = try await collectProjectReportObservations()
                let now = Date()
                projectObservationSnapshots = projectObservationSnapshots.filter { ProjectObservationSnapshotFreshness.isFresh(createdAt: $0.value.createdAt, now: now) }
                if projectObservationSnapshots.count >= 8,
                   let oldest = projectObservationSnapshots.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                    projectObservationSnapshots.removeValue(forKey: oldest)
                }
                let snapshotID = UUID()
                projectObservationSnapshots[snapshotID] = (now, observations)
                return (.init(id: request.id, result: .projectObservationSnapshot(.init(snapshotID: snapshotID))), true)
            case .projectStatus, .projectInspect, .projectDoctor:
                let params = try request.params?.decode(ProjectEnvironmentRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Project environment parameters are required.") }()
                let project = try await resolveProject(selector: params.selector, workingDirectory: params.workingDirectory)
                let observations: ProjectReportObservations
                if let snapshotID = params.snapshotID {
                    guard let snapshot = projectObservationSnapshots[snapshotID], ProjectObservationSnapshotFreshness.isFresh(createdAt: snapshot.createdAt, now: Date()) else {
                        throw IPCErrorPayload(code: .projectObservationSnapshotExpired, message: "The project observation snapshot expired. Refresh and retry.")
                    }
                    observations = snapshot.observations
                } else {
                    observations = try await collectProjectReportObservations()
                }
                let report = try await projectEnvironmentReport(for: project, observations: observations)
                return (.init(id: request.id, result: .projectEnvironment(.init(report: report))), true)
            case .projectAdoptionPreview:
                let params = try request.params?.decode(ProjectEnvironmentRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Project adoption preview parameters are required.") }()
                let project = try await resolveProject(selector: params.selector, workingDirectory: params.workingDirectory)
                let report = try await projectEnvironmentReport(for: project)
                let discovery = ProjectAdoptionPreviewBuilder.discover(at: project.rootPath.string)
                let observed = try? await router.observedRoutes()
                let routes = try routeRepository?.all() ?? Array(routeIntents.values)
                let preview = ProjectAdoptionPreviewBuilder.build(report: report, routes: routes, observedRoutes: observed, unavailableReason: observed == nil ? "Live route observation is unavailable." : nil, discovery: discovery)
                let inventory = try assessedServiceInstanceInventory()
                let id = UUID()
                projectAdoptionSessions = projectAdoptionSessions.filter { ProjectObservationSnapshotFreshness.isFresh(createdAt: $0.value.createdAt, now: Date()) }
                if projectAdoptionSessions.count >= 8, let oldest = projectAdoptionSessions.min(by: { $0.value.createdAt < $1.value.createdAt })?.key { projectAdoptionSessions.removeValue(forKey: oldest) }
                projectAdoptionSessions[id] = ProjectAdoptionSession(createdAt: Date(), project: report.identity, preview: preview, routes: routes, instances: inventory)
                return (.init(id: request.id, result: .projectAdoptionPreview(.init(confirmation: id, preview: preview))), true)
            case .projectAdoptionApply:
                let params = try request.params?.decode(ProjectAdoptionApplyRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Project adoption choices are required.") }()
                guard let session = projectAdoptionSessions.removeValue(forKey: params.confirmation), ProjectObservationSnapshotFreshness.isFresh(createdAt: session.createdAt, now: Date()) else {
                    throw IPCErrorPayload(code: .invalidRequest, message: "The adoption review expired or was already used. Run the preview again.")
                }
                let project = try await resolveProject(selector: params.selector, workingDirectory: params.workingDirectory)
                guard ProjectEnvironmentIdentity(project: project) == session.project else { throw IPCErrorPayload(code: .invalidRequest, message: "The project identity changed after review. Run the preview again.") }
                guard params.spec.version == 2, session.preview.manifestState == .absent else { throw IPCErrorPayload(code: .invalidRequest, message: "Adoption can create a new V2 vaelen.yml only. Existing declarations remain unchanged.") }
                guard !session.preview.herdYMLPresent, !session.preview.hasRouteOwnershipConflicts else { throw IPCErrorPayload(code: .invalidRequest, message: "The preview contains unsupported or conflicting evidence. Resolve it and run the preview again.") }
                guard session.preview.php.sources.isEmpty || params.spec.php != nil,
                      session.preview.node.sources.isEmpty || params.spec.node != nil else { throw IPCErrorPayload(code: .invalidRequest, message: "Choose an explicit PHP and Node declaration for each detected runtime requirement.") }
                guard params.webChoiceConfirmed,
                      params.spec.web == nil ? (params.selectedRouteIDs.isEmpty && !params.createRoute) : (params.createRoute ? params.selectedRouteIDs.isEmpty : params.selectedRouteIDs.count == 1) else { throw IPCErrorPayload(code: .invalidRequest, message: "Confirm no web route, one reviewed route, or explicit route creation.") }
                guard let projectID = project.id else { throw IPCErrorPayload(code: .invalidRequest, message: "Link this project before claiming service instances.") }
                let report = try await projectEnvironmentReport(for: project)
                let observed = try? await router.observedRoutes()
                let currentRoutes = try routeRepository?.all() ?? Array(routeIntents.values)
                let discovery = ProjectAdoptionPreviewBuilder.discover(at: project.rootPath.string)
                let currentPreview = ProjectAdoptionPreviewBuilder.build(report: report, routes: currentRoutes, observedRoutes: observed, unavailableReason: observed == nil ? "Live route observation is unavailable." : nil, discovery: discovery)
                guard discovery.issues.isEmpty else { throw IPCErrorPayload(code: .invalidRequest, message: "Runtime discovery contains unsupported evidence. Resolve it and run the preview again.") }
                let inventory = try assessedServiceInstanceInventory()
                guard currentPreview == session.preview, currentRoutes == session.routes, inventory == session.instances else { throw IPCErrorPayload(code: .invalidRequest, message: "Project, route, or service evidence changed after review. Run the preview again.") }
                guard params.selectedRouteIDs.count == Set(params.selectedRouteIDs).count,
                      params.selectedRouteIDs.allSatisfy({ id in session.preview.routes.contains(where: { $0.id == id }) }) else { throw IPCErrorPayload(code: .invalidRequest, message: "Choose only routes listed in the reviewed project preview.") }
                guard projectServiceBindings.isAvailable else { throw IPCErrorPayload(code: .invalidRequest, message: "The service instance catalog is unavailable.") }
                if let web = params.spec.web {
                    guard let host = web.host, let documentRoot = web.documentRoot, let secure = web.secure, web.createRoute == params.createRoute else { throw IPCErrorPayload(code: .invalidRequest, message: "Choose the host, document root, and secure mode, and confirm whether Vaelen may create the route.") }
                    if params.createRoute {
                        let normalizedHost = host.lowercased()
                        let proxies = try localProxyRepository?.list() ?? []
                        guard let observed,
                              observed.allSatisfy({ $0.hostname.lowercased() != normalizedHost }),
                              currentRoutes.allSatisfy({ $0.route.hostname.lowercased() != normalizedHost }),
                              proxies.allSatisfy({ $0.route.hostname.lowercased() != normalizedHost }) else { throw IPCErrorPayload(code: .invalidRequest, message: "The requested host already has a route, proxy owner, or unavailable live-route evidence; no manifest or claim was changed.") }
                    } else {
                        guard let route = session.preview.routes.first(where: { $0.hostname == host }), params.selectedRouteIDs == [route.id] else { throw IPCErrorPayload(code: .invalidRequest, message: "A web host must match the single route that you explicitly selected in the review.") }
                        guard secure == (route.tls != .disabled) else { throw IPCErrorPayload(code: .invalidRequest, message: "The secure setting must match the reviewed route TLS mode.") }
                    }
                    if !params.createRoute, let route = session.preview.routes.first(where: { $0.hostname == host }), let reviewedRoot = route.documentRoot {
                        guard let normalizedRouteRoot = adoptionDocumentRoot(reviewedRoot, projectRoot: project.rootPath.string),
                              let normalizedChoice = adoptionDocumentRoot(documentRoot, projectRoot: project.rootPath.string) else {
                            throw IPCErrorPayload(code: .invalidRequest, message: "The selected route document root must stay within the project.")
                        }
                        guard normalizedRouteRoot == normalizedChoice else { throw IPCErrorPayload(code: .invalidRequest, message: "The document root must match the reviewed route.") }
                    }
                }
                let manifest = URL(fileURLWithPath: project.rootPath.string, isDirectory: true).appendingPathComponent("vaelen.yml")
                var createdManifestBytes: Data?
                do {
                    createdManifestBytes = try ProjectAdoptionManifestWriter.create(spec: params.spec, at: project.rootPath.string, expectedManifest: nil)
                    if !params.spec.services.isEmpty {
                        try projectServiceBindings.adopt(params.spec.services, projectID: projectID)
                    }
                } catch {
                    if let createdManifestBytes, (try? Data(contentsOf: manifest)) == createdManifestBytes { try? FileManager.default.removeItem(at: manifest) }
                    throw IPCErrorPayload(code: .invalidRequest, message: "Adoption could not complete and its new manifest was rolled back: \(error.localizedDescription)")
                }
                return (.init(id: request.id, result: .projectAdoptionApply(.init(identity: session.project, manifestCreated: true, claimedServices: params.spec.services, selectedRoutes: params.selectedRouteIDs))), true)
            case .projectPlan, .projectActivate, .projectDown:
                let params = try request.params?.decode(ProjectEnvironmentRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Project reconciliation parameters are required.") }()
                let project = try await resolveProject(selector: params.selector, workingDirectory: params.workingDirectory)
                guard project.registrationKind == .linked, project.id != nil else { throw IPCErrorPayload(code: .invalidRequest, message: "Project reconciliation requires a registered linked project.") }
                if method == .projectPlan {
                    let report = try await projectEnvironmentReport(for: project)
                    return (.init(id: request.id, result: .projectPlan(.init(plan: ProjectReconciliationPlanner().plan(report: report)))), true)
                }
                if method == .projectDown {
                    return (.init(id: request.id, result: .projectActivation(.init(execution: try await deactivate(project: project)))), true)
                }
                return (.init(id: request.id, result: .projectActivation(.init(execution: try await activate(project: project)))), true)
            case .projectPHP:
                let params = try request.params?.decode(ProjectPHPRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Project PHP parameters are required.") }()
                let project = try await resolveProject(selector: params.selector, workingDirectory: params.workingDirectory)
                guard project.registrationKind == .linked, let projectID = project.id else { throw IPCErrorPayload(code: .invalidRequest, message: "Only linked projects may select a PHP runtime.") }
                let previous = try await registry.phpOverride(for: projectID)
                if params.version != nil && params.useDefault { throw IPCErrorPayload(code: .invalidRequest, message: "Choose a PHP version or Use Default, not both.") }
                if let version = params.version {
                    let observation = php?.packageObservations().first { $0.version == version }
                    guard observation?.eligibility == .eligible, observation?.package != nil else { throw IPCErrorPayload(code: .invalidRequest, message: "PHP \(version) is not an installed eligible managed runtime.") }
                }
                let mutating = params.version != nil || params.useDefault
                if mutating && phpPackageOperationsInFlight > 0 { throw PHPModuleError.operationInProgress("Finish the current PHP operation before changing a project's PHP selection") }
                if mutating { try await registry.setPHPOverride(params.version, for: projectID) }
                if !mutating { return (.init(id: request.id, result: .projectPHP(try await projectPHPSelection(project))), true) }
                do {
                    _ = try await activate(project: project)
                    let verified = try await projectEnvironmentReport(for: project)
                    guard verified.observed.php.resolutionState == .resolved, verified.observed.php.fpmHealth == "healthy", verified.routeTargets.allSatisfy({ $0.disposition == .satisfied }) else {
                        throw IPCErrorPayload(code: .invalidRequest, message: "PHP selection was saved but the effective PHP runtime or project route did not verify healthy.")
                    }
                } catch {
                    try? await registry.setPHPOverride(previous, for: projectID)
                    throw error
                }
                return (.init(id: request.id, result: .projectPHP(try await projectPHPSelection(project))), true)
            case .projectPHPSelections:
                let projects = try await registry.linkedProjects()
                let overrides = try await registry.phpOverrides()
                let snapshot = php?.selectionSnapshot()
                let inspector = ProjectEnvironmentInspector()
                let selections = projects.filter { $0.availability == .available }.map { project in
                    let observed = inspector.observePHP(
                        phpPackages: snapshot?.packages ?? [],
                        phpStatuses: snapshot?.statuses ?? [],
                        phpDefault: snapshot?.defaultVersion,
                        phpOverride: project.id.flatMap { overrides[$0] },
                        invalidPHPVersions: snapshot?.invalidVersions ?? []
                    )
                    return projectPHPSelection(project, observed: observed)
                }
                return (.init(id: request.id, result: .projectPHPSelections(.init(selections: selections))), true)
            case .pathPark:
                let params = try request.params?.decode(ParkPathRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Park parameters are required.") }()
                let path = try await registry.parkWithCreation(path: params.path, workingDirectory: params.workingDirectory)
                logger.info("Path parked: \(path.path.rootPath.string, privacy: .public)")
                let summary = try await reconcileParkedProjectRoutes()
                return (.init(id: request.id, result: .parkedPathMutation(.init(path: .init(path.path), created: path.created, reconciliation: summary))), true)
            case .pathUnpark:
                let params = try request.params?.decode(UnparkPathRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Unpark parameters are required.") }()
                let canonical = CanonicalPathService().canonicalize(params.path, relativeTo: params.workingDirectory).string
                let summary = try await removeParkOwnedRoutes(parentPath: canonical)
                try await registry.unpark(path: params.path, workingDirectory: params.workingDirectory)
                await refreshParkRouteMonitor()
                logger.info("Path unparked")
                return (.init(id: request.id, result: .parkedPathMutation(.init(path: nil, created: false, reconciliation: summary))), true)
            case .pathList:
                return (.init(id: request.id, result: .parkedPathList(.init(paths: try await registry.parkedPaths().map(ParkedPathWire.init)))), true)
            case .phpVersions:
                let module = try phpModule(); return (.init(id: request.id, result: .phpVersions(.init(available: (try? module.availableVersions()) ?? [], installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpCatalog:
                let module = try phpModule()
                await Task.detached {
                    try? module.refreshCatalogIfNeeded()
                    module.refreshOfficialReleaseAdvisories(force: false)
                }.value
                return (.init(id: request.id, result: .phpCatalog(.init(catalog: try await phpCatalog(module)))), true)
            case .phpCatalogSnapshot:
                return (.init(id: request.id, result: .phpCatalog(.init(catalog: try await phpCatalog(phpModule())))), true)
            case .phpCatalogCheck:
                let module = try phpModule(); try await Task.detached {
                    let providerCheck = Result { try module.checkCatalogNow() }
                    module.refreshOfficialReleaseAdvisories(force: true)
                    try providerCheck.get()
                }.value; return (.init(id: request.id, result: .phpCatalog(.init(catalog: try await phpCatalog(module)))), true)
            case .phpInstall:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); _ = try await withPHPPackageOperation {
                    return try await Task.detached { try module.install(requestedVersion: params.version) }.value
                }; return (.init(id: request.id, result: .phpVersions(.init(available: (try? module.availableVersions()) ?? [], installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpUpdate:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }()
                // Install, settings carry-over, default handover, runtime start,
                // and route convergence all happen off the dispatcher executor so
                // status, progress, navigation and Quit stay responsive — but
                // inside one package-operation reservation, so the operation
                // stays observably pending through convergence and no other
                // package work or shutdown can race unfinished work.
                let result = try await withPHPPackageOperation {
                    try await self.performPHPUpdate(module: module, params: params)
                }
                return (.init(id: request.id, result: .phpUpdateResult(result)), true)
            case .phpRemove:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }();
                var dependencies = [String]()
                for project in try await registry.linkedProjects() { if let id = project.id, try await registry.phpOverride(for: id) == params.version { dependencies.append(project.name) } }
                if !dependencies.isEmpty { throw IPCErrorPayload(code: .invalidRequest, message: "PHP \(params.version) is required by linked project(s): \(dependencies.joined(separator: ", ")). Clear those project overrides first.") }
                try await withPHPPackageOperation { try await Task.detached { try module.remove(requestedVersion: params.version) }.value }
                try serviceIntents.set("php:\(params.version)", enabled: false)
                return (.init(id: request.id, result: .phpVersions(.init(available: (try? module.availableVersions()) ?? [], installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpOperation:
                let module = try phpModule(); return (.init(id: request.id, result: .phpOperation(.init(operation: module.operationState()))), true)
            case .phpDefaultSet:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }()
                let result = try await withPHPPackageOperation { try await self.selectDefaultAndReconcile(module: module, version: params.version) }
                return (.init(id: request.id, result: .phpDefaultSelection(result)), true)
            case .phpUse:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }()
                let exact = try module.resolveEligible(params.version).version
                _ = try await withPHPPackageOperation { try await self.selectDefaultAndReconcile(module: module, version: exact) }
                return (.init(id: request.id, result: .phpVersions(.init(available: (try? module.availableVersions()) ?? [], installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpExec:
                let module = try phpModule(); let params = try request.params?.decode(PHPExecRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP execution parameters are required.") }(); let result = try module.exec(requestedVersion: params.version, workingDirectory: params.workingDirectory, arguments: params.arguments); return (.init(id: request.id, result: .phpExec(.init(exitStatus: result.status, output: result.output))), true)
            case .phpResolve:
                let params = try request.params?.decode(PHPResolveRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP resolution requires the current working directory.") }()
                return (.init(id: request.id, result: .phpResolve(try await phpExecutableResolution(workingDirectory: params.workingDirectory))), true)
            case .phpStart:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); let status = try module.start(requestedVersion: params.version); if status.state == .running { try serviceIntents.set("php:\(params.version)", enabled: true) }; return (.init(id: request.id, result: .phpStatus(.init(status: status))), true)
            case .phpStop:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); let status = try module.stop(requestedVersion: params.version); if status.state == .stopped { try serviceIntents.set("php:\(params.version)", enabled: false) }; return (.init(id: request.id, result: .phpStatus(.init(status: status))), true)
            case .phpStatus:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); return (.init(id: request.id, result: .phpStatus(.init(status: try module.status(requestedVersion: params.version)))), true)
            case .phpConfiguration:
                let module = try phpModule(); return (.init(id: request.id, result: .phpConfiguration(phpConfigurationWire(try module.configuration()))), true)
            case .phpConfigurationUpdate:
                let module = try phpModule(); let params = try request.params?.decode(PHPConfigurationUpdateRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP configuration settings are required.") }()
                let settings = params.settings.map { PHPManagedSettings(uploadLimitMB: $0.uploadLimitMB, memoryLimitMB: $0.memoryLimitMB, maxExecutionTimeSeconds: $0.maxExecutionTimeSeconds, maxInputVariables: $0.maxInputVariables, postLimitMB: $0.postLimitMB) }
                return (.init(id: request.id, result: .phpConfiguration(phpConfigurationWire(try module.updateConfiguration(version: params.version, settings: settings)))), true)
            case .mysqlVersions:
                let module = try mysqlModule(); return (.init(id: request.id, result: .mysqlVersions(.init(mysql: .init(available: module.availableVersions(), installed: module.installedVersions().map(MySQLPackageWire.init), default: module.selectedVersion())))), true)
            case .mysqlInstall:
                let module = try mysqlModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "MySQL version is required.") }(); _ = try module.install(requestedVersion: params.version); return (.init(id: request.id, result: .mysqlVersions(.init(mysql: .init(available: module.availableVersions(), installed: module.installedVersions().map(MySQLPackageWire.init), default: module.selectedVersion())))), true)
            case .mysqlRemove:
                let module = try mysqlModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "MySQL version is required.") }()
                guard module.installedVersions().contains(where: { $0.version == params.version }) else { throw IPCErrorPayload(code: .invalidRequest, message: "Core could not verify ownership of MySQL \(params.version); no service or files were changed.") }
                let singletonID = ServiceInstanceID(kind: .mysql, name: try ProjectInstanceName("default"))
                let installed = try projectServiceBindings.removeSingletonAfterSuccessfulAction(for: singletonID, packageIdentifier: "mysql-\(params.version)") {
                    try serviceIntents.set("mysql", enabled: false)
                    _ = try module.stop()
                    return try module.remove(requestedVersion: params.version)
                }
                return (.init(id: request.id, result: .mysqlVersions(.init(mysql: .init(available: module.availableVersions(), installed: installed.map(MySQLPackageWire.init), default: module.selectedVersion())))), true)
            case .mysqlUse:
                let module = try mysqlModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "MySQL version is required.") }(); let singletonID = ServiceInstanceID(kind: .mysql, name: try ProjectInstanceName("default")); _ = try projectServiceBindings.withNoProjectClaims(for: singletonID) { try module.use(params.version) }; return (.init(id: request.id, result: .mysqlVersions(.init(mysql: .init(available: module.availableVersions(), installed: module.installedVersions().map(MySQLPackageWire.init), default: module.selectedVersion())))), true)
            case .mysqlInitialize:
                let module = try mysqlModule(); try module.initialize(); return (.init(id: request.id, result: .mysqlStatus(.init(mysql: module.status()))), true)
            case .mysqlStart:
                let module = try mysqlModule(); try serviceIntents.set("mysql", enabled: true); return (.init(id: request.id, result: .mysqlStatus(.init(mysql: try module.start()))), true)
            case .mysqlStop:
                let module = try mysqlModule(); try serviceIntents.set("mysql", enabled: false); return (.init(id: request.id, result: .mysqlStatus(.init(mysql: try module.stop()))), true)
            case .mysqlStatus:
                let module = try mysqlModule(); return (.init(id: request.id, result: .mysqlStatus(.init(mysql: module.status()))), true)
            case .mailpitVersions:
                let module = try mailpitModule(); return (.init(id: request.id, result: .mailpitVersions(.init(mailpit: .init(available: module.availableVersions(), installed: module.installedVersions().map(MailpitPackageWire.init))))), true)
            case .mailpitInstall:
                let module = try mailpitModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Mailpit version is required.") }(); _ = try module.install(requestedVersion: params.version); return (.init(id: request.id, result: .mailpitVersions(.init(mailpit: .init(available: module.availableVersions(), installed: module.installedVersions().map(MailpitPackageWire.init))))), true)
            case .mailpitRemove:
                let module = try mailpitModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Mailpit version is required.") }()
                guard module.installedVersions().contains(where: { $0.version == params.version }) else { throw IPCErrorPayload(code: .invalidRequest, message: "Core could not verify ownership of Mailpit \(params.version); no service or files were changed.") }
                let singletonID = ServiceInstanceID(kind: .mailpit, name: try ProjectInstanceName("default"))
                let installed = try projectServiceBindings.removeSingletonAfterSuccessfulAction(for: singletonID, packageIdentifier: "mailpit-\(params.version)") {
                    try serviceIntents.set("mailpit", enabled: false)
                    _ = try module.stop()
                    return try module.remove(requestedVersion: params.version)
                }
                return (.init(id: request.id, result: .mailpitVersions(.init(mailpit: .init(available: module.availableVersions(), installed: installed.map(MailpitPackageWire.init))))), true)
            case .mailpitStart:
                let module = try mailpitModule(); try serviceIntents.set("mailpit", enabled: true); return (.init(id: request.id, result: .mailpitStatus(.init(mailpit: try module.start()))), true)
            case .mailpitStop:
                let module = try mailpitModule(); try serviceIntents.set("mailpit", enabled: false); return (.init(id: request.id, result: .mailpitStatus(.init(mailpit: try module.stop()))), true)
            case .mailpitStatus:
                let module = try mailpitModule(); return (.init(id: request.id, result: .mailpitStatus(.init(mailpit: module.status()))), true)
            case .routingStatus:
                return (.init(id: request.id, result: .routingStatus(.init(router: await router.status()))), true)
            case .routingStart:
                try serviceIntents.set("caddy", enabled: true); try await router.start(); try await router.reconcile(routes: routeIntents.values.map(\.route)); _ = try await completeProxyDeletionsIfConverged(); return (.init(id: request.id, result: .routingStatus(.init(router: await router.status()))), true)
            case .routingStop:
                try serviceIntents.set("caddy", enabled: false); try await router.stop(); return (.init(id: request.id, result: .routingStatus(.init(router: await router.status()))), true)
            case .routeList:
                return (.init(id: request.id, result: .routeList(.init(routes: routeIntents.values.sorted { $0.route.hostname < $1.route.hostname }))), true)
            case .localProxyList:
                return (.init(id: request.id, result: .localProxyList(.init(proxies: try await localProxyList()))), true)
            case .localProxyAdd:
                guard let params = try request.params?.decode(LocalProxyCreateRequest.self) else { throw IPCErrorPayload(code: .invalidRequest, message: "Proxy hostname and upstream URL are required.") }
                return (.init(id: request.id, result: .localProxyMutation(try await createLocalProxy(hostname: params.hostname, upstreamURL: params.upstreamURL))), true)
            case .localProxyRemove:
                guard let params = try request.params?.decode(LocalProxyRemoveRequest.self) else { throw IPCErrorPayload(code: .invalidRequest, message: "A proxy hostname is required.") }
                try await removeLocalProxy(hostname: params.hostname)
                return (.init(id: request.id, result: .localProxyList(.init(proxies: try await localProxyList()))), true)
            case .routeObservedList:
                let status = await router.status()
                guard status.state == .running, status.health == .healthy else {
                    return (.init(id: request.id, result: .routeObservedList(.init(observedRoutes: nil, unavailableReason: "Router is not observed healthy."))), true)
                }
                do {
                    let observed = try await router.observedRoutes()
                    return (.init(id: request.id, result: .routeObservedList(.init(observedRoutes: observed.sorted { $0.hostname < $1.hostname }))), true)
                } catch {
                    return (.init(id: request.id, result: .routeObservedList(.init(observedRoutes: nil, unavailableReason: "Router routes could not be observed."))), true)
                }
            case .routeAdd:
                guard let repository = routeRepository else { throw IPCErrorPayload(code: .internalError, message: "Route persistence is unavailable.") }
                let intent = try request.params?.decode(RouteIntent.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Route parameters are required.") }()
                let validated = try intent.route.validated()
                var projectPath = intent.projectPath
                if let projectID = intent.projectID {
                    guard let project = try await registry.linkedProject(id: ProjectID(rawValue: projectID)) else { throw IPCErrorPayload(code: .invalidRequest, message: "Route project identity is not a registered M1 project.") }
                    projectPath = projectPath ?? project.rootPath.string
                }
                let normalized = RouteIntent(route: validated, projectID: intent.projectID, projectPath: projectPath)
                let proxyOwnerships = try localProxyRepository?.list() ?? []
                if proxyOwnerships.contains(where: { $0.routeID == validated.id }) {
                    throw IPCErrorPayload(code: .invalidRequest, message: "This route is explicitly owned by a local proxy. Manage it with ‘val proxy’.")
                }
                if proxyOwnerships.contains(where: { $0.route.hostname == validated.hostname }) {
                    throw IPCErrorPayload(code: .invalidRequest, message: "Hostname \(validated.hostname) has a pending local-proxy ownership record; resolve that proxy operation before adding another route.")
                }
                if let conflict = routeIntents.values.first(where: { $0.route.id != validated.id && $0.route.hostname == validated.hostname }) {
                    throw IPCErrorPayload(code: .invalidRequest, message: "Hostname \(validated.hostname) is already owned by route \(conflict.route.id); no route was changed.")
                }
                try repository.upsert(normalized); routeIntents[validated.id] = normalized
                if (await router.status()).state == .running { try await router.reconcile(routes: routeIntents.values.map(\.route)) }
                return (.init(id: request.id, result: .routeMutation(normalized)), true)
            case .routeRemove:
                guard let repository = routeRepository else { throw IPCErrorPayload(code: .internalError, message: "Route persistence is unavailable.") }
                let params = try request.params?.decode(RouteRemoveRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Route ID is required.") }()
                guard routeIntents[params.id] != nil else { throw RouterError.routeNotFound(params.id) }
                if try localProxyRepository?.list().contains(where: { $0.routeID == params.id }) == true {
                    throw IPCErrorPayload(code: .invalidRequest, message: "Route \(params.id) is explicitly owned by a local proxy; remove it with ‘val proxy remove <hostname>’.")
                }
                try repository.remove(id: params.id); routeIntents.removeValue(forKey: params.id)
                if (await router.status()).state == .running { try await router.reconcile(routes: routeIntents.values.map(\.route)) }
                return (.init(id: request.id, result: .routeList(.init(routes: routeIntents.values.sorted { $0.route.hostname < $1.route.hostname }))), true)
            case .routeProjectAssociationAttach:
                guard let repository = routeRepository else { throw IPCErrorPayload(code: .internalError, message: "Route persistence is unavailable.") }
                let params = try request.params?.decode(RouteProjectAssociationRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Route association parameters are required.") }()
                guard let intent = routeIntents[params.routeID] else { throw IPCErrorPayload(code: .invalidRequest, message: "The requested route does not exist.") }
                if try localProxyRepository?.list().contains(where: { $0.routeID == params.routeID }) == true {
                    throw IPCErrorPayload(code: .invalidRequest, message: "A local-proxy route cannot be associated with a project.")
                }
                guard let project = try await registry.linkedProject(id: params.projectID) else { throw IPCErrorPayload(code: .invalidRequest, message: "Route association requires a registered linked project.") }
                if intent.projectID == params.projectID.rawValue {
                    return (.init(id: request.id, result: .routeAssociation(.init(route: intent, state: .satisfied))), true)
                }
                guard intent.projectID == nil else { throw IPCErrorPayload(code: .invalidRequest, message: "The route is already associated with another project.") }
                let report = try await projectEnvironmentReport(for: project)
                guard report.observed.route.associationState == .safelyAssociable else {
                    throw IPCErrorPayload(code: .invalidRequest, message: report.observed.route.mutationAuthorityReason)
                }
                guard report.observed.route.hostname == intent.route.hostname || report.observed.route.hostname == nil else {
                    throw IPCErrorPayload(code: .invalidRequest, message: "The requested route is not the route identified by the current project evidence.")
                }
                let path = project.rootPath.string
                try repository.associateMetadata(id: params.routeID, projectID: params.projectID.rawValue, projectPath: path)
                let associated = RouteIntent(route: intent.route, projectID: params.projectID.rawValue, projectPath: path)
                routeIntents[params.routeID] = associated
                return (.init(id: request.id, result: .routeAssociation(.init(route: associated, state: .associated))), true)
            case .routePHPTargetUpdate:
                let params = try request.params?.decode(RoutePHPTargetUpdateRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Route target update parameters are required.") }()
                let result = try await updatePHPTarget(projectID: params.projectID, routeID: params.routeID, expectedCurrentSocket: params.expectedCurrentSocket)
                return (.init(id: request.id, result: .routePHPTargetUpdate(result)), true)
            case .dnsStatus:
                let value = await dns.status()
                return (.init(id: request.id, result: .dnsStatus(.init(dns: value))), true)
            case .dnsInstall:
                let params = try request.params?.decode(DNSInstallRequest.self) ?? .init()
                try serviceIntents.set("dns", enabled: true); return (.init(id: request.id, result: .dnsStatus(.init(dns: try await dns.install(takeover: params.takeover)))), true)
            case .dnsRemove:
                try serviceIntents.set("dns", enabled: false); return (.init(id: request.id, result: .dnsStatus(.init(dns: try await dns.remove()))), true)
            case .tlsStatus:
                return (.init(id: request.id, result: .tlsStatus(.init(tls: await tls.status()))), true)
            case .tlsInstall:
                return (.init(id: request.id, result: .tlsStatus(.init(tls: try await tls.install()))), true)
            case .tlsRemove:
                return (.init(id: request.id, result: .tlsStatus(.init(tls: try await tls.remove()))), true)
            case .tlsTrustLocalCA:
                return (.init(id: request.id, result: .tlsTrust(.init(result: try await tls.trustLocalCA()))), true)
            case .tlsRemoveLocalCATrust:
                return (.init(id: request.id, result: .tlsTrust(.init(result: try await tls.removeLocalCATrust()))), true)
            case .portsStatus:
                return (.init(id: request.id, result: .portsStatus(.init(ports: await ports.status()))), true)
            case .logsCatalog:
                return (.init(id: request.id, result: .logsCatalog(.init(logs: logs.list()))), true)
            case .logsTail:
                guard case .logsTail(let params)? = request.params else { throw IPCErrorPayload(code: .invalidRequest, message: "A log ID and line count are required.") }
                return (.init(id: request.id, result: .logsTail(.init(tail: try logs.tail(id: params.id, lines: params.lines)))), true)
            case .portsInstall:
                standardPortsLogger.info("IPC ports.install entered; persisting desired Standard Ports state ON")
                try serviceIntents.set("standard-ports", enabled: true)
                let status = try await ports.install()
                standardPortsLogger.info("IPC ports.install completed; status=\(status.state.rawValue, privacy: .public)")
                return (.init(id: request.id, result: .portsStatus(.init(ports: status))), true)
            case .portsRemove:
                try serviceIntents.set("standard-ports", enabled: false); return (.init(id: request.id, result: .portsStatus(.init(ports: try await ports.remove()))), true)
            case .handshake:
                fatalError("handled above")
            }
        } catch let error as PHPModuleError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as MySQLModuleError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as MailpitModuleError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as ProjectRegistryError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as IPCErrorPayload {
            return (.init(id: request.id, error: error), true)
        } catch let error as CoreLogError {
            switch error {
            case .unknownLog(let id): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Unknown Vaelen log ID '\(id)'. Run 'val logs' to list supported logs.")), true)
            case .invalidLineCount: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Line count must be between 1 and \(CoreLogCatalog.maxLines).")), true)
            case .missing(let id): return (.init(id: request.id, error: .init(code: .logMissing, message: "Log '\(id)' is missing.")), true)
            case .unreadable(let id): return (.init(id: request.id, error: .init(code: .logUnreadable, message: "Log '\(id)' is unreadable.")), true)
            case .unsafePath(let id): return (.init(id: request.id, error: .init(code: .logUnsafePath, message: "Log '\(id)' resolves outside Vaelen's owned log directory.")), true)
            }
        } catch let error as StandardPortsError {
            standardPortsLogger.error("IPC Standard Ports request returned an error payload: \(String(describing: error), privacy: .public)")
            switch error {
            case .helperUnavailable: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Local Ports require approval in Vaelen.app.")), true)
            case .authorizationRequired(let detail): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports authorization failed: \(detail)")), true)
            case .externalConflict(let detail): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports conflict: \(detail)")), true)
            case .ownershipMismatch: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports ownership mismatch: external state changed.")), true)
            case .incomplete(let detail): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports are incomplete and cannot be repaired automatically: \(detail)")), true)
            case .backendUnavailable: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports require the backend router to be running.")), true)
            case .unavailable(let detail): return (.init(id: request.id, error: .init(code: .internalError, message: "Standard Ports are unavailable: \(detail)")), true)
            }
        } catch let error as TLSError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as LocalProxyError {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: localProxyErrorMessage(error))), true)
        } catch {
            logger.error("Registry operation failed: \(String(describing: error), privacy: .public)")
            return (.init(id: request.id, error: .init(code: .internalError, message: "Core operation failed: \(error)")), true)
        }
    }

    private func requiresStartupRecoveryBarrier(_ method: CoreMethod, params: RequestParams?) -> Bool {
        switch method {
        case .projectLink, .projectUnlink, .projectAdoptionApply, .projectActivate, .projectDown,
             .mysqlStart, .mysqlStop, .mailpitStart, .mailpitStop:
            return true
        case .projectPHP:
            guard let params, let request = try? params.decode(ProjectPHPRequest.self) else { return false }
            return request.version != nil || request.useDefault
        case .serviceInstanceLifecycle:
            guard let params, let lifecycle = try? params.decode(ServiceInstanceLifecycleRequest.self) else { return false }
            return lifecycle.action != .status
        default:
            return false
        }
    }

    private func createLocalProxy(hostname: String, upstreamURL: String) async throws -> LocalProxyMutationResult {
        guard let localProxyRepository, let routeRepository else { throw LocalProxyError.persistence("Local proxy persistence is unavailable.") }
        let configuration = try LocalProxyConfiguration(hostname: hostname, upstreamURL: upstreamURL)
        guard let upstreamHost = configuration.upstreamURL.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              let port = configuration.upstreamURL.port else { throw LocalProxyError.invalidUpstreamURL("The upstream URL is missing its normalized host or port.") }
        let target = RouteTarget.http(host: upstreamHost.lowercased(), port: port)
        let ownerships = try localProxyRepository.list()
        if let existing = routeIntents.values.first(where: { $0.route.hostname == configuration.hostname }) {
            guard let owned = ownerships.first(where: { $0.routeID == existing.route.id }), owned.route == existing.route,
                  existing.projectID == nil, existing.projectPath == nil,
                  existing.route.target == target, existing.route.tls == .disabled else {
                throw IPCErrorPayload(code: .invalidRequest, message: "Hostname \(configuration.hostname) is already owned by another route or uses a different upstream. No route was changed.")
            }
            guard owned.phase != .deleting else { throw IPCErrorPayload(code: .invalidRequest, message: "Proxy removal for \(configuration.hostname) is still pending. Retry ‘val proxy remove \(configuration.hostname)’ before creating it again.") }
            if owned.phase == .prepared { try localProxyRepository.activate(routeID: owned.routeID, expectedRoute: owned.route) }
            if (await router.status()).state == .running {
                do { try await router.reconcile(routes: routeIntents.values.map(\.route)) }
                catch { throw IPCErrorPayload(code: .invalidRequest, message: "Proxy \(configuration.hostname) is saved, but Caddy did not apply it. Start or retry Vaelen routing; the upstream was not started.") }
            }
            let proxy = try await localProxyList().first(where: { $0.routeID == owned.routeID.description }) ?? { throw LocalProxyError.recordMismatch }()
            return LocalProxyMutationResult(proxy: proxy, created: false)
        }
        if let owned = ownerships.first(where: { $0.route.hostname == configuration.hostname }) {
            guard owned.phase == .prepared, routeIntents[owned.routeID] == nil else { throw LocalProxyError.recordMismatch }
            try localProxyRepository.markDeleting(routeID: owned.routeID, expectedRoute: owned.route)
            try localProxyRepository.removeRecord(routeID: owned.routeID, expectedRoute: owned.route)
        }

        let route = Route(hostname: configuration.hostname, target: target, tls: .disabled)
        let intent = RouteIntent(route: route)
        try localProxyRepository.createPrepared(route: route, expectedRoute: route)
        try routeRepository.upsert(intent)
        routeIntents[route.id] = intent
        try localProxyRepository.activate(routeID: route.id, expectedRoute: route)
        if (await router.status()).state == .running {
            do { try await router.reconcile(routes: routeIntents.values.map(\.route)) }
            catch { throw IPCErrorPayload(code: .invalidRequest, message: "Proxy \(route.hostname) is saved, but Caddy did not apply it. Start or retry Vaelen routing; the upstream was not started.") }
        }
        let proxy = try await localProxyList().first(where: { $0.routeID == route.id.description }) ?? { throw LocalProxyError.recordMismatch }()
        return LocalProxyMutationResult(proxy: proxy, created: true)
    }

    private func removeLocalProxy(hostname: String) async throws {
        guard let localProxyRepository, let routeRepository else { throw LocalProxyError.persistence("Local proxy persistence is unavailable.") }
        let normalizedHostname = try LocalProxyConfiguration(hostname: hostname, upstreamURL: "http://127.0.0.1:1").hostname
        guard let record = try localProxyRepository.list().first(where: { $0.route.hostname == normalizedHostname }) else {
            throw IPCErrorPayload(code: .invalidRequest, message: "No explicitly proxy-owned route exists for \(normalizedHostname). Other route types were not changed.")
        }
        if record.phase != .deleting { try localProxyRepository.markDeleting(routeID: record.routeID, expectedRoute: record.route) }
        if let current = routeIntents[record.routeID] {
            guard current.route == record.route, current.projectID == nil, current.projectPath == nil else { throw LocalProxyError.recordMismatch }
            try routeRepository.remove(id: record.routeID)
            routeIntents.removeValue(forKey: record.routeID)
        } else if record.phase != .deleting {
            throw LocalProxyError.recordMismatch
        }
        let routerState = await router.status()
        if routerState.state == .running {
            do {
                try await router.reconcile(routes: routeIntents.values.map(\.route))
                guard try await completeProxyDeletionsIfConverged() else {
                    throw IPCErrorPayload(code: .invalidRequest, message: "Proxy \(normalizedHostname) is removed from saved routing, but Caddy has not confirmed removal. Retry after checking Caddy.")
                }
            } catch {
                if let error = error as? IPCErrorPayload { throw error }
                throw IPCErrorPayload(code: .invalidRequest, message: "Proxy \(normalizedHostname) is removed from saved routing, but Caddy cleanup is pending. Retry ‘val proxy remove \(normalizedHostname)’ after checking Caddy.")
            }
        } else if routerState.state == .stopped {
            guard try await completeProxyDeletionsIfConverged() else {
                throw IPCErrorPayload(code: .invalidRequest, message: "Proxy \(normalizedHostname) is removed from saved routing, but ownership cleanup is pending. Retry after checking routing state.")
            }
        } else {
            throw IPCErrorPayload(code: .invalidRequest, message: "Proxy \(normalizedHostname) is removed from saved routing, but Caddy is degraded and removal is not confirmed. Retry after checking Caddy.")
        }
    }

    private func localProxyList() async throws -> [LocalProxyWire] {
        guard let localProxyRepository else { throw LocalProxyError.persistence("Local proxy persistence is unavailable.") }
        _ = try await completeProxyDeletionsIfConverged()
        let records = try localProxyRepository.list()
        for record in records {
            if let intent = routeIntents[record.routeID] {
                guard intent.route == record.route, intent.projectID == nil, intent.projectPath == nil else { throw LocalProxyError.recordMismatch }
            } else if record.phase != .deleting && record.phase != .prepared {
                throw LocalProxyError.recordMismatch
            }
        }
        let routerStatus = await router.status()
        let observedRoutes: [Route]?
        if routerStatus.state == .running && routerStatus.health == .healthy {
            observedRoutes = try? await router.observedRoutes()
        } else {
            observedRoutes = nil
        }
        var reachability = [RouteID: LocalProxyUpstreamReachability]()
        await withTaskGroup(of: (RouteID, LocalProxyUpstreamReachability).self) { group in
            for record in records {
                group.addTask { (record.routeID, await Self.probeLocalProxyUpstream(record.route)) }
            }
            for await (id, value) in group { reachability[id] = value }
        }
        return records.map { record in
            let observed = observedRoutes?.contains(where: {
                $0.hostname == record.route.hostname && $0.target == record.route.target && $0.tls == record.route.tls
            })
            let caddy: LocalProxyCaddyObservation
            if observedRoutes == nil { caddy = .unavailable }
            else { caddy = observed == true ? .observed : .notObserved }
            return LocalProxyWire(routeID: record.routeID.description, hostname: record.route.hostname,
                upstreamURL: Self.upstreamURL(for: record.route), caddyObservation: caddy,
                upstreamReachability: reachability[record.routeID] ?? .unknown,
                ownershipPhase: LocalProxyOwnershipPhase(rawValue: record.phase.rawValue) ?? .prepared)
        }.sorted { $0.hostname < $1.hostname }
    }

    private func completeProxyDeletionsIfConverged() async throws -> Bool {
        guard let localProxyRepository, let routeRepository else { return false }
        let records = try localProxyRepository.list().filter { $0.phase == .deleting }
        guard !records.isEmpty else { return true }
        let persistedRoutes = try routeRepository.all()
        for record in records {
            if let intent = persistedRoutes.first(where: { $0.route.id == record.routeID }) {
                guard intent.route == record.route, intent.projectID == nil, intent.projectPath == nil else {
                    throw LocalProxyError.recordMismatch
                }
            }
        }
        let state = await router.status()
        if state.state == .stopped {
            for record in records where !persistedRoutes.contains(where: { $0.route.id == record.routeID }) {
                try localProxyRepository.removeRecord(routeID: record.routeID, expectedRoute: record.route)
            }
            return try localProxyRepository.list().allSatisfy { $0.phase != .deleting }
        }
        guard state.state == .running && state.health == .healthy, let observed = try? await router.observedRoutes() else { return false }
        for record in records where !persistedRoutes.contains(where: { $0.route.id == record.routeID }) && !observed.contains(where: { $0.hostname == record.route.hostname }) {
            try localProxyRepository.removeRecord(routeID: record.routeID, expectedRoute: record.route)
        }
        return try localProxyRepository.list().allSatisfy { $0.phase != .deleting }
    }

    private static func upstreamURL(for route: Route) -> String {
        guard case .http(let host, let port) = route.target else { return "" }
        let address = host.contains(":") ? "[\(host)]" : host
        return "http://\(address):\(port)/"
    }

    private static func probeLocalProxyUpstream(_ route: Route) async -> LocalProxyUpstreamReachability {
        guard let url = URL(string: upstreamURL(for: route)) else { return .unknown }
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral, delegate: LocalProxyProbeRedirectPolicy(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse ? .reachable : .unknown
        } catch {
            return .unreachable
        }
    }

    private func localProxyErrorMessage(_ error: LocalProxyError) -> String {
        switch error {
        case .invalidHostname(let message), .invalidUpstreamURL(let message): return message
        case .routeNotEligible: return "A local proxy must be an HTTP loopback route ending in .test, with TLS disabled."
        case .ownershipConflict: return "A proxy ownership record already exists for this exact route. No route was changed."
        case .recordNotFound: return "No exact proxy ownership record exists. Other routes were not changed."
        case .recordMismatch, .invalidRecord: return "Proxy ownership evidence is missing or inconsistent. Core refused to change the route."
        case .persistence(let detail): return "Local proxy persistence failed: \(detail)"
        }
    }

    private func withPHPPackageOperation<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        guard phpPackageOperationsInFlight == 0 else { throw PHPModuleError.operationInProgress("another PHP package operation is active") }
        guard !shutdownBegun else { throw PHPModuleError.operationInProgress("Core shutdown is in progress") }
        phpPackageOperationsInFlight += 1
        defer { phpPackageOperationsInFlight -= 1 }
        return try await body()
    }

    private(set) var lastPHPDefaultSwitchTimings: [String: Double] = [:]

    private func selectDefaultAndReconcile(module: PHPModule, version: String) async throws -> PHPDefaultSelectionResult {
        // Provider validation/startup is synchronous. Detach it so this actor
        // can continue serving status, progress and Quit. Keep the operation
        // reservation through routing reconciliation so Quit waits safely.
        let catalog = try await Task.detached { try module.selectDefault(requestedVersion: version) }.value
        try serviceIntents.set("php:\(version)", enabled: true)
        let reconcileStarted = ContinuousClock.now
        var failures = [String]()
        let converged = await reconcileInheritedPHPRoutes(failures: &failures)
        _ = converged
        let reconciliationFinished = ContinuousClock.now
        lastPHPDefaultSwitchTimings = module.defaultSwitchTimings().merging(["apply_verify_ms": timingMilliseconds(reconcileStarted.duration(to: reconciliationFinished))]) { _, new in new }
        logger.info("PHP default switch version=\(version, privacy: .public) routing-reconciliation_ms=\(self.timingMilliseconds(reconcileStarted.duration(to: reconciliationFinished)), privacy: .public) failures=\(failures.count, privacy: .public)")
        let issues = await phpProjectIssues(from: failures)
        return PHPDefaultSelectionResult(catalog: catalog, projectIssues: issues, routingIssues: failures.filter { $0.hasPrefix("Routing:") })
    }

    /// Projects whose FastCGI target inherits the PHP default, reported with the
    /// convergence failures that concern them.
    private func phpProjectIssues(from failures: [String]) async -> [PHPDefaultProjectIssue] {
        let projects = (try? await registry.linkedProjects()) ?? []
        return projects.compactMap { project in
            let related = failures.filter { $0.hasPrefix("\(project.name):") }
            guard !related.isEmpty else { return nil }
            return PHPDefaultProjectIssue(projectName: project.name, message: related.joined(separator: "; "))
        }
    }

    /// Converge inherited project routes after a PHP default change.
    ///
    /// Only projects that inherit the default are touched. Projects with an
    /// explicit PHP pin are left resolving to the version their user chose.
    private func reconcileInheritedPHPRoutes(failures: inout [String]) async -> Bool {
        let reconcileStarted = ContinuousClock.now
        let projects = (try? await registry.linkedProjects()) ?? []
        let overrides = (try? await registry.phpOverrides()) ?? [:]
        let inheritedProjects = projects.filter { $0.id.map { overrides[$0] == nil } == true }
        let scanFinished = ContinuousClock.now
        // A failure to observe the existing state must not be reported as a
        // converged route set.
        guard let observations = try? await collectProjectReportObservations() else {
            failures.append("Routing: Vaelen could not observe current project routes; retry the update")
            return false
        }
        // A default change only converges inherited FastCGI targets. Running
        // full project activation repeatedly re-observed every service and
        // reloaded the entire Caddy configuration for each individual route.
        // Take one planning observation, preserve transition provenance, then
        // apply and verify the complete route set once.
        var changed = [(Project, RouteID)]()
        for project in inheritedProjects {
            guard let id = project.id else { continue }
            guard let report = try? await projectEnvironmentReport(for: project, observations: observations) else {
                failures.append("\(project.name): Vaelen could not observe this project's PHP route; retry the update")
                continue
            }
            guard (try? await registry.phpOverride(for: id)) == nil,
                  (try? await registry.linkedProject(id: id)) != nil else { continue }
            for target in report.routeTargets where target.disposition != .satisfied {
                guard target.disposition == .actionable || target.disposition == .pending,
                      let socket = target.desiredSocket, let repository = routeRepository else {
                    failures.append("\(project.name): \(target.reason ?? "PHP route target cannot be reconciled")")
                    continue
                }
                do {
                    if target.persistedSocket != socket {
                        let transition = try repository.persistFastCGITargetTransition(id: target.routeID, projectID: id.rawValue, expectedSocket: target.persistedSocket, desiredSocket: socket)
                        routeIntents[target.routeID] = transition.intent
                    }
                    changed.append((project, target.routeID))
                } catch { failures.append("\(project.name): \(error.localizedDescription)") }
            }
        }
        let planned = ContinuousClock.now
        if !changed.isEmpty {
            var routingFailed = false
            do { try await router.reconcile(routes: routeIntents.values.map(\.route)) }
            catch { failures.append("Routing: \(error.localizedDescription)"); routingFailed = true }
            guard let verifiedObservations = try? await collectProjectReportObservations() else {
                failures.append("Routing: Vaelen could not verify the applied routes; retry the update")
                return false
            }
            for project in inheritedProjects where !routingFailed && changed.contains(where: { $0.0.id == project.id }) {
                guard let report = try? await projectEnvironmentReport(for: project, observations: verifiedObservations) else {
                    failures.append("\(project.name): Vaelen could not verify this project's route after the update")
                    continue
                }
                for (owner, routeID) in changed where owner.id == project.id {
                    if report.routeTargets.first(where: { $0.routeID == routeID })?.disposition != .satisfied {
                        failures.append("\(project.name): route \(routeID) is still pending; retry after resolving routing health")
                    }
                }
            }
        }
        let finished = ContinuousClock.now
        let failureCount = failures.count
        logger.info("PHP inherited-route convergence projects=\(inheritedProjects.count, privacy: .public) scan_ms=\(self.timingMilliseconds(reconcileStarted.duration(to: scanFinished)), privacy: .public) planning_ms=\(self.timingMilliseconds(scanFinished.duration(to: planned)), privacy: .public) apply_verify_ms=\(self.timingMilliseconds(planned.duration(to: finished)), privacy: .public) failures=\(failureCount, privacy: .public)")
        return failures.isEmpty
    }

    /// Post-update convergence: persist the new start intent and converge
    /// inherited routes, reporting partial success when a step fails after the
    /// replacement is already installed.
    /// The full update inside one reservation: package work with its operation
    /// held open, then convergence, then a single terminal operation state.
    private func performPHPUpdate(module: PHPModule, params: PHPVersionRequest) async throws -> PHPUpdateResult {
        _ = try? await Task.detached { try module.refreshCatalogIfNeeded() }.value
        // Dependency pre-check before any mutation: an exact-version project pin
        // or a persisted route that the update cannot move must refuse the update
        // with specifics, never silently migrate pins or strand routes.
        try await refusePinnedOrServingUpdateSource(module: module, params: params)
        let outcome = try await Task.detached { try module.update(requestedVersion: params.version, sourceVersion: params.sourceVersion, holdOpenOnSuccess: true) }.value
        // Convergence: persist the new start intent, converge inherited
        // routes, and report partial success honestly.
        let convergence = await convergeAfterPHPUpdate(outcome: outcome, module: module)
        return PHPUpdateResult(outcome: outcome, convergence: convergence.converged, convergenceError: convergence.failure)
    }

    /// Refuse an update whose source is still required, before anything mutates.
    ///
    /// Exact-version pins are never migrated by an update: the user migrates
    /// projects explicitly. Routes the update cannot move — orphaned intents, or
    /// intents of pinned projects — must not be left dialling a removed runtime.
    /// Associated routes of unpinned projects converge onto the replacement
    /// during the update, so they are not blockers.
    private func refusePinnedOrServingUpdateSource(module: PHPModule, params: PHPVersionRequest) async throws {
        guard let source = try? module.updateSourceCandidate(target: params.version, sourceVersion: params.sourceVersion) else { return }
        let overrides = (try? await registry.phpOverrides()) ?? [:]
        if !overrides.isEmpty {
            let projects = (try? await registry.linkedProjects()) ?? []
            let pinned = overrides.compactMap { (id, version) -> String? in
                guard version == source.version else { return nil }
                return projects.first { $0.id == id }?.name ?? id.rawValue.uuidString
            }.sorted()
            if !pinned.isEmpty {
                throw PHPModuleError.invalidUpdateSource("PHP \(source.version) cannot be updated because explicitly pinned projects still require it: \(pinned.joined(separator: ", ")). Change those projects to PHP \(params.version) or the default first, then update again.")
            }
        }
        // Routes that would still dial the source after the update: orphaned
        // intents no project owns, which convergence cannot move.
        let sourceSocket = (try? module.status(requestedVersion: source.version))?.socket
        if let sourceSocket {
            let expected = URL(fileURLWithPath: sourceSocket).standardizedFileURL.path
            let stranded = routeIntents.values.compactMap { intent -> String? in
                guard case .fastCGI(let socket, _) = intent.route.target,
                      URL(fileURLWithPath: socket).standardizedFileURL.path == expected,
                      intent.projectID == nil
                else { return nil }
                return intent.route.hostname
            }.sorted()
            if !stranded.isEmpty {
                throw PHPModuleError.invalidUpdateSource("PHP \(source.version) cannot be updated because routes with no owning project still dial it: \(stranded.joined(separator: ", ")). Associate or remove those routes first, then update again.")
            }
        }
    }

    private func convergeAfterPHPUpdate(outcome: PHPUpdateOutcome, module: PHPModule) async -> (converged: [String], failure: String?) {
        // The package is installed; follow-up work now owns the operation until
        // it is reported complete or partial.
        module.beginPostInstallConvergence(targetVersion: outcome.version)
        var converged: [String] = []
        var failures: [String] = []
        // The replacement inherits the replaced runtime's start intent only when
        // that runtime was meant to be running.
        if outcome.wasRunning || outcome.isRunning {
            do { try serviceIntents.set("php:\(outcome.version)", enabled: true); converged.append("intents") }
            catch { failures.append("start intent: \(error.localizedDescription)") }
        }
        // Convergence must be verified, not assumed. Ask for the inherited-route pass
        // and only claim success when it reports no unresolved project.
        if outcome.isDefault {
            await reconcileInheritedPHPRoutes(failures: &failures)
            if failures.isEmpty { converged.append("routes") }
        }
        var failure = failures.isEmpty ? nil : failures.joined(separator: "; ")
        if failure != nil {
            logger.warning("PHP \(outcome.version, privacy: .public) installed but convergence reported: \(failure!, privacy: .public)")
        }
        // Replacement cleanup runs only after verified convergence. The source
        // stays installed while anything is incomplete; nothing is deleted
        // prematurely and complete success is never reported when cleanup failed.
        if failure == nil, let replaced = outcome.replacedVersion {
            do {
                // A pin created mid-update wins over cleanup: keep the runtime
                // rather than strand the project that now requires it.
                let pinnedNow = (try? await registry.phpOverrides())?.values.contains(replaced) ?? false
                guard !pinnedNow else {
                    throw PHPModuleError.invalidUpdateSource("PHP \(replaced) became pinned while updating; it was kept installed.")
                }
                try await Task.detached { try module.stop(requestedVersion: replaced) }.value
                try await Task.detached { try module.removeReplacedRuntime(version: replaced) }.value
                try serviceIntents.set("php:\(replaced)", enabled: false)
                converged.append("cleanup")
            } catch {
                failures.append("cleanup: \(error.localizedDescription)")
                failure = failures.joined(separator: "; ")
                logger.warning("PHP \(outcome.version, privacy: .public) installed but cleanup reported: \(error.localizedDescription, privacy: .public)")
            }
        }
        // One terminal operation state for the whole update: ready only when
        // everything converged, otherwise the specific partial failure.
        module.finishPostInstallConvergence(targetVersion: outcome.version, failure: failure)
        return (converged, failure)
    }

    private func timingMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    public func reconcilePersistedRoutesOnStartup() async throws {
        if (await router.status()).state == .running {
            try await router.reconcile(routes: routeIntents.values.map(\.route))
        }
        _ = try await completeProxyDeletionsIfConverged()
        let summary = try await reconcileParkedProjectRoutes()
        if !summary.conflicts.isEmpty || !summary.issues.isEmpty {
            logger.warning("Startup park route reconciliation reported conflicts/issues: \((summary.conflicts + summary.issues).joined(separator: "; "), privacy: .public)")
        }
        startParkedProjectRouteMonitoring()
    }

    public func reconcileParkedProjectRoutes() async throws -> ParkRouteReconciliationSummary {
        guard let routeRepository else {
            return .init(issues: ["Route persistence is unavailable; parked paths were not reconciled."])
        }
        let parkedPaths = try await registry.parkedPaths()
        let parkedByPath = Dictionary(uniqueKeysWithValues: parkedPaths.map { ($0.rootPath.string, $0) })
        let discovery = ProjectDiscovery()
        let linkedAndDiscovered = try await registry.projectsList()
        var candidates = [ParkedProjectCandidate]()
        var completeParents = Set<String>()
        var recognizedPathsByParent = [String: Set<String>]()
        var issues = [String]()

        for parked in parkedPaths {
            do {
                let discovered = try discovery.discoverDirectChildren(under: parked)
                completeParents.insert(parked.rootPath.string)
                var childPaths = Set<String>()
                for detected in discovered {
                    let project = linkedAndDiscovered.first(where: { $0.rootPath == detected.rootPath }) ?? detected
                    let framework = ProjectFrameworkDetector().inspect(root: URL(fileURLWithPath: project.rootPath.string, isDirectory: true))
                    childPaths.insert(project.rootPath.string)
                    candidates.append(.init(parentPath: parked.rootPath.string, project: project, framework: framework))
                }
                recognizedPathsByParent[parked.rootPath.string] = childPaths
            } catch {
                // A failed or partial scan is never evidence that prior children
                // disappeared. Preserve all owned routes for this parent.
                issues.append("Could not completely scan \(parked.rootPath.string); its park-owned routes were left unchanged: \(error)")
                logger.error("Parked project scan failed for \(parked.rootPath.string, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        let ownerships = try routeRepository.parkRouteOwnerships()
        var staleOwnerships = [ParkRouteOwnership]()
        for ownership in ownerships {
            let parentIsParked = parkedByPath[ownership.parentPath] != nil
            if parentIsParked && !completeParents.contains(ownership.parentPath) { continue }
            let childStillRecognized = recognizedPathsByParent[ownership.parentPath]?.contains(ownership.childPath) == true
            if !parentIsParked || !childStillRecognized {
                staleOwnerships.append(ownership)
            }
        }

        // Existing explicit routes are never adopted. Existing park-owned routes
        // are also left byte-for-byte intact, including their TLS mode.
        let currentRoutes = routeIntents.values.sorted { $0.route.hostname < $1.route.hostname }
        let staleIDs = Set(staleOwnerships.map(\.routeID))
        var ownershipByChild = Dictionary(grouping: ownerships, by: { "\($0.parentPath)\u{0}\($0.childPath)" })
        var additions = [RouteIntent]()
        var addedHosts = [String]()
        var conflicts = [String]()
        let candidateGroups = Dictionary(grouping: candidates, by: { $0.hostname.lowercased() })

        func documentRoot(of route: Route) -> String? {
            switch route.target {
            case .fastCGI(_, let root), .staticFiles(let root): return URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
            case .http: return nil
            }
        }
        func routesForChild(_ candidate: ParkedProjectCandidate) -> [RouteIntent] {
            return currentRoutes.filter { intent in
                if let id = candidate.project.id?.rawValue, intent.projectID == id { return true }
                if let path = intent.projectPath,
                   URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == candidate.childPath { return true }
                // A matching document root is not route ownership. Explicit or
                // legacy routes without project metadata must remain independent;
                // hostname collision handling below leaves them untouched.
                return false
            }
        }

        for (hostKey, group) in candidateGroups.sorted(by: { $0.key < $1.key }) {
            let currentOwners = group.compactMap { candidate in
                ownershipByChild["\(candidate.parentPath)\u{0}\(candidate.childPath)"]?.first
            }.filter { !staleIDs.contains($0.routeID) && routeIntents[$0.routeID] != nil }
            let explicitRoutes = group.flatMap(routesForChild)
            let hasExistingHost = currentRoutes.contains { $0.route.hostname.lowercased() == hostKey && !staleIDs.contains($0.route.id) }
            let existingClaim = !currentOwners.isEmpty || !explicitRoutes.isEmpty || hasExistingHost

            if group.count > 1 && !existingClaim {
                let locations = group.map { $0.childPath }.sorted().joined(separator: ", ")
                conflicts.append("\(hostKey) is requested by multiple parked children (\(locations)); all new claims were skipped.")
                continue
            }

            for candidate in group {
                let key = "\(candidate.parentPath)\u{0}\(candidate.childPath)"
                let childOwners = ownershipByChild[key] ?? []
                if let owner = childOwners.first(where: { !staleIDs.contains($0.routeID) }), routeIntents[owner.routeID] != nil {
                    continue
                }
                if !routesForChild(candidate).isEmpty { continue }
                if group.count == 1,
                   let relativeRoot = candidate.framework.suggestedDocumentRoot,
                   let existingForHost = currentRoutes.first(where: { $0.route.hostname.caseInsensitiveCompare(candidate.hostname) == .orderedSame }),
                   let existingRoot = documentRoot(of: existingForHost.route) {
                    let expectedRoot = URL(fileURLWithPath: candidate.childPath)
                        .appendingPathComponent(relativeRoot)
                        .standardizedFileURL.resolvingSymlinksInPath().path
                    // An exact hostname+document-root route already serves this
                    // child. Preserve it as explicit/legacy state; do not claim
                    // park ownership or warn as if it belonged elsewhere.
                    if existingRoot == expectedRoot { continue }
                }
                if group.count > 1 {
                    conflicts.append("\(candidate.hostname) for \(candidate.childPath) conflicts with another parked child; skipped.")
                    continue
                }
                if let routeConflict = currentRoutes.first(where: { $0.route.hostname.caseInsensitiveCompare(candidate.hostname) == .orderedSame && !staleIDs.contains($0.route.id) }) {
                    let ownerPath = routeConflict.projectPath ?? documentRoot(of: routeConflict.route) ?? "an existing route"
                    conflicts.append("\(candidate.hostname) for \(candidate.childPath) is already routed to \(ownerPath); skipped without changing that route.")
                    continue
                }
                guard let relativeRoot = candidate.framework.suggestedDocumentRoot else {
                    issues.append("\(candidate.childPath) is recognized as \(candidate.framework.framework), but has no supported document-root plan; no route was created.")
                    continue
                }
                let documentRoot = URL(fileURLWithPath: candidate.childPath).appendingPathComponent(relativeRoot).standardizedFileURL.path
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: documentRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
                    issues.append("The planned document root for \(candidate.childPath) is unavailable (\(documentRoot)); no route was created.")
                    continue
                }
                let frameworkName = candidate.framework.framework.lowercased()
                let target: RouteTarget
                if candidate.framework.composerPHPRequirement != nil || frameworkName.contains("php") || frameworkName.contains("laravel") || frameworkName.contains("wordpress") {
                    let report = try await projectEnvironmentReport(for: candidate.project)
                    guard report.observed.php.fpmHealth == "healthy", let socket = report.observed.php.fpmSocket else {
                        issues.append("PHP for \(candidate.childPath) is not healthy/available; no route was created.")
                        continue
                    }
                    target = .fastCGI(socketPath: socket, documentRoot: documentRoot)
                } else {
                    target = .staticFiles(documentRoot: documentRoot)
                }
                let validated: Route
                do { validated = try Route(hostname: candidate.hostname, target: target, tls: .disabled).validated() }
                catch {
                    conflicts.append("\(candidate.hostname) is not a valid host for \(candidate.childPath); skipped: \(error)")
                    continue
                }
                let intent = RouteIntent(route: validated, projectID: nil, projectPath: candidate.childPath)
                additions.append(intent)
                addedHosts.append(validated.hostname)
            }
        }

        // Persist new ownership before provider application so a Core crash can
        // recover and reconcile the exact route on startup.
        for intent in additions {
            guard let candidate = candidates.first(where: { $0.hostname.caseInsensitiveCompare(intent.route.hostname) == .orderedSame && routesForChild($0).isEmpty }) else { continue }
            do {
                try routeRepository.insertParkOwnedRoute(intent, parentPath: candidate.parentPath, childPath: candidate.childPath)
                routeIntents[intent.route.id] = intent
                ownershipByChild["\(candidate.parentPath)\u{0}\(candidate.childPath)"] = [.init(routeID: intent.route.id, parentPath: candidate.parentPath, childPath: candidate.childPath)]
            } catch {
                issues.append("Could not persist park ownership for \(intent.route.hostname): \(error)")
                addedHosts.removeAll(where: { $0 == intent.route.hostname })
            }
        }

        let removableOwnerships = staleOwnerships.filter { ownership in
            guard let current = routeIntents[ownership.routeID] else { return true }
            return current.projectID == nil && current.projectPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) == Optional(ownership.childPath)
        }
        let desiredRoutes = routeIntents.values.filter { !Set(removableOwnerships.map(\.routeID)).contains($0.route.id) }.map(\.route)
        var providerReady = false
        let routerStatus = await router.status()
        if routerStatus.state == .running, routerStatus.health == .healthy {
            do {
                let observed = try await router.observedRoutes()
                if observed.sorted(by: { $0.hostname < $1.hostname }) != desiredRoutes.sorted(by: { $0.hostname < $1.hostname }) {
                    try await router.reconcile(routes: desiredRoutes)
                }
                providerReady = true
            } catch {
                issues.append("Park routes are saved, but routing could not apply the current plan: \(error)")
            }
        } else {
            // Desired routes remain durable and will be applied when Caddy starts.
            providerReady = true
            if !additions.isEmpty || !removableOwnerships.isEmpty {
                issues.append("Routing is not healthy; parked route changes are saved for the next router start.")
            }
        }

        var removedHosts = [String]()
        if providerReady, !staleOwnerships.isEmpty {
            do {
                let removed = try routeRepository.removeParkOwnedRoutes(staleOwnerships)
                for intent in removed {
                    routeIntents.removeValue(forKey: intent.route.id)
                    removedHosts.append(intent.route.hostname)
                }
            } catch {
                issues.append("The provider applied stale-route removals but ownership cleanup did not persist; Core will retry: \(error)")
            }
        }
        return .init(added: addedHosts.sorted(), removed: removedHosts.sorted(), conflicts: conflicts.sorted(), issues: issues.sorted())
    }

    public func startParkedProjectRouteMonitoring(intervalSeconds: UInt64 = 5) {
        guard parkRouteMonitorTask == nil else { return }
        parkRouteMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000) }
                catch { break }
                guard let self else { break }
                do {
                    let summary = try await self.reconcileParkedProjectRoutes()
                    if !summary.conflicts.isEmpty || !summary.issues.isEmpty {
                        self.logger.warning("Park route reconciliation reported conflicts/issues: \((summary.conflicts + summary.issues).joined(separator: "; "), privacy: .public)")
                    }
                } catch {
                    self.logger.error("Park route reconciliation failed without deleting existing routes: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func removeParkOwnedRoutes(parentPath: String) async throws -> ParkRouteReconciliationSummary {
        guard let routeRepository else { return .init(issues: ["Route persistence is unavailable; no park routes were removed."]) }
        let ownerships = try routeRepository.parkRouteOwnerships().filter { $0.parentPath == parentPath }
        let removable = ownerships.filter { ownership in
            guard let intent = routeIntents[ownership.routeID] else { return true }
            return intent.projectID == nil && intent.projectPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) == Optional(ownership.childPath)
        }
        let preserved = ownerships.filter { !removable.contains($0) }
        let removeIDs = Set(removable.map(\.routeID))
        let desiredRoutes = routeIntents.values.filter { !removeIDs.contains($0.route.id) }.map(\.route)
        let status = await router.status()
        if status.state == .running {
            guard status.health == .healthy else { throw IPCErrorPayload(code: .invalidRequest, message: "Unpark was not completed because routing is unhealthy; the parent remains parked and its routes are unchanged.") }
            do { try await router.reconcile(routes: desiredRoutes) }
            catch { throw IPCErrorPayload(code: .invalidRequest, message: "Unpark was not completed because owned routes could not be removed: \(error). The parent remains parked.") }
        }
        // Do not relinquish ownership until provider changes have succeeded.
        // If unpark fails, retry/restart must still know which routes belong to
        // this parent.
        for ownership in preserved { try routeRepository.removeParkOwnership(routeID: ownership.routeID) }
        let removed = try routeRepository.removeParkOwnedRoutes(removable)
        for intent in removed { routeIntents.removeValue(forKey: intent.route.id) }
        return .init(removed: removed.map(\.route.hostname).sorted())
    }

    private func refreshParkRouteMonitor() async {
        parkRouteMonitorTask?.cancel()
        parkRouteMonitorTask = nil
        startParkedProjectRouteMonitoring()
    }

    /// Kick off one restoration pass without holding up the Core IPC actor.
    /// Providers continue to report observed state; saved choices are never
    /// treated as proof that a service is running.
    public func restoreServicesOnStartup() {
        guard !restorationStarted else { return }
        restorationStarted = true
        let intents = serviceIntents
        let php = self.php, mysql = self.mysql, mailpit = self.mailpit
        let router = self.router, dns = self.dns, ports = self.ports
        let projectServices = self.projectServiceBindings
        let routes = routeIntents.values.map(\.route)
        restorationTask = Task.detached { [weak self] in
            // An overdue PHP provider check runs once on startup so a machine
            // that was asleep or off when the twelve-hour interval elapsed still
            // discovers newly published patches. It never blocks the interface:
            // every request is already serviceable from the last usable catalog,
            // and a failure simply leaves availability as cached.
            if let php {
                try? await Task.detached { try php.refreshCatalogIfNeeded() }.value
            }
            let enabled: Set<String>
            do { enabled = try intents.enabledServices() }
            catch {
                enabled = []
                Logger(subsystem: "dev.vaelen.daemon", category: "service-restoration").error("Saved service intents could not be read; project-owned service recovery will still run.")
            }
            func note(_ service: String, _ operation: () async throws -> Void) async {
                do {
                    try await operation()
                    try? intents.clearFailure(service)
                } catch {
                    let detail: String
                    if let error = error as? DNSCapabilityError {
                        switch error {
                        case .externalConflict: detail = "An external /etc/resolver/test file exists; it was left unchanged."
                        case .ownershipMismatch: detail = "The resolver no longer matches Vaelen's saved preimage; it was left unchanged."
                        case .privilegeUnavailable: detail = "macOS authorization for resolver changes is unavailable."
                        case .authorizationRequired(let message): detail = "Resolver authorization failed: \(message)"
                        case .responderUnverified(let message), .responderShutdownFailed(let message), .ownershipUncertain(let message), .resolverConflict(let message), .processFailed(let message): detail = message
                        case .invalidPort(let port): detail = "DNS port \(port) is invalid."
                        }
                    } else if let error = error as? StandardPortsError {
                        switch error {
                        case .helperUnavailable: detail = "Standard Ports require approval in Vaelen.app."
                        case .authorizationRequired(let message): detail = "PF authorization failed: \(message)"
                        case .externalConflict(let message): detail = "External PF/port conflict: \(message)"
                        case .ownershipMismatch: detail = "PF ownership no longer matches Vaelen's saved record; external rules were left unchanged."
                        case .incomplete(let message): detail = "Vaelen's PF integration is incomplete and cannot be repaired automatically: \(message)"
                        case .backendUnavailable: detail = "Caddy must be healthy before Standard Ports can be enabled."
                        case .unavailable(let message): detail = message
                        }
                    } else { detail = String(describing: error) }
                    try? intents.setFailure(service, detail: detail)
                    Logger(subsystem: "dev.vaelen.daemon", category: "service-restoration").error("Saved \(service, privacy: .public) service could not start: \(detail, privacy: .public)")
                }
            }
            // Restore local services before the router; PF forwarding is last
            // because it requires a healthy Caddy backend.
            for item in enabled.sorted() where item.hasPrefix("php:") {
                guard !Task.isCancelled else { return }
                let version = String(item.dropFirst(4))
                if let php { await note(item) { _ = try php.start(requestedVersion: version) } }
            }
            guard !Task.isCancelled else { return }
            if enabled.contains("mysql"), let mysql { await note("mysql") { _ = try mysql.start() } }
            guard !Task.isCancelled else { return }
            if enabled.contains("mailpit"), let mailpit { await note("mailpit") { _ = try mailpit.start() } }
            guard !Task.isCancelled else { return }
            do {
                let failures = try projectServices.recoverClaimedInstances()
                let failedKeys = Set(failures.map(\.serviceKey))
                for failure in failures {
                    try? intents.setFailure(failure.serviceKey, detail: failure.detail)
                    Logger(subsystem: "dev.vaelen.daemon", category: "service-restoration").error("Claimed project service recovery failed for \(failure.serviceKey, privacy: .public).")
                }
                let inventory = try projectServices.inventorySnapshot()
                let claimedKeys = Set(inventory.entries.flatMap { entry in
                    entry.claims.compactMap { claim -> String? in
                        guard case .project(_, let binding) = claim else { return nil }
                        return "project-service.\(binding.kind.rawValue).\(binding.instance.value)"
                    }
                })
                for key in claimedKeys.subtracting(failedKeys) { try? intents.clearFailure(key) }
                for key in intents.failures().keys where key.hasPrefix("project-service.") && !claimedKeys.contains(key) {
                    try? intents.clearFailure(key)
                }
                try? intents.clearFailure("project-service-inventory")
            } catch {
                let key = "project-service-inventory"
                try? intents.setFailure(key, detail: "Project service claims could not be read during startup recovery.")
                Logger(subsystem: "dev.vaelen.daemon", category: "service-restoration").error("Project service claims could not be read during startup recovery.")
            }
            guard !Task.isCancelled else { return }
            if enabled.contains("caddy") {
                await note("caddy") { try await router.start(); try await router.reconcile(routes: routes) }
            }
            guard !Task.isCancelled else { return }
            if enabled.contains("dns") { await note("dns") { _ = try await dns.install() } }
            guard !Task.isCancelled else { return }
            if enabled.contains("standard-ports") { await note("standard-ports") { _ = try await ports.install() } }
            if let self { _ = try? await self.completeProxyDeletionsIfConverged() }
        }
    }

    public func shouldExitAfterShutdownResponse() -> Bool {
        shutdownTask != nil && shutdownBegun && !shutdownRunInFlight && lastShutdownResponse != nil
    }

    public func isShutdownInProgress() -> Bool { shutdownBegun }

    private var lastShutdownResponse: CoreShutdownResponse?

    private func performShutdown() async -> CoreShutdownResponse {
        logShutdownTiming("shutdown begin")
        while phpPackageOperationsInFlight > 0 {
            logShutdownTiming("waiting for PHP package operation")
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        while nodeInstallInFlight {
            logShutdownTiming("waiting for Node package installation")
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        parkRouteMonitorTask?.cancel()
        if let parkRouteMonitorTask { await parkRouteMonitorTask.value }
        parkRouteMonitorTask = nil
        restorationTask?.cancel()
        if let restorationTask { await restorationTask.value }
        var outcomes = [CoreShutdownComponentResult]()
        func result(_ name: String, _ body: () throws -> String) {
            do { outcomes.append(.init(component: name, succeeded: true, detail: try body())) }
            catch { outcomes.append(.init(component: name, succeeded: false, detail: String(describing: error))) }
        }

        // Keep every subsystem available until each exact provider stop has
        // returned. Continue after failures so one resistant service does not
        // leave other owned resources running unnecessarily.
        if let php {
            let packages = php.installedVersions()
            if packages.isEmpty { outcomes.append(.init(component: "php-fpm", succeeded: true, detail: "No installed managed PHP runtimes.")) }
            for package in packages {
                logShutdownTiming("PHP \(package.version) begin")
                result("php-fpm \(package.version)") {
                    let status = try php.stop(requestedVersion: package.version)
                    guard status.state == .stopped else { throw NSError(domain: "VaelenShutdown", code: 1, userInfo: [NSLocalizedDescriptionKey: "PHP-FPM reports \(status.health)"]) }
                    return status.health == "stopped" ? "Stopped or already stopped." : "Stopped."
                }
                logShutdownTiming("PHP \(package.version) end")
            }
        } else { outcomes.append(.init(component: "php-fpm", succeeded: true, detail: "PHP provider is not configured.")) }

        if let mysql {
            logShutdownTiming("MySQL begin")
            result("mysql") {
                let status = try mysql.stop()
                guard status.state == .stopped || status.state == .notInstalled else { throw NSError(domain: "VaelenShutdown", code: 2, userInfo: [NSLocalizedDescriptionKey: "MySQL reports \(status.health)"]) }
                return "Stopped or already stopped."
            }
            logShutdownTiming("MySQL end")
        } else { outcomes.append(.init(component: "mysql", succeeded: true, detail: "MySQL provider is not configured.")) }

        if let mailpit {
            logShutdownTiming("Mailpit begin")
            result("mailpit") {
                let status = try mailpit.stop()
                guard status.state == .stopped || status.state == .installed || status.state == .notInstalled else { throw NSError(domain: "VaelenShutdown", code: 3, userInfo: [NSLocalizedDescriptionKey: "Mailpit reports \(status.health)"]) }
                return "Stopped or already stopped."
            }
            logShutdownTiming("Mailpit end")
        } else { outcomes.append(.init(component: "mailpit", succeeded: true, detail: "Mailpit provider is not configured.")) }

        logShutdownTiming("Caddy begin")
        do {
            try await router.stop()
            let status = await router.status()
            guard status.state == .stopped else { throw NSError(domain: "VaelenShutdown", code: 4, userInfo: [NSLocalizedDescriptionKey: "Caddy reports \(status.health)"]) }
            outcomes.append(.init(component: "caddy", succeeded: true, detail: "Stopped or already stopped."))
        } catch { outcomes.append(.init(component: "caddy", succeeded: false, detail: String(describing: error))) }
        logShutdownTiming("Caddy end")

        logShutdownTiming("DNS begin")
        do {
            let status = try await dns.shutdownForQuit()
            let responderState = status.responderState
            let respondersStopped = responderState == .stopped || responderState == .exited
            guard respondersStopped else { throw NSError(domain: "VaelenShutdown", code: 5, userInfo: [NSLocalizedDescriptionKey: "DNS responder remains \(responderState.rawValue); resolver state is \(status.health)"]) }
            outcomes.append(.init(component: "dns", succeeded: true, detail: "Resolver ownership restored where recorded; owned responder is stopped."))
        } catch { outcomes.append(.init(component: "dns", succeeded: false, detail: String(describing: error))) }
        logShutdownTiming("DNS end")

        logShutdownTiming("post-DNS cleanup begin")
        do {
            let status = try await ports.shutdownCleanup()
            outcomes.append(.init(component: "standard-ports-pf", succeeded: true, detail: status.detail ?? (status.state == .absent ? "No Vaelen PF forwarding remains." : "Existing PF state was left unchanged.")))
        } catch { outcomes.append(.init(component: "standard-ports-pf", succeeded: false, detail: String(describing: error))) }
        logShutdownTiming("post-DNS cleanup end")

        let response = CoreShutdownResponse(components: outcomes)
        lastShutdownResponse = response
        shutdownRunInFlight = false
        logShutdownTiming("shutdown response ready")
        return response
    }

    private func logShutdownTiming(_ event: String) {
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        shutdownTimingLogger.notice("SHUTDOWN_TIMING \(event, privacy: .public) epoch=\(timestamp, privacy: .public)")
    }


    private func phpModule() throws -> PHPModule { guard let php else { throw IPCErrorPayload(code: .internalError, message: "PHP distribution manifest is not configured.") }; return php }

    private func map(_ error: PHPModuleError) -> IPCErrorPayload {
        switch error {
        case .invalidWorkingDirectory(let path):
            return .init(code: .invalidRequest, message: "PHP working directory is unavailable: \(path)")
        case .packageMissing(let version):
            return .init(code: .invalidRequest, message: "PHP \(version) is not an installed managed runtime.")
        case .invalidUpdateSource(let reason):
            // The user's selected runtime cannot serve as the update source. Say
            // so precisely rather than substituting a different runtime.
            return .init(code: .invalidRequest, message: "PHP update rejected: \(reason)")
        case .unsupportedVersion(let version):
            return .init(code: .invalidRequest, message: "PHP version \(version) is not supported.")
        case .operationInProgress(let version):
            return .init(code: .invalidRequest, message: "Another PHP operation is in progress for \(version). Please wait and try again.")
        case .cannotRemoveDefaultRuntime(let version):
            return .init(code: .invalidRequest, message: "PHP \(version) is the current default runtime and cannot be removed.")
        case .cannotRemoveActiveRuntime(let version):
            return .init(code: .invalidRequest, message: "PHP \(version) is running and cannot be removed.")
        case .verificationFailed:
            return .init(code: .invalidRequest, message: "PHP package could not be verified. Existing PHP runtimes were not changed.")
        case .manifestUnavailable:
            return .init(code: .invalidRequest, message: "PHP package metadata is unavailable. Installed runtimes remain usable.")
        case .catalogUnavailable(let reason):
            return .init(code: .invalidRequest, message: reason)
        case .invalidManifest:
            return .init(code: .invalidRequest, message: "PHP package metadata is invalid and cannot be installed.")
        case .validationFailed(let detail):
            return .init(code: .invalidRequest, message: detail)
        case .processFailed(let detail):
            return .init(code: .internalError, message: "PHP runtime operation failed: \(detail)")
        case .processIdentityMismatch:
            return .init(code: .invalidRequest, message: "PHP-FPM could not be verified safely; no process was changed.")
        default:
            return .init(code: .internalError, message: "PHP operation could not be completed.")
        }
    }
    private func mysqlModule() throws -> MySQLModule { guard let mysql else { throw IPCErrorPayload(code: .internalError, message: "MySQL module is not configured.") }; return mysql }
    private func mailpitModule() throws -> MailpitModule { guard let mailpit else { throw IPCErrorPayload(code: .internalError, message: "Mailpit module is not configured.") }; return mailpit }

    private func resolveProject(selector: String?, workingDirectory: String) async throws -> Project {
        let projects = try await registry.projectsList()
        let pathService = CanonicalPathService()
        guard let selector, !selector.isEmpty else {
            let current = pathService.canonicalize(workingDirectory).string
            guard let project = projects.first(where: { $0.rootPath.string == current }) else { throw ProjectRegistryError.projectNotFound }
            return project
        }
        if let uuid = UUID(uuidString: selector), let project = projects.first(where: { $0.id?.rawValue == uuid }) { return project }
        if selector.hasPrefix("/") || selector.hasPrefix("~") || selector.contains("/") {
            let path = pathService.canonicalize(selector, relativeTo: workingDirectory).string
            guard let project = projects.first(where: { $0.rootPath.string == path }) else { throw ProjectRegistryError.projectNotFound }
            return project
        }
        let matches = projects.filter { $0.name == selector || $0.id?.description == selector }
        guard matches.count == 1, let project = matches.first else {
            if matches.count > 1 { throw ProjectRegistryError.projectNameAmbiguous }
            throw ProjectRegistryError.projectNotFound
        }
        return project
    }

    private func phpExecutableResolution(workingDirectory: String) async throws -> PHPResolveResult {
        let module = try phpModule()
        let paths = CanonicalPathService()
        let current = paths.canonicalize(workingDirectory).string
        let linked = try await registry.linkedProjects().filter { $0.availability == .available }
        let project = linked
            .filter { candidate in
                let root = candidate.rootPath.string
                return current == root || current.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
            .max { $0.rootPath.string.count < $1.rootPath.string.count }

        let override: String?
        if let project, let id = project.id { override = try await registry.phpOverride(for: id) }
        else { override = nil }
        guard let version = override ?? module.defaultVersion() else {
            throw IPCErrorPayload(code: .invalidRequest, message: "Vaelen has no default PHP runtime. Install and select a PHP version first.")
        }
        guard let observation = module.packageObservations().first(where: { $0.version == version }),
              observation.eligibility == .eligible,
              let package = observation.package,
              FileManager.default.isExecutableFile(atPath: package.cliPath) else {
            throw IPCErrorPayload(code: .invalidRequest, message: "PHP \(version) is selected but its managed executable is unavailable. Repair the runtime in Vaelen and try again.")
        }
        return PHPResolveResult(version: version, cliPath: package.cliPath, projectName: project?.name)
    }

    private func collectProjectReportObservations() async throws -> ProjectReportObservations {
        let phpObservations = php?.packageObservations() ?? []
        let phpPackages = phpObservations.filter { $0.eligibility == .eligible }.compactMap(\.package)
        let phpStatuses = phpPackages.compactMap { try? php?.status(requestedVersion: $0.version) }.compactMap { $0 }
        async let routerStatus = router.status()
        async let observedRoutes = try? await router.observedRoutes()
        async let linkedProjects = registry.linkedProjects()
        async let dnsStatus = dns.status()
        async let tlsStatus = tls.status()
        async let portsStatus = ports.status()
        let routerValue = await routerStatus
        let runtimeRoutesValue = await observedRoutes
        let linkedProjectsValue = try await linkedProjects
        let dnsValue = await dnsStatus
        let portsValue = await portsStatus
        async let phpOverrides = registry.phpOverrides()
        let phpOverridesValue = try await phpOverrides
        let pendingTransitions = try routeRepository?.pendingTransitions() ?? []
        let readiness = projectReadinessTestOverride
        return ProjectReportObservations(
            phpObservations: readiness.map { [.init(package: $0.phpPackage, version: $0.phpPackage.version, eligibility: .eligible)] } ?? phpObservations,
            phpStatuses: readiness.map { [$0.phpStatus] } ?? phpStatuses,
            phpDefault: readiness?.phpPackage.version ?? php?.defaultVersion(),
            routes: routeIntents.values.sorted { $0.route.hostname < $1.route.hostname },
            router: routerValue,
            runtimeRoutes: runtimeRoutesValue,
            linkedProjects: linkedProjectsValue,
            phpOverrides: phpOverridesValue,
            pendingTransitions: pendingTransitions,
            mysql: mysql?.status(),
            mailpit: mailpit?.status(),
            dns: readiness?.dns ?? dnsValue,
            tls: await tlsStatus,
            ports: readiness?.ports ?? portsValue
        )
    }

    private func projectEnvironmentReport(for project: Project) async throws -> ProjectEnvironmentReport {
        try await projectEnvironmentReport(for: project, observations: try await collectProjectReportObservations())
    }

    private func projectEnvironmentReport(for project: Project, observations: ProjectReportObservations) async throws -> ProjectEnvironmentReport {
        let phpObservations = observations.phpObservations
        let phpPackages = phpObservations.filter { $0.eligibility == .eligible }.compactMap(\.package)
        let invalidPHPVersions = phpObservations.filter { $0.eligibility != .eligible }.compactMap(\.version)
        let phpStatuses = observations.phpStatuses
        let routerStatus = observations.router
        let runtimeRoutes = observations.runtimeRoutes
        let linkedProjects = observations.linkedProjects
        let pendingTransitions = observations.pendingTransitions
        let override = project.id.flatMap { observations.phpOverrides[$0] }
        let report = await Task.detached(priority: .utility) {
            ProjectEnvironmentInspector().inspect(
                project: project,
                routes: observations.routes,
                phpPackages: phpPackages,
                phpStatuses: phpStatuses,
                phpDefault: observations.phpDefault,
                phpOverride: override,
                mysql: observations.mysql,
                mailpit: observations.mailpit,
                router: routerStatus,
                dns: observations.dns,
                tls: observations.tls,
                standardPorts: observations.ports,
                invalidPHPVersions: invalidPHPVersions,
                registeredProjects: linkedProjects, runtimeRoutes: runtimeRoutes, pendingTransitions: pendingTransitions
            )
        }.value
        if let routeRepository, let projectID = project.id?.rawValue, runtimeRoutes != nil, routerStatus.state == .running, routerStatus.health == .healthy, report.observed.php.fpmHealth == "healthy", let resolvedVersion = report.observed.php.resolvedVersion, let desiredSocket = report.observed.php.fpmSocket {
            for transition in pendingTransitions where transition.projectID == projectID && transition.desiredSocket == desiredSocket && transition.desiredRoute.target.fastCGISocket == desiredSocket {
                guard linkedProjects.contains(where: { $0.id?.rawValue == projectID }), let target = report.routeTargets.first(where: { $0.routeID == transition.routeID }), target.disposition == .satisfied, target.resolvedPHPVersion == resolvedVersion, let runtime = runtimeRoutes?.first(where: { $0.hostname == transition.desiredRoute.hostname }), (try? routeProviderFingerprint(runtime)) == transition.desiredProviderFingerprint else { continue }
                try routeRepository.completeFastCGITargetTransition(id: transition.routeID, projectID: projectID, desiredRoute: transition.desiredRoute)
            }
        }
        guard let spec = report.projectSpec, spec.version == 2 else { return report }
        let bindings = spec.services.map { binding -> ProjectServiceBindingObservation in
            return (try? projectServiceBindings.observation(binding, projectID: project.id)) ?? ProjectServiceBindingObservation(binding: binding, packageIdentifier: nil, endpoint: nil, dataDirectory: nil, health: "unavailable", claimed: false)
        }
        var nodeState: String?
        var selectedNodeVersion: String?
        if let requirement = spec.node, let projectID = project.id {
            let candidates = NodeRelease.reviewed.map(\.version).filter { $0.description == requirement.value || $0.description.hasPrefix(requirement.value + ".") }.sorted { $0.description > $1.description }
            let records = try await registry.nodeRecords()
            let snapshot = node.validationSnapshot(records: records, including: candidates)
            selectedNodeVersion = candidates.first(where: { (try? snapshot.package($0)) != nil })?.description
            if let selectedNodeVersion, let version = try? NodeVersion(selectedNodeVersion) {
                nodeState = records.first(where: { $0.id == projectID })?.pin == version ? "selected" : "available"
            } else { nodeState = "missing" }
        } else if spec.node != nil {
            nodeState = "unsupported"
        }
        return ProjectEnvironmentReport(identity: report.identity, desired: report.desired, configured: report.configured, observed: report.observed, derived: report.derived, secret: report.secret, diagnostics: report.diagnostics, routeTargets: report.routeTargets, projectSpec: report.projectSpec, serviceBindings: bindings, nodeRequirementState: nodeState, nodeRequirementVersion: selectedNodeVersion)
    }

    private func assessedServiceInstanceInventory() throws -> ServiceInstanceInventorySnapshot {
        try projectServiceBindings.inventorySnapshot()
    }

    private func assessedHealth(for record: ServiceInstanceRecord) -> String {
        projectServiceBindings.assessedHealth(for: record)
    }

    private func bindingEligible(record: ServiceInstanceRecord, health: String) -> Bool {
        projectServiceBindings.isEligible(record: record, health: health)
    }

    private func projectPHPSelection(_ project: Project) async throws -> ProjectPHPSelection {
        let report = try await projectEnvironmentReport(for: project)
        return projectPHPSelection(project, observed: report.observed.php)
    }

    private func nodeCommand(_ request: NodeCommandRequest) async throws -> NodeCommandSnapshot {
        var installed: NodePackageIdentity?
        switch request.action {
        case .install:
            guard let version = request.version, request.selector == nil else { throw IPCErrorPayload(code: .invalidRequest, message: "Node install requires one exact version.") }
            guard !nodeInstallInFlight else { throw IPCErrorPayload(code: .invalidRequest, message: "A Node installation is already in progress.") }
            nodeInstallInFlight = true
            defer { nodeInstallInFlight = false }
            let manager = node
            installed = try await Task.detached { try manager.install(version) }.value
        case .isolate, .useDefault:
            guard (request.action == .isolate) == (request.version != nil) else { throw IPCErrorPayload(code: .invalidRequest, message: "Choose an exact Node version or Use Default.") }
        case .list, .isolated:
            guard request.version == nil, request.selector == nil else { throw IPCErrorPayload(code: .invalidRequest, message: "Node listing does not take a project or version.") }
        }
        let records = try await registry.nodeRecords()
        let manager = node
        let validation = await Task.detached {
            manager.validationSnapshot(records: records, including: request.version.map { [$0] } ?? [])
        }.value
        var responseRecords = records
        if request.action == .isolate || request.action == .useDefault {
            let projectID: ProjectID
            if let selector = request.selector {
                let project = try await resolveProject(selector: selector, workingDirectory: request.workingDirectory)
                guard project.registrationKind == .linked, let id = project.id else { throw ProjectRegistryError.projectNotFound }
                projectID = id
            } else {
                guard let project = NodeProjectBoundary.select(records, workingDirectory: request.workingDirectory) else { throw ProjectRegistryError.projectNotFound }
                projectID = project.id
            }
            if let version = request.version { _ = try validation.package(version) }
            try await registry.setNodeOverride(request.version, for: projectID)
            responseRecords = records.map { record in
                record.id == projectID ? NodeProjectRecord(id: record.id, name: record.name, path: record.path, pin: request.version) : record
            }
        }
        let selectedRecords = responseRecords
        var selections = await Task.detached { validation.selections(selectedRecords) }.value
        if request.action == .isolated { selections = selections.filter { $0.pinnedVersion != nil } }
        let installedPackages = NodeRelease.reviewed.compactMap { try? validation.package($0.version) }
        return .init(releases: NodeRelease.reviewed, selections: selections, installedPackages: installedPackages, installedPackage: installed)
    }

    private func projectPHPSelection(_ project: Project, observed: ProjectObservedPHP) -> ProjectPHPSelection {
        .init(project: .init(project), overrideVersion: observed.overrideVersion, defaultVersion: observed.defaultVersion, effectiveVersion: observed.resolvedVersion, observedVersion: observed.resolvedState == PHPFPMState.running.rawValue ? observed.resolvedVersion : nil, available: observed.resolutionState == .resolved)
    }

    private func phpCatalog(_ module: PHPModule) async throws -> PHPRuntimeCatalog {
        let catalog = try module.runtimeCatalog()
        let projects = try await registry.linkedProjects()
        var usage = Dictionary(uniqueKeysWithValues: catalog.installedVersions.map { ($0.version, PHPProjectUsage(version: $0.version)) })
        for project in projects {
            guard let id = project.id else { continue }
            let override = try await registry.phpOverride(for: id)
            let version = override ?? catalog.defaultVersion
            guard let version, var value = usage[version] else { continue }
            if override == nil { value = PHPProjectUsage(version: version, explicit: value.explicit, inherited: value.inherited + 1) }
            else { value = PHPProjectUsage(version: version, explicit: value.explicit + 1, inherited: value.inherited) }
            usage[version] = value
        }
        return catalog.withProjectUsage(Array(usage.values))
    }

    private func phpConfigurationWire(_ value: PHPConfigurationSnapshot) -> PHPConfigurationResult {
        let defaults = value.defaultSettings
        return PHPConfigurationResult(
            defaultSettings: PHPSettingsValues(uploadLimitMB: defaults.uploadLimitMB, memoryLimitMB: defaults.memoryLimitMB, maxExecutionTimeSeconds: defaults.maxExecutionTimeSeconds, maxInputVariables: defaults.maxInputVariables, postLimitMB: defaults.postLimitMB),
            versions: value.versions.map { item in
                let settings = item.settings
                return PHPVersionConfiguration(version: item.version, settings: PHPSettingsValues(uploadLimitMB: settings.uploadLimitMB, memoryLimitMB: settings.memoryLimitMB, maxExecutionTimeSeconds: settings.maxExecutionTimeSeconds, maxInputVariables: settings.maxInputVariables, postLimitMB: settings.postLimitMB), inheritsDefault: item.inheritsDefault, cliIniPath: item.cliIniPath, fpmIniPath: item.fpmIniPath, fpmConfigurationPath: item.fpmConfigurationPath, fpmRunning: item.fpmRunning)
            },
            directory: value.directory,
            affectedVersions: value.affectedVersions
        )
    }

    private func deactivate(project: Project) async throws -> ProjectReconciliationExecutionResult {
        let planner = ProjectReconciliationPlanner()
        let initial = planner.plan(report: try await projectEnvironmentReport(for: project))
        let fresh = try await projectEnvironmentReport(for: project)
        let finalInitial = planner.plan(report: fresh)
        guard let projectID = project.id else {
            return .init(initialPlan: initial, operations: [.init(operationID: "project.down", state: .failed, message: "Project service claims are unavailable.", verified: false)], finalPlan: finalInitial, state: .failed)
        }
        let summary: ProjectServiceReleaseSummary
        do { summary = try projectServiceBindings.releaseProjectClaims(projectID: projectID) }
        catch { return .init(initialPlan: initial, operations: [.init(operationID: "project.down", state: .failed, message: "Project service claims could not be released: \(error.localizedDescription)", verified: false)], finalPlan: finalInitial, state: .failed) }
        let finalPlan = planner.plan(report: try await projectEnvironmentReport(for: project))
        let state: ProjectReconciliationExecutionState = summary.failed ? (summary.releasedBindingCount > 0 ? .partial : .failed) : .succeeded
        return .init(initialPlan: initial, operations: summary.operations, finalPlan: finalPlan, state: state)
    }

    private func activate(project: Project) async throws -> ProjectReconciliationExecutionResult {
        let planner = ProjectReconciliationPlanner()
        let initialReport = try await projectEnvironmentReport(for: project)
        let initialPlan = planner.plan(report: initialReport)
        let freshReport = try await projectEnvironmentReport(for: project)
        let freshPlan = planner.plan(report: freshReport)
        var results = [ProjectReconciliationOperationResult]()
        var startedMailpit = false
        var startedPHP = false
        var selectedPHPVersion: String?
        var serviceClaimsReconciled = freshReport.projectSpec?.version != 2

        if let projectID = project.id, let spec = freshReport.projectSpec, spec.version == 2,
           projectServiceBindings.isAvailable {
            do {
                try projectServiceBindings.prepareActivation(projectID: projectID, desired: spec.services, observations: freshReport.serviceBindings ?? [])
                serviceClaimsReconciled = true
            } catch {
                results.append(.init(operationID: "service.claims.reconcile", state: .failed, message: "Desired service claims were not reconciled; retired ownership was retained where stop could not be verified: \(error.localizedDescription)", verified: false))
            }
        }

        for operation in freshPlan.operations {
            guard operation.disposition != .satisfied else {
                results.append(.init(operationID: operation.id, state: .satisfied, message: "Already satisfied; no mutation performed.", verified: true))
                continue
            }
            guard operation.disposition == .actionable || operation.disposition == .pending else {
                results.append(.init(operationID: operation.id, state: .blocked, message: operation.reason ?? "Operation is not executable in M8 Slice 1.", verified: false))
                continue
            }
            guard let current = freshPlan.operations.first(where: { $0.id == operation.id }), current.disposition == .actionable || current.disposition == .pending else {
                results.append(.init(operationID: operation.id, state: .skipped, message: "The plan became stale before execution; no mutation performed.", verified: false))
                continue
            }
            switch operation.id {
            case "mailpit.start":
                guard let mailpit else {
                    results.append(.init(operationID: operation.id, state: .failed, message: "Mailpit module is unavailable.", verified: false)); continue
                }
                do {
                    _ = try mailpit.start()
                    startedMailpit = true
                    results.append(.init(operationID: operation.id, state: .succeeded, message: "Mailpit start requested; final health verification follows.", verified: false))
                } catch {
                    results.append(.init(operationID: operation.id, state: .failed, message: "Mailpit start failed; actual state was re-observed.", verified: false))
                }
            case "php.fpm.start":
                guard let php, let version = selectedPHPVersion ?? freshReport.observed.php.resolvedVersion else {
                    results.append(.init(operationID: operation.id, state: .failed, message: "The desired PHP runtime is unavailable at execution time.", verified: false)); continue
                }
                do {
                    _ = try php.start(requestedVersion: version)
                    startedPHP = true
                    results.append(.init(operationID: operation.id, state: .succeeded, message: "PHP-FPM start requested; final socket and readiness verification follows.", verified: false))
                } catch {
                    results.append(.init(operationID: operation.id, state: .failed, message: "PHP-FPM start failed; actual state was re-observed.", verified: false))
                }
            case "route.create":
                let routeReport = try await projectEnvironmentReport(for: project)
                guard let projectID = project.id, let repository = routeRepository,
                      routeReport.projectSpec == freshReport.projectSpec,
                      let spec = routeReport.projectSpec, spec.version == 2,
                      let web = spec.web, web.createRoute,
                      let host = web.host, let declaredRoot = web.documentRoot, let secure = web.secure,
                      let socket = routeReport.observed.php.fpmSocket,
                      routeReport.observed.php.fpmHealth == "healthy",
                      let absoluteRoot = adoptionDocumentRoot(declaredRoot, projectRoot: project.rootPath.string) else {
                    results.append(.init(operationID: operation.id, state: .blocked, message: "Route creation requires complete explicit web intent, a healthy selected PHP-FPM socket, and a document root within the project.", verified: false)); continue
                }
                guard (try? ProjectWebRequirement(host: host, documentRoot: declaredRoot, secure: secure)) != nil,
                      (try? Route(hostname: host, target: .fastCGI(socketPath: socket, documentRoot: absoluteRoot), tls: secure ? .local : .disabled).validated()) != nil else {
                    results.append(.init(operationID: operation.id, state: .blocked, message: "The declared host or FastCGI route intent is invalid.", verified: false)); continue
                }
                let normalizedHost = host.lowercased()
                let persisted = try repository.all()
                let retryIntent = persisted.first { intent in
                    intent.projectID == projectID.rawValue && intent.projectPath == project.rootPath.string &&
                    intent.route.hostname.lowercased() == normalizedHost && intent.route.target == .fastCGI(socketPath: socket, documentRoot: absoluteRoot) &&
                    intent.route.tls == (secure ? .local : .disabled)
                }
                let retryIsReviewed = retryIntent.map { intent in
                    routeReport.routeTargets.count == 1 && routeReport.routeTargets[0].routeID == intent.route.id &&
                    routeReport.routeTargets[0].providerAgreement == .missing && routeReport.routeTargets[0].associationAuthority == .allowed
                } ?? false
                guard (!routeReport.observed.route.intentExists && routeReport.routeTargets.isEmpty) || retryIsReviewed else {
                    results.append(.init(operationID: operation.id, state: .blocked, message: "An existing route does not match the same reviewed, durably owned project intent; no route was changed.", verified: false)); continue
                }
                let proxies = try localProxyRepository?.list() ?? []
                let observed = try? await router.observedRoutes()
                let retryObservationMatches: (Route) -> Bool = { liveRoute in
                    guard let retryIntent, liveRoute.hostname.lowercased() == normalizedHost,
                          liveRoute.tls == retryIntent.route.tls else { return false }
                    guard case .fastCGI(let expectedSocket, let expectedRoot) = retryIntent.route.target,
                          case .fastCGI(let liveSocket, let liveRoot) = liveRoute.target else { return false }
                    return liveSocket == expectedSocket && liveRoot == expectedRoot
                }
                guard routeIntents.values.allSatisfy({ $0.route.id == retryIntent?.route.id || $0.route.hostname.lowercased() != normalizedHost }),
                      proxies.allSatisfy({ $0.route.hostname.lowercased() != normalizedHost }),
                      observed?.allSatisfy({ $0.hostname.lowercased() != normalizedHost || retryObservationMatches($0) }) == true,
                      let latestProject = try await registry.linkedProject(id: projectID),
                      latestProject.rootPath == project.rootPath,
                      try repository.all().allSatisfy({ $0.route.hostname.lowercased() != normalizedHost || $0.route.id == retryIntent?.route.id }) else {
                    results.append(.init(operationID: operation.id, state: .blocked, message: "The requested host now has a route, proxy claim, or unavailable live-route evidence; no route was changed.", verified: false)); continue
                }
                do {
                    let dnsStatus: DNSStatus
                    if let readiness = projectReadinessTestOverride { dnsStatus = readiness.dns } else { dnsStatus = await dns.status() }
                    let routerStatus = await router.status()
                    let tlsStatus = secure ? await tls.status() : nil
                    let portsStatus: StandardPortsStatus
                    if let readiness = projectReadinessTestOverride { portsStatus = readiness.ports } else { portsStatus = await ports.status() }
                    guard normalizedHost.hasSuffix(".test"), dnsStatus.health == "healthy",
                          portsStatus.state == .healthy,
                          routerStatus.state == .running, routerStatus.health == .healthy else {
                        results.append(.init(operationID: operation.id, state: .blocked, message: "Local project routes require the .test host namespace, healthy DNS, healthy standard ports, and a healthy router. No route was changed.", verified: false)); continue
                    }
                    if secure && (tlsStatus?.state != .trusted || tlsStatus?.trustObserved != true) {
                        results.append(.init(operationID: operation.id, state: .blocked, message: "Local HTTPS requires an existing trusted Local CA. No route was changed.", verified: false)); continue
                    }
                }
                let latestProxies = try localProxyRepository?.list() ?? []
                let latestLiveRoutes = try await router.observedRoutes()
                let latestPersistedRoutes = try repository.all()
                guard routeIntents.values.allSatisfy({ $0.route.id == retryIntent?.route.id || $0.route.hostname.lowercased() != normalizedHost }),
                      latestProxies.allSatisfy({ $0.route.hostname.lowercased() != normalizedHost }),
                      latestLiveRoutes.allSatisfy({ $0.hostname.lowercased() != normalizedHost || retryObservationMatches($0) }),
                      latestPersistedRoutes.allSatisfy({ $0.route.hostname.lowercased() != normalizedHost || $0.route.id == retryIntent?.route.id }),
                      let latestProject = try await registry.linkedProject(id: projectID), latestProject.rootPath == project.rootPath else {
                    results.append(.init(operationID: operation.id, state: .blocked, message: "Route ownership, host availability, or linked-project evidence changed before mutation; no route was changed.", verified: false)); continue
                }
                let route = retryIntent?.route ?? Route(hostname: normalizedHost, target: .fastCGI(socketPath: socket, documentRoot: absoluteRoot), tls: secure ? .local : .disabled)
                let intent = RouteIntent(route: route, projectID: projectID.rawValue, projectPath: project.rootPath.string)
                do {
                    if retryIntent == nil { try repository.createIfHostnameAvailable(intent) }
                    routeIntents[route.id] = intent
                    guard (await router.status()).state == .running else { throw RouterError.notRunning }
                    try await router.reconcile(routes: routeIntents.values.map(\.route))
                    let live = try await router.observedRoutes()
                    guard live.contains(where: { observed in
                        guard case .fastCGI(let observedSocket, let observedRoot) = observed.target,
                              case .fastCGI(let expectedSocket, let expectedRoot) = route.target else { return false }
                        return observed.hostname.lowercased() == route.hostname.lowercased() && observedSocket == expectedSocket && observedRoot == expectedRoot && observed.tls == route.tls
                    }), (await router.status()).health == .healthy else { throw RouterError.notRunning }
                    results.append(.init(operationID: operation.id, state: .succeeded, message: "The exact project route was saved and observed live.", verified: true))
                } catch {
                    results.append(.init(operationID: operation.id, state: .failed, message: "The project route intent is retained with durable ownership, but Caddy reconciliation is pending: \(error.localizedDescription)", verified: false))
                }
            case "requirement.php.select":
                let eligibleVersions = php?.packageObservations().filter { $0.eligibility == .eligible && $0.package != nil }.compactMap(\.version) ?? []
                guard let projectID = project.id, let php, let requirement = freshReport.projectSpec?.php,
                      let selected = requirement.resolveInstalledVersion(from: eligibleVersions) else {
                    results.append(.init(operationID: operation.id, state: .blocked, message: "No eligible installed PHP package matches the declared requirement.", verified: false)); continue
                }
                do {
                    try await registry.setPHPOverride(selected, for: projectID)
                    selectedPHPVersion = selected
                    _ = try php.start(requestedVersion: selected)
                    startedPHP = true
                    results.append(.init(operationID: operation.id, state: .succeeded, message: "PHP \(selected) matching the declared requirement was selected and started for this project.", verified: false))
                } catch {
                    results.append(.init(operationID: operation.id, state: .failed, message: "The exact PHP version could not be selected: \(error.localizedDescription)", verified: false))
                }
            case let id where id.hasPrefix("route.php-target.update."):
                continue
            case "requirement.node":
                guard let projectID = project.id, let selectedVersion = freshReport.nodeRequirementVersion, let version = try? NodeVersion(selectedVersion), freshReport.nodeRequirementState == "available" else {
                    results.append(.init(operationID: operation.id, state: .blocked, message: operation.reason ?? "The exact Node runtime is unavailable.", verified: false)); continue
                }
                do {
                    try await registry.setNodeOverride(version, for: projectID)
                    results.append(.init(operationID: operation.id, state: .succeeded, message: "The exact installed Node runtime was selected for this project.", verified: false))
                } catch {
                    results.append(.init(operationID: operation.id, state: .failed, message: "The exact Node runtime could not be selected: \(error.localizedDescription)", verified: false))
                }
            case "route.project-association.attach":
                guard let projectID = project.id, let routeRepository else {
                    results.append(.init(operationID: operation.id, state: .blocked, message: "A unique safely associable durable route could not be verified.", verified: false)); continue
                }
                if let persisted = try? routeRepository.all() { routeIntents = Dictionary(uniqueKeysWithValues: persisted.map { ($0.route.id, $0) }) }
                let currentRouteReport = try await projectEnvironmentReport(for: project)
                let persistedRoutes = try routeRepository.all()
                let candidates = routeIntents.values.filter { $0.route.hostname == currentRouteReport.observed.route.hostname && $0.projectID == nil }
                let persistedHostRoutes = persistedRoutes.filter { $0.route.hostname == currentRouteReport.observed.route.hostname }
                guard candidates.count == 1, let intent = candidates.first,
                      persistedHostRoutes.count == 1,
                      currentRouteReport.observed.route.associationState == .safelyAssociable,
                      currentRouteReport.observed.route.intentExists,
                      currentRouteReport.observed.route.hostname == intent.route.hostname,
                      currentRouteReport.observed.route.documentRoot == routeDocumentRoot(intent.route),
                      currentRouteReport.observed.route.target == routeTargetDescription(intent.route.target),
                      currentRouteReport.observed.route.tls == intent.route.tls,
                      persistedHostRoutes.first == intent,
                      try localProxyRepository?.list().contains(where: { $0.routeID == intent.route.id }) != true else {
                    results.append(.init(operationID: operation.id, state: .blocked, message: "The reviewed route is ambiguous, already owned, or belongs to a local proxy.", verified: false)); continue
                }
                do {
                    try routeRepository.associateMetadata(id: intent.route.id, projectID: projectID.rawValue, projectPath: project.rootPath.string)
                    routeIntents[intent.route.id] = RouteIntent(route: intent.route, projectID: projectID.rawValue, projectPath: project.rootPath.string)
                    results.append(.init(operationID: operation.id, state: .succeeded, message: "The unique reviewed route was durably associated with this project.", verified: true))
                } catch {
                    results.append(.init(operationID: operation.id, state: .failed, message: "The durable route association failed: \(error.localizedDescription)", verified: false))
                }
            case let id where id.hasPrefix("service."):
                guard serviceClaimsReconciled else {
                    results.append(.init(operationID: id, state: .blocked, message: "Service claims were not reconciled after lifecycle preflight.", verified: false)); continue
                }
                guard let projectID = project.id, let binding = freshReport.projectSpec?.services.first(where: { "service.\($0.alias.value)" == id }) else {
                    results.append(.init(operationID: id, state: .blocked, message: operation.reason ?? "This exact service operation is unsupported.", verified: false)); continue
                }
                let instanceID = ServiceInstanceID(kind: binding.kind, name: binding.instance)
                guard let observation = freshReport.serviceBindings?.first(where: { $0.binding.alias == binding.alias }),
                      let record = try projectServiceBindings.record(for: instanceID),
                      let current = freshReport.serviceBindings?.first(where: { $0.binding.alias == binding.alias }), current.binding == binding,
                      current == observation else {
                    results.append(.init(operationID: id, state: .blocked, message: "The exact \(binding.kind.rawValue) catalog observation did not verify before mutation.", verified: false)); continue
                }
                do {
                    try projectServiceBindings.activate(binding, projectID: projectID, record: record, action: operation.action, expected: observation)
                    results.append(.init(operationID: id, state: .succeeded, message: "Exact \(binding.kind.rawValue) instance is claimed and healthy.", verified: true))
                } catch {
                    results.append(.init(operationID: id, state: .failed, message: "\(binding.kind.rawValue) activation failed: \(error.localizedDescription). The project claim was retained for retry.", verified: false))
                }
            default:
                results.append(.init(operationID: operation.id, state: .skipped, message: "This operation is not executable in M9.", verified: false))
            }
        }

        var finalPlan = planner.plan(report: try await projectEnvironmentReport(for: project))
        if startedMailpit, let resultIndex = results.firstIndex(where: { $0.operationID == "mailpit.start" }) {
            let healthy = finalPlan.operations.first(where: { $0.id == "mailpit.start" })?.disposition == .satisfied
            results[resultIndex] = .init(operationID: "mailpit.start", state: healthy ? .succeeded : .failed, message: healthy ? "Mailpit is healthy after activation." : "Mailpit did not verify healthy after activation.", verified: healthy)
        }
        if startedPHP, let resultIndex = results.firstIndex(where: { $0.operationID == "php.fpm.start" }) {
            let healthy = finalPlan.operations.first(where: { $0.id == "php.fpm.start" })?.disposition == .satisfied
            results[resultIndex] = .init(operationID: "php.fpm.start", state: healthy ? .succeeded : .failed, message: healthy ? "PHP-FPM is healthy after activation." : "PHP-FPM did not verify healthy after activation.", verified: healthy)
        }
        for operation in finalPlan.operations where operation.id.hasPrefix("route.php-target.update.") && (operation.disposition == .actionable || operation.disposition == .pending) {
            guard let routeID = UUID(uuidString: String(operation.id.dropFirst("route.php-target.update.".count))), let projectID = project.id else { continue }
            guard let observation = (try await projectEnvironmentReport(for: project)).routeTargets.first(where: { $0.routeID == RouteID(rawValue: routeID) }) else { continue }
            do {
                let result = try await updatePHPTarget(projectID: projectID, routeID: RouteID(rawValue: routeID), expectedCurrentSocket: observation.persistedSocket)
                let state: ProjectReconciliationOperationResultState = result.state == .pending ? .pending : result.state == .satisfied ? .satisfied : .succeeded
                results.append(.init(operationID: operation.id, state: state, message: result.state == .pending ? "Desired route target is persisted; Caddy provider application is pending." : result.state == .satisfied ? "Route target already satisfied; no mutation performed." : "FastCGI route target converged.", verified: result.state != .pending))
            } catch {
                results.append(.init(operationID: operation.id, state: .failed, message: "Route target convergence failed: \(error)", verified: false))
            }
        }
        finalPlan = planner.plan(report: try await projectEnvironmentReport(for: project))
        for index in results.indices where results[index].state == .blocked {
            let operationID = results[index].operationID
            guard operationID.hasPrefix("requirement.web.") || operationID.hasPrefix("route.php-target.update."),
                  finalPlan.operations.first(where: { $0.id == operationID })?.disposition == .satisfied else { continue }
            results[index] = .init(operationID: operationID, state: .satisfied, message: "Final observation proves this route requirement is satisfied.", verified: true)
        }
        let state: ProjectReconciliationExecutionState
        if finalPlan.state == .satisfied && results.allSatisfy({ $0.state == .satisfied || $0.state == .succeeded }) {
            state = .succeeded
        } else if results.contains(where: { $0.state == .succeeded }) {
            state = .partial
        } else if results.contains(where: { $0.state == .failed }) {
            state = .failed
        } else {
            state = .blocked
        }
        return .init(initialPlan: initialPlan, operations: results, finalPlan: finalPlan, state: state)
    }

    private func updatePHPTarget(projectID: ProjectID, routeID: RouteID, expectedCurrentSocket: String) async throws -> RoutePHPTargetUpdateResult {
        guard let repository = routeRepository, let project = try await registry.linkedProject(id: projectID), project.registrationKind == .linked else { throw IPCErrorPayload(code: .invalidRequest, message: "Route target convergence requires a linked project.") }
        let report = try await projectEnvironmentReport(for: project)
        guard let observation = report.routeTargets.first(where: { $0.routeID == routeID }) else { throw IPCErrorPayload(code: .invalidRequest, message: "The route is not an eligible durable FastCGI route for this project.") }
        guard observation.persistedSocket == expectedCurrentSocket else { throw IPCErrorPayload(code: .invalidRequest, message: "The route target plan is stale; the persisted socket changed.") }
        if observation.disposition == .satisfied {
            return .init(observation: observation, state: .satisfied)
        }
        guard observation.disposition == .actionable || observation.disposition == .pending, let desiredSocket = observation.desiredSocket else { throw IPCErrorPayload(code: .invalidRequest, message: observation.reason ?? "Route target convergence is blocked.") }
        let currentIntent = routeIntents[routeID]
        guard currentIntent != nil else { throw IPCErrorPayload(code: .invalidRequest, message: "The route disappeared before target convergence.") }
        if currentIntent?.route.target.fastCGISocket != desiredSocket {
            guard observation.disposition == .actionable else { throw IPCErrorPayload(code: .invalidRequest, message: "The pending transition is not valid for the current route state.") }
            let updated = try repository.persistFastCGITargetTransition(id: routeID, projectID: projectID.rawValue, expectedSocket: observation.persistedSocket, desiredSocket: desiredSocket).intent
            routeIntents[routeID] = updated
        }
        do {
            guard (await router.status()).state == .running, (await router.status()).health == .healthy else { throw RouterError.notRunning }
            try await router.reconcile(routes: routeIntents.values.map(\.route))
            let verifiedReport = try await projectEnvironmentReport(for: project)
            guard let verified = verifiedReport.routeTargets.first(where: { $0.routeID == routeID }), verified.disposition == .satisfied else {
                return .init(observation: verifiedReport.routeTargets.first(where: { $0.routeID == routeID }) ?? observation, state: .pending)
            }
            return .init(observation: verified, state: .updated)
        } catch {
            let pendingReport = try await projectEnvironmentReport(for: project)
            let pendingObservation = pendingReport.routeTargets.first(where: { $0.routeID == routeID }) ?? observation
            return .init(observation: pendingObservation, state: .pending)
        }
    }

    private func map(_ error: MySQLModuleError) -> IPCErrorPayload {
        switch error {
        case .unsupportedVersion, .unsupportedArchitecture, .packageMissing, .notInitialized, .alreadyInitialized, .partialInitialization, .instanceVersionMismatch, .credentialsUnavailable:
            return .init(code: .invalidRequest, message: "MySQL operation rejected: \(error)")
        case .portConflict(let port): return .init(code: .invalidRequest, message: "MySQL port conflict on 127.0.0.1:\(port); external processes were not modified.")
        case .processIdentityMismatch: return .init(code: .invalidRequest, message: "MySQL process identity could not be verified; no process was signaled.")
        default: return .init(code: .internalError, message: "MySQL operation failed: \(error)")
        }
    }

    private func map(_ error: MailpitModuleError) -> IPCErrorPayload {
        switch error {
        case .unsupportedVersion, .packageMissing: return .init(code: .invalidRequest, message: "Mailpit operation rejected: \(error)")
        case .portConflict(let port): return .init(code: .invalidRequest, message: "Mailpit port conflict on 127.0.0.1:\(port); external processes were not modified.")
        case .processIdentityMismatch: return .init(code: .invalidRequest, message: "Mailpit process identity could not be verified; no process was signaled.")
        case .unhealthy(let detail): return .init(code: .invalidRequest, message: "Mailpit is unhealthy: \(detail)")
        default: return .init(code: .internalError, message: "Mailpit operation failed: \(error)")
        }
    }

    private func map(_ error: TLSError) -> IPCErrorPayload {
        switch error {
        case .ownershipMismatch: return .init(code: .tlsIdentityMismatch, message: error.localizedDescription)
        case .keyCertificateMismatch: return .init(code: .tlsKeyCertificateMismatch, message: error.localizedDescription)
        case .trustProvenanceUnavailable: return .init(code: .tlsOwnershipUnavailable, message: error.localizedDescription)
        case .trustSettingsMismatch: return .init(code: .tlsRemovalBlocked, message: error.localizedDescription)
        case .trustSettingsUnsupported: return .init(code: .tlsTrustSettingsUnsupported, message: error.localizedDescription)
        case .trustObservationFailed: return .init(code: .tlsObservationFailed, message: error.localizedDescription)
        case .trustRemovalUnverified, .keychain, .certificate, .unavailable, .unsupportedHostname:
            return .init(code: .tlsTrustOperationFailed, message: error.localizedDescription)
        }
    }

    private func map(_ error: ProjectRegistryError) -> IPCErrorPayload {
        switch error {
        case .pathUnavailable(.notDirectory): return .init(code: .pathNotDirectory, message: "The path is not a directory.")
        case .pathUnavailable(.missing): return .init(code: .pathNotFound, message: "The path does not exist.")
        case .pathUnavailable(.unreadable): return .init(code: .pathUnreadable, message: "The path is not readable.")
        case .pathUnavailable: return .init(code: .pathNotFound, message: "The path is unavailable.")
        case .projectNotFound: return .init(code: .projectNotFound, message: "Project registration was not found.")
        case .projectNameAmbiguous: return .init(code: .projectNameAmbiguous, message: "Project name is ambiguous.")
        case .projectNameConflict: return .init(code: .projectNameConflict, message: "Project name is already in use.")
        case .invalidName: return .init(code: .invalidRequest, message: "Project name is invalid.")
        case .parkedPathNotFound: return .init(code: .parkedPathNotFound, message: "Parked path was not found.")
        }
    }
}
