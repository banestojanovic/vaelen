import Foundation
import XCTest
@testable import VaelenCore

final class ProjectReconciliationTests: XCTestCase {
    private let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("reconciliation-fixture-\(UUID().uuidString)", isDirectory: true)

    private func report(php: String? = "8.4", resolvedPHP: String? = "8.4.23", phpRunning: Bool = true, mysql: MySQLStatus? = nil, mailpit: MailpitStatus? = nil, secureWeb: Bool? = true, dbMatches: Bool? = true, mailMatches: Bool? = true, dnsHealth: String = "healthy", registration: ProjectRegistrationKind = .linked, routeTargetMatchesPHP: Bool? = nil, routeTLS: TLSMode? = .local, runtimeRouteObserved: Bool? = true) -> ProjectEnvironmentReport {
        try! FileManager.default.createDirectory(at: fixtureRoot.appendingPathComponent("public", isDirectory: true), withIntermediateDirectories: true)
        let root = CanonicalPath(url: fixtureRoot)
        let project = Project(id: registration == .linked ? ProjectID() : nil, name: "fixture", rootPath: root, registrationKind: registration, availability: .available)
        let desired = ProjectDesiredEnvironment(file: .valid, php: php, secureWeb: secureWeb, mysql: mysql != nil, mailpit: mailpit != nil)
        let configured = ProjectConfiguredEnvironment(envFile: root.string + "/.env", envFilePresent: true, dbConnection: "mysql", dbHost: "127.0.0.1", dbPort: "13306", database: "app", usernameConfigured: true, password: .available, mailer: "smtp", mailHost: "127.0.0.1", mailPort: "11025", mailPassword: .missing)
        let observedPHP = ProjectObservedPHP(installedVersions: resolvedPHP.map { [$0] } ?? [], runningVersions: phpRunning ? (resolvedPHP.map { [$0] } ?? []) : [], resolvedVersion: resolvedPHP, resolvedState: resolvedPHP == nil ? "unresolved" : (phpRunning ? "running" : "not-running"), defaultVersion: resolvedPHP)
        let observedRoute = ProjectObservedRoute(intentExists: true, hostname: "fixture.test", documentRoot: fixtureRoot.appendingPathComponent("public").path, target: "fastcgi socket", tls: routeTLS, routerState: .running, routerHealth: .healthy, runtimeRouteObserved: runtimeRouteObserved, associatedRouteCount: 1)
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

    func testVersionTwoRequirementsBlockOnlyUnverifiedSelectionsAndWebState() throws {
        let base = report(mysql: nil, mailpit: nil)
        let services = [try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .postgresql, instance: ProjectInstanceName("db"))]
        let spec = try ProjectEnvironmentSpec(php: PHPRequirement(value: "8.4"), node: NodeRequirement(value: "22"), web: ProjectWebRequirement(host: "app.test", documentRoot: "public", secure: true), services: services)
        let v2 = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec)
        let plan = ProjectReconciliationPlanner().plan(report: v2)
        XCTAssertEqual(plan.state, .blocked)
        XCTAssertFalse(plan.operations.contains { $0.id == "requirement.php" })
        XCTAssertTrue(plan.operations.contains { $0.id == "requirement.node" && $0.disposition == .blocked && $0.reason?.contains("Node") == true })
        XCTAssertTrue(plan.operations.contains { $0.disposition == .blocked && $0.reason?.contains("web host") == true })
        XCTAssertTrue(plan.operations.contains { $0.disposition == .blocked && $0.reason?.contains("document root") == true })
        XCTAssertTrue(plan.operations.contains { $0.disposition == .unsupported && $0.reason?.contains("postgresql") == true })
    }

    func testOmittedSingletonVersionRequiresPersistedCatalogIdentity() throws {
        let base = report(mysql: nil, mailpit: nil)
        let alias = try ProjectBindingAlias("database")
        let instance = try ProjectInstanceName("default")
        let omitted = try ProjectServiceBinding(alias: alias, kind: .mysql, instance: instance)
        let explicit = try ProjectServiceBinding(alias: alias, kind: .mysql, instance: instance, version: "mysql-8.4.11")
        func plan(_ binding: ProjectServiceBinding) -> ProjectReconciliationPlan {
            let spec = try! ProjectEnvironmentSpec(services: [binding])
            let observation = ProjectServiceBindingObservation(binding: binding, packageIdentifier: "mysql-8.4.11", endpoint: ["mysql": "127.0.0.1:3306"], dataDirectory: "/data/mysql/default", health: "healthy", claimed: false, catalogPersisted: false)
            let report = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec, serviceBindings: [observation])
            return ProjectReconciliationPlanner().plan(report: report)
        }

        let omittedOperation = try XCTUnwrap(plan(omitted).operations.first { $0.id == "service.database" })
        XCTAssertEqual(omittedOperation.disposition, .blocked)
        XCTAssertTrue(omittedOperation.reason?.contains("already persisted") == true)
        XCTAssertEqual(plan(explicit).operations.first { $0.id == "service.database" }?.disposition, .actionable)
    }

    func testHTTPRouteCreationRequiresLocalDNSPortsAndNamespace() throws {
        let base = report(mysql: nil, mailpit: nil, secureWeb: nil)
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let project = Project(id: base.identity.id, name: base.identity.name, rootPath: CanonicalPath(url: projectRoot), registrationKind: .linked, availability: .available)
        func plan(host: String = "shop.test", documentRoot: String = "public", dns: String = "healthy", ports: StandardPortsStatus = .init(state: .healthy)) throws -> ProjectReconciliationPlan {
            let observed = ProjectObservedEnvironment(
                php: base.observed.php, mysql: nil, mailpit: nil,
                route: ProjectObservedRoute(intentExists: false, routerState: .running, routerHealth: .healthy),
                dns: DNSStatus(state: .installed, ownership: .vaelen, health: dns),
                tls: TLSStatus(state: .absent, trustObserved: false), standardPorts: ports
            )
            let web = try ProjectWebRequirement(host: host, documentRoot: documentRoot, secure: false, createRoute: true)
            let requested = try ProjectEnvironmentSpec(web: web)
            let value = ProjectEnvironmentReport(identity: ProjectEnvironmentIdentity(project: project), desired: base.desired, configured: base.configured, observed: observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: requested)
            return ProjectReconciliationPlanner().plan(report: value)
        }

        XCTAssertEqual(try plan().operations.first { $0.id == "route.create" }?.disposition, .actionable)
        XCTAssertEqual(try plan(dns: "unhealthy").operations.first { $0.id == "route.create" }?.disposition, .blocked)
        XCTAssertEqual(try plan(ports: .init(state: .conflict)).operations.first { $0.id == "route.create" }?.disposition, .blocked)
        XCTAssertEqual(try plan(host: "shop.example.com").operations.first { $0.id == "route.create" }?.disposition, .blocked)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: projectRoot.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertEqual(try plan(documentRoot: "escape").operations.first { $0.id == "route.create" }?.disposition, .blocked)
    }

    func testMissingProviderRouteWithSameReviewedOwnershipPlansRetry() throws {
        let base = report(mysql: nil, mailpit: nil)
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let project = Project(id: base.identity.id, name: base.identity.name, rootPath: CanonicalPath(url: projectRoot), registrationKind: .linked, availability: .available)
        let spec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(host: "fixture.test", documentRoot: "public", secure: true, createRoute: true))
        let target = ProjectPHPRouteTargetObservation(
            projectID: try XCTUnwrap(base.identity.id).rawValue, routeID: RouteID(), hostname: "fixture.test",
            persistedDocumentRoot: projectRoot.appendingPathComponent("public").path, observedDocumentRoot: nil,
            persistedTLS: .local, observedTLS: nil, persistedSocket: "/tmp/php.sock", observedSocket: nil,
            currentPHPVersion: "8.4.23", desiredPHPDeclaration: "8.4", resolvedPHPVersion: "8.4.23", desiredSocket: "/tmp/php.sock",
            associationAuthority: .allowed, currentTargetOwnership: .proven, desiredTargetOwnership: .proven,
            providerAgreement: .missing, disposition: .blocked, reason: "The persisted route is missing from the live Caddy configuration."
        )
        let value = ProjectEnvironmentReport(identity: ProjectEnvironmentIdentity(project: project), desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], routeTargets: [target], projectSpec: spec)
        XCTAssertEqual(ProjectReconciliationPlanner().plan(report: value).operations.first { $0.id == "route.create" }?.disposition, .actionable)
    }

    func testVersionTwoPostgreSQLBindingPlansOnlyExactCataloguedInstances() throws {
        let base = report(mysql: nil, mailpit: nil)
        let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .postgresql, instance: ProjectInstanceName("db"), version: PostgreSQLServiceModule.packageIdentifier)
        let spec = try ProjectEnvironmentSpec(services: [binding])
        func plan(package: String?, health: String, claimed: Bool) -> ProjectReconciliationPlan {
            let observation = ProjectServiceBindingObservation(binding: binding, packageIdentifier: package, endpoint: ["postgresql": "127.0.0.1:15432"], dataDirectory: "/tmp/postgres/db/data", health: health, claimed: claimed)
            let value = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec, serviceBindings: [observation])
            return ProjectReconciliationPlanner().plan(report: value)
        }
        XCTAssertEqual(plan(package: PostgreSQLServiceModule.packageIdentifier, health: "stopped", claimed: true).operations.first { $0.id == "service.database" }?.disposition, .actionable)
        XCTAssertEqual(plan(package: PostgreSQLServiceModule.packageIdentifier, health: "stopped", claimed: false).operations.first { $0.id == "service.database" }?.action, .start)
        XCTAssertEqual(plan(package: PostgreSQLServiceModule.packageIdentifier, health: "healthy", claimed: false).operations.first { $0.id == "service.database" }?.action, .associate)
        XCTAssertEqual(plan(package: "postgresql-17", health: "healthy", claimed: true).operations.first { $0.id == "service.database" }?.disposition, .blocked)
        XCTAssertEqual(plan(package: PostgreSQLServiceModule.packageIdentifier, health: "identity-unverified", claimed: true).operations.first { $0.id == "service.database" }?.disposition, .blocked)
    }

    func testVersionTwoValkeyBindingRequiresExactIdentityAndPreservesDispositionTable() throws {
        let base = report(mysql: nil, mailpit: nil)
        let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("cache"), kind: .valkey, instance: ProjectInstanceName("storefront-cache"), version: ValkeyServiceModule.packageIdentifier)
        let spec = try ProjectEnvironmentSpec(services: [binding])
        func plan(package: String? = ValkeyServiceModule.packageIdentifier, version: String? = ValkeyServiceModule.packageIdentifier, endpoint: [String: String] = ["valkey": "127.0.0.1:16379"], observationBinding: ProjectServiceBinding? = nil, health: String, claimed: Bool) -> ProjectReconciliationPlan {
            let observedBinding = observationBinding ?? (try! ProjectServiceBinding(alias: binding.alias, kind: binding.kind, instance: binding.instance, version: version))
            let observation = ProjectServiceBindingObservation(binding: observedBinding, packageIdentifier: package, endpoint: endpoint, dataDirectory: "/tmp/valkey/storefront-cache/data", health: health, claimed: claimed)
            let value = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec, serviceBindings: [observation])
            return ProjectReconciliationPlanner().plan(report: value)
        }

        XCTAssertEqual(plan(health: "stopped", claimed: true).operations.first { $0.id == "service.cache" }?.action, .start)
        XCTAssertEqual(plan(health: "stopped", claimed: false).operations.first { $0.id == "service.cache" }?.action, .start)
        XCTAssertEqual(plan(health: "healthy", claimed: true).operations.first { $0.id == "service.cache" }?.disposition, .satisfied)
        XCTAssertEqual(plan(health: "healthy", claimed: false).operations.first { $0.id == "service.cache" }?.action, .associate)
        XCTAssertEqual(plan(package: "valkey-9.1.1", health: "healthy", claimed: true).operations.first { $0.id == "service.cache" }?.disposition, .blocked)
        XCTAssertEqual(plan(version: nil, health: "healthy", claimed: true).operations.first { $0.id == "service.cache" }?.disposition, .blocked)
        XCTAssertEqual(plan(endpoint: ["valkey": "127.0.0.1:16379", "redis": "127.0.0.1:6379"], health: "healthy", claimed: true).operations.first { $0.id == "service.cache" }?.disposition, .blocked)
        XCTAssertEqual(plan(health: "identity-unverified", claimed: true).operations.first { $0.id == "service.cache" }?.disposition, .blocked)
        let wrongBinding = try ProjectServiceBinding(alias: binding.alias, kind: .valkey, instance: ProjectInstanceName("other-cache"), version: ValkeyServiceModule.packageIdentifier)
        XCTAssertEqual(plan(observationBinding: wrongBinding, health: "healthy", claimed: true).operations.first { $0.id == "service.cache" }?.disposition, .blocked)
        let wrongVersion = try ProjectServiceBinding(alias: binding.alias, kind: .valkey, instance: binding.instance, version: "valkey-9.1.1")
        let wrongVersionSpec = try ProjectEnvironmentSpec(services: [wrongVersion])
        let wrongVersionObservation = ProjectServiceBindingObservation(binding: wrongVersion, packageIdentifier: ValkeyServiceModule.packageIdentifier, endpoint: ["valkey": "127.0.0.1:16379"], dataDirectory: "/tmp/valkey/storefront-cache/data", health: "healthy", claimed: true)
        let wrongVersionReport = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: wrongVersionSpec, serviceBindings: [wrongVersionObservation])
        XCTAssertEqual(ProjectReconciliationPlanner().plan(report: wrongVersionReport).operations.first { $0.id == "service.cache" }?.disposition, .unsupported)
    }

    func testSingletonBindingsRequireDefaultExactIdentityAndVerifiedHealth() throws {
        let base = report(mysql: nil, mailpit: nil)
        func plan(kind: ProjectServiceKind, instance: String = "default", version: String?, package: String?, endpoint: [String: String]?, health: String, claimed: Bool) throws -> ProjectReconciliationPlan {
            let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("service"), kind: kind, instance: ProjectInstanceName(instance), version: version)
            let spec = try ProjectEnvironmentSpec(services: [binding])
            let observation = ProjectServiceBindingObservation(binding: binding, packageIdentifier: package, endpoint: endpoint, dataDirectory: "/tmp/vaelen/instances/\(kind.rawValue)/default", health: health, claimed: claimed)
            let value = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec, serviceBindings: [observation])
            return ProjectReconciliationPlanner().plan(report: value)
        }

        let mysqlPackage = "mysql-\(MySQLModule.defaultVersion)"
        XCTAssertEqual(try plan(kind: .mysql, version: mysqlPackage, package: mysqlPackage, endpoint: ["mysql": "127.0.0.1:33417"], health: "healthy", claimed: true).operations.first { $0.id == "service.service" }?.disposition, .satisfied)
        XCTAssertEqual(try plan(kind: .mysql, version: "mysql-8.0.0", package: mysqlPackage, endpoint: ["mysql": "127.0.0.1:33417"], health: "healthy", claimed: true).operations.first { $0.id == "service.service" }?.disposition, .unsupported)
        XCTAssertEqual(try plan(kind: .mysql, instance: "other", version: mysqlPackage, package: mysqlPackage, endpoint: ["mysql": "127.0.0.1:33417"], health: "healthy", claimed: true).operations.first { $0.id == "service.service" }?.disposition, .unsupported)
        XCTAssertEqual(try plan(kind: .mysql, version: mysqlPackage, package: mysqlPackage, endpoint: ["mysql": "127.0.0.1:33417"], health: "not-initialized", claimed: false).operations.first { $0.id == "service.service" }?.disposition, .blocked)

        let mailpitPackage = "mailpit-\(MailpitModule.defaultVersion)"
        let exactMailpit = ["smtp": "127.0.0.1:1125", "http": "127.0.0.1:18025"]
        XCTAssertEqual(try plan(kind: .mailpit, version: mailpitPackage, package: mailpitPackage, endpoint: exactMailpit, health: "installed", claimed: false).operations.first { $0.id == "service.service" }?.action, .start)
        XCTAssertEqual(try plan(kind: .mailpit, version: mailpitPackage, package: mailpitPackage, endpoint: ["smtp": "127.0.0.1:1125"], health: "healthy", claimed: true).operations.first { $0.id == "service.service" }?.disposition, .blocked)
        XCTAssertEqual(try plan(kind: .mailpit, version: mailpitPackage, package: mailpitPackage, endpoint: exactMailpit, health: "identity-unverified", claimed: false).operations.first { $0.id == "service.service" }?.disposition, .blocked)
    }

    func testPHPFamilyRequirementSelectsOnlyMatchingInstalledFamily() throws {
        let base = report(php: "8.4", resolvedPHP: "8.4.23", mysql: nil, mailpit: nil)
        let installed = ProjectObservedPHP(installedVersions: ["8.3.30", "8.4.23"], runningVersions: ["8.4.23"], resolvedVersion: "8.4.23", resolvedState: "running", defaultVersion: "8.4")
        let spec = try ProjectEnvironmentSpec(php: PHPRequirement(value: "8.3"))
        let mismatch = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: ProjectObservedEnvironment(php: installed, mysql: nil, mailpit: nil, route: base.observed.route, dns: base.observed.dns, tls: base.observed.tls, standardPorts: base.observed.standardPorts), derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec)
        XCTAssertEqual(ProjectReconciliationPlanner().plan(report: mismatch).operations.first { $0.id == "requirement.php.select" }?.disposition, .actionable)

        let matchingPHP = ProjectObservedPHP(installedVersions: ["8.3.30", "8.4.23"], runningVersions: ["8.3.30"], resolvedVersion: "8.3.30", resolvedState: "running", defaultVersion: "8.3")
        let matching = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: ProjectObservedEnvironment(php: matchingPHP, mysql: nil, mailpit: nil, route: base.observed.route, dns: base.observed.dns, tls: base.observed.tls, standardPorts: base.observed.standardPorts), derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec)
        XCTAssertFalse(ProjectReconciliationPlanner().plan(report: matching).operations.contains { $0.id == "requirement.php.select" })
    }

    func testExactPHPRequirementRequiresAndPlansItsExactInstalledPatch() throws {
        let base = report(php: "8.4.23", resolvedPHP: "8.4.24", mysql: nil, mailpit: nil)
        let spec = try ProjectEnvironmentSpec(php: PHPRequirement(value: "8.4.23"))
        func plan(installed: [String]) -> ProjectReconciliationPlan {
            let php = ProjectObservedPHP(installedVersions: installed, runningVersions: ["8.4.24"], resolvedVersion: "8.4.24", resolvedState: "running", defaultVersion: "8.4.24")
            let observed = ProjectObservedEnvironment(php: php, mysql: nil, mailpit: nil, route: base.observed.route, dns: base.observed.dns, tls: base.observed.tls, standardPorts: base.observed.standardPorts)
            return ProjectReconciliationPlanner().plan(report: ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec))
        }

        XCTAssertEqual(plan(installed: ["8.4.24"]).operations.first { $0.id == "requirement.php.select" }?.disposition, .blocked)
        XCTAssertEqual(plan(installed: ["8.4.23", "8.4.24"]).operations.first { $0.id == "requirement.php.select" }?.disposition, .actionable)
    }

    func testPHPRequirementActivationResolutionKeepsExactAndFamilySemantics() throws {
        let installed = ["8.4.23", "8.4.24"]
        XCTAssertEqual(try PHPRequirement(value: "8.4.23").resolveInstalledVersion(from: installed), "8.4.23")
        XCTAssertNil(try PHPRequirement(value: "8.4.23").resolveInstalledVersion(from: ["8.4.24"]))
        XCTAssertEqual(try PHPRequirement(value: "8.4").resolveInstalledVersion(from: installed), "8.4.24")
    }

    func testExactNodeSelectionAndPHPVersionAreVerifiedFromObservedState() throws {
        let base = report(php: "8.4.23", resolvedPHP: "8.4.23", mysql: nil, mailpit: nil)
        let spec = try ProjectEnvironmentSpec(php: PHPRequirement(value: "8.4.23"), node: NodeRequirement(value: "24.22.1"))
        func plan(nodeState: String?) -> ProjectReconciliationPlan {
            ProjectReconciliationPlanner().plan(report: ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec, nodeRequirementState: nodeState))
        }
        XCTAssertEqual(plan(nodeState: "selected").operations.first { $0.id == "requirement.node" }?.disposition, .satisfied)
        XCTAssertEqual(plan(nodeState: "available").operations.first { $0.id == "requirement.node" }?.disposition, .actionable)
        XCTAssertEqual(plan(nodeState: "missing").operations.first { $0.id == "requirement.node" }?.disposition, .blocked)
        XCTAssertFalse(plan(nodeState: "selected").operations.contains { $0.id == "requirement.php.exact" })
    }

    func testVersionTwoSecureWebRequirementRequiresObservedLocalTLS() throws {
        let base = report(mysql: nil, mailpit: nil)
        let spec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(secure: true))
        let target = ProjectPHPRouteTargetObservation(projectID: base.identity.id!.rawValue, routeID: RouteID(), hostname: "fixture.test", persistedDocumentRoot: fixtureRoot.appendingPathComponent("public").path, observedDocumentRoot: fixtureRoot.appendingPathComponent("public").path, persistedTLS: .local, observedTLS: .local, persistedSocket: "/tmp/php-8.4.23.sock", observedSocket: "/tmp/php-8.4.23.sock", currentPHPVersion: "8.4.23", desiredPHPDeclaration: "8.4", resolvedPHPVersion: "8.4.23", desiredSocket: "/tmp/php-8.4.23.sock", associationAuthority: .allowed, currentTargetOwnership: .proven, desiredTargetOwnership: .proven, providerAgreement: .agreed, disposition: .satisfied)
        let v2 = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], routeTargets: [target], projectSpec: spec)
        let plan = ProjectReconciliationPlanner().plan(report: v2)
        XCTAssertFalse(plan.operations.contains { $0.disposition == .unsupported && $0.reason?.contains("web") == true })
        XCTAssertEqual(plan.operations.first { $0.id == "route.secure" }?.disposition, .satisfied)
    }

    func testSecureWebRequirementCanUseSelectedStaticOrProxyRouteWithoutPHPRouteTargets() throws {
        let base = report(mysql: nil, mailpit: nil)
        let spec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(secure: true))
        let plan = ProjectReconciliationPlanner().plan(report: ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec))

        XCTAssertEqual(plan.operations.first { $0.id == "route.secure" }?.disposition, .satisfied)
    }

    func testMissingRouteIsActionableOnlyWithCompleteDeclaredWebIntent() throws {
        let base = report(mysql: nil, mailpit: nil, secureWeb: nil)
        let missingRoute = ProjectObservedRoute(intentExists: false, hostname: nil, documentRoot: nil, target: nil, tls: nil, routerState: .running, routerHealth: .healthy, runtimeRouteObserved: false, associatedRouteCount: 0)
        let observed = ProjectObservedEnvironment(php: base.observed.php, mysql: nil, mailpit: nil, route: missingRoute, dns: base.observed.dns, tls: base.observed.tls, standardPorts: base.observed.standardPorts)
        let complete = try ProjectEnvironmentSpec(web: ProjectWebRequirement(host: "shop.test", documentRoot: "public", secure: false, createRoute: true))
        let actionableReport = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: complete)
        XCTAssertEqual(ProjectReconciliationPlanner().plan(report: actionableReport).operations.first { $0.id == "route.create" }?.disposition, .actionable)

        let incomplete = try ProjectEnvironmentSpec(web: ProjectWebRequirement(secure: false))
        let incompleteReport = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: incomplete)
        let operation = ProjectReconciliationPlanner().plan(report: incompleteReport).operations.first { $0.id == "route.create" }
        XCTAssertEqual(operation?.disposition, .blocked)
        XCTAssertTrue(operation?.reason?.contains("will not invent") == true)

        let secureSpec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(host: "shop.example", documentRoot: "public", secure: true, createRoute: true))
        let secureReport = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: secureSpec)
        let secureOperation = ProjectReconciliationPlanner().plan(report: secureReport).operations.first { $0.id == "route.create" }
        XCTAssertEqual(secureOperation?.disposition, .blocked)
        XCTAssertTrue(secureOperation?.reason?.contains(".test") == true)

        let trustedHostSpec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(host: "shop.test", documentRoot: "public", secure: true, createRoute: true))
        let untrustedObserved = ProjectObservedEnvironment(php: base.observed.php, mysql: nil, mailpit: nil, route: missingRoute, dns: base.observed.dns, tls: TLSStatus(state: .createdButUntrusted, trustObserved: false), standardPorts: base.observed.standardPorts)
        let untrustedReport = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: untrustedObserved, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: trustedHostSpec)
        let untrustedOperation = ProjectReconciliationPlanner().plan(report: untrustedReport).operations.first { $0.id == "route.create" }
        XCTAssertEqual(untrustedOperation?.disposition, .blocked)
        XCTAssertTrue(untrustedOperation?.reason?.contains("trusted Local CA") == true)
    }

    func testWebHostRequirementMatchesCaseNormalizedRouteHostname() throws {
        let base = report(mysql: nil, mailpit: nil)
        let spec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(host: "FIXTURE.TEST", documentRoot: "public", secure: true))
        let report = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec)

        let operation = ProjectReconciliationPlanner().plan(report: report).operations.first { $0.id == "requirement.web.host" }
        XCTAssertEqual(operation?.disposition, .satisfied)
    }

    func testLegacyReportWithoutAssociatedRouteCountCannotProveSecureRouteCoverage() throws {
        let base = report(mysql: nil, mailpit: nil)
        let encoded = try JSONEncoder().encode(base)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var observed = try XCTUnwrap(object["observed"] as? [String: Any])
        var route = try XCTUnwrap(observed["route"] as? [String: Any])
        route.removeValue(forKey: "associatedRouteCount")
        observed["route"] = route
        object["observed"] = observed

        let legacyReport = try JSONDecoder().decode(ProjectEnvironmentReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacyReport.observed.route.associatedRouteCount)
        XCTAssertEqual(legacyReport.observed.route.tls, .local)
        XCTAssertEqual(legacyReport.observed.route.runtimeRouteObserved, true)

        let spec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(secure: true))
        let report = ProjectEnvironmentReport(identity: legacyReport.identity, desired: legacyReport.desired, configured: legacyReport.configured, observed: legacyReport.observed, derived: legacyReport.derived, secret: legacyReport.secret, diagnostics: [], projectSpec: spec)
        let secure = ProjectReconciliationPlanner().plan(report: report).operations.first { $0.id == "route.secure" }
        XCTAssertEqual(secure?.disposition, .blocked)
        XCTAssertEqual(secure?.currentState, .unknown)
    }

    func testSecureWebRequirementNeedsCompleteTLSCoverageForMultipleAssociatedRoutes() throws {
        let base = report(mysql: nil, mailpit: nil)
        let spec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(secure: true))
        let routeIDs = [RouteID(), RouteID()]
        let target = { (id: RouteID, tls: TLSMode) in
            ProjectPHPRouteTargetObservation(projectID: base.identity.id!.rawValue, routeID: id, hostname: "fixture-\(id.description).test", persistedDocumentRoot: self.fixtureRoot.appendingPathComponent("public").path, observedDocumentRoot: self.fixtureRoot.appendingPathComponent("public").path, persistedTLS: tls, observedTLS: tls, persistedSocket: "/tmp/php-8.4.23.sock", observedSocket: "/tmp/php-8.4.23.sock", currentPHPVersion: "8.4.23", desiredPHPDeclaration: "8.4", resolvedPHPVersion: "8.4.23", desiredSocket: "/tmp/php-8.4.23.sock", associationAuthority: .allowed, currentTargetOwnership: .proven, desiredTargetOwnership: .proven, providerAgreement: .agreed, disposition: .satisfied)
        }
        let observed = ProjectObservedEnvironment(php: base.observed.php, mysql: nil, mailpit: nil, route: ProjectObservedRoute(intentExists: true, routerState: .running, routerHealth: .healthy, associatedRouteCount: 2), dns: base.observed.dns, tls: base.observed.tls, standardPorts: base.observed.standardPorts)
        func plan(_ targets: [ProjectPHPRouteTargetObservation]) -> ProjectReconciliationOperation? {
            let report = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: observed, derived: base.derived, secret: base.secret, diagnostics: [], routeTargets: targets, projectSpec: spec)
            return ProjectReconciliationPlanner().plan(report: report).operations.first { $0.id == "route.secure" }
        }

        XCTAssertEqual(plan(routeIDs.map { target($0, .local) })?.disposition, .satisfied)
        XCTAssertEqual(plan([target(routeIDs[0], .local)])?.disposition, .blocked)
        XCTAssertEqual(plan([target(routeIDs[0], .local), target(routeIDs[1], .disabled)])?.disposition, .blocked)
    }

    func testVersionOneSecureWebRequirementBlocksHTTPRoute() throws {
        let base = report(mysql: nil, mailpit: nil, routeTLS: .disabled)
        let spec = try ProjectEnvironmentSpec(version: 1, web: ProjectWebRequirement(secure: true))
        let plan = ProjectReconciliationPlanner().plan(report: ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec))

        let secure = plan.operations.first { $0.id == "route.secure" }
        XCTAssertEqual(secure?.disposition, .blocked)
        XCTAssertEqual(secure?.currentState, .mismatch)
    }

    func testSecureWebRequirementBlocksHTTPRouteWithoutMutatingIt() throws {
        let base = report(mysql: nil, mailpit: nil, routeTLS: .disabled)
        let spec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(secure: true))
        let v2 = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec)

        let plan = ProjectReconciliationPlanner().plan(report: v2)

        let secure = plan.operations.first { $0.id == "route.secure" }
        XCTAssertEqual(secure?.disposition, .blocked)
        XCTAssertEqual(secure?.currentState, .mismatch)
        XCTAssertTrue(secure?.reason?.contains("will not mutate or downgrade") == true)
    }

    func testSecureWebRequirementBlocksWhenRouteTLSCannotBeProven() throws {
        let base = report(mysql: nil, mailpit: nil, routeTLS: nil, runtimeRouteObserved: nil)
        let spec = try ProjectEnvironmentSpec(web: ProjectWebRequirement(secure: true))
        let v2 = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: [], projectSpec: spec)

        let plan = ProjectReconciliationPlanner().plan(report: v2)

        let secure = plan.operations.first { $0.id == "route.secure" }
        XCTAssertEqual(secure?.disposition, .blocked)
        XCTAssertEqual(secure?.currentState, .unknown)
        XCTAssertTrue(secure?.reason?.contains("could not be proven") == true)
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
            persistedDocumentRoot: fixtureRoot.appendingPathComponent("public").path,
            observedDocumentRoot: fixtureRoot.appendingPathComponent("public").path,
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

    func testPHPRouteTargetIsPlannedWithoutSecureWebDeclaration() {
        let base = report(mysql: nil, mailpit: healthyMailpit(), secureWeb: nil)
        let route = ProjectPHPRouteTargetObservation(
            projectID: base.identity.id!.rawValue,
            routeID: RouteID(),
            hostname: "fixture.test",
            persistedDocumentRoot: fixtureRoot.appendingPathComponent("public").path,
            observedDocumentRoot: fixtureRoot.appendingPathComponent("public").path,
            persistedTLS: .local,
            observedTLS: .local,
            persistedSocket: "/tmp/php-8.4.22.sock",
            observedSocket: "/tmp/php-8.4.22.sock",
            currentPHPVersion: "8.4.22",
            desiredPHPDeclaration: "8.4",
            resolvedPHPVersion: "8.4.23",
            desiredSocket: "/tmp/php-8.4.23.sock",
            associationAuthority: .allowed,
            currentTargetOwnership: .proven,
            desiredTargetOwnership: .proven,
            providerAgreement: .diverged,
            disposition: .actionable,
            reason: "The linked project selected a different PHP runtime."
        )
        let updated = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: base.diagnostics, routeTargets: [route])

        let operation = ProjectReconciliationPlanner().plan(report: updated).operations.first { $0.id.hasPrefix("route.php-target.update.") }

        XCTAssertEqual(operation?.disposition, .actionable)
    }

    func testPHPRouteTargetDoesNotCreateRedundantGenericRouteBlocker() {
        let base = report(mysql: nil, mailpit: healthyMailpit(), routeTargetMatchesPHP: false)
        let route = ProjectPHPRouteTargetObservation(
            projectID: base.identity.id!.rawValue,
            routeID: RouteID(),
            hostname: "fixture.test",
            persistedDocumentRoot: fixtureRoot.appendingPathComponent("public").path,
            observedDocumentRoot: fixtureRoot.appendingPathComponent("public").path,
            persistedTLS: .local,
            observedTLS: .local,
            persistedSocket: "/tmp/php-8.4.22.sock",
            observedSocket: "/tmp/php-8.4.22.sock",
            currentPHPVersion: "8.4.22",
            desiredPHPDeclaration: "8.4",
            resolvedPHPVersion: "8.4.23",
            desiredSocket: "/tmp/php-8.4.23.sock",
            associationAuthority: .allowed,
            currentTargetOwnership: .proven,
            desiredTargetOwnership: .proven,
            providerAgreement: .diverged,
            disposition: .actionable,
            reason: "The linked project selected a different PHP runtime."
        )
        let updated = ProjectEnvironmentReport(identity: base.identity, desired: base.desired, configured: base.configured, observed: base.observed, derived: base.derived, secret: base.secret, diagnostics: base.diagnostics, routeTargets: [route])

        let operations = ProjectReconciliationPlanner().plan(report: updated).operations

        XCTAssertTrue(operations.contains { $0.id.hasPrefix("route.php-target.update.") && $0.disposition == .actionable })
        XCTAssertFalse(operations.contains { $0.id == "route.reconcile" })
    }
}
