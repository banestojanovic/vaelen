import Foundation
import XCTest
@testable import VaelenCore

final class ProjectEnvironmentTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func project(at root: URL, registration: ProjectRegistrationKind = .linked) -> Project {
        Project(id: registration == .linked ? ProjectID() : nil,
                name: root.lastPathComponent,
                rootPath: CanonicalPath(url: root),
                registrationKind: registration,
                availability: .available)
    }

    private func inspect(_ project: Project, routes: [RouteIntent] = []) -> ProjectEnvironmentReport {
        ProjectEnvironmentInspector().inspect(
            project: project,
            routes: routes,
            phpPackages: [],
            phpStatuses: [],
            phpDefault: nil,
            mysql: MySQLStatus(state: .stopped, health: "stopped", installedVersion: nil, selectedVersion: nil, pid: nil, port: 3306, socket: "", datadir: "", executablePath: ""),
            mailpit: MailpitStatus(state: .stopped, health: "stopped", installedVersion: nil, pid: nil, smtpPort: 1025, httpPort: 8025, database: "", uiEndpoint: "", executablePath: ""),
            router: RouterStatus(provider: "test", state: .stopped, health: .unknown, routeCount: 0),
            dns: DNSStatus(state: .installed, ownership: .vaelen, health: "healthy"),
            tls: TLSStatus(state: .absent),
            standardPorts: StandardPortsStatus(state: .absent)
        )
    }

    func testValidLaravelEnvironmentIsObservedWithoutReturningSecrets() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["bootstrap", "config", "public"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("<?php".utf8).write(to: root.appendingPathComponent("artisan"))
        try Data("<?php".utf8).write(to: root.appendingPathComponent("public/index.php"))
        try Data("{\"require\":{\"laravel/framework\":\"^11.0\",\"php\":\"^8.3\"}}".utf8).write(to: root.appendingPathComponent("composer.json"))
        try Data("version: 1\nphp: \"8.3\"\nweb:\n  secure: true\nservices:\n  mysql: true\n  mailpit: true\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        try Data("DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=3306\nDB_DATABASE=app\nDB_USERNAME=vaelen\nDB_PASSWORD=secret-value\nMAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PORT=1025\nMAIL_PASSWORD=\n".utf8).write(to: root.appendingPathComponent(".env"))

        let report = inspect(project(at: root))

        XCTAssertEqual(report.desired.file, .valid)
        XCTAssertEqual(report.desired.php, "8.3")
        XCTAssertEqual(report.derived.framework.framework, "Laravel")
        XCTAssertEqual(report.derived.framework.confidence, .high)
        XCTAssertEqual(report.configured.database, "app")
        XCTAssertEqual(report.secret.databasePassword, .available)
        XCTAssertEqual(report.secret.mailPassword, .missing)
        XCTAssertFalse(report.configured.source.contains("secret-value"))
        XCTAssertFalse(report.secret.notes.isEmpty)
    }

    func testUnknownYamlFieldsAndUnsupportedVersionsAreReported() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("version: 2\nphp: 8.3\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        let report = inspect(project(at: root))
        XCTAssertEqual(report.desired.file, .invalid)
        XCTAssertTrue(report.diagnostics.contains { $0.code == "VAELEN_CONFIG_INVALID" })

        try Data("version: 1\nunknown: true\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        let second = inspect(project(at: root))
        XCTAssertEqual(second.desired.file, .invalid)
        XCTAssertTrue(second.desired.fileError?.contains("unknown field") == true)
    }

    func testDiscoveredProjectIsEphemeralAndInspectionDoesNotMutateFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("DB_PASSWORD=\"quoted\"\nMAIL_MAILER=smtp\nMAIL_PASSWORD=null\n".utf8).write(to: root.appendingPathComponent(".env"))
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let report = inspect(project(at: root, registration: .discovered))
        let after = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

        XCTAssertNil(report.identity.id)
        XCTAssertEqual(report.identity.registration, .discovered)
        XCTAssertTrue(report.diagnostics.contains { $0.code == "PROJECT_DISCOVERED_EPHEMERAL" })
        XCTAssertEqual(report.secret.databasePassword, .available)
        XCTAssertEqual(report.secret.mailPassword, .missing)
        XCTAssertEqual(before, after)
    }

    func testMissingRouteAndUnavailableRequestedServicesProduceDiagnostics() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("version: 1\nservices:\n  mysql: true\n  mailpit: true\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        let report = inspect(project(at: root))
        let codes = Set(report.diagnostics.map(\.code))
        XCTAssertTrue(codes.contains("ROUTE_INTENT_MISSING"))
        XCTAssertTrue(codes.contains("MYSQL_NOT_HEALTHY"))
        XCTAssertTrue(codes.contains("MAILPIT_NOT_HEALTHY"))
    }
}
