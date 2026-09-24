import XCTest
import Darwin
@testable import VaelenCore

/// Fixture privileged implementation: fixed-policy file operations inside a
/// temporary directory. Mirrors what the production helper does as root.
private actor FixtureStandardPortsPrivileged: StandardPortsPrivileged {
    let paths: StandardPortsPaths
    var pfEnabled = false
    init(paths: StandardPortsPaths) { self.paths = paths }

    func inspectForwarding() async throws -> StandardPortsInspection {
        StandardPortsInspection(
            anchorContent: try? String(contentsOfFile: paths.anchorPath, encoding: .utf8),
            pfConfContent: try? String(contentsOfFile: paths.pfConfPath, encoding: .utf8),
            pfEnabled: pfEnabled
        )
    }

    func installForwarding() async throws -> String? {
        try StandardPortsForwardingPolicy.writeAnchor(to: paths.anchorPath)
        let pfConf = (try? String(contentsOfFile: paths.pfConfPath, encoding: .utf8)) ?? ""
        try StandardPortsForwardingPolicy.addingReference(to: pfConf, anchorPath: paths.anchorPath).write(toFile: paths.pfConfPath, atomically: true, encoding: .utf8)
        if !pfEnabled { pfEnabled = true; return "fixture-token" }
        return nil
    }

    func removeForwarding(pfToken: String?) async throws {
        try? FileManager.default.removeItem(atPath: paths.anchorPath)
        guard let pfConf = try? String(contentsOfFile: paths.pfConfPath, encoding: .utf8) else { return }
        try StandardPortsForwardingPolicy.removingReference(from: pfConf, anchorPath: paths.anchorPath).write(toFile: paths.pfConfPath, atomically: true, encoding: .utf8)
    }
}

final class StandardPortsCapabilityTests: XCTestCase {
    private struct Fixture {
        let dir: URL
        let paths: StandardPortsPaths
        let privileged: FixtureStandardPortsPrivileged
        let ledger: SystemModificationLedger
    }

    private func makeFixture(pfConf: String = "# fixture pf.conf\n") throws -> Fixture {
        let dir = URL(fileURLWithPath: "/tmp/vaelen-ports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let anchorPath = dir.appendingPathComponent("pf.anchors-dev.vaelen").path
        let pfConfPath = dir.appendingPathComponent("pf.conf").path
        try pfConf.write(toFile: pfConfPath, atomically: true, encoding: .utf8)
        let layout = VaelenFilesystemLayout(rootURL: dir.appendingPathComponent("state"))
        let ledger = SystemModificationLedger(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        return Fixture(dir: dir, paths: StandardPortsPaths(anchorPath: anchorPath, pfConfPath: pfConfPath), privileged: FixtureStandardPortsPrivileged(paths: StandardPortsPaths(anchorPath: anchorPath, pfConfPath: pfConfPath)), ledger: ledger)
    }

    private final class Occupancy: @unchecked Sendable { var ports: Set<Int> = [] }

    private func makeCapability(_ fixture: Fixture, occupancy: Occupancy = Occupancy(), backendHealthy: Bool = false) -> StandardPortsCapability {
        StandardPortsCapability(privileged: fixture.privileged, paths: fixture.paths, ledger: fixture.ledger, portOccupied: { occupancy.ports.contains($0) }, backendHealthy: { backendHealthy })
    }

    private func tearDown(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.dir)
    }

    func testAbsentWhenNothingInstalled() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let status = await makeCapability(fixture).status()
        XCTAssertEqual(status.state, .absent)
        XCTAssertEqual(status.httpPort, 80); XCTAssertEqual(status.httpsPort, 443)
        XCTAssertEqual(status.backendHTTPPort, VaelenNetworkPorts.httpBackend)
        XCTAssertEqual(status.backendHTTPSPort, VaelenNetworkPorts.httpsBackend)
    }

