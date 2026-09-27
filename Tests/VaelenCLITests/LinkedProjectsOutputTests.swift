import XCTest
@testable import VaelenCLI
import VaelenCore
import VaelenIPC

final class LinkedProjectsOutputTests: XCTestCase {
    func testAllHostsAndObservationAreRenderedAndJSONProjectContractRemainsUnchanged() throws {
        let id = UUID()
        let project = ProjectWire(id: id, name: "sample", path: "/tmp/sample project", registration: "linked", availability: "available")
        let first = Route(hostname: "sample.test", target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/tmp/sample/public"), tls: .disabled)
        let second = Route(hostname: "secure.sample.test", target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: "/tmp/sample/public"), tls: .local)
        let routes = [RouteIntent(route: first, projectID: id, projectPath: project.path), RouteIntent(route: second, projectID: id, projectPath: project.path)]
        let output = linkedProjectsHumanOutput([project], routes: routes, observedRoutes: [second], phpByProject: [project.path: "8.4.23"], width: 120, color: false)
        XCTAssertTrue(output.contains("http://sample.test"))
        XCTAssertTrue(output.contains("https://secure.sample.test"))
        XCTAssertTrue(output.contains("8.4.23"))
        XCTAssertTrue(output.contains("Not observed"))
        XCTAssertTrue(output.contains("Observed (config)"))
        XCTAssertTrue(output.contains("does not test HTTP reachability"))
        XCTAssertTrue(output.contains("/tmp/sample project"))
        XCTAssertFalse(output.contains("+---"))
        let colored = linkedProjectsHumanOutput([project], routes: routes, observedRoutes: [second], phpByProject: [:], width: 120, color: true)
        XCTAssertTrue(colored.contains("\u{001B}[32mAvailable\u{001B}[0m"))

        struct ProjectEnvelope: Encodable { let projects: [ProjectWire] }
        let json = try IPCCodec.encode(ProjectEnvelope(projects: [project]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["projects"])
    }

    func testNarrowOutputWrapsPathsWithoutDroppingHostsAndMarksMissingFolders() {
        let id = UUID()
        let path = "/tmp/a-very-long-temporary-project-folder-name-that-must-wrap/sample"
        let project = ProjectWire(id: id, name: "sample", path: path, registration: "linked", availability: "missing")
        let route = Route(hostname: "sample.test", target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: path), tls: .local)
        let output = linkedProjectsHumanOutput([project], routes: [RouteIntent(route: route, projectID: id, projectPath: path)], observedRoutes: [], phpByProject: [:], width: 40, color: false)
        XCTAssertTrue(output.contains("Availability"))
        XCTAssertTrue(output.contains("missing"))
        XCTAssertTrue(output.contains("https://sample.test"))
        XCTAssertTrue(output.contains("PHP"))
        XCTAssertTrue(output.contains("Unavailable"))
        XCTAssertTrue(output.contains("Caddy config"))
        XCTAssertTrue(output.contains("Not observed"))
        XCTAssertTrue(output.contains("a-very-long"), output)
        XCTAssertTrue(output.contains("sample"))
        XCTAssertLessThanOrEqual(output.split(separator: "\n").map(\.count).max() ?? 0, 40)
    }

    func testParkedFolderListHasHeadingSpacingAndAvailabilityColor() {
        let folder = ParkedPathWire(id: UUID(), path: "/tmp/workspace", availability: "available")
        let plain = VaelenCLIMain.parkedPathsOutput([folder], width: 80, color: false)
        XCTAssertTrue(plain.hasPrefix("Parked folders\n\n"))
        XCTAssertTrue(plain.contains("Available"))
        XCTAssertFalse(plain.contains("\u{001B}["))
        XCTAssertTrue(VaelenCLIMain.parkedPathsOutput([folder], width: 80, color: true).contains("\u{001B}[32mAvailable\u{001B}[0m"))
    }

    func testEditSelectionAndAmbiguityErrorsUseSharedProjectPolicy() throws {
        guard case .edit(selector: nil) = try VaelenCLIMain.parse(["edit"]) else { return XCTFail("edit without selector should use cwd") }
        guard case .edit(selector: "/tmp/sample") = try VaelenCLIMain.parse(["edit", "/tmp/sample"]) else { return XCTFail("explicit project selector not parsed") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["edit", "one", "two"]))
        let first = ProjectWire(id: UUID(), name: "same", path: "/tmp/one/same", registration: "linked", availability: "available")
        let second = ProjectWire(id: UUID(), name: "same", path: "/tmp/two/same", registration: "linked", availability: "available")
        XCTAssertThrowsError(try selectedProject("same", projects: [first, second], workingDirectory: "/tmp")) { error in
            XCTAssertTrue(String(describing: error).contains("ambiguous"))
            XCTAssertTrue(String(describing: error).contains("/tmp/one/same"))
            XCTAssertTrue(String(describing: error).contains("/tmp/two/same"))
        }
    }
}
