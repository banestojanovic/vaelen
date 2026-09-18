import XCTest
@testable import VaelenIPC

final class ClientTests: XCTestCase {
    func testSharedClientUsesInMemoryTransport() async throws {
        let pair = InMemoryTransport.pair()
        let client = VaelenCoreClient(
            transport: pair.client,
            identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version)
        )
        let server = Task {
            try await pair.server.connect()
            var decoder = FrameDecoder()
            while !Task.isCancelled {
                let data = try await pair.server.read()
                for frame in try decoder.append(data) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    let response: IPCResponse
                    switch request.knownMethod! {
                    case .handshake:
                        response = IPCResponse(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))
                    case .status:
                        response = IPCResponse(id: request.id, result: .status(.init(core: .init(state: .running, version: "0.0.1-dev", pid: 99), protocolVersion: 1)))
                    default:
                        XCTFail("Unexpected test method")
                        return
                    }
                    try await pair.server.write(FrameEncoder().encode(IPCCodec.encode(response)))
                }
            }
        }

        try await client.connect()
        let status = try await client.status()
        await client.disconnect()
        server.cancel()

        XCTAssertEqual(status.core.pid, 99)
        XCTAssertEqual(status.core.version, "0.0.1-dev")
    }

    func testOlderCoreMissingSchemaIdentityFailsBeforeNormalDispatch() async throws {
        let pair = InMemoryTransport.pair()
        let recorder = RequestRecorder()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), result: .handshake(.init(protocolVersion: 1, coreVersion: "0.0.10-dev"))), recorder: recorder)
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("stale Core should be rejected")
        } catch let error as CoreClientError {
            guard case .coreIncompatible = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(recorder.methods, [CoreMethod.handshake.rawValue])
        server.cancel()
    }

    func testNewerSchemaIdentityFailsStrictly() async throws {
        let pair = InMemoryTransport.pair()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), result: .handshake(.init(protocolVersion: 1, coreVersion: "0.0.12-dev", schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion + 1, buildIdentity: "future"))))
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("newer Core should be rejected")
        } catch let error as CoreClientError {
            guard case .coreIncompatible = error else { return XCTFail("unexpected error: \(error)") }
        }
        server.cancel()
    }

    func testProtocolMismatchRemainsDistinctFromSchemaMismatch() async throws {
        let pair = InMemoryTransport.pair()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), result: .handshake(.init(protocolVersion: 2, coreVersion: "future", schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion))))
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("protocol mismatch should be rejected")
        } catch let error as CoreClientError {
            XCTAssertEqual(error, .protocolIncompatible(client: 1, core: 2))
        }
        server.cancel()
    }

    func testUnknownHandshakeResponseIsClassifiedAsIncompatible() async throws {
        let pair = InMemoryTransport.pair()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), error: .init(code: .invalidRequest, message: "unknown method")))
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("old handshake should be rejected")
        } catch let error as CoreClientError {
            guard case .coreIncompatible = error else { return XCTFail("unexpected error: \(error)") }
        }
        server.cancel()
    }

    func testMalformedHandshakeResultIsClassifiedAsIncompatible() async throws {
        let pair = InMemoryTransport.pair()
        let server = handshakeServer(pair.server, response: IPCResponse(id: UUID(), result: .status(.init(core: .init(state: .running, version: "old", pid: 1), protocolVersion: 1))))
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))

        do {
            try await client.connect()
            XCTFail("malformed handshake should be rejected")
        } catch let error as CoreClientError {
            guard case .coreIncompatible = error else { return XCTFail("unexpected error: \(error)") }
        }
        server.cancel()
    }

    func testMalformedNormalResponseRemainsInvalidResponseAfterValidHandshake() async throws {
        let pair = InMemoryTransport.pair()
        let server = Task {
            try? await pair.server.connect()
            var decoder = FrameDecoder()
            var count = 0
            while count < 2, let data = try? await pair.server.read() {
                for frame in try! decoder.append(data) {
                    let request = try! IPCCodec.decode(IPCRequest.self, from: frame)
                    count += 1
                    if request.knownMethod == .handshake {
                        let response = IPCResponse(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))
                        try? await pair.server.write(FrameEncoder().encode(IPCCodec.encode(response)))
                    } else {
                        let invalid = Data("{\"id\":\"\(request.id.uuidString)\",\"protocolVersion\":1}".utf8)
                        try? await pair.server.write(FrameEncoder().encode(invalid))
                    }
                }
            }
        }
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))
        try await client.connect()
        do {
            _ = try await client.status()
            XCTFail("malformed normal response should fail")
        } catch let error as CoreClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
        server.cancel()
    }

    func testUnavailableCoreRemainsDistinct() async throws {
        let client = VaelenCoreClient(transport: UnavailableTransport(), identity: ClientIdentity(name: "test", version: VaelenBuildInfo.version))
        do {
            try await client.connect()
            XCTFail("unavailable Core should fail")
        } catch let error as CoreClientError {
            XCTAssertEqual(error, .coreUnavailable)
        }
    }

    private func handshakeServer(_ server: InMemoryTransport, response: IPCResponse, recorder: RequestRecorder? = nil) -> Task<Void, Never> {
        Task {
            try? await server.connect()
            var decoder = FrameDecoder()
            guard let data = try? await server.read(), let frames = try? decoder.append(data) else { return }
            for frame in frames {
                guard let request = try? IPCCodec.decode(IPCRequest.self, from: frame) else { return }
                recorder?.append(request.method)
                let reply: IPCResponse
                if let result = response.result {
                    reply = IPCResponse(id: request.id, result: result)
                } else if let error = response.error {
                    reply = IPCResponse(id: request.id, error: error)
                } else {
                    return
                }
                try? await server.write(FrameEncoder().encode(IPCCodec.encode(reply)))
            }
        }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String]()
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private struct UnavailableTransport: CoreTransport {
    func connect() async throws { throw CoreTransportError.unavailable }
    func write(_ data: Data) async throws { throw CoreTransportError.notConnected }
    func read() async throws -> Data { throw CoreTransportError.unavailable }
    func disconnect() async {}
}
