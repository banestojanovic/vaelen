import XCTest
@testable import VaelenCLI
import VaelenIPC

final class ProjectPHPCLIParsingTests: XCTestCase {
    func testProjectPHPSetAndReadFormsParse() throws {
        guard case .projectPHP(let selector, let version, let useDefault, let json) = try VaelenCLIMain.parse(["project", "php", "syncproof", "--version", "8.4.23", "--json"]) else { return XCTFail("project php version form did not parse") }
        XCTAssertEqual(selector, "syncproof")
        XCTAssertEqual(version, "8.4.23")
        XCTAssertFalse(useDefault)
        XCTAssertTrue(json)
        guard case .projectPHP(let readSelector, let readVersion, let readDefault, _) = try VaelenCLIMain.parse(["project", "php"]) else { return XCTFail("project php read form did not parse") }
        XCTAssertNil(readSelector); XCTAssertNil(readVersion); XCTAssertFalse(readDefault)
    }

    func testPHPResolverPathCommandParses() throws {
        guard case .phpResolvePath = try VaelenCLIMain.parse(["php", "resolve", "--path"]) else {
            return XCTFail("PHP shell resolver command did not parse")
        }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["php", "resolve"]))
    }

    func testHerdStylePHPAliasesPreserveDistinctSelectionScopes() throws {
        guard case .phpUse("8.4.23") = try VaelenCLIMain.parse(["use", "8.4.23"]) else { return XCTFail("use must select CLI PHP") }
        guard case .projectPHP(selector: nil, version: "8.4.23", useDefault: false, json: false) = try VaelenCLIMain.parse(["isolate", "8.4.23"]) else { return XCTFail("isolate must set current project override") }
        guard case .projectPHP(selector: "demo", version: nil, useDefault: true, json: false) = try VaelenCLIMain.parse(["unisolate", "demo"]) else { return XCTFail("unisolate must clear the override") }
        guard case .isolated(json: false) = try VaelenCLIMain.parse(["isolated"]) else { return XCTFail("isolated must list overrides") }
        guard case .isolated(json: true) = try VaelenCLIMain.parse(["isolated", "--json"]) else { return XCTFail("isolated --json must list overrides as JSON") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["isolated", "--json", "--json"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["isolated", "project"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["isolated", "--unknown"]))
        guard case .phpResolvePath = try VaelenCLIMain.parse(["which-php"]) else { return XCTFail("which-php must resolve project-effective PHP") }
        guard case .phpINI(version: nil) = try VaelenCLIMain.parse(["ini"]) else { return XCTFail("ini without a version must use effective PHP") }
        guard case .phpINI(version: "8.4.23") = try VaelenCLIMain.parse(["ini", "8.4.23"]) else { return XCTFail("ini version form did not parse") }
        guard case .phpExec(version: nil, effective: true, arguments: ["artisan", "about"]) = try VaelenCLIMain.parse(["php", "exec", "--effective", "--", "artisan", "about"]) else { return XCTFail("effective PHP execution did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["use"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["isolate"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["php", "exec", "--effective", "artisan"]))
    }

    func testIsolatedOutputUsesCoreSelectionsAndRetainsUnavailableOverrides() throws {
        let inherited = ProjectPHPSelection(
            project: ProjectWire(id: UUID(), name: "inherited", path: "/projects/inherited", registration: "linked", availability: "available"),
            overrideVersion: nil, defaultVersion: "8.4.23", effectiveVersion: "8.4.23", observedVersion: nil, available: true
        )
        let unavailable = ProjectPHPSelection(
            project: ProjectWire(id: UUID(), name: "unavailable", path: "/projects/unavailable", registration: "linked", availability: "available"),
            overrideVersion: "99.0.0", defaultVersion: "8.4.23", effectiveVersion: nil, observedVersion: nil, available: false
        )
        let available = ProjectPHPSelection(
            project: ProjectWire(id: UUID(), name: "available", path: "/projects/available", registration: "linked", availability: "available"),
            overrideVersion: "8.3.12", defaultVersion: "8.4.23", effectiveVersion: "8.3.12", observedVersion: "8.3.12", available: true
        )

        let json = try VaelenCLIMain.isolatedProjectsOutput([unavailable, inherited, available], json: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let selections = try XCTUnwrap(object["selections"] as? [[String: Any]])
        XCTAssertEqual(selections.compactMap { ($0["project"] as? [String: Any])?["name"] as? String }, ["available", "unavailable"])
        XCTAssertEqual(selections[1]["overrideVersion"] as? String, "99.0.0")
        XCTAssertEqual(selections[1]["available"] as? Bool, false)
        XCTAssertNil(selections[1]["effectiveVersion"])
        XCTAssertNil(selections[1]["observedVersion"])
        XCTAssertFalse(json.contains("Isolated projects"))
        XCTAssertTrue(json.hasPrefix("{"))

        let empty = try VaelenCLIMain.isolatedProjectsOutput([inherited], json: true)
        let emptyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(empty.utf8)) as? [String: Any])
        XCTAssertEqual((emptyObject["selections"] as? [Any])?.count, 0)
        let human = try VaelenCLIMain.isolatedProjectsOutput([unavailable, available], json: false)
        XCTAssertTrue(human.contains("Isolated projects"))
        XCTAssertTrue(human.contains("99.0.0"))
        XCTAssertTrue(human.contains("unavailable"))
    }

    func testIsolatedOutputPropagatesBatchObservationErrors() async throws {
        let pair = InMemoryTransport.pair()
        let server = Task { () throws -> CoreMethod? in
            try await pair.server.connect()
            var decoder = FrameDecoder()
            func request() async throws -> IPCRequest {
                let data = try await pair.server.read()
                let frame = try XCTUnwrap(decoder.append(data).first)
                return try IPCCodec.decode(IPCRequest.self, from: frame)
            }
            let handshake = try await request()
            try await pair.server.write(FrameEncoder().encode(IPCCodec.encode(IPCResponse(
                id: handshake.id,
                result: .handshake(HandshakeResult(protocolVersion: ProtocolVersion.v1.rawValue, coreVersion: "test", schemaCompatibilityVersion: IPCCompatibility.schemaVersion))
            ))))
            let batch = try await request()
            try await pair.server.write(FrameEncoder().encode(IPCCodec.encode(IPCResponse(
                id: batch.id,
                error: IPCErrorPayload(code: .internalError, message: "batch observation failed")
            ))))
            return batch.knownMethod
        }
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "isolated-output-test", version: "test"))
        try await client.connect()
        do {
            _ = try await VaelenCLIMain.isolatedProjectsOutput(client: client, json: true)
            XCTFail("a failed batch observation must not return an empty inventory")
        } catch let error as CoreClientError {
            XCTAssertEqual(error, .remote(IPCErrorPayload(code: .internalError, message: "batch observation failed")))
        }
        let receivedMethod = try await server.value
        XCTAssertEqual(receivedMethod, .projectPHPSelections)
        await client.disconnect()
        await pair.server.disconnect()
    }

    func testShellIntegrationLifecycleCommandsParse() throws {
        guard case .shellStatus = try VaelenCLIMain.parse(["shell", "status"]) else { return XCTFail("shell status did not parse") }
        guard case .shellInstall = try VaelenCLIMain.parse(["shell", "install"]) else { return XCTFail("shell install did not parse") }
        guard case .shellUninstall = try VaelenCLIMain.parse(["shell", "uninstall"]) else { return XCTFail("shell uninstall did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["shell", "unknown"]))
    }
}
