import Foundation
import XCTest
@testable import VaelenCore

final class ProjectReconciliationTests: XCTestCase {
    private func report(php: String? = "8.4", resolvedPHP: String? = "8.4.23", phpRunning: Bool = true, mysql: MySQLStatus? = nil, mailpit: MailpitStatus? = nil, secureWeb: Bool? = true, dbMatches: Bool? = true, mailMatches: Bool? = true, dnsHealth: String = "healthy", registration: ProjectRegistrationKind = .linked, routeTargetMatchesPHP: Bool? = nil) -> ProjectEnvironmentReport {
        let root = CanonicalPath(url: URL(fileURLWithPath: "/tmp/reconciliation-fixture", isDirectory: true))
        let project = Project(id: registration == .linked ? ProjectID() : nil, name: "fixture", rootPath: root, registrationKind: registration, availability: .available)
        let desired = ProjectDesiredEnvironment(file: .valid, php: php, secureWeb: secureWeb, mysql: mysql != nil, mailpit: mailpit != nil)
        let configured = ProjectConfiguredEnvironment(envFile: root.string + "/.env", envFilePresent: true, dbConnection: "mysql", dbHost: "127.0.0.1", dbPort: "13306", database: "app", usernameConfigured: true, password: .available, mailer: "smtp", mailHost: "127.0.0.1", mailPort: "11025", mailPassword: .missing)
        let observedPHP = ProjectObservedPHP(installedVersions: resolvedPHP.map { [$0] } ?? [], runningVersions: phpRunning ? (resolvedPHP.map { [$0] } ?? []) : [], resolvedVersion: resolvedPHP, resolvedState: resolvedPHP == nil ? "unresolved" : (phpRunning ? "running" : "not-running"), defaultVersion: resolvedPHP)
        let observedRoute = ProjectObservedRoute(intentExists: true, hostname: "fixture.test", documentRoot: "/tmp/reconciliation-fixture/public", target: "fastcgi socket", tls: .local, routerState: .running, routerHealth: .healthy)
        let observed = ProjectObservedEnvironment(php: observedPHP, mysql: mysql, mailpit: mailpit, route: observedRoute, dns: DNSStatus(state: .installed, ownership: .vaelen, health: dnsHealth), tls: TLSStatus(state: .trusted, trustObserved: true), standardPorts: StandardPortsStatus(state: .healthy))
        let derived = ProjectDerivedEnvironment(framework: ProjectFrameworkInspection(framework: "Laravel", confidence: .high, evidence: ["artisan"], suggestedDocumentRoot: "public/"), phpResolution: resolvedPHP == nil ? "desired \(php ?? "unknown") is unavailable" : "\(php ?? "unknown") resolves to \(resolvedPHP!)", dbEndpoint: .init(configuredHost: "127.0.0.1", configuredPort: "13306", expectedHost: "127.0.0.1", expectedPort: 13306, matches: dbMatches), mailEndpoint: .init(configuredHost: "127.0.0.1", configuredPort: "11025", expectedHost: "127.0.0.1", expectedPort: 11025, matches: mailMatches), mailAuthentication: .init(requirement: .unknown), routeDocumentRootMatches: true, routeTargetMatchesPHP: routeTargetMatchesPHP, configCache: .init(state: "absent", cachePath: root.string + "/bootstrap/cache/config.php"))
        return ProjectEnvironmentReport(identity: .init(project: project), desired: desired, configured: configured, observed: observed, derived: derived, secret: .init(databasePassword: .available, mailPassword: .missing), diagnostics: [])
    }

    private func healthyMailpit() -> MailpitStatus {
        MailpitStatus(state: .running, health: "healthy", installedVersion: "1.31.1", pid: 1, smtpPort: 11025, httpPort: 18025, database: "/tmp/messages.db", uiEndpoint: "http://127.0.0.1:18025", executablePath: "/tmp/mailpit")
    }

