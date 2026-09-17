import XCTest
@testable import VaelenIPC

final class ClientTests: XCTestCase {
    func testSharedClientUsesInMemoryTransport() async throws {
        let pair = InMemoryTransport.pair()
        let client = VaelenCoreClient(
            transport: pair.client,
            identity: ClientIdentity(name: "test", version: "0.0.1-dev")
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
                        response = IPCResponse(id: request.id, result: .handshake(.init(protocolVersion: 1, coreVersion: "0.0.1-dev")))
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
}
