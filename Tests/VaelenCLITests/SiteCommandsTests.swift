import XCTest
import VaelenCore
import VaelenIPC
@testable import VaelenCLI

final class SiteCommandsTests: XCTestCase {
    private func project(_ path: String, name: String = "app", id: UUID? = UUID(), registration: String = "linked", availability: String = "available", sources: [String]? = ["explicitLink"]) -> ProjectWire {
        ProjectWire(id: id, name: name, path: path, registration: registration, availability: availability, detectedFramework: "Laravel", sources: sources)
    }

    private func route(_ host: String, path: String, id: UUID? = nil, tls: TLSMode = .disabled) -> RouteIntent {
        let route = Route(hostname: host, target: .staticFiles(documentRoot: path + "/public"), tls: tls)
        return RouteIntent(route: route, projectID: id, projectPath: path)
    }

    func testParkedSitesIncludeLinkedProjectWithParkFolderProvenanceExactlyOnceInHumanAndJSON() throws {
        let linked = project("/tmp/linked")
        let discovered = project("/tmp/work/child", id: nil, registration: "discovered", sources: ["parkedFolder"])
        let linkedAndParked = project("/tmp/work/linked-child", name: "UniqueHumanSiteName", sources: ["explicitLink", "parkedFolder"])
        let unrelated = project("/tmp/outside", id: nil, registration: "discovered", sources: ["explicitLink"])
        let parked = discoveredParkedProjects([linked, discovered, linkedAndParked, unrelated])
        XCTAssertEqual(parked, [discovered, linkedAndParked])

        let human = parkedSitesHumanOutput(parked, folders: [])
        XCTAssertEqual(human.components(separatedBy: "UniqueHumanSiteName").count - 1, 1)
        XCTAssertTrue(human.contains("Linked · parked"))

        let json = try IPCCodec.encode(ParkedSitesEnvelope(sites: parked, unavailableFolders: []))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let sites = try XCTUnwrap(object["sites"] as? [[String: Any]])
        XCTAssertEqual(sites.filter { $0["path"] as? String == "/tmp/work/linked-child" }.count, 1)
        XCTAssertEqual(sites.count, 2)
    }

    func testMissingProjectFolderDoesNotLookServedFromItsConfiguredRoute() throws {
        let missing = "/tmp/vaelen-missing-site-\(UUID().uuidString)"
        let route = route("gone.test", path: missing)
        let item = try XCTUnwrap(configuredSiteItems(routes: [route], projects: [], observedRoutes: [], unavailableReason: nil).first)
        XCTAssertTrue(item.configured)
        XCTAssertEqual(item.projectAvailability, "missing")
        XCTAssertEqual(item.caddyRouteObserved, false)
        XCTAssertEqual(item.caddyObservationState, "exact-route-not-observed")
    }

    func testUnknownRouterObservationRemainsUnknownRatherThanNotServed() throws {
        let route = route("app.test", path: "/tmp/app")
        let item = try XCTUnwrap(configuredSiteItems(routes: [route], projects: [], observedRoutes: nil, unavailableReason: "Router state unavailable").first)
        XCTAssertNil(item.caddyRouteObserved)
        XCTAssertEqual(item.caddyObservationState, "Router state unavailable")
    }

    func testSameHostnameWithDifferentProviderConfigurationIsNotReportedAsServingConfiguredRoute() throws {
        let configured = route("app.test", path: "/tmp/app")
        let mismatched = Route(hostname: "app.test", target: .staticFiles(documentRoot: "/tmp/other/public"), tls: .disabled)
        let item = try XCTUnwrap(configuredSiteItems(routes: [configured], projects: [], observedRoutes: [mismatched], unavailableReason: nil).first)
        XCTAssertEqual(item.caddyRouteObserved, false)
        XCTAssertEqual(item.caddyObservationState, "hostname-observed-with-different-route")
    }

    func testProviderRouteIdentityDoesNotNeedToReusePersistedRouteID() throws {
        let configured = route("app.test", path: "/tmp/app")
        let providerRoute = Route(hostname: "app.test", target: .staticFiles(documentRoot: "/tmp/app/public"), tls: .disabled)
        XCTAssertNotEqual(providerRoute.id, configured.route.id)
        XCTAssertTrue(routeConfigurationMatches(providerRoute, configured: configured.route))
        let item = try XCTUnwrap(configuredSiteItems(routes: [configured], projects: [], observedRoutes: [providerRoute], unavailableReason: nil).first)
        XCTAssertEqual(item.caddyRouteObserved, true)
        XCTAssertEqual(item.caddyObservationState, "exact-route-observed")
    }

