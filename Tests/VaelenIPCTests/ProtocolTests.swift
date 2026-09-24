import XCTest
@testable import VaelenCore
@testable import VaelenIPC

final class ProtocolTests: XCTestCase {
    func testProjectPHPSelectionRoundTripsThroughJSON() throws {
        let request = IPCRequest(method: .projectPHP, params: .projectPHP(.init(selector: "syncproof", workingDirectory: "/tmp/syncproof", version: "8.4.23")))
        let decoded = try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request))
        XCTAssertEqual(decoded.knownMethod, .projectPHP)
        let response = IPCResponse(id: UUID(), result: .projectPHP(.init(project: .init(id: nil, name: "syncproof", path: "/tmp/syncproof", registration: "linked", availability: "available"), overrideVersion: "8.4.23", defaultVersion: "8.4.23", effectiveVersion: "8.4.23", observedVersion: "8.4.23", available: true)))
        let restored = try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response))
        guard case .projectPHP(let selection) = restored.result else { return XCTFail("project PHP response did not decode") }
        XCTAssertEqual(selection.overrideVersion, "8.4.23")
    }
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

    func testPHPResolveRequestAndResponseRoundTripThroughJSON() throws {
        let request = IPCRequest(method: .phpResolve, params: .phpResolve(.init(workingDirectory: "/Users/test/project")))
        let restoredRequest = try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request))
        XCTAssertEqual(restoredRequest.knownMethod, .phpResolve)
        guard case .phpResolve(let params) = restoredRequest.params else { return XCTFail("PHP resolve params did not decode") }
        XCTAssertEqual(params.workingDirectory, "/Users/test/project")

        let response = IPCResponse(id: UUID(), result: .phpResolve(.init(version: "8.4.23", cliPath: "/managed/php/8.4.23/php", projectName: "sample")))
        let restoredResponse = try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response))
        guard case .phpResolve(let result) = restoredResponse.result else { return XCTFail("PHP resolve result did not decode") }
        XCTAssertEqual(result.version, "8.4.23")
        XCTAssertEqual(result.cliPath, "/managed/php/8.4.23/php")
        XCTAssertEqual(result.projectName, "sample")
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
                protocolVersion: 1,
                serviceIssues: ["dns": "external resolver"],
                serviceIntents: ["mysql"]
            ))
        )

        let data = try IPCCodec.encode(response)
        let decoded = try IPCCodec.decode(IPCResponse.self, from: data)

        XCTAssertEqual(decoded, response)
    }

    func testTypedCoreShutdownRequestAndComponentOutcomesRoundTrip() throws {
        let request = IPCRequest(method: .shutdown)
        let restored = try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request))
        XCTAssertEqual(restored.knownMethod, .shutdown)
        let value = CoreShutdownResponse(components: [
            .init(component: "mailpit", succeeded: true, detail: "Stopped."),
            .init(component: "standard-ports-pf", succeeded: false, detail: "No safe provenance.")
        ])
        XCTAssertFalse(value.completed)
        let response = IPCResponse(id: UUID(), result: .shutdown(value))
        guard case .shutdown(let decoded) = try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response)).result else { return XCTFail("shutdown result did not decode as typed response") }
        XCTAssertEqual(decoded, value)
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
