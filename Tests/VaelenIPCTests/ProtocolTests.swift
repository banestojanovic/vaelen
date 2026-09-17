import XCTest
@testable import VaelenIPC

final class ProtocolTests: XCTestCase {
    func testRequestRoundTripsThroughJSON() throws {
        let request = IPCRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            method: .handshake,
            params: .handshake(HandshakeParams(client: ClientIdentity(name: "val", version: "0.0.1-dev")))
        )

        let data = try IPCCodec.encode(request)
        let decoded = try IPCCodec.decode(IPCRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func testStatusResponseRoundTripsThroughJSON() throws {
        let response = IPCResponse(
            id: UUID(),
            result: .status(CoreStatusResponse(
                core: .init(state: .running, version: "0.0.1-dev", pid: 42),
                protocolVersion: .v1
            ))
        )

        let data = try IPCCodec.encode(response)
        let decoded = try IPCCodec.decode(IPCResponse.self, from: data)

        XCTAssertEqual(decoded, response)
    }
}
