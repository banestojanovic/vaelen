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
            guard result.protocolVersion == .v1 else {
                throw CoreClientError.protocolIncompatible(client: ProtocolVersion.v1.rawValue, core: result.protocolVersion.rawValue)
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

    public func disconnect() async {
        connected = false
        await transport.disconnect()
    }

    private func send(_ request: IPCRequest) async throws -> IPCResponse {
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
