import Foundation
import OSLog
import VaelenCore
import VaelenIPC

public actor CoreRequestDispatcher {
    private let runtime: CoreRuntime
    private let registry: ProjectRegistry
    private let php: PHPModule?
    private let router: any Router
    private let routeRepository: RouteIntentRepository?
    private let dns: DNSCapability
    private let tls: TLSCapability
    private let ports: StandardPortsCapability
    private var routeIntents: [RouteID: RouteIntent]
    private let logger = Logger(subsystem: "dev.vaelen.daemon", category: "registry")

    public init(runtime: CoreRuntime, registry: ProjectRegistry, php: PHPModule? = nil, router: any Router = InMemoryRouter(), routeRepository: RouteIntentRepository? = nil, dns: DNSCapability = DNSCapability(), tls: TLSCapability = TLSCapability(), ports: StandardPortsCapability = StandardPortsCapability()) {
        self.runtime = runtime; self.registry = registry; self.php = php; self.router = router; self.routeRepository = routeRepository; self.dns = dns; self.tls = tls; self.ports = ports
        self.routeIntents = Dictionary(uniqueKeysWithValues: (try? routeRepository?.all() ?? [])?.map { ($0.route.id, $0) } ?? [])
    }

    public func dispatch(_ request: IPCRequest, handshaken: Bool) async -> (response: IPCResponse, handshaken: Bool) {
        guard request.protocolVersion == ProtocolVersion.v1.rawValue else {
            return (.init(id: request.id, error: .init(code: .protocolIncompatible, message: "Client and Core protocol versions are incompatible.", details: ["clientProtocolVersion": "\(request.protocolVersion)", "coreProtocolVersion": "1"])), handshaken)
        }
        guard let method = request.knownMethod else {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Unknown Core method: \(request.method).")), handshaken)
        }
        if method == .handshake {
            guard let params = request.params, (try? params.decode(HandshakeParams.self)) != nil else {
                return (.init(id: request.id, error: .init(code: .invalidRequest, message: "A valid handshake payload is required.")), false)
            }
            return (.init(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: runtime.status.version))), true)
        }
        guard handshaken else {
            return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Handshake is required before other requests.")), false)
        }
        do {
            switch method {
            case .status:
                return (.init(id: request.id, result: .status(.init(core: runtime.status, protocolVersion: 1))), true)
            case .projectLink:
                let params = try request.params?.decode(LinkProjectRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Link parameters are required.") }()
                let mutation = try await registry.linkWithCreation(path: params.path, workingDirectory: params.workingDirectory, name: params.name)
                let project = mutation.project
                logger.info("Project linked: \(project.rootPath.string, privacy: .public)")
                return (.init(id: request.id, result: .projectMutation(.init(project: .init(project), created: mutation.created))), true)
            case .projectUnlink:
                let params = try request.params?.decode(UnlinkProjectRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Unlink parameters are required.") }()
                if let name = params.name { try await registry.unlink(name: name) }
                else { try await registry.unlink(path: params.path ?? params.workingDirectory, workingDirectory: params.workingDirectory) }
                logger.info("Project unlinked")
                return (.init(id: request.id, result: .projectMutation(.init(project: nil, created: false))), true)
            case .projectLinks:
                return (.init(id: request.id, result: .projectList(.init(projects: try await registry.linkedProjects().map(ProjectWire.init)))), true)
            case .projectList:
                return (.init(id: request.id, result: .projectList(.init(projects: try await registry.projectsList().map(ProjectWire.init)))), true)
            case .pathPark:
                let params = try request.params?.decode(ParkPathRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Park parameters are required.") }()
                let path = try await registry.parkWithCreation(path: params.path, workingDirectory: params.workingDirectory)
                logger.info("Path parked: \(path.path.rootPath.string, privacy: .public)")
                return (.init(id: request.id, result: .parkedPathMutation(.init(path: .init(path.path), created: path.created))), true)
            case .pathUnpark:
                let params = try request.params?.decode(UnparkPathRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Unpark parameters are required.") }()
                try await registry.unpark(path: params.path, workingDirectory: params.workingDirectory)
                logger.info("Path unparked")
                return (.init(id: request.id, result: .parkedPathMutation(.init(path: nil, created: false))), true)
            case .pathList:
                return (.init(id: request.id, result: .parkedPathList(.init(paths: try await registry.parkedPaths().map(ParkedPathWire.init)))), true)
            case .phpVersions:
                let module = try phpModule(); return (.init(id: request.id, result: .phpVersions(.init(available: try module.availableVersions(), installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpInstall:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); _ = try module.install(requestedVersion: params.version); return (.init(id: request.id, result: .phpVersions(.init(available: try module.availableVersions(), installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpUse:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); _ = try module.setDefault(requestedVersion: params.version); return (.init(id: request.id, result: .phpVersions(.init(available: try module.availableVersions(), installed: module.installedVersions().map(PHPPackageWire.init), default: module.defaultVersion()))), true)
            case .phpExec:
                let module = try phpModule(); let params = try request.params?.decode(PHPExecRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP execution parameters are required.") }(); let result = try module.exec(requestedVersion: params.version, workingDirectory: params.workingDirectory, arguments: params.arguments); return (.init(id: request.id, result: .phpExec(.init(exitStatus: result.status, output: result.output))), true)
            case .phpStart:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); return (.init(id: request.id, result: .phpStatus(.init(status: try module.start(requestedVersion: params.version)))), true)
            case .phpStop:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); return (.init(id: request.id, result: .phpStatus(.init(status: try module.stop(requestedVersion: params.version)))), true)
            case .phpStatus:
                let module = try phpModule(); let params = try request.params?.decode(PHPVersionRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "PHP version is required.") }(); return (.init(id: request.id, result: .phpStatus(.init(status: try module.status(requestedVersion: params.version)))), true)
            case .routingStatus:
                return (.init(id: request.id, result: .routingStatus(.init(router: await router.status()))), true)
            case .routingStart:
                try await router.start(); try await router.reconcile(routes: routeIntents.values.map(\.route)); return (.init(id: request.id, result: .routingStatus(.init(router: await router.status()))), true)
            case .routingStop:
                try await router.stop(); return (.init(id: request.id, result: .routingStatus(.init(router: await router.status()))), true)
            case .routeList:
                return (.init(id: request.id, result: .routeList(.init(routes: routeIntents.values.sorted { $0.route.hostname < $1.route.hostname }))), true)
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
                try repository.upsert(normalized); routeIntents[validated.id] = normalized
                if (await router.status()).state == .running { try await router.reconcile(routes: routeIntents.values.map(\.route)) }
                return (.init(id: request.id, result: .routeMutation(normalized)), true)
            case .routeRemove:
                guard let repository = routeRepository else { throw IPCErrorPayload(code: .internalError, message: "Route persistence is unavailable.") }
                let params = try request.params?.decode(RouteRemoveRequest.self) ?? { throw IPCErrorPayload(code: .invalidRequest, message: "Route ID is required.") }()
                guard routeIntents[params.id] != nil else { throw RouterError.routeNotFound(params.id) }
                try repository.remove(id: params.id); routeIntents.removeValue(forKey: params.id)
                if (await router.status()).state == .running { try await router.reconcile(routes: routeIntents.values.map(\.route)) }
                return (.init(id: request.id, result: .routeList(.init(routes: routeIntents.values.sorted { $0.route.hostname < $1.route.hostname }))), true)
            case .dnsStatus:
                return (.init(id: request.id, result: .dnsStatus(.init(dns: await dns.status()))), true)
            case .dnsInstall:
                let params = try request.params?.decode(DNSInstallRequest.self) ?? .init()
                return (.init(id: request.id, result: .dnsStatus(.init(dns: try await dns.install(takeover: params.takeover)))), true)
            case .dnsRemove:
                return (.init(id: request.id, result: .dnsStatus(.init(dns: try await dns.remove()))), true)
            case .tlsStatus:
                return (.init(id: request.id, result: .tlsStatus(.init(tls: await tls.status()))), true)
            case .tlsInstall:
                return (.init(id: request.id, result: .tlsStatus(.init(tls: try await tls.install()))), true)
            case .tlsRemove:
                return (.init(id: request.id, result: .tlsStatus(.init(tls: try await tls.remove()))), true)
            case .portsStatus:
                return (.init(id: request.id, result: .portsStatus(.init(ports: await ports.status()))), true)
            case .portsInstall:
                return (.init(id: request.id, result: .portsStatus(.init(ports: try await ports.install()))), true)
            case .portsRemove:
                return (.init(id: request.id, result: .portsStatus(.init(ports: try await ports.remove()))), true)
            case .handshake:
                fatalError("handled above")
            }
        } catch let error as PHPModuleError {
            switch error {
            case .invalidWorkingDirectory(let path): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "PHP working directory is unavailable: \(path)")), true)
            default: return (.init(id: request.id, error: .init(code: .internalError, message: "PHP operation failed: \(error)")), true)
            }
        } catch let error as ProjectRegistryError {
            return (.init(id: request.id, error: map(error)), true)
        } catch let error as IPCErrorPayload {
            return (.init(id: request.id, error: error), true)
        } catch let error as StandardPortsError {
            switch error {
            case .helperUnavailable: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Local Ports require approval in Vaelen.app.")), true)
            case .authorizationRequired(let detail): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports authorization failed: \(detail)")), true)
            case .externalConflict(let detail): return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports conflict: \(detail)")), true)
            case .ownershipMismatch: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports ownership mismatch: external state changed.")), true)
            case .backendUnavailable: return (.init(id: request.id, error: .init(code: .invalidRequest, message: "Standard Ports require the backend router to be running.")), true)
            case .unavailable(let detail): return (.init(id: request.id, error: .init(code: .internalError, message: "Standard Ports are unavailable: \(detail)")), true)
            }
        } catch {
            logger.error("Registry operation failed: \(String(describing: error), privacy: .public)")
            return (.init(id: request.id, error: .init(code: .internalError, message: "Core operation failed: \(error)")), true)
        }
    }

    public func reconcilePersistedRoutesOnStartup() async throws {
        guard (await router.status()).state == .running else { return }
        try await router.reconcile(routes: routeIntents.values.map(\.route))
    }

    private func phpModule() throws -> PHPModule { guard let php else { throw IPCErrorPayload(code: .internalError, message: "PHP distribution manifest is not configured.") }; return php }

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
