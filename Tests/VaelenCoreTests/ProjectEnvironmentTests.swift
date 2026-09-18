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

    private func inspect(_ project: Project, routes: [RouteIntent] = [], mailpit: MailpitStatus? = nil) -> ProjectEnvironmentReport {
        ProjectEnvironmentInspector().inspect(
            project: project,
            routes: routes,
            phpPackages: [],
            phpStatuses: [],
            phpDefault: nil,
            mysql: MySQLStatus(state: .stopped, health: "stopped", installedVersion: nil, selectedVersion: nil, pid: nil, port: 3306, socket: "", datadir: "", executablePath: ""),
            mailpit: mailpit ?? MailpitStatus(state: .stopped, health: "stopped", installedVersion: nil, pid: nil, smtpPort: 1025, httpPort: 8025, database: "", uiEndpoint: "", executablePath: ""),
            router: RouterStatus(provider: "test", state: .stopped, health: .unknown, routeCount: 0),
            dns: DNSStatus(state: .installed, ownership: .vaelen, health: "healthy"),
            tls: TLSStatus(state: .absent),
            standardPorts: StandardPortsStatus(state: .absent)
        )
    }

    private func healthyMailpit(port: Int = 1025) -> MailpitStatus {
        MailpitStatus(state: .running, health: "healthy", installedVersion: "1.31.1", pid: 1, smtpPort: port, httpPort: port + 7000, database: "", uiEndpoint: "", executablePath: "")
    }

    private func writeMailEnvironment(_ root: URL, mailer: String = "smtp", host: String = "127.0.0.1", port: Int = 1025, password: String = "null") throws {
        try Data("MAIL_MAILER=\(mailer)\nMAIL_HOST=\(host)\nMAIL_PORT=\(port)\nMAIL_PASSWORD=\(password)\n".utf8).write(to: root.appendingPathComponent(".env"))
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

    func testEndpointMismatchDiagnosticsRespectTriStateAndRequestedState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("version: 1\nservices:\n  mysql: true\n  mailpit: true\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        try Data("DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=3306\nMAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PORT=1025\nMAIL_PASSWORD=null\n".utf8).write(to: root.appendingPathComponent(".env"))

        let matching = inspect(project(at: root), mailpit: healthyMailpit())
        XCTAssertFalse(matching.diagnostics.contains { $0.code == "DB_ENDPOINT_MISMATCH" })
        XCTAssertFalse(matching.diagnostics.contains { $0.code == "MAIL_ENDPOINT_MISMATCH" })

        try Data("DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=13306\nMAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PORT=11026\nMAIL_PASSWORD=null\n".utf8).write(to: root.appendingPathComponent(".env"))
        let mismatched = inspect(project(at: root), mailpit: healthyMailpit())
        XCTAssertTrue(mismatched.diagnostics.contains { $0.code == "DB_ENDPOINT_MISMATCH" })
        XCTAssertTrue(mismatched.diagnostics.contains { $0.code == "MAIL_ENDPOINT_MISMATCH" })
        XCTAssertEqual(mismatched.derived.mailAuthentication.requirement, .unknown)
        XCTAssertFalse(mismatched.diagnostics.contains { $0.code == "MAIL_PASSWORD_MISSING" })
        XCTAssertTrue(mismatched.diagnostics.allSatisfy { !$0.message.contains("null") })

        try Data("version: 1\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        let unrequested = inspect(project(at: root), mailpit: healthyMailpit())
        XCTAssertFalse(unrequested.diagnostics.contains { $0.code == "DB_ENDPOINT_MISMATCH" })
        XCTAssertFalse(unrequested.diagnostics.contains { $0.code == "MAIL_ENDPOINT_MISMATCH" })

        try FileManager.default.removeItem(at: root.appendingPathComponent(".env"))
        try Data("version: 1\nservices:\n  mysql: true\n  mailpit: true\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        let unknown = inspect(project(at: root), mailpit: healthyMailpit())
        XCTAssertFalse(unknown.diagnostics.contains { $0.code == "DB_ENDPOINT_MISMATCH" })
        XCTAssertFalse(unknown.diagnostics.contains { $0.code == "MAIL_ENDPOINT_MISMATCH" })
    }

    func testVaelenMailpitDoesNotRequireAnSMTPPassword() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMailEnvironment(root, port: 1025)
        let report = inspect(project(at: root), mailpit: healthyMailpit())
        XCTAssertEqual(report.configured.mailPassword, .missing)
        XCTAssertEqual(report.derived.mailAuthentication.requirement, .notRequired)
        XCTAssertTrue(report.derived.mailAuthentication.evidence.contains { $0.contains("Vaelen-managed Mailpit") })
        XCTAssertFalse(report.diagnostics.contains { $0.code == "MAIL_PASSWORD_MISSING" })

        try writeMailEnvironment(root, port: 1025, password: "")
        let empty = inspect(project(at: root), mailpit: healthyMailpit())
        XCTAssertEqual(empty.configured.mailPassword, .missing)
        XCTAssertEqual(empty.derived.mailAuthentication.requirement, .notRequired)
        XCTAssertFalse(empty.diagnostics.contains { $0.code == "MAIL_PASSWORD_MISSING" })
    }

    func testArbitrarySMTPDoesNotInferAuthenticationRequirement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMailEnvironment(root, host: "smtp.example.test", port: 587)
        let missing = inspect(project(at: root), mailpit: healthyMailpit())
        XCTAssertEqual(missing.derived.mailAuthentication.requirement, .unknown)
        XCTAssertFalse(missing.diagnostics.contains { $0.code == "MAIL_PASSWORD_MISSING" })

        try writeMailEnvironment(root, host: "smtp.example.test", port: 587, password: "configured")
        let configured = inspect(project(at: root), mailpit: healthyMailpit())
        XCTAssertEqual(configured.configured.mailPassword, .available)
        XCTAssertEqual(configured.derived.mailAuthentication.requirement, .unknown)
        XCTAssertFalse(configured.diagnostics.contains { $0.code == "MAIL_PASSWORD_MISSING" })
    }

    func testMailpitInferenceRequiresLoopbackAndMatchingObservedPortAndService() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMailEnvironment(root, host: "localhost", port: 1025)
        XCTAssertEqual(inspect(project(at: root), mailpit: healthyMailpit()).derived.mailAuthentication.requirement, .unknown)

        try writeMailEnvironment(root, port: 1026)
        XCTAssertEqual(inspect(project(at: root), mailpit: healthyMailpit()).derived.mailAuthentication.requirement, .unknown)

        try writeMailEnvironment(root, port: 1025)
        let stopped = MailpitStatus(state: .stopped, health: "stopped", installedVersion: "1.31.1", pid: nil, smtpPort: 1025, httpPort: 8025, database: "", uiEndpoint: "", executablePath: "")
        XCTAssertEqual(inspect(project(at: root), mailpit: stopped).derived.mailAuthentication.requirement, .unknown)
    }

    func testMailAuthenticationDiagnosticRuleRequiresExplicitRequiredState() throws {
        XCTAssertNotNil(ProjectEnvironmentInspector.mailPasswordDiagnostic(authentication: .required, password: .missing))
        XCTAssertNil(ProjectEnvironmentInspector.mailPasswordDiagnostic(authentication: .required, password: .available))
        XCTAssertNil(ProjectEnvironmentInspector.mailPasswordDiagnostic(authentication: .unknown, password: .missing))
        XCTAssertNil(ProjectEnvironmentInspector.mailPasswordDiagnostic(authentication: .notRequired, password: .missing))
        XCTAssertNil(ProjectEnvironmentInspector.mailPasswordDiagnostic(authentication: .notApplicable, password: .missing))
    }

    func testNonSMTPTransportDoesNotProduceSMTPPasswordDiagnosticOrExposeSecrets() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMailEnvironment(root, mailer: "log", password: "secret-value")
        let report = inspect(project(at: root))
        XCTAssertEqual(report.derived.mailAuthentication.requirement, .notApplicable)
        XCTAssertFalse(report.diagnostics.contains { $0.code == "MAIL_PASSWORD_MISSING" })
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret-value"))
    }
}
