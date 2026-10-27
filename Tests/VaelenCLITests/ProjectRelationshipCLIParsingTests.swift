import XCTest
import VaelenCore
@testable import VaelenCLI

final class ProjectRelationshipCLIParsingTests: XCTestCase {
    func testProjectDatabaseCommandsParseOperationMetadataWithoutSecretArguments() throws {
        guard case .projectDatabaseCreate(let database, let user, let selector, let json) = try VaelenCLIMain.parse(["project", "db", "create", "app_db", "app_user", "demo", "--json"]) else { return XCTFail("project db create did not parse") }
        XCTAssertEqual(database, "app_db"); XCTAssertEqual(user, "app_user"); XCTAssertEqual(selector, "demo"); XCTAssertTrue(json)
        let operationID = UUID()
        guard case .projectDatabaseStatus(let parsedID, let statusSelector, false) = try VaelenCLIMain.parse(["project", "db", "status", operationID.uuidString, "demo"]) else { return XCTFail("project db status did not parse") }
        XCTAssertEqual(parsedID, operationID); XCTAssertEqual(statusSelector, "demo")
        guard case .projectDatabaseRetry(let retryID, let retrySelector, true) = try VaelenCLIMain.parse(["project", "db", "retry", operationID.uuidString, "demo", "--json"]) else { return XCTFail("project db retry did not parse") }
        XCTAssertEqual(retryID, operationID); XCTAssertEqual(retrySelector, "demo")
        guard case .projectDatabasePassword(let revealID, let revealSelector, false) = try VaelenCLIMain.parse(["project", "db", "password", "reveal", operationID.uuidString, "demo"]) else { return XCTFail("explicit reveal did not parse") }
        XCTAssertEqual(revealID, operationID); XCTAssertEqual(revealSelector, "demo")
        guard case .projectDatabasePassword(_, nil, true) = try VaelenCLIMain.parse(["project", "db", "password", "copy", operationID.uuidString]) else { return XCTFail("explicit copy did not parse") }
        for args in [["project", "db", "password", operationID.uuidString], ["project", "db", "password", "reveal", operationID.uuidString, "--json"], ["project", "db", "password", "copy", operationID.uuidString, "demo", "extra"]] {
            XCTAssertThrowsError(try VaelenCLIMain.parse(args))
        }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["project", "db", "create", "db", "user", "--password", "secret"]))
    }

    func testParkCommandsAcceptCurrentDirectoryOrExplicitPath() throws {
        guard case .park(let currentParkPath) = try VaelenCLIMain.parse(["park"]) else {
            return XCTFail("park without a path should use the current directory")
        }
        XCTAssertNil(currentParkPath)
        guard case .park(let path) = try VaelenCLIMain.parse(["park", "workspace"]) else {
            return XCTFail("park did not parse")
        }
        XCTAssertEqual(path, "workspace")

        guard case .unpark(let unparkedPath) = try VaelenCLIMain.parse(["unpark", "workspace"]) else {
            return XCTFail("unpark did not parse")
        }
        XCTAssertEqual(unparkedPath, "workspace")
        guard case .unpark(let currentUnparkPath) = try VaelenCLIMain.parse(["unpark"]) else {
            return XCTFail("unpark without a path should use the current directory")
        }
        XCTAssertNil(currentUnparkPath)
        for args in [["park", "one", "two"], ["unpark", "one", "two"]] {
            XCTAssertThrowsError(try VaelenCLIMain.parse(args)) { error in
                XCTAssertTrue(String(describing: error).contains("val \(args[0]) [workspace-folder]"))
                XCTAssertFalse(String(describing: error).contains("Usage: val <command>"))
            }
        }
    }

    func testUnparkVerificationUsesTheResolvedCurrentDirectoryTarget() {
        XCTAssertEqual(
            VaelenCLIMain.unparkTargetPath(nil, workingDirectory: "/tmp/workspace"),
            "/tmp/workspace"
        )
    }

    func testBareUnlinkTargetRemovesOnlyTemporaryRelationshipAndPreservesFilesAndRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-unlink-cli-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectPath = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let sentinel = projectPath.appendingPathComponent("keep.txt")
        try Data("preserve me".utf8).write(to: sentinel)

        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let linked = try await registry.link(path: projectPath)
        let route = Route(hostname: "unlink-fixture.test", target: .staticFiles(documentRoot: projectPath.path), tls: .disabled)
        let routeRepository = RouteIntentRepository(store: store)
        try routeRepository.upsert(RouteIntent(route: route, projectID: linked.id?.rawValue, projectPath: projectPath.path))

        let cwdTarget = VaelenCLIMain.unlinkTargetPath(nil, workingDirectory: projectPath.path)
        XCTAssertEqual(cwdTarget, projectPath.standardizedFileURL.path)
        try await registry.unlink(path: URL(fileURLWithPath: cwdTarget))

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try routeRepository.all().map(\.route.hostname), ["unlink-fixture.test"])
        let remaining = try await registry.linkedProjects()
        XCTAssertFalse(remaining.contains { $0.id == linked.id })
    }

    func testLinkAndUnlinkAcceptHerdSiteNameCurrentDirectoryAndExplicitPathForms() throws {
        guard case .link(let currentDirectoryPath, nil) = try VaelenCLIMain.parse(["link"]) else {
            return XCTFail("link without a path should use the current directory")
        }
        XCTAssertNil(currentDirectoryPath)

        guard case .link(nil, let hostname) = try VaelenCLIMain.parse(["link", "some-site"]) else {
            return XCTFail("Herd-like site name did not map to the current directory")
        }
        XCTAssertEqual(hostname, "some-site.test")
        guard case .link(let explicitPath, nil) = try VaelenCLIMain.parse(["link", "./project"]) else {
            return XCTFail("path-like positional link form did not parse")
        }
        XCTAssertEqual(explicitPath, "./project")
        guard case .link(let namedPath, _) = try VaelenCLIMain.parse(["link", "--path", "project"]) else {
            return XCTFail("--path did not disambiguate a bare directory name")
        }
        XCTAssertEqual(namedPath, "project")
        guard case .link(let pathWithHost, let exactHost) = try VaelenCLIMain.parse(["link", "--path", "project", "--host", "api.example.test"]) else {
            return XCTFail("explicit path plus exact host did not parse")
        }
        XCTAssertEqual(pathWithHost, "project")
        XCTAssertEqual(exactHost, "api.example.test")

        guard case .unlink(let currentUnlinkPath) = try VaelenCLIMain.parse(["unlink"]) else {
            return XCTFail("unlink without a path should use the current directory")
        }
        XCTAssertNil(currentUnlinkPath)

        guard case .unlink(let unlinkedPath) = try VaelenCLIMain.parse(["unlink", "project"]) else {
            return XCTFail("unlink did not parse")
        }
        XCTAssertEqual(unlinkedPath, "project")
        XCTAssertThrowsError(try VaelenCLIMain.parse(["unlink", "one", "two"])) { error in
            XCTAssertTrue(String(describing: error).contains("val unlink <project-directory>"))
            XCTAssertFalse(String(describing: error).contains("Usage: val <command>"))
        }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["unlink", "--name", "project"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["link", "one", "two"]))
        let temporaryProject = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-unlink-fixture-\(UUID().uuidString)")
        XCTAssertEqual(VaelenCLIMain.unlinkTargetPath(nil, workingDirectory: temporaryProject.path), temporaryProject.standardizedFileURL.path)
        XCTAssertEqual(VaelenCLIMain.unlinkTargetPath("child", workingDirectory: temporaryProject.path), temporaryProject.appendingPathComponent("child").standardizedFileURL.path)
    }

    func testRelationshipListsSupportOnlyTheStructuredOutputOption() throws {
        guard case .parks(json: false) = try VaelenCLIMain.parse(["parks"]) else {
            return XCTFail("parks did not parse")
        }
        guard case .parks(json: true) = try VaelenCLIMain.parse(["parks", "--json"]) else {
            return XCTFail("parks --json did not parse")
        }
        guard case .links(json: false) = try VaelenCLIMain.parse(["links"]) else {
            return XCTFail("links did not parse")
        }
        guard case .links(json: true) = try VaelenCLIMain.parse(["links", "--json"]) else {
            return XCTFail("links --json did not parse")
        }
        guard case .parks(json: false) = try VaelenCLIMain.parse(["paths"]) else {
            return XCTFail("legacy paths alias did not parse")
        }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["parks", "unexpected"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["links", "--json", "unexpected"]))
        guard case .edit(selector: nil) = try VaelenCLIMain.parse(["edit"]) else { return XCTFail("edit should support current-directory project selection") }
        guard case .edit(selector: "sample") = try VaelenCLIMain.parse(["edit", "sample"]) else { return XCTFail("edit selector was not parsed") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["edit", "one", "two"]))
    }

    func testHelpDocumentsProjectRelationshipSyntax() throws {
        let helpEntries = [
            ("park", "val park [workspace-folder]"),
            ("parks", "val parks --json"),
            ("unpark", "val unpark [workspace-folder]"),
            ("link", "val link <site-name>"),
            ("links", "val links --json"),
            ("edit", "val edit [project]"),
            ("unlink", "val unlink <project-directory>")
        ]
        for (command, entry) in helpEntries {
            XCTAssertTrue(VaelenCLIMain.helpText(for: [command]).contains(entry), "missing current help entry for \(command)")
        }
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["php"]).contains("config"))
        guard case .phpConfig(version: nil) = try VaelenCLIMain.parse(["php", "config"]) else { return XCTFail("PHP config should open the managed configuration folder") }
        guard case .phpConfig(version: "8.4.23") = try VaelenCLIMain.parse(["php", "config", "8.4.23"]) else { return XCTFail("PHP config version should select the version-specific FPM ini") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["php", "config", "8.4.23", "unexpected"]))
        guard case .help(path: []) = try VaelenCLIMain.parse(["--help"]) else {
            return XCTFail("--help did not parse")
        }
    }

    func testEmptyRelationshipListsHaveClearHumanOutput() {
        XCTAssertEqual(VaelenCLIMain.parkedPathsOutput([]), "Parked folders\n\nNo parked folders.")
        XCTAssertEqual(VaelenCLIMain.linkedProjectsOutput([]), "Linked projects\nNo linked projects.")
    }
}
