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

    func testRouteTargetDivergenceRequiresExactDurableTransitionProvenance() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["bootstrap", "config", "public"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        try Data("<?php".utf8).write(to: root.appendingPathComponent("artisan"))
        try Data("<?php".utf8).write(to: root.appendingPathComponent("public/index.php"))
        try Data("version: 1\nphp: \"8.4\"\nweb:\n  secure: true\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        let project = project(at: root)
        let projectID = try XCTUnwrap(project.id?.rawValue)
        let previous = Route(hostname: "transition.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: root.appendingPathComponent("public").path), tls: .local)
        let desired = Route(id: previous.id, hostname: previous.hostname, target: .fastCGI(socketPath: "/tmp/php-b.sock", documentRoot: root.appendingPathComponent("public").path), tls: previous.tls)
        let package = PHPPackage(version: "8.4.23", architecture: "arm64", packagePath: "/tmp/php", cliPath: "/tmp/php", fpmPath: "/tmp/php-fpm", source: "test", cliSHA256: "cli", fpmSHA256: "fpm", installedAt: Date())
        let status = PHPStatus(version: "8.4.23", package: package, state: .running, pid: 1, socket: "/tmp/php-b.sock", health: "healthy", isDefault: true)
        let common = ProjectEnvironmentInspector()
        let inspect: ([RouteIntent], [Route], [RouteTargetTransition]) -> ProjectEnvironmentReport = { intents, runtime, transitions in
            common.inspect(project: project, routes: intents, phpPackages: [package], phpStatuses: [status], phpDefault: "8.4", mysql: nil, mailpit: nil, router: RouterStatus(provider: "test", state: .running, health: .healthy, routeCount: runtime.count), dns: DNSStatus(state: .installed, ownership: .vaelen, health: "healthy"), tls: TLSStatus(state: .trusted, trustObserved: true), standardPorts: StandardPortsStatus(state: .healthy), registeredProjects: [project], runtimeRoutes: runtime, pendingTransitions: transitions)
        }
        let intent = RouteIntent(route: desired, projectID: projectID, projectPath: root.path)
        let unexplained = inspect([intent], [previous], [])
        XCTAssertEqual(unexplained.routeTargets.first?.disposition, .blocked)
        let unexplainedPlan = ProjectReconciliationPlanner().plan(report: unexplained)
        XCTAssertEqual(unexplainedPlan.operations.first { $0.id.hasPrefix("route.php-target.update.") }?.disposition, .blocked)
        let transition = RouteTargetTransition(routeID: previous.id, projectID: projectID, previousRoute: previous, desiredRoute: desired, previousProviderFingerprint: try routeProviderFingerprint(previous), desiredProviderFingerprint: try routeProviderFingerprint(desired), previousSocket: "/tmp/php-a.sock", desiredSocket: "/tmp/php-b.sock")
        let knownPartial = inspect([intent], [previous], [transition])
        XCTAssertEqual(knownPartial.routeTargets.first?.disposition, .pending)
        let wrongProvider = inspect([intent], [Route(id: previous.id, hostname: previous.hostname, target: .fastCGI(socketPath: "/tmp/php-c.sock", documentRoot: root.appendingPathComponent("public").path), tls: previous.tls)], [transition])
        XCTAssertEqual(wrongProvider.routeTargets.first?.disposition, .blocked)

        let wrongProject = RouteTargetTransition(routeID: previous.id, projectID: UUID(), previousRoute: previous, desiredRoute: desired, previousProviderFingerprint: try routeProviderFingerprint(previous), desiredProviderFingerprint: try routeProviderFingerprint(desired), previousSocket: "/tmp/php-a.sock", desiredSocket: "/tmp/php-b.sock")
        XCTAssertEqual(inspect([intent], [previous], [wrongProject]).routeTargets.first?.disposition, .blocked)
        let changedAssociation = RouteIntent(route: desired, projectID: UUID(), projectPath: root.path)
        let changedAssociationReport = inspect([changedAssociation], [previous], [transition])
        XCTAssertTrue(changedAssociationReport.routeTargets.isEmpty)
        XCTAssertEqual(changedAssociationReport.observed.route.associationState, .orphaned)
        let orphaned = common.inspect(project: project, routes: [changedAssociation], phpPackages: [package], phpStatuses: [status], phpDefault: "8.4", mysql: nil, mailpit: nil, router: RouterStatus(provider: "test", state: .running, health: .healthy, routeCount: 1), dns: DNSStatus(state: .installed, ownership: .vaelen, health: "healthy"), tls: TLSStatus(state: .trusted, trustObserved: true), standardPorts: StandardPortsStatus(state: .healthy), registeredProjects: [project], runtimeRoutes: [previous], pendingTransitions: [transition])
        XCTAssertTrue(orphaned.routeTargets.isEmpty)
        XCTAssertEqual(orphaned.observed.route.associationState, .orphaned)

        let packageC = PHPPackage(version: "8.4.24", architecture: "arm64", packagePath: "/tmp/php-c", cliPath: "/tmp/php-c", fpmPath: "/tmp/php-fpm-c", source: "test", cliSHA256: "cli-c", fpmSHA256: "fpm-c", installedAt: Date())
        let statusC = PHPStatus(version: "8.4.24", package: packageC, state: .running, pid: 1, socket: "/tmp/php-c.sock", health: "healthy", isDefault: true)
        let staleDesired = common.inspect(project: project, routes: [intent], phpPackages: [packageC], phpStatuses: [statusC], phpDefault: "8.4", mysql: nil, mailpit: nil, router: RouterStatus(provider: "test", state: .running, health: .healthy, routeCount: 1), dns: DNSStatus(state: .installed, ownership: .vaelen, health: "healthy"), tls: TLSStatus(state: .trusted, trustObserved: true), standardPorts: StandardPortsStatus(state: .healthy), registeredProjects: [project], runtimeRoutes: [previous], pendingTransitions: [transition])
        XCTAssertEqual(staleDesired.routeTargets.first?.disposition, .blocked)

        let semanticVariants = [
            Route(id: previous.id, hostname: "changed.test", target: desired.target, tls: desired.tls),
            Route(id: previous.id, hostname: desired.hostname, target: .fastCGI(socketPath: desired.target.fastCGISocket!, documentRoot: "/tmp/other/public"), tls: desired.tls),
            Route(id: previous.id, hostname: desired.hostname, target: desired.target, tls: .disabled)
        ]
        for variant in semanticVariants {
            XCTAssertEqual(inspect([RouteIntent(route: variant, projectID: projectID, projectPath: root.path)], [previous], [transition]).routeTargets.first?.disposition, .blocked)
        }

        let missingProvider = inspect([intent], [], [transition])
        XCTAssertEqual(missingProvider.routeTargets.first?.disposition, .blocked)

        let neitherExpected = inspect([intent], [Route(id: previous.id, hostname: previous.hostname, target: .fastCGI(socketPath: "/tmp/php-z.sock", documentRoot: root.appendingPathComponent("public").path), tls: previous.tls)], [transition])
        XCTAssertEqual(neitherExpected.routeTargets.first?.disposition, .blocked)

        let noTransition = { (router: RouterStatus, statuses: [PHPStatus], runtime: [Route]?) in
            common.inspect(project: project, routes: [intent], phpPackages: [package], phpStatuses: statuses, phpDefault: "8.4", mysql: nil, mailpit: nil, router: router, dns: DNSStatus(state: .installed, ownership: .vaelen, health: "healthy"), tls: TLSStatus(state: .trusted, trustObserved: true), standardPorts: StandardPortsStatus(state: .healthy), registeredProjects: [project], runtimeRoutes: runtime, pendingTransitions: [])
        }
        let stopped = noTransition(RouterStatus(provider: "test", state: .stopped, health: .unknown, routeCount: 1), [status], [desired])
        let unhealthy = noTransition(RouterStatus(provider: "test", state: .running, health: .unhealthy, routeCount: 1), [status], [desired])
        let adminUnavailable = noTransition(RouterStatus(provider: "test", state: .running, health: .healthy, routeCount: 0), [status], nil)
        let ownershipUnproven = noTransition(RouterStatus(provider: "test", state: .running, health: .healthy, routeCount: 1), [PHPStatus(version: "8.4.23", package: nil, state: .running, pid: 1, socket: "/tmp/php-b.sock", health: "healthy", isDefault: true)], [desired])
        let fpmUnhealthy = noTransition(RouterStatus(provider: "test", state: .running, health: .healthy, routeCount: 1), [PHPStatus(version: "8.4.23", package: package, state: .running, pid: 1, socket: "/tmp/php-b.sock", health: "unhealthy", isDefault: true)], [desired])
        for report in [stopped, unhealthy, adminUnavailable, ownershipUnproven] {
            XCTAssertEqual(report.routeTargets.first?.disposition, .blocked)
        }
        XCTAssertEqual(fpmUnhealthy.routeTargets.first?.disposition, .deferred)
    }

    func testRouteProviderFingerprintCoversAllProviderSemantics() throws {
        let base = Route(hostname: "fingerprint.test", target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/public"), tls: .local)
        let variants = [
            Route(id: base.id, hostname: "other.test", target: base.target, tls: base.tls),
            Route(id: base.id, hostname: base.hostname, target: .fastCGI(socketPath: "/tmp/php-b.sock", documentRoot: "/tmp/public"), tls: base.tls),
            Route(id: base.id, hostname: base.hostname, target: .fastCGI(socketPath: "/tmp/php-a.sock", documentRoot: "/tmp/other"), tls: base.tls),
            Route(id: base.id, hostname: base.hostname, target: base.target, tls: .disabled),
            Route(id: base.id, hostname: base.hostname, target: .staticFiles(documentRoot: "/tmp/public"), tls: base.tls)
        ]
        let original = try routeProviderFingerprint(base)
        XCTAssertTrue(try variants.allSatisfy { try routeProviderFingerprint($0) != original })
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
