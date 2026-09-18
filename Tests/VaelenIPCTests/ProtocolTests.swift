import XCTest
@testable import VaelenIPC

final class ProtocolTests: XCTestCase {
    func testUnknownProtocolVersionSurvivesEnvelopeDecoding() throws {
        let request = IPCRequest(rawMethod: "core.status", protocolVersion: 2)
        let decoded = try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request))

        XCTAssertEqual(decoded.protocolVersion, 2)
        XCTAssertEqual(decoded.knownMethod, .status)
    }

    func testUnknownMethodSurvivesEnvelopeDecoding() throws {
        let request = IPCRequest(rawMethod: "project.future", protocolVersion: 1)
        let decoded = try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request))

        XCTAssertNil(decoded.knownMethod)
        XCTAssertEqual(decoded.method, "project.future")
    }

    func testResponseRequiresExactlyOneResultOrError() throws {
        let id = UUID()
        let invalid = "{\"id\":\"\(id.uuidString)\",\"protocolVersion\":1}"

        XCTAssertThrowsError(try IPCCodec.decode(IPCResponse.self, from: Data(invalid.utf8)))
    }

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

    func testPHPExecRequestCarriesWorkingDirectoryAndArguments() throws {
        let request = IPCRequest(
            method: .phpExec,
            params: .phpExec(PHPExecRequest(version: nil, workingDirectory: "/tmp/fixture with spaces", arguments: ["test.php", "--flag", "value with spaces"]))
        )

        let decoded = try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request))
        let params = try decoded.params?.decode(PHPExecRequest.self)
        XCTAssertEqual(params?.workingDirectory, "/tmp/fixture with spaces")
        XCTAssertEqual(params?.arguments, ["test.php", "--flag", "value with spaces"])
    }

    func testStatusResponseRoundTripsThroughJSON() throws {
        let response = IPCResponse(
            id: UUID(),
            result: .status(CoreStatusResponse(
                core: .init(state: .running, version: "0.0.1-dev", pid: 42),
                protocolVersion: 1
            ))
        )

        let data = try IPCCodec.encode(response)
        let decoded = try IPCCodec.decode(IPCResponse.self, from: data)

        XCTAssertEqual(decoded, response)
    }
}
