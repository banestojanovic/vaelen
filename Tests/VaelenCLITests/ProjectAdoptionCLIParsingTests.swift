import XCTest
@testable import VaelenCLI
@testable import VaelenCore

final class ProjectAdoptionCLIParsingTests: XCTestCase {
    func testProjectUpDownAndActivateAliasParse() throws {
        guard case .projectActivate(selector: "my-app", json: true) = try VaelenCLIMain.parse(["project", "up", "my-app", "--json"]) else { return XCTFail("project up did not parse") }
        guard case .projectDown(selector: nil, json: false) = try VaelenCLIMain.parse(["project", "down"]) else { return XCTFail("project down did not parse") }
        guard case .projectActivate(selector: "my-app", json: false) = try VaelenCLIMain.parse(["project", "activate", "my-app"]) else { return XCTFail("project activate compatibility alias did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["project", "down", "one", "two"]))
    }

    func testProjectAdoptFormsAndHelp() throws {
        guard case .projectAdopt(selector: nil, json: false) = try VaelenCLIMain.parse(["project", "adopt"]) else { return XCTFail("adopt did not parse") }
        guard case .projectAdopt(selector: "my-app", json: true) = try VaelenCLIMain.parse(["project", "adopt", "my-app", "--json"]) else { return XCTFail("adopt JSON form did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["project", "adopt", "one", "two"]))
        let help = VaelenCLIMain.helpText(for: ["project", "adopt"])
        XCTAssertTrue(help.contains("val project adopt [project] [--json]"))
        XCTAssertTrue(help.contains("--apply <confirmation>"))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["project", "adopt", "--apply"]))
        let confirmation = UUID().uuidString
        let routeID = UUID().uuidString
        guard case .projectAdoptApply(selector: "my-app", confirmation: _, php: "8.3", node: "22", webHost: "app.test", documentRoot: "public", secure: true, createRoute: false, webChoiceConfirmed: true, services: _, routeIDs: let parsedRouteIDs, json: true) = try VaelenCLIMain.parse(["project", "adopt", "--apply", confirmation, "my-app", "--php", "8.3", "--node", "22", "--web-host", "app.test", "--document-root", "public", "--secure", "--select-route", routeID, "--json"]) else { return XCTFail("explicit adoption apply form did not parse") }
        XCTAssertEqual(parsedRouteIDs.map(\.rawValue), [UUID(uuidString: routeID)!])
        guard case .projectAdoptApply(selector: "my-app", confirmation: _, php: nil, node: nil, webHost: "new.test", documentRoot: "public", secure: false, createRoute: true, webChoiceConfirmed: true, services: [], routeIDs: [], json: false) = try VaelenCLIMain.parse(["project", "adopt", "--apply", confirmation, "my-app", "--web-host", "new.test", "--document-root", "public", "--insecure", "--create-route"]) else { return XCTFail("explicit route creation choice did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["project", "adopt", "--apply", confirmation, "my-app", "--web-host", "new.test", "--document-root", "public", "--insecure", "--create-route", "--select-route", routeID]))
    }

    func testHumanPreviewPrintsReviewBoundaryAndSafeEndpointFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = Project(id: ProjectID(), name: "demo", rootPath: CanonicalPath(url: root), registrationKind: .linked, availability: .available)
        let preview = ProjectAdoptionPreview(
            identity: ProjectEnvironmentIdentity(project: project), manifestState: .absent, manifestVersion: nil,
            php: ProjectAdoptionRequirement(state: .notDetected, sources: []), node: ProjectAdoptionRequirement(state: .notDetected, sources: []), routes: [],
            liveRoutesAvailable: false, liveRoutesUnavailableReason: "offline",
            database: ProjectAdoptionEndpoint(connection: "mysql", host: "db.test", port: "3306", secretAvailability: .available),
            mail: ProjectAdoptionEndpoint(connection: "smtp", host: "mail.test", port: "1025", secretAvailability: .missing), cache: nil,
            herdYMLPresent: false, unresolvedDecisions: ["Review database and mail endpoint mappings before adoption."],
            safetyBoundary: "Preview only. No project, route, service, or ownership mutation is performed. No secret values are imported or emitted.")
        let output = VaelenCLIMain.projectAdoptionPreviewOutput(preview)
        XCTAssertTrue(output.contains("demo"))
        XCTAssertTrue(output.contains("db.test: 3306"))
        XCTAssertTrue(output.contains("No secret values are imported or emitted"))
        XCTAssertFalse(output.contains("private-user"))
    }

    func testHumanPreviewSanitizesTerminalControlsAndNewlinesInConstraints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = Project(id: ProjectID(), name: "demo", rootPath: CanonicalPath(url: root), registrationKind: .linked, availability: .available)
        let raw = "^8.2\u{001B}[31m\nINJECTED"
        let preview = ProjectAdoptionPreview(
            identity: ProjectEnvironmentIdentity(project: project), manifestState: .absent, manifestVersion: nil,
            php: ProjectAdoptionRequirement(state: .needsChoice, sources: [.init(source: "composer.json", rawValue: raw)]), node: ProjectAdoptionRequirement(state: .notDetected, sources: []), routes: [],
            liveRoutesAvailable: true, liveRoutesUnavailableReason: nil,
            database: ProjectAdoptionEndpoint(connection: nil, host: nil, port: nil, secretAvailability: .unknown),
            mail: ProjectAdoptionEndpoint(connection: nil, host: nil, port: nil, secretAvailability: .unknown), cache: nil,
            herdYMLPresent: false, unresolvedDecisions: [], safetyBoundary: "Preview only.")
        let output = VaelenCLIMain.projectAdoptionPreviewOutput(preview)
        XCTAssertFalse(output.unicodeScalars.contains { $0.value == 0x1B })
        XCTAssertFalse(output.contains("\nINJECTED"))
        XCTAssertTrue(output.contains("INJECTED"))
    }

    func testHumanPreviewSanitizesProjectRouteAndEndpointText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unsafe\u{001B}[31m\nPATH", isDirectory: true)
        let project = Project(id: ProjectID(), name: "unsafe\u{001B}[31m\nNAME", rootPath: CanonicalPath(url: root), registrationKind: .linked, availability: .available)
        let route = ProjectAdoptionRoute(id: RouteID(), hostname: "host\u{001B}[2J\nINJECTED", targetKind: .staticFiles, documentRoot: "public\u{001B}\nROOT", tls: .local, liveObserved: true)
        let preview = ProjectAdoptionPreview(
            identity: ProjectEnvironmentIdentity(project: project), manifestState: .absent, manifestVersion: nil,
            php: ProjectAdoptionRequirement(state: .notDetected, sources: []), node: ProjectAdoptionRequirement(state: .notDetected, sources: []), routes: [route],
            liveRoutesAvailable: true, liveRoutesUnavailableReason: nil,
            database: ProjectAdoptionEndpoint(connection: "mysql\u{001B}\nDB", host: "db\u{001B}\nHOST", port: "3306", secretAvailability: .unknown),
            mail: ProjectAdoptionEndpoint(connection: nil, host: nil, port: nil, secretAvailability: .unknown), cache: nil,
            herdYMLPresent: false, unresolvedDecisions: [], safetyBoundary: "Preview only.")
        let output = VaelenCLIMain.projectAdoptionPreviewOutput(preview)
        XCTAssertFalse(output.unicodeScalars.contains { $0.value == 0x1B })
        XCTAssertFalse(output.contains("\nNAME"))
        XCTAssertFalse(output.contains("\nPATH"))
        XCTAssertFalse(output.contains("\nINJECTED"))
        XCTAssertFalse(output.contains("\nROOT"))
        XCTAssertFalse(output.contains("\nDB"))
        XCTAssertFalse(output.contains("\nHOST"))
        XCTAssertTrue(output.contains("INJECTED"))
    }
}