    func testHealthyProjectPlanIsSatisfiedAndHasNoExecutableOperations() {
        let mysql = MySQLStatus(state: .running, health: "healthy", installedVersion: "8.4.11", selectedVersion: "8.4.11", pid: 1, port: 13306, socket: "/tmp/mysql.sock", datadir: "/tmp/mysql", executablePath: "/tmp/mysqld")
        let plan = ProjectReconciliationPlanner().plan(report: report(mysql: mysql, mailpit: healthyMailpit()))
        XCTAssertEqual(plan.state, .satisfied)
        XCTAssertFalse(plan.operations.contains { $0.disposition == .actionable })
    }

    func testStoppedMailpitIsTheOnlyActionableOperation() {
        let mysql = MySQLStatus(state: .running, health: "healthy", installedVersion: "8.4.11", selectedVersion: "8.4.11", pid: 1, port: 13306, socket: "/tmp/mysql.sock", datadir: "/tmp/mysql", executablePath: "/tmp/mysqld")
        let stopped = MailpitStatus(state: .stopped, health: "stopped", installedVersion: "1.31.1", pid: nil, smtpPort: 11025, httpPort: 18025, database: "/tmp/messages.db", uiEndpoint: "http://127.0.0.1:18025", executablePath: "/tmp/mailpit")
        let plan = ProjectReconciliationPlanner().plan(report: report(mysql: mysql, mailpit: stopped))
        XCTAssertEqual(plan.state, .actionable)
        XCTAssertEqual(plan.operations.filter { $0.disposition == .actionable }.map(\.id), ["mailpit.start"])
    }

    func testMailpitAbsentAndConflictAreNotExecutable() {
        let absent = MailpitStatus(state: .notInstalled, health: "not-installed", installedVersion: nil, pid: nil, smtpPort: 11025, httpPort: 18025, database: "/tmp/messages.db", uiEndpoint: "http://127.0.0.1:18025", executablePath: "")
        let absentPlan = ProjectReconciliationPlanner().plan(report: report(mysql: nil, mailpit: absent))
        XCTAssertEqual(absentPlan.operations.first { $0.id == "mailpit.install" }?.disposition, .deferred)

        let conflict = MailpitStatus(state: .conflict, health: "port-conflict-11025", installedVersion: "1.31.1", pid: nil, smtpPort: 11025, httpPort: 18025, database: "/tmp/messages.db", uiEndpoint: "http://127.0.0.1:18025", executablePath: "/tmp/mailpit")
        let conflictPlan = ProjectReconciliationPlanner().plan(report: report(mysql: nil, mailpit: conflict))
        XCTAssertEqual(conflictPlan.operations.first { $0.id == "mailpit.start" }?.mutationClass, .externalConflict)
        XCTAssertEqual(conflictPlan.operations.first { $0.id == "mailpit.start" }?.disposition, .blocked)
    }

    func testApplicationMismatchesAndUnavailablePHPAreBlockersWithoutSecrets() throws {
        let plan = ProjectReconciliationPlanner().plan(report: report(php: "8.3", resolvedPHP: nil, mysql: nil, mailpit: healthyMailpit(), dbMatches: false, mailMatches: false))
        XCTAssertEqual(plan.state, .blocked)
        XCTAssertTrue(plan.operations.contains { $0.id == "application.db-endpoint" && $0.mutationClass == .applicationMutation })
        XCTAssertTrue(plan.operations.contains { $0.id == "application.mail-endpoint" && $0.mutationClass == .applicationMutation })
        XCTAssertTrue(plan.operations.contains { $0.id == "php.fpm.start" && $0.reason?.contains("PHP_FAMILY_UNAVAILABLE") == true })
        let encoded = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        XCTAssertFalse(encoded.contains("password"))
        XCTAssertFalse(encoded.contains("app-key"))
    }

