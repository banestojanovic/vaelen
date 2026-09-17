import Foundation

public enum CoreClientError: Error, Equatable, Sendable {
    case coreUnavailable
    case protocolIncompatible(client: Int, core: Int)
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
            let request = IPCRequest(method: .handshake, params: .handshake(HandshakeParams(client: identity)))
            let response = try await send(request)
            guard case .handshake(let result) = try result(from: response) else { throw CoreClientError.invalidResponse }
            guard result.protocolVersion == ProtocolVersion.v1.rawValue else {
                throw CoreClientError.protocolIncompatible(client: ProtocolVersion.v1.rawValue, core: result.protocolVersion)
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
        return .remote(error)
    }
}
