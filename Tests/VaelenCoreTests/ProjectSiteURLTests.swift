import Foundation
import XCTest
@testable import VaelenCore

/// Slice 6: the menu-bar Projects tab presents Core's unified project list and
/// enables Open Site only from an authoritative usable route. These tests pin
/// the route-action gating predicate and the deterministic unified ordering.
final class ProjectSiteURLTests: XCTestCase {
    private func report(
        intentExists: Bool = true,
        hostname: String? = "syncproof.test",
        tls: TLSMode? = .local,
        association: RouteAssociationState = .durable,
        routerState: RouterState = .running,
        routerHealth: RouterHealth = .healthy,
        dnsState: SystemCapabilityState = .installed,
        dnsOwnership: DNSOwnership = .vaelen,
        dnsHealth: String = "healthy",
        tlsState: TLSCapabilityState = .trusted,
        trustObserved: Bool = true,
        tlsOwnership: TLSOwnershipState = .owned,
        portsState: StandardPortsState = .healthy,
        runtimeRouteObserved: Bool = true
    ) -> ProjectEnvironmentReport {
        let project = Project(id: ProjectID(), name: "syncproof", rootPath: CanonicalPath(url: URL(fileURLWithPath: "/tmp/syncproof")), registrationKind: .linked, availability: .available)
        return ProjectEnvironmentReport(
            identity: .init(project: project),
            desired: .init(file: .absent),
            configured: .init(envFile: "/tmp/syncproof/.env", envFilePresent: false),
            observed: .init(
                php: .init(installedVersions: [], runningVersions: [], resolvedVersion: nil, resolvedState: "unresolved", defaultVersion: nil),
                mysql: nil,
                mailpit: nil,
                route: .init(intentExists: intentExists, hostname: hostname, tls: tls, routerState: routerState, routerHealth: routerHealth, associationState: association, runtimeRouteObserved: runtimeRouteObserved),
                dns: DNSStatus(state: dnsState, ownership: dnsOwnership, resolverContent: dnsState == .conflict ? "nameserver 127.0.0.1\nport 53535\n" : nil, pid: 1, health: dnsHealth),
                tls: TLSStatus(state: tlsState, trustObserved: trustObserved, ownership: tlsOwnership),
                standardPorts: StandardPortsStatus(state: portsState)
            ),
            derived: .init(
                framework: .init(framework: "Laravel", confidence: .high, evidence: ["artisan"]),
                phpResolution: "unknown",
                dbEndpoint: .init(configuredHost: nil, configuredPort: nil, expectedHost: nil, expectedPort: nil, matches: nil),
                mailEndpoint: .init(configuredHost: nil, configuredPort: nil, expectedHost: nil, expectedPort: nil, matches: nil),
                mailAuthentication: .init(requirement: .unknown),
                routeDocumentRootMatches: nil,
                configCache: .init(state: "absent", cachePath: "/tmp/syncproof/bootstrap/cache/config.php")
            ),
            secret: .init(databasePassword: .unknown, mailPassword: .unknown),
            diagnostics: []
        )
    }

    func testHealthySecureStackYieldsHTTPSURL() {
        XCTAssertEqual(report().usableSiteURL?.absoluteString, "https://syncproof.test")
    }

    func testDisabledTLSYieldsHTTPURLWithoutTrustGate() {
        let result = report(tls: .disabled, tlsState: .absent, trustObserved: false, tlsOwnership: .unverified).usableSiteURL
        XCTAssertEqual(result?.absoluteString, "http://syncproof.test")
    }

    func testMissingRouteYieldsNoURL() {
        XCTAssertNil(report(intentExists: false).usableSiteURL)
    }

    func testLegacyAssociationCanBeOpenableWithoutMutationAuthority() {
        let inferred = report(association: .inferred)
        XCTAssertEqual(inferred.usableSiteURL?.absoluteString, "https://syncproof.test")
        XCTAssertEqual(inferred.observed.route.mutationAuthority, .blocked)
        let safelyAssociable = report(association: .safelyAssociable)
        XCTAssertEqual(safelyAssociable.usableSiteURL?.absoluteString, "https://syncproof.test")
        XCTAssertEqual(safelyAssociable.observed.route.mutationAuthority, .blocked)
        XCTAssertNil(report(association: .none).usableSiteURL)
    }

    func testUnhealthyRouterYieldsNoURL() {
        XCTAssertNil(report(routerState: .stopped).usableSiteURL)
        XCTAssertNil(report(routerHealth: .unhealthy).usableSiteURL)
    }

    func testMissingHostnameYieldsNoURL() {
        XCTAssertNil(report(hostname: nil).usableSiteURL)
        XCTAssertNil(report(hostname: "").usableSiteURL)
    }

    func testResolverConflictCanBeOpenableWithoutDNSOwnership() {
        XCTAssertEqual(report(dnsState: .conflict, dnsOwnership: .unknown, dnsHealth: "conflict").usableSiteURL?.absoluteString, "https://syncproof.test")
        XCTAssertNil(report(dnsState: .unavailable, dnsOwnership: .unknown, dnsHealth: "unknown").usableSiteURL)
    }

    func testUntrustedLocalCAYieldsNoURL() {
        XCTAssertNil(report(trustObserved: false).usableSiteURL)
        XCTAssertNil(report(tlsState: .createdButUntrusted, trustObserved: false).usableSiteURL)
        XCTAssertEqual(report(tlsOwnership: .mismatch).usableSiteURL?.absoluteString, "https://syncproof.test")
    }

    func testUnhealthyStandardPortsYieldsNoURL() {
        XCTAssertNil(report(portsState: .unhealthy).usableSiteURL)
        XCTAssertNil(report(portsState: .absent).usableSiteURL)
    }

    func testConfiguredRouteWithoutLiveRuntimeEvidenceIsNotOpenable() {
        XCTAssertNil(report(runtimeRouteObserved: false).usableSiteURL)
    }

    func testUnifiedProjectListOrderingIsDeterministicByPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Recognized projects in non-alphabetical creation order.
        for name in ["bravo", "alpha", "charlie"] {
            let project = root.appendingPathComponent(name, isDirectory: true)
            for path in ["bootstrap", "config", "public"] {
                try FileManager.default.createDirectory(at: project.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            try Data("marker".utf8).write(to: project.appendingPathComponent("artisan"))
            try Data("<?php".utf8).write(to: project.appendingPathComponent("public/index.php"))
        }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("db.sqlite")))
        _ = try await registry.park(path: root)
        // One project is both explicitly linked and parked-folder discovered:
        // it must still appear exactly once.
        _ = try await registry.link(path: root.appendingPathComponent("bravo"))
        let first = try await registry.projectsList()
        let second = try await registry.projectsList()
        XCTAssertEqual(first.map(\.rootPath.string), second.map(\.rootPath.string))
        XCTAssertEqual(first.map(\.name), ["alpha", "bravo", "charlie"])
        XCTAssertEqual(first.count, 3)
        let bravo = first.first(where: { $0.name == "bravo" })
        XCTAssertEqual(bravo?.registrationKind, .linked)
        XCTAssertEqual(bravo?.visibilitySources, [.explicitLink, .parkedFolder])
    }
}