    func testStoppedMySQLIsDeferredAndNeverActionableInSliceOne() {
        let mysql = MySQLStatus(state: .stopped, health: "stopped", installedVersion: "8.4.11", selectedVersion: "8.4.11", pid: nil, port: 13306, socket: "/tmp/mysql.sock", datadir: "/tmp/mysql", executablePath: "/tmp/mysqld")
        let plan = ProjectReconciliationPlanner().plan(report: report(mysql: mysql, mailpit: healthyMailpit()))
        XCTAssertEqual(plan.operations.first { $0.id == "mysql.start" }?.disposition, .deferred)
        XCTAssertFalse(plan.operations.contains { $0.id == "mysql.start" && $0.disposition == .actionable })
    }

    func testMissingDNSRequiresAuthorizationAndIsNotExecutable() {
        let plan = ProjectReconciliationPlanner().plan(report: report(mysql: nil, mailpit: healthyMailpit(), dnsHealth: "stopped"))
        XCTAssertEqual(plan.operations.first { $0.id == "dns.install" }?.disposition, .authorizationRequired)
        XCTAssertEqual(plan.operations.first { $0.id == "dns.install" }?.requiresPrivilege, true)
    }

    func testStoppedPHPFPMIsActionable() {
        let plan = ProjectReconciliationPlanner().plan(report: report(phpRunning: false, mysql: nil, mailpit: healthyMailpit()))
        XCTAssertEqual(plan.operations.first { $0.id == "php.fpm.start" }?.disposition, .actionable)
        XCTAssertEqual(plan.operations.first { $0.id == "php.fpm.start" }?.requiresNetwork, false)
        XCTAssertEqual(plan.operations.first { $0.id == "php.fpm.start" }?.requiresPrivilege, false)
    }

    func testDNSBlockerDoesNotMakeStoppedPHPNonActionable() {
        let plan = ProjectReconciliationPlanner().plan(report: report(phpRunning: false, mysql: nil, mailpit: healthyMailpit(), dnsHealth: "stopped"))
        XCTAssertEqual(plan.state, .blocked)
        XCTAssertEqual(plan.operations.first { $0.id == "php.fpm.start" }?.disposition, .actionable)
        XCTAssertEqual(plan.operations.first { $0.id == "dns.install" }?.disposition, .authorizationRequired)
    }

    func testRoutePHPMismatchIsBlockedAndReadOnly() {
        let plan = ProjectReconciliationPlanner().plan(report: report(mysql: nil, mailpit: healthyMailpit(), routeTargetMatchesPHP: false))
        let route = plan.operations.first { $0.id == "route.reconcile" }
        XCTAssertEqual(route?.disposition, .blocked)
        XCTAssertTrue(route?.reason?.contains("does not mutate routes") == true)
    }

    func testPendingRouteTargetRemainsExplicitlyPending() {
        let base = report(mysql: nil, mailpit: healthyMailpit())
        let route = ProjectPHPRouteTargetObservation(
            projectID: base.identity.id!.rawValue,
            routeID: RouteID(),
            hostname: "fixture.test",
            persistedDocumentRoot: "/tmp/reconciliation-fixture/public",
            observedDocumentRoot: "/tmp/reconciliation-fixture/public",
            persistedTLS: .local,
            observedTLS: .local,
            persistedSocket: "/tmp/php-8.4.23.sock",
            observedSocket: "/tmp/php-8.4.22.sock",
            currentPHPVersion: "8.4.22",
            desiredPHPDeclaration: "8.4",
            resolvedPHPVersion: "8.4.23",
            desiredSocket: "/tmp/php-8.4.23.sock",
            associationAuthority: .allowed,
            currentTargetOwnership: .proven,
            desiredTargetOwnership: .proven,
            providerAgreement: .diverged,
            disposition: .pending,
            reason: "provider apply failed"
        )
        let report = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: base.diagnostics, routeTargets: [route])
        let operation = ProjectReconciliationPlanner().plan(report: report).operations.first { $0.id.hasPrefix("route.php-target.update.") }
        XCTAssertNotNil(operation)
        XCTAssertEqual(operation?.disposition, ProjectReconciliationDisposition.pending)
        XCTAssertEqual(operation?.currentState, ProjectReconciliationResourceState.unknown)
    }
}