    func testInstallProducesExactAnchorAndReference() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let occupancy = Occupancy()
        let installedCold = try await makeCapability(fixture, occupancy: occupancy, backendHealthy: true).install()
        XCTAssertEqual(installedCold.state, .unhealthy, "rules installed but ports unreachable until PF loads them")
        occupancy.ports = [80, 443]
        let installed = await makeCapability(fixture, occupancy: occupancy, backendHealthy: true).status()
        XCTAssertEqual(installed.state, .healthy)
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.anchorPath, encoding: .utf8), StandardPortsForwardingPolicy.anchorRules())
        let pfConf = try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8)
        for line in StandardPortsForwardingPolicy.pfConfReferenceLines(anchorPath: fixture.paths.anchorPath) { XCTAssertTrue(pfConf.contains(line), "pf.conf must contain \(line)") }
        let record = try fixture.ledger.standardPortsRecord()
        XCTAssertEqual(record?.active, true)
        XCTAssertEqual(record?.anchorRules, StandardPortsForwardingPolicy.anchorRules())
        XCTAssertEqual(record?.pfToken, "fixture-token")
    }

    func testRepeatedInstallIsIdempotent() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let occupancy = Occupancy()
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        _ = try await capability.install()
        occupancy.ports = [80, 443]
        let repeated = try await capability.install()
        XCTAssertEqual(repeated.state, .healthy)
        let pfConf = try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8)
        let occurrences = pfConf.components(separatedBy: StandardPortsForwardingPolicy.anchorName).count - 1
        XCTAssertEqual(occurrences, 2, "reference lines must not duplicate")
    }

    func testHealthyRequiresBackendAndReachablePorts() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let occupancy = Occupancy()
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: false)
        _ = try await capability.install()
        occupancy.ports = [80, 443]
        let observed = await capability.status()
        XCTAssertEqual(observed.state, .installed)
    }

    func testUnhealthyWhenPortsRefuseDespiteIntegration() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let capability = makeCapability(fixture, backendHealthy: true)
        _ = try await capability.install()
        // Ports refuse while anchor exists: rules not loaded or PF off.
        let observed = await capability.status()
        XCTAssertEqual(observed.state, .unhealthy)
    }

    func testExternalPortOccupancyIsConflictAndInstallRefuses() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let occupancy = Occupancy(); occupancy.ports = [80]
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        let status = await capability.status()
        XCTAssertEqual(status.state, .conflict)
        XCTAssertTrue(status.conflict?.contains("80") ?? false)
        do { _ = try await capability.install(); XCTFail("install must refuse a stolen port") }
        catch let error as StandardPortsError { XCTAssertEqual(error, .externalConflict(status.conflict ?? "")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.anchorPath), "failed install must not create the anchor")
    }

    func testExternalAnchorModificationIsOwnershipMismatch() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let occupancy = Occupancy()
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        _ = try await capability.install()
        occupancy.ports = [80, 443]
        try "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port 9999\n".write(toFile: fixture.paths.anchorPath, atomically: true, encoding: .utf8)
        let observed = await capability.status()
        XCTAssertEqual(observed.state, .ownershipMismatch)
        do { _ = try await capability.remove(); XCTFail("remove must refuse mismatched ownership") }
        catch let error as StandardPortsError { XCTAssertEqual(error, .ownershipMismatch) }
    }

    func testExternalPfConfLineRemovalIsMismatch() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let occupancy = Occupancy()
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        _ = try await capability.install()
        occupancy.ports = [80, 443]
        var pfConf = try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8)
        pfConf = pfConf.replacingOccurrences(of: "load anchor \"\(StandardPortsForwardingPolicy.anchorName)\" from \"\(fixture.paths.anchorPath)\"\n", with: "")
        try pfConf.write(toFile: fixture.paths.pfConfPath, atomically: true, encoding: .utf8)
        let observed = await capability.status()
        XCTAssertEqual(observed.state, .ownershipMismatch)
    }

    func testSafeRemovalRestoresPfConf() async throws {
        let fixture = try makeFixture(pfConf: "# fixture pf.conf\npass all\n"); defer { tearDown(fixture) }
        let before = try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8)
        let occupancy = Occupancy()
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        _ = try await capability.install()
        occupancy.ports = [80, 443]
        let preRemove = await capability.status()
        XCTAssertEqual(preRemove.state, .healthy)
        // After PF removal nothing answers the standard ports anymore.
        occupancy.ports = []
        let removed = try await capability.remove()
        XCTAssertEqual(removed.state, .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.anchorPath))
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8), before)
        let repeated = try await capability.remove()
        XCTAssertEqual(repeated.state, .absent)
    }

    func testQuitReleasesOwnedForwardingButPreservesSavedOnChoice() async throws {
        let original = "# unrelated PF configuration\npass quick on lo0 all\n"
        let fixture = try makeFixture(pfConf: original); defer { tearDown(fixture) }
        let intentStore = ServiceIntentStore(url: fixture.dir.appendingPathComponent("state/service-intents.json"))
        try intentStore.set("standard-ports", enabled: true)
        let occupancy = Occupancy()
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        _ = try await capability.install()
        XCTAssertEqual(try fixture.ledger.standardPortsRecord()?.active, true)

        occupancy.ports = []
        let released = try await capability.shutdownCleanup()
        XCTAssertEqual(released.state, .absent)
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.anchorPath))
        XCTAssertEqual(try fixture.ledger.standardPortsRecord()?.active, false)
        XCTAssertEqual(try intentStore.enabledServices(), ["standard-ports"])

        // With external PF content unchanged, the saved-on choice can safely
        // re-install through the same ownership-checked path.
        let relaunched = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        let running = try await relaunched.install()
        XCTAssertNotEqual(running.state, .conflict)
        XCTAssertEqual(try fixture.ledger.standardPortsRecord()?.active, true)
        XCTAssertEqual(try intentStore.enabledServices(), ["standard-ports"])
        occupancy.ports = []
        _ = try await relaunched.shutdownCleanup()
    }

    func testSavedStandardPortsChoiceReportsForeignPFConflictWithoutMutation() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let foreign = "# unrelated PF rules\nanchor \"foreign.example\"\n"
        try foreign.write(toFile: fixture.paths.anchorPath, atomically: true, encoding: .utf8)
        let intentStore = ServiceIntentStore(url: fixture.dir.appendingPathComponent("state/service-intents.json"))
        try intentStore.set("standard-ports", enabled: true)
        let status = await makeCapability(fixture, backendHealthy: true).status()
        XCTAssertEqual(status.state, .conflict)
        do { _ = try await makeCapability(fixture, backendHealthy: true).install(); XCTFail("foreign PF anchor must block auto-restoration") }
        catch let error as StandardPortsError { XCTAssertEqual(error, .externalConflict("Foreign PF anchor claims \(StandardPortsForwardingPolicy.anchorName)")) }
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.anchorPath, encoding: .utf8), foreign)
        XCTAssertEqual(try intentStore.enabledServices(), ["standard-ports"])
    }

    func testLegacyMatchingPFFilesWithoutOwnershipCannotBeEnabledOrRemoved() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let anchor = StandardPortsForwardingPolicy.anchorRules()
        let references = StandardPortsForwardingPolicy.pfConfReferenceLines(anchorPath: fixture.paths.anchorPath).joined(separator: "\n") + "\n"
        try anchor.write(toFile: fixture.paths.anchorPath, atomically: true, encoding: .utf8)
        try references.write(toFile: fixture.paths.pfConfPath, atomically: true, encoding: .utf8)
        let capability = makeCapability(fixture, backendHealthy: true)
        let observed = await capability.status()
        XCTAssertEqual(observed.state, .unhealthy)
        XCTAssertEqual(observed.ownership, .external)
        let anchorBefore = try Data(contentsOf: URL(fileURLWithPath: fixture.paths.anchorPath))
        let pfConfBefore = try Data(contentsOf: URL(fileURLWithPath: fixture.paths.pfConfPath))

        do { _ = try await capability.install(); XCTFail("saved start must not adopt matching legacy PF files") }
        catch let error as StandardPortsError {
            guard case .externalConflict = error else { return XCTFail("unexpected error: \(error)") }
        }
        do { _ = try await capability.remove(); XCTFail("unowned PF files must not be removed") }
        catch let error as StandardPortsError {
            guard case .externalConflict = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.anchorPath)), anchorBefore)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.pfConfPath)), pfConfBefore)
        XCTAssertNil(try fixture.ledger.standardPortsRecord())
    }

    func testReferencePrecedesFilterAnchorsAndHealsMisplacement() {
        let appleStyle = "# Default PF configuration file.\nscrub-anchor \"com.apple/*\"\nnat-anchor \"com.apple/*\"\nrdr-anchor \"com.apple/*\"\ndummynet-anchor \"com.apple/*\"\nanchor \"com.apple/*\"\nload anchor \"com.apple\" from \"/etc/pf.anchors/com.apple\"\n"
        let integrated = StandardPortsForwardingPolicy.addingReference(to: appleStyle)
        let lines = integrated.components(separatedBy: "\n")
        let rdrIndex = lines.firstIndex(of: "rdr-anchor \"\(StandardPortsForwardingPolicy.anchorName)\"")
        let filterIndex = lines.firstIndex(of: "anchor \"com.apple/*\"")
        XCTAssertNotNil(rdrIndex); XCTAssertNotNil(filterIndex)
        XCTAssertLessThan(rdrIndex!, filterIndex!, "translation anchors must precede filter anchors")
        XCTAssertEqual(StandardPortsForwardingPolicy.addingReference(to: integrated), integrated, "idempotent")
        XCTAssertEqual(StandardPortsForwardingPolicy.removingReference(from: integrated), appleStyle, "surgical removal restores bytes")
        // Misplaced block (appended after filter anchors, as the first
        // implementation did) is moved, not duplicated.
        let misplaced = appleStyle + StandardPortsForwardingPolicy.pfConfReferenceLines().joined(separator: "\n") + "\n"
        XCTAssertEqual(StandardPortsForwardingPolicy.addingReference(to: misplaced), integrated)
    }

    func testPartialAnchorWithoutReferenceIsConflict() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        try StandardPortsForwardingPolicy.anchorRules().write(toFile: fixture.paths.anchorPath, atomically: true, encoding: .utf8)
        let observed = await makeCapability(fixture).status()
        XCTAssertEqual(observed.state, .conflict)
    }

    func testHelperUnavailable() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let capability = StandardPortsCapability(privileged: UnavailableStandardPortsPrivileged(paths: fixture.paths), paths: fixture.paths, ledger: fixture.ledger, portOccupied: { _ in false }, backendHealthy: { true })
        let observed = await capability.status()
        XCTAssertEqual(observed.state, .absent)
        do { _ = try await capability.install(); XCTFail("install without helper must fail") }
        catch let error as StandardPortsError { XCTAssertEqual(error, .helperUnavailable) }
    }
}
