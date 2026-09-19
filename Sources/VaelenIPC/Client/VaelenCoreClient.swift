import Foundation
import VaelenCore

public enum CoreClientError: Error, Equatable, Sendable {
    case coreUnavailable
    case protocolIncompatible(client: Int, core: Int)
    case coreIncompatible(reason: String)
    case invalidResponse
    case remote(IPCErrorPayload)
}

public actor VaelenCoreClient {
    private let transport: any CoreTransport
    private let identity: ClientIdentity
    private var decoder = FrameDecoder()
    private var connected = false

    public init(transport: any CoreTransport, identity: ClientIdentity) {
        self.transport = transport
        self.identity = identity
    }

    public func connect() async throws {
        do {
            try await transport.connect()
            connected = true
            let request = IPCRequest(method: .handshake, params: .handshake(HandshakeParams(client: ClientIdentity(name: identity.name, version: identity.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))))
            let response = try await send(request)
            do {
                guard case .handshake(let result) = try result(from: response) else { throw CoreClientError.coreIncompatible(reason: "The running Vaelen Core returned an incompatible handshake.") }
                guard result.protocolVersion == ProtocolVersion.v1.rawValue else {
                    throw CoreClientError.protocolIncompatible(client: ProtocolVersion.v1.rawValue, core: result.protocolVersion)
                }
                guard result.schemaCompatibilityVersion == VaelenBuildInfo.schemaCompatibilityVersion else {
                    throw CoreClientError.coreIncompatible(reason: "The running Vaelen Core uses an incompatible command schema.")
                }
            } catch let error as CoreClientError {
                switch error {
                case .remote(let payload):
                    if payload.code == .invalidRequest || payload.code == .coreIncompatible {
                        throw CoreClientError.coreIncompatible(reason: "The running Vaelen Core rejected the compatibility handshake.")
                    }
                    throw error
                case .invalidResponse:
                    throw CoreClientError.coreIncompatible(reason: "The running Vaelen Core returned an incompatible handshake.")
                default:
                    throw error
                }
            }
        } catch let error as CoreTransportError {
            await transport.disconnect()
            connected = false
            if case .unavailable = error { throw CoreClientError.coreUnavailable }
            throw error
        } catch {
            await transport.disconnect()
            connected = false
            throw error
        }
    }

    public func status() async throws -> CoreStatusResponse {
        guard connected else { throw CoreClientError.coreUnavailable }
        let response = try await send(IPCRequest(method: .status))
        guard case .status(let status) = try result(from: response) else { throw CoreClientError.invalidResponse }
        return status
    }

    public func link(path: String?, workingDirectory: String, name: String?) async throws -> ProjectMutationResult {
        let request = IPCRequest(method: .projectLink, params: .link(LinkProjectRequest(path: path, workingDirectory: workingDirectory, name: name)))
        guard case .projectMutation(let result) = try result(from: await send(request)) else { throw CoreClientError.invalidResponse }
        return result
    }

    public func unlink(path: String?, name: String?, workingDirectory: String) async throws {
        let request = IPCRequest(method: .projectUnlink, params: .unlink(UnlinkProjectRequest(path: path, name: name, workingDirectory: workingDirectory)))
        guard case .projectMutation = try result(from: await send(request)) else { throw CoreClientError.invalidResponse }
    }

    public func linkedProjects() async throws -> [ProjectWire] {
        let request = IPCRequest(method: .projectLinks, params: .listProjects(.init()))
        guard case .projectList(let result) = try result(from: await send(request)) else { throw CoreClientError.invalidResponse }
        return result.projects
    }

    public func projectList() async throws -> [ProjectWire] {
        let request = IPCRequest(method: .projectList, params: .listProjects(.init()))
        guard case .projectList(let result) = try result(from: await send(request)) else { throw CoreClientError.invalidResponse }
        return result.projects
    }

    public func projectStatus(selector: String?, workingDirectory: String) async throws -> ProjectEnvironmentReport {
        try await projectEnvironment(method: .projectStatus, selector: selector, workingDirectory: workingDirectory)
    }

    public func projectInspect(selector: String?, workingDirectory: String) async throws -> ProjectEnvironmentReport {
        try await projectEnvironment(method: .projectInspect, selector: selector, workingDirectory: workingDirectory)
    }

    public func projectDoctor(selector: String?, workingDirectory: String) async throws -> ProjectEnvironmentReport {
        try await projectEnvironment(method: .projectDoctor, selector: selector, workingDirectory: workingDirectory)
    }

    public func projectPlan(selector: String?, workingDirectory: String) async throws -> ProjectReconciliationPlan {
        guard case .projectPlan(let result) = try result(from: await send(IPCRequest(method: .projectPlan, params: .projectEnvironment(.init(selector: selector, workingDirectory: workingDirectory))))) else { throw CoreClientError.invalidResponse }
        return result.plan
    }

    public func projectActivate(selector: String?, workingDirectory: String) async throws -> ProjectReconciliationExecutionResult {
        guard case .projectActivation(let result) = try result(from: await send(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: selector, workingDirectory: workingDirectory))))) else { throw CoreClientError.invalidResponse }
        return result.execution
    }

    private func projectEnvironment(method: CoreMethod, selector: String?, workingDirectory: String) async throws -> ProjectEnvironmentReport {
        guard case .projectEnvironment(let result) = try result(from: await send(IPCRequest(method: method, params: .projectEnvironment(.init(selector: selector, workingDirectory: workingDirectory))))) else { throw CoreClientError.invalidResponse }
        return result.report
    }

    public func park(path: String?, workingDirectory: String) async throws -> ParkedPathMutationResult {
        let request = IPCRequest(method: .pathPark, params: .park(ParkPathRequest(path: path, workingDirectory: workingDirectory)))
        guard case .parkedPathMutation(let result) = try result(from: await send(request)) else { throw CoreClientError.invalidResponse }
        return result
    }

    public func unpark(path: String?, workingDirectory: String) async throws {
        let request = IPCRequest(method: .pathUnpark, params: .unpark(UnparkPathRequest(path: path, workingDirectory: workingDirectory)))
        guard case .parkedPathMutation = try result(from: await send(request)) else { throw CoreClientError.invalidResponse }
    }

    public func parkedPaths() async throws -> [ParkedPathWire] {
        let request = IPCRequest(method: .pathList, params: .listProjects(.init()))
        guard case .parkedPathList(let result) = try result(from: await send(request)) else { throw CoreClientError.invalidResponse }
        return result.paths
    }

    public func phpVersions() async throws -> PHPVersionsResult {
        guard case .phpVersions(let result) = try result(from: await send(IPCRequest(method: .phpVersions))) else { throw CoreClientError.invalidResponse }; return result
    }
    public func phpInstall(_ version: String) async throws -> PHPPackageWire {
        guard case .phpVersions(let result) = try result(from: await send(IPCRequest(method: .phpInstall, params: .phpVersion(.init(version: version))))) else { throw CoreClientError.invalidResponse }; guard let package = result.installed.first(where: { $0.version == version }) ?? result.installed.last else { throw CoreClientError.invalidResponse }; return package
    }
    public func phpUse(_ version: String) async throws -> PHPPackageWire {
        guard case .phpVersions(let result) = try result(from: await send(IPCRequest(method: .phpUse, params: .phpVersion(.init(version: version))))) else { throw CoreClientError.invalidResponse }; guard let resolved = PHPVersionResolver.resolve(version, versionStrings: result.installed.map(\.version)), let package = result.installed.first(where: { $0.version == resolved }) else { throw CoreClientError.invalidResponse }; return package
    }
    public func phpExec(version: String? = nil, workingDirectory: String, arguments: [String]) async throws -> PHPExecResult {
        guard case .phpExec(let result) = try result(from: await send(IPCRequest(method: .phpExec, params: .phpExec(.init(version: version, workingDirectory: workingDirectory, arguments: arguments))))) else { throw CoreClientError.invalidResponse }; return result
    }
    public func phpStart(_ version: String) async throws -> PHPStatus { guard case .phpStatus(let result) = try result(from: await send(IPCRequest(method: .phpStart, params: .phpVersion(.init(version: version))))) else { throw CoreClientError.invalidResponse }; return result.status }
    public func phpStop(_ version: String) async throws -> PHPStatus { guard case .phpStatus(let result) = try result(from: await send(IPCRequest(method: .phpStop, params: .phpVersion(.init(version: version))))) else { throw CoreClientError.invalidResponse }; return result.status }
    public func phpStatus(_ version: String) async throws -> PHPStatus { guard case .phpStatus(let result) = try result(from: await send(IPCRequest(method: .phpStatus, params: .phpVersion(.init(version: version))))) else { throw CoreClientError.invalidResponse }; return result.status }
    public func mysqlVersions() async throws -> MySQLVersionsPayload { guard case .mysqlVersions(let result) = try result(from: await send(IPCRequest(method: .mysqlVersions))) else { throw CoreClientError.invalidResponse }; return result.mysql }
    public func mysqlInstall(_ version: String) async throws -> MySQLVersionsPayload { guard case .mysqlVersions(let result) = try result(from: await send(IPCRequest(method: .mysqlInstall, params: .phpVersion(.init(version: version))))) else { throw CoreClientError.invalidResponse }; return result.mysql }
    public func mysqlUse(_ version: String) async throws -> MySQLVersionsPayload { guard case .mysqlVersions(let result) = try result(from: await send(IPCRequest(method: .mysqlUse, params: .phpVersion(.init(version: version))))) else { throw CoreClientError.invalidResponse }; return result.mysql }
    public func mysqlInitialize() async throws -> MySQLStatus { guard case .mysqlStatus(let result) = try result(from: await send(IPCRequest(method: .mysqlInitialize))) else { throw CoreClientError.invalidResponse }; return result.mysql }
    public func mysqlStart() async throws -> MySQLStatus { guard case .mysqlStatus(let result) = try result(from: await send(IPCRequest(method: .mysqlStart))) else { throw CoreClientError.invalidResponse }; return result.mysql }
    public func mysqlStop() async throws -> MySQLStatus { guard case .mysqlStatus(let result) = try result(from: await send(IPCRequest(method: .mysqlStop))) else { throw CoreClientError.invalidResponse }; return result.mysql }
    public func mysqlStatus() async throws -> MySQLStatus { guard case .mysqlStatus(let result) = try result(from: await send(IPCRequest(method: .mysqlStatus))) else { throw CoreClientError.invalidResponse }; return result.mysql }
    public func mailpitVersions() async throws -> MailpitVersionsPayload { guard case .mailpitVersions(let result) = try result(from: await send(IPCRequest(method: .mailpitVersions))) else { throw CoreClientError.invalidResponse }; return result.mailpit }
    public func mailpitInstall(_ version: String) async throws -> MailpitPackageWire { guard case .mailpitVersions(let result) = try result(from: await send(IPCRequest(method: .mailpitInstall, params: .phpVersion(.init(version: version))))) else { throw CoreClientError.invalidResponse }; guard let package = result.mailpit.installed.first(where: { $0.version == version }) ?? result.mailpit.installed.last else { throw CoreClientError.invalidResponse }; return package }
    public func mailpitStart() async throws -> MailpitStatus { guard case .mailpitStatus(let result) = try result(from: await send(IPCRequest(method: .mailpitStart))) else { throw CoreClientError.invalidResponse }; return result.mailpit }
    public func mailpitStop() async throws -> MailpitStatus { guard case .mailpitStatus(let result) = try result(from: await send(IPCRequest(method: .mailpitStop))) else { throw CoreClientError.invalidResponse }; return result.mailpit }
    public func mailpitStatus() async throws -> MailpitStatus { guard case .mailpitStatus(let result) = try result(from: await send(IPCRequest(method: .mailpitStatus))) else { throw CoreClientError.invalidResponse }; return result.mailpit }
    public func routingStatus() async throws -> RouterStatus { guard case .routingStatus(let result) = try result(from: await send(IPCRequest(method: .routingStatus))) else { throw CoreClientError.invalidResponse }; return result.router }
    public func routingStart() async throws -> RouterStatus { guard case .routingStatus(let result) = try result(from: await send(IPCRequest(method: .routingStart))) else { throw CoreClientError.invalidResponse }; return result.router }
    public func routingStop() async throws -> RouterStatus { guard case .routingStatus(let result) = try result(from: await send(IPCRequest(method: .routingStop))) else { throw CoreClientError.invalidResponse }; return result.router }
    public func routeList() async throws -> [RouteIntent] { guard case .routeList(let result) = try result(from: await send(IPCRequest(method: .routeList))) else { throw CoreClientError.invalidResponse }; return result.routes }
    public func routeAdd(_ intent: RouteIntent) async throws -> RouteIntent { guard case .routeMutation(let result) = try result(from: await send(IPCRequest(method: .routeAdd, params: .route(intent)))) else { throw CoreClientError.invalidResponse }; return result }
    public func routeRemove(_ id: RouteID) async throws -> [RouteIntent] { guard case .routeList(let result) = try result(from: await send(IPCRequest(method: .routeRemove, params: .routeRemove(.init(id: id))))) else { throw CoreClientError.invalidResponse }; return result.routes }
    public func routeAssociate(routeID: RouteID, projectID: ProjectID) async throws -> RouteProjectAssociationResult { guard case .routeAssociation(let result) = try result(from: await send(IPCRequest(method: .routeProjectAssociationAttach, params: .routeAssociation(.init(routeID: routeID, projectID: projectID))))) else { throw CoreClientError.invalidResponse }; return result }
    public func routePHPTargetUpdate(routeID: RouteID, projectID: ProjectID, expectedCurrentSocket: String) async throws -> RoutePHPTargetUpdateResult { guard case .routePHPTargetUpdate(let result) = try result(from: await send(IPCRequest(method: .routePHPTargetUpdate, params: .routePHPTargetUpdate(.init(routeID: routeID, projectID: projectID, expectedCurrentSocket: expectedCurrentSocket))))) else { throw CoreClientError.invalidResponse }; return result }
    public func dnsStatus() async throws -> DNSStatus { guard case .dnsStatus(let result) = try result(from: await send(IPCRequest(method: .dnsStatus))) else { throw CoreClientError.invalidResponse }; return result.dns }
    public func dnsInstall(takeover: Bool = false) async throws -> DNSStatus { guard case .dnsStatus(let result) = try result(from: await send(IPCRequest(method: .dnsInstall, params: .dnsInstall(.init(takeover: takeover))))) else { throw CoreClientError.invalidResponse }; return result.dns }
    public func dnsRemove() async throws -> DNSStatus { guard case .dnsStatus(let result) = try result(from: await send(IPCRequest(method: .dnsRemove))) else { throw CoreClientError.invalidResponse }; return result.dns }
    public func tlsStatus() async throws -> TLSStatus { guard case .tlsStatus(let result) = try result(from: await send(IPCRequest(method: .tlsStatus))) else { throw CoreClientError.invalidResponse }; return result.tls }
    public func tlsInstall() async throws -> TLSStatus { guard case .tlsStatus(let result) = try result(from: await send(IPCRequest(method: .tlsInstall))) else { throw CoreClientError.invalidResponse }; return result.tls }
    public func tlsRemove() async throws -> TLSStatus { guard case .tlsStatus(let result) = try result(from: await send(IPCRequest(method: .tlsRemove))) else { throw CoreClientError.invalidResponse }; return result.tls }
    public func portsStatus() async throws -> StandardPortsStatus { guard case .portsStatus(let result) = try result(from: await send(IPCRequest(method: .portsStatus))) else { throw CoreClientError.invalidResponse }; return result.ports }
    public func portsInstall() async throws -> StandardPortsStatus { guard case .portsStatus(let result) = try result(from: await send(IPCRequest(method: .portsInstall))) else { throw CoreClientError.invalidResponse }; return result.ports }
    public func portsRemove() async throws -> StandardPortsStatus { guard case .portsStatus(let result) = try result(from: await send(IPCRequest(method: .portsRemove))) else { throw CoreClientError.invalidResponse }; return result.ports }

    public func disconnect() async {
        connected = false
        await transport.disconnect()
    }

    private func send(_ request: IPCRequest) async throws -> IPCResponse {
        do {
            let payload = try IPCCodec.encode(request)
            let frame = try FrameEncoder().encode(payload)
            try await transport.write(frame)

            while true {
                let data = try await transport.read()
                let frames = try decoder.append(data)
                for frame in frames {
                    let response = try IPCCodec.decode(IPCResponse.self, from: frame)
                    if response.id == request.id { return response }
                }
            }
        } catch let error as CoreTransportError {
            connected = false
            await transport.disconnect()
            if case .unavailable = error { throw CoreClientError.coreUnavailable }
            throw error
        } catch is DecodingError {
            throw CoreClientError.invalidResponse
        } catch is IPCModelError {
            throw CoreClientError.invalidResponse
        }
    }

    private func result(from response: IPCResponse) throws -> ResponseResult {
        if let error = response.error { throw map(error) }
        guard let result = response.result else { throw CoreClientError.invalidResponse }
        return result
    }

    private func map(_ error: IPCErrorPayload) -> CoreClientError {
        if error.code == .protocolIncompatible,
           let details = error.details,
           let client = Int(details["clientProtocolVersion"] ?? ""),
           let core = Int(details["coreProtocolVersion"] ?? "") {
            return .protocolIncompatible(client: client, core: core)
        }
        if error.code == .coreIncompatible { return .coreIncompatible(reason: error.message) }
        return .remote(error)
    }
}
