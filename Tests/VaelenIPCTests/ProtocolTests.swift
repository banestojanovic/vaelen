import XCTest
@testable import VaelenCore
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

    func testM13TrustCommandsAreParameterlessAndTyped() throws {
        let trust = IPCRequest(method: .tlsTrustLocalCA)
        let untrust = IPCRequest(method: .tlsRemoveLocalCATrust)
        XCTAssertNil(trust.params)
        XCTAssertNil(untrust.params)

        let status = TLSStatus(state: .trusted, trustObserved: true, ownership: .owned, trustProvenance: .confirmedByVaelen)
        let payload = TLSTrustResult(status: status, operation: .confirmed, message: "confirmed")
        let response = IPCResponse(id: trust.id, result: .tlsTrust(.init(result: payload)))
        let decoded = try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response))
        guard case .tlsTrust(let wire)? = decoded.result else { return XCTFail("M13 trust result did not round-trip") }
        XCTAssertEqual(wire.result, payload)
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

    func testPHPCatalogMethodAndResponseRoundTripThroughJSON() throws {
        let request = IPCRequest(method: .phpCatalog)
        XCTAssertEqual(try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request)).knownMethod, .phpCatalog)
        let catalog = PHPRuntimeCatalog(availableVersions: ["8.4.23"], installedVersions: [.init(version: "8.4.23", running: true, isDefault: true)], defaultVersion: "8.4.23", runningVersions: ["8.4.23"])
        let response = IPCResponse(id: request.id, result: .phpCatalog(.init(catalog: catalog)))
        XCTAssertEqual(try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response)), response)
        let emptyOperation = IPCResponse(id: request.id, result: .phpOperation(.init(operation: nil)))
        XCTAssertEqual(try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(emptyOperation)), emptyOperation)
    }

    func testPHPDefaultSetMethodAndCatalogResponseRoundTripThroughJSON() throws {
        let request = IPCRequest(method: .phpDefaultSet, params: .phpVersion(.init(version: "8.4.23")))
        XCTAssertEqual(try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request)), request)
        let catalog = PHPRuntimeCatalog(availableVersions: ["8.4.23"], installedVersions: [.init(version: "8.4.23", running: true, isDefault: true)], defaultVersion: "8.4.23", runningVersions: ["8.4.23"])
        let response = IPCResponse(id: request.id, result: .phpCatalog(.init(catalog: catalog)))
        XCTAssertEqual(try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response)), response)
    }

    func testPortsMethodsAndResponseRoundTripThroughJSON() throws {
        for method in [CoreMethod.portsStatus, .portsInstall, .portsRemove] {
            let request = IPCRequest(method: method)
            let decoded = try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request))
            XCTAssertEqual(decoded.knownMethod, method)
        }
        let response = IPCResponse(id: UUID(), result: .portsStatus(PortsStatusResult(ports: StandardPortsStatus(state: .healthy))))
        let decoded = try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response))
        XCTAssertEqual(decoded, response)
    }

    func testMySQLMethodsAndStatusResponseRoundTripThroughJSON() throws {
        for method in [CoreMethod.mysqlVersions, .mysqlInstall, .mysqlUse, .mysqlInitialize, .mysqlStart, .mysqlStop, .mysqlStatus] {
            let request = IPCRequest(method: method)
            XCTAssertEqual(try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request)).knownMethod, method)
        }
        let status = MySQLStatus(state: .stopped, health: "stopped", installedVersion: "8.4.11", selectedVersion: "8.4.11", pid: nil, port: 13306, socket: "/tmp/mysql.sock", datadir: "/tmp/mysql-data", executablePath: "/tmp/mysqld")
        let response = IPCResponse(id: UUID(), result: .mysqlStatus(MySQLStatusResult(mysql: status)))
        XCTAssertEqual(try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response)), response)
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

    func testProjectReconciliationMethodsAndResponsesRoundTripThroughJSON() throws {
        for method in [CoreMethod.projectPlan, .projectActivate] {
            let request = IPCRequest(method: method, params: .projectEnvironment(.init(selector: "syncproof", workingDirectory: "/tmp")))
            XCTAssertEqual(try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request)).knownMethod, method)
        }
        let identity = ProjectEnvironmentIdentity(project: Project(id: ProjectID(), name: "syncproof", rootPath: CanonicalPath(url: URL(fileURLWithPath: "/tmp/syncproof")), registrationKind: .linked, availability: .available))
        let desired = ProjectDesiredEnvironment(file: .valid, php: "8.4", secureWeb: true, mysql: true, mailpit: true)
        let plan = ProjectReconciliationPlan(identity: identity, desired: desired, observedAt: Date(timeIntervalSince1970: 1), operations: [], state: .satisfied)
        let response = IPCResponse(id: UUID(), result: .projectPlan(.init(plan: plan)))
        XCTAssertEqual(try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response)), response)
    }

    func testRouteAssociationRequestAndResponseRoundTripThroughJSON() throws {
        let routeID = RouteID()
        let projectID = ProjectID()
        let request = IPCRequest(method: .routeProjectAssociationAttach, params: .routeAssociation(.init(routeID: routeID, projectID: projectID)))
        let decodedRequest = try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request))
        XCTAssertEqual(decodedRequest, request)

        let route = RouteIntent(route: Route(id: routeID, hostname: "project.test", target: .staticFiles(documentRoot: "/tmp/project"), tls: .disabled), projectID: projectID.rawValue, projectPath: "/tmp/project")
        let response = IPCResponse(id: UUID(), result: .routeAssociation(.init(route: route, state: .associated)))
        XCTAssertEqual(try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response)), response)
    }
}