    func testSiteDriverReportsEveryConfiguredTargetAndExactCaddyObservationSeparatelyFromFramework() {
        let id = UUID()
        let app = project("/tmp/site-project", id: id)
        let first = route("one.test", path: app.path, id: id)
        let second = route("two.test", path: app.path, id: id)
        let observed = Route(hostname: first.route.hostname, target: first.route.target, tls: first.route.tls)
        let routes = siteDriverRoutes(project: app, routeIntents: [first, second], observedRoutes: [observed], unavailableReason: nil)
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes.map(\.hostname), ["one.test", "two.test"])
        XCTAssertTrue(routes[0].target.contains("Static files"))
        XCTAssertEqual(routes[0].caddyRouteObserved, true)
        XCTAssertEqual(routes[0].caddyObservationState, "exact-route-observed")
        XCTAssertEqual(routes[1].caddyRouteObserved, false)
        XCTAssertEqual(routes[1].caddyObservationState, "exact-route-not-observed")

        XCTAssertTrue(siteDriverRoutes(project: app, routeIntents: [], observedRoutes: [], unavailableReason: nil).isEmpty)
        let unavailable = siteDriverRoutes(project: app, routeIntents: [first], observedRoutes: nil, unavailableReason: "caddy-observation-unavailable")
        XCTAssertNil(unavailable.first?.caddyRouteObserved)
        XCTAssertEqual(unavailable.first?.caddyObservationState, "caddy-observation-unavailable")
    }

    func testSiteSelectionHandlesCurrentDirectoryAmbiguityAndExplicitProject() throws {
        let id = UUID()
        let app = project("/tmp/site-project", id: id)
        let first = route("one.test", path: app.path, id: id)
        let second = route("two.test", path: app.path, id: id)
        XCTAssertEqual(try selectedRoute("one.test", projects: [app], routes: [first, second], workingDirectory: app.path).route.hostname, "one.test")
        XCTAssertThrowsError(try selectedRoute(nil, projects: [app], routes: [first, second], workingDirectory: app.path)) { error in
            guard case SiteCommandError.routeAmbiguous = error else { return XCTFail("Expected current-directory ambiguity, got \(error)") }
        }
        XCTAssertEqual(try selectedRoute(app.path, projects: [app], routes: [first], workingDirectory: "/tmp").route.hostname, "one.test")
    }

    func testDiscoveredProjectCanResolveItsParkOwnedRoute() throws {
        let discovered = project("/tmp/work/child", id: nil, registration: "discovered", sources: ["parkedFolder"])
        let route = route("child.test", path: discovered.path)
        XCTAssertEqual(try selectedRoute(discovered.path, projects: [discovered], routes: [route], workingDirectory: "/tmp").route.hostname, "child.test")
    }

    func testProjectNameAmbiguityFailsClosedAndPathSelectsExactProject() throws {
        let one = project("/tmp/one/app")
        let two = project("/tmp/two/app")
        XCTAssertThrowsError(try selectedProject("app", projects: [one, two], workingDirectory: "/tmp")) { error in
            guard case SiteCommandError.projectAmbiguous = error else { return XCTFail("Expected ambiguous project") }
        }
        XCTAssertEqual(try selectedProject(two.path, projects: [one, two], workingDirectory: "/tmp").path, two.path)
    }

    func testFrameworkDriverIncludesEvidenceAndUnknownIsHonest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-site-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bootstrap"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for marker in ["artisan", "public/index.php"] {
            let url = root.appendingPathComponent(marker)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let result = ProjectFrameworkDetector().inspect(root: root)
        XCTAssertEqual(result.framework, "Laravel")
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(result.evidence.contains("artisan"))

        let unknown = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-unknown-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unknown) }
        let unknownResult = ProjectFrameworkDetector().inspect(root: unknown)
        XCTAssertEqual(unknownResult.confidence, .low)
        XCTAssertEqual(unknownResult.framework, "Generic/Unknown")
        XCTAssertTrue(unknownResult.evidence.isEmpty)
    }

    func testOpenURLUsesExactHostnameAndConfiguredTLSMode() throws {
        let secure = try XCTUnwrap(siteURL(for: Route(hostname: "secure.test", target: .staticFiles(documentRoot: "/tmp"), tls: .local)))
        let plain = try XCTUnwrap(siteURL(for: Route(hostname: "plain.test", target: .staticFiles(documentRoot: "/tmp"), tls: .disabled)))
        XCTAssertEqual(secure.absoluteString, "https://secure.test")
        XCTAssertEqual(plain.absoluteString, "http://plain.test")
        XCTAssertEqual(externalOpenArguments(bundleIdentifier: nil, url: secure), ["https://secure.test"])
        XCTAssertEqual(externalOpenArguments(bundleIdentifier: "com.tinyapp.TablePlus", url: URL(string: "mysql://root@127.0.0.1:3306/app")!), ["-b", "com.tinyapp.TablePlus", "mysql://root@127.0.0.1:3306/app"])
    }
}
