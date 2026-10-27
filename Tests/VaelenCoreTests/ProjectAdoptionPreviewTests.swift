import Foundation
import XCTest
@testable import VaelenCore

final class ProjectAdoptionPreviewTests: XCTestCase {
    func testDiscoveryPreservesRangesAndExactPinsWithoutParsingHerdYML() throws {
        let root = try temporaryDirectory()
        try Data(#"{"engines":{"node":">=20"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data("v20.1.0\n".utf8).write(to: root.appendingPathComponent(".nvmrc"))
        try Data("not a schema we inspect".utf8).write(to: root.appendingPathComponent("herd.yml"))
        try Data(#"{"require":{"php":"^8.2"}}"#.utf8).write(to: root.appendingPathComponent("composer.json"))
        let before = try snapshot(root)
        let discovery = ProjectAdoptionPreviewBuilder.discover(at: root.path)
        let report = makeReport(root: root)
        let route = Route(hostname: "one.test", target: .staticFiles(documentRoot: "."))
        let preview = ProjectAdoptionPreviewBuilder.build(report: report, routes: [RouteIntent(route: route, projectPath: root.path)], observedRoutes: nil, unavailableReason: "offline", discovery: discovery)
        XCTAssertEqual(preview.node.state, .needsChoice)
        XCTAssertNil(preview.node.exactSelectorCandidate)
        XCTAssertEqual(preview.php.state, .needsChoice)
        XCTAssertEqual(preview.php.sources.first?.rawValue, "^8.2")
        XCTAssertTrue(preview.herdYMLPresent)
        XCTAssertEqual(preview.routes.map(\.hostname), ["one.test"])
        XCTAssertNil(preview.routes.first?.liveObserved)
        XCTAssertEqual(try snapshot(root), before)
    }

    func testExactRequirementsAndOutputOmitDotenvSecrets() throws {
        let root = try temporaryDirectory()
        try Data("DB_CONNECTION=mysql\nDB_HOST=db.test\nDB_PORT=3306\nDB_DATABASE=private_db\nDB_USERNAME=private_user\nDB_PASSWORD=secret-value\nMAIL_PASSWORD=mail-secret\n".utf8).write(to: root.appendingPathComponent(".env"))
        try Data("20.1.0\n".utf8).write(to: root.appendingPathComponent(".node-version"))
        try Data(#"{"require":{"php":"8.4"}}"#.utf8).write(to: root.appendingPathComponent("composer.json"))
        let before = try snapshot(root)
        let discovery = ProjectAdoptionPreviewBuilder.discover(at: root.path)
        let preview = ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [], observedRoutes: [], discovery: discovery)
        XCTAssertEqual(preview.php.exactSelectorCandidate, "8.4")
        XCTAssertEqual(preview.node.exactSelectorCandidate, "20.1.0")
        XCTAssertEqual(preview.database.secretAvailability, .available)
        XCTAssertEqual(preview.mail.secretAvailability, .available)
        let json = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        XCTAssertFalse(json.contains("secret-value"))
        XCTAssertFalse(json.contains("mail-secret"))
        XCTAssertFalse(json.contains("private_db"))
        XCTAssertFalse(json.contains("private_user"))
        XCTAssertEqual(try snapshot(root), before)
    }

    func testMalformedAndOversizedInputsAreIgnoredAndManifestVersionsAreReported() throws {
        let root = try temporaryDirectory()
        try Data("{invalid".utf8).write(to: root.appendingPathComponent("package.json"))
        XCTAssertTrue(ProjectAdoptionPreviewBuilder.discover(at: root.path).node.isEmpty)
        try Data("[]".utf8).write(to: root.appendingPathComponent("package.json"))
        try Data(repeating: 0x61, count: 64 * 1024 + 1).write(to: root.appendingPathComponent(".nvmrc"))
        try Data(repeating: 0x61, count: 64 * 1024 + 1).write(to: root.appendingPathComponent("composer.json"))
        var discovery = ProjectAdoptionPreviewBuilder.discover(at: root.path)
        XCTAssertTrue(discovery.node.isEmpty)
        try Data("version: 1\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        XCTAssertEqual(makeReport(root: root).projectSpec?.version, 1)
        try Data("version: 2\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        XCTAssertEqual(makeReport(root: root).projectSpec?.version, 2)
        try FileManager.default.removeItem(at: root.appendingPathComponent("vaelen.yml"))
        let report = makeReport(root: root)
        XCTAssertEqual(report.desired.file, .absent)
        discovery = ProjectAdoptionPreviewBuilder.discover(at: root.path)
        XCTAssertTrue(discovery.php.isEmpty)
        XCTAssertFalse(discovery.issues.isEmpty)
    }

    func testOptionalManifestSectionsAreNotDiscoveryIssuesButWrongTypesAre() throws {
        let root = try temporaryDirectory()
        try Data("{}".utf8).write(to: root.appendingPathComponent("composer.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
        var discovery = ProjectAdoptionPreviewBuilder.discover(at: root.path)
        XCTAssertTrue(discovery.issues.isEmpty)
        XCTAssertTrue(discovery.php.isEmpty)
        XCTAssertTrue(discovery.node.isEmpty)
        try Data(#"{"require":true}"#.utf8).write(to: root.appendingPathComponent("composer.json"))
        try Data(#"{"engines":{"node":20}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        discovery = ProjectAdoptionPreviewBuilder.discover(at: root.path)
        XCTAssertEqual(discovery.issues.count, 2)
    }

    func testEndpointSecretAvailabilityPreservesUnknownAndCacheFactsAreRedacted() throws {
        let root = try temporaryDirectory()
        try Data("CACHE_DRIVER=redis\nREDIS_HOST=cache.test\nREDIS_PORT=6379\nREDIS_PASSWORD=cache-secret\n".utf8).write(to: root.appendingPathComponent(".env"))
        let preview = ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [], observedRoutes: [], discovery: ProjectAdoptionPreviewBuilder.discover(at: root.path))
        XCTAssertEqual(preview.database.secretAvailability, .unknown)
        XCTAssertEqual(preview.mail.secretAvailability, .unknown)
        XCTAssertEqual(preview.cache?.connection, "redis")
        XCTAssertEqual(preview.cache?.host, "cache.test")
        XCTAssertEqual(preview.cache?.port, "6379")
        XCTAssertEqual(preview.cache?.secretAvailability, .available)
        let json = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        XCTAssertFalse(json.contains("cache-secret"))
    }

    func testModernCacheStoreVariableIsPreferred() throws {
        let root = try temporaryDirectory()
        try Data("CACHE_STORE=redis\nCACHE_DRIVER=file\nREDIS_HOST=127.0.0.1\nREDIS_PORT=6379\n".utf8).write(to: root.appendingPathComponent(".env"))
        let report = makeReport(root: root)
        let preview = ProjectAdoptionPreviewBuilder.build(report: report, routes: [], observedRoutes: [], discovery: ProjectAdoptionPreviewBuilder.discover(at: root.path))
        XCTAssertEqual(preview.cache?.connection, "redis")
    }

    func testDatabaseCacheStoreDoesNotBorrowRedisFacts() throws {
        let root = try temporaryDirectory()
        try Data("CACHE_STORE=database\nREDIS_HOST=stale-cache.test\nREDIS_PORT=6379\nREDIS_PASSWORD=stale-secret\n".utf8).write(to: root.appendingPathComponent(".env"))
        let preview = ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [], observedRoutes: [], discovery: ProjectAdoptionPreviewBuilder.discover(at: root.path))
        XCTAssertEqual(preview.cache?.connection, "database")
        XCTAssertNil(preview.cache?.host)
        XCTAssertNil(preview.cache?.port)
        XCTAssertEqual(preview.cache?.secretAvailability, .unknown)
    }

    func testGenericCacheFactsUseExplicitCacheVariables() throws {
        let root = try temporaryDirectory()
        try Data("CACHE_STORE=file\nCACHE_HOST=cache.test\nCACHE_PORT=11211\nCACHE_PASSWORD=cache-secret\nREDIS_HOST=stale-redis.test\nREDIS_PASSWORD=stale-secret\n".utf8).write(to: root.appendingPathComponent(".env"))
        let preview = ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [], observedRoutes: [], discovery: ProjectAdoptionPreviewBuilder.discover(at: root.path))
        XCTAssertEqual(preview.cache?.host, "cache.test")
        XCTAssertEqual(preview.cache?.port, "11211")
        XCTAssertEqual(preview.cache?.secretAvailability, .available)
    }

    func testLiveObservationMatchesConfigurationWithoutRouteID() throws {
        let root = try temporaryDirectory()
        let route = Route(hostname: "same.test", target: .staticFiles(documentRoot: "public"), tls: .local)
        let liveCopy = Route(hostname: "same.test", target: .staticFiles(documentRoot: "public"), tls: .local)
        XCTAssertNotEqual(route.id, liveCopy.id)
        let mismatch = Route(hostname: "same.test", target: .staticFiles(documentRoot: "other"), tls: .local)
        let intent = RouteIntent(route: route, projectPath: root.path)
        func preview(_ observed: [Route]) -> ProjectAdoptionPreview {
            ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [intent], observedRoutes: observed, discovery: ProjectAdoptionPreviewBuilder.discover(at: root.path))
        }
        XCTAssertEqual(preview([liveCopy]).routes.first?.liveObserved, true)
        XCTAssertEqual(preview([mismatch]).routes.first?.liveObserved, false)
    }

    func testInvalidManifestProducesGenericDecisionWithoutRawError() throws {
        let root = try temporaryDirectory()
        try Data("version: [private-secret\u{001B}\n".utf8).write(to: root.appendingPathComponent("vaelen.yml"))
        let report = makeReport(root: root)
        XCTAssertEqual(report.desired.file, .invalid)
        XCTAssertNotNil(report.desired.fileError)
        let preview = ProjectAdoptionPreviewBuilder.build(report: report, routes: [], observedRoutes: [], discovery: ProjectAdoptionPreviewBuilder.discover(at: root.path))
        XCTAssertTrue(preview.unresolvedDecisions.contains { $0.contains("invalid vaelen.yml") })
        XCTAssertFalse(preview.unresolvedDecisions.contains { $0.contains("private-secret") || $0.contains("\u{001B}") })
    }

    func testMissingAssociatedRouteRequiresHostRootAndTLSDecision() throws {
        let root = try temporaryDirectory()
        let preview = ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [], observedRoutes: [], discovery: ProjectAdoptionPreviewBuilder.discover(at: root.path))
        XCTAssertTrue(preview.unresolvedDecisions.contains { $0.contains("host, document root, and TLS") })
    }

    func testMissingSecretsRemainDistinctFromUnknown() throws {
        let root = try temporaryDirectory()
        try Data("DB_PASSWORD=null\nMAIL_PASSWORD=\nREDIS_PASSWORD=null\nCACHE_DRIVER=redis\n".utf8).write(to: root.appendingPathComponent(".env"))
        let preview = ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [], observedRoutes: [], discovery: ProjectAdoptionPreviewBuilder.discover(at: root.path))
        XCTAssertEqual(preview.database.secretAvailability, .missing)
        XCTAssertEqual(preview.mail.secretAvailability, .missing)
        XCTAssertEqual(preview.cache?.secretAvailability, .missing)
    }

    func testMismatchedProjectIDBlocksPathFallbackAndReportsOwnershipDecision() throws {
        let root = try temporaryDirectory()
        let report = makeReport(root: root)
        let ownedByOther = RouteIntent(route: Route(hostname: "other.test", target: .staticFiles(documentRoot: ".")), projectID: UUID(), projectPath: root.path)
        let legacyUnassociated = RouteIntent(route: Route(hostname: "legacy.test", target: .staticFiles(documentRoot: ".")), projectPath: root.path)
        let discovery = ProjectAdoptionPreviewBuilder.discover(at: root.path)
        let preview = ProjectAdoptionPreviewBuilder.build(report: report, routes: [ownedByOther, legacyUnassociated], observedRoutes: [], discovery: discovery)
        XCTAssertEqual(preview.routes.map(\.hostname), ["legacy.test"])
        XCTAssertTrue(preview.unresolvedDecisions.contains { $0.contains("ownership conflicts") })
        XCTAssertTrue(preview.unresolvedDecisions.contains { $0.contains("TLS mode") })
    }

    func testDifferingExactSelectorsAreAConflict() throws {
        let root = try temporaryDirectory()
        try Data("20.1.0\n".utf8).write(to: root.appendingPathComponent(".nvmrc"))
        try Data("21.2.3\n".utf8).write(to: root.appendingPathComponent(".node-version"))
        let discovery = ProjectAdoptionPreviewBuilder.discover(at: root.path)
        let preview = ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [], observedRoutes: [], discovery: discovery)
        XCTAssertEqual(preview.node.state, .conflict)
        XCTAssertNil(preview.node.exactSelectorCandidate)
    }

    func testCompatibleSelectorsWithDifferentPrecisionNeedAChoice() throws {
        let root = try temporaryDirectory()
        try Data(#"{"engines":{"node":"20"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data("20.1.0\n".utf8).write(to: root.appendingPathComponent(".node-version"))
        try Data(#"{"require":{"php":"8.4"}}"#.utf8).write(to: root.appendingPathComponent("composer.json"))
        try Data("8.4.1\n".utf8).write(to: root.appendingPathComponent(".php-version"))

        let preview = ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [], observedRoutes: [], discovery: ProjectAdoptionPreviewBuilder.discover(at: root.path))

        XCTAssertEqual(preview.node.state, .needsChoice)
        XCTAssertNil(preview.node.exactSelectorCandidate)
        XCTAssertEqual(preview.php.state, .needsChoice)
        XCTAssertNil(preview.php.exactSelectorCandidate)
    }

    func testDifferentRuntimeFamiliesConflict() throws {
        let root = try temporaryDirectory()
        let discovery = ProjectAdoptionDiscovery(
            php: [.init(source: "composer.json require.php", rawValue: "8.4"), .init(source: ".php-version", rawValue: "8.5.1")],
            node: [.init(source: "package.json engines.node", rawValue: "20"), .init(source: ".node-version", rawValue: "21.1.0")],
            herdYMLPresent: false
        )

        let preview = ProjectAdoptionPreviewBuilder.build(report: makeReport(root: root), routes: [], observedRoutes: [], discovery: discovery)

        XCTAssertEqual(preview.node.state, .conflict)
        XCTAssertEqual(preview.php.state, .conflict)
    }

    private func makeReport(root: URL) -> ProjectEnvironmentReport {
        let project = Project(id: ProjectID(), name: root.lastPathComponent, rootPath: CanonicalPath(url: root), registrationKind: .linked, availability: .available)
        return ProjectEnvironmentInspector().inspect(project: project, routes: [], phpPackages: [], phpStatuses: [], phpDefault: nil,
            mysql: nil, mailpit: nil, router: RouterStatus(provider: "test", state: .stopped, health: .unknown, routeCount: 0),
            dns: DNSStatus(state: .notInstalled, ownership: .none, health: "unknown"), tls: TLSStatus(state: .absent), standardPorts: StandardPortsStatus(state: .absent, ownership: .unknown))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
    }
}
