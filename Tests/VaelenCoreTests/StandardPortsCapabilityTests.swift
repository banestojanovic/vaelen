import XCTest
import Darwin
@testable import VaelenCore

/// Fixture privileged implementation: fixed-policy file operations inside a
/// temporary directory. Mirrors what the production helper does as root.
private actor FixtureStandardPortsPrivileged: StandardPortsPrivileged {
    let paths: StandardPortsPaths
    var pfEnabled = false
    var forwardingActive = false
    init(paths: StandardPortsPaths, pfEnabled: Bool = false) { self.paths = paths; self.pfEnabled = pfEnabled }

    func inspectForwarding() async throws -> StandardPortsInspection {
        StandardPortsInspection(
            anchorContent: try? String(contentsOfFile: paths.anchorPath, encoding: .utf8),
            pfConfContent: try? String(contentsOfFile: paths.pfConfPath, encoding: .utf8),
            pfEnabled: pfEnabled, forwardingActive: forwardingActive
        )
    }

    func installForwarding() async throws -> StandardPortsAcquisition {
        let preConf = try snapshot(paths.pfConfPath), preAnchor = try snapshot(paths.anchorPath)
        let wasActive = forwardingActive
        let pfConf = (try? String(contentsOfFile: paths.pfConfPath, encoding: .utf8)) ?? ""
        let changed = !preAnchor.exists && !pfConf.contains(StandardPortsForwardingPolicy.anchorName)
        if changed {
            try StandardPortsForwardingPolicy.writeAnchor(to: paths.anchorPath)
            try StandardPortsForwardingPolicy.addingReference(to: pfConf, anchorPath: paths.anchorPath).write(toFile: paths.pfConfPath, atomically: true, encoding: .utf8)
        } else if preAnchor.bytes != Data(StandardPortsForwardingPolicy.anchorRules().utf8) || !StandardPortsForwardingPolicy.pfConfReferenceLines(anchorPath: paths.anchorPath).allSatisfy(pfConf.contains) { throw StandardPortsError.externalConflict("incompatible fixture state") }
        let token = pfEnabled ? nil : "fixture-token"
        pfEnabled = true; forwardingActive = true
        return StandardPortsAcquisition(preimagePFConf: preConf, preimageAnchor: preAnchor, writtenPFConf: try snapshot(paths.pfConfPath), writtenAnchor: try snapshot(paths.anchorPath), changedPFConf: changed, changedAnchor: changed, forwardingWasActive: wasActive, pfToken: token)
    }

    func removeForwarding(acquisition: StandardPortsAcquisition) async throws {
        if acquisition.changedPFConf { try restore(paths.pfConfPath, expected: acquisition.writtenPFConf, preimage: acquisition.preimagePFConf) }
        if acquisition.changedAnchor { try restore(paths.anchorPath, expected: acquisition.writtenAnchor, preimage: acquisition.preimageAnchor) }
        if acquisition.pfToken != nil { pfEnabled = false }
        forwardingActive = false
    }

    func isPFEnabled() -> Bool { pfEnabled }

    private func snapshot(_ path: String) throws -> StandardPortsFileSnapshot {
        guard FileManager.default.fileExists(atPath: path) else { return StandardPortsFileSnapshot(exists: false, bytes: nil, owner: nil, group: nil, mode: nil) }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return StandardPortsFileSnapshot(exists: true, bytes: try Data(contentsOf: URL(fileURLWithPath: path)), owner: (attrs[.ownerAccountID] as? NSNumber)?.uint32Value, group: (attrs[.groupOwnerAccountID] as? NSNumber)?.uint32Value, mode: (attrs[.posixPermissions] as? NSNumber).map { UInt16($0.uint16Value) })
    }
    private func restore(_ path: String, expected: StandardPortsFileSnapshot, preimage: StandardPortsFileSnapshot) throws {
        guard try snapshot(path) == expected else { throw StandardPortsError.ownershipMismatch }
        if preimage.exists { try preimage.bytes!.write(to: URL(fileURLWithPath: path), options: .atomic) } else { try FileManager.default.removeItem(atPath: path) }
    }
}

private actor ReadOnlyStandardPortsPrivileged: StandardPortsPrivileged {
    let inspection: StandardPortsInspection
    init(inspection: StandardPortsInspection) { self.inspection = inspection }
    func inspectForwarding() async throws -> StandardPortsInspection { inspection }
    func installForwarding() async throws -> StandardPortsAcquisition { throw StandardPortsPrivilegeError.unavailable }
    func removeForwarding(acquisition: StandardPortsAcquisition) async throws { throw StandardPortsPrivilegeError.unavailable }
}

final class StandardPortsCapabilityTests: XCTestCase {
    func testPFEnableTokenParsesEitherPfctlOutputStreamAndWhitespace() {
        XCTAssertEqual(StandardPortsPFEnableToken.parse(stdout: "Token : 42\n", stderr: ""), "42")
        XCTAssertEqual(StandardPortsPFEnableToken.parse(stdout: "", stderr: "pf enabled\nToken:\t73\n"), "73")
        XCTAssertNil(StandardPortsPFEnableToken.parse(stdout: "pf enabled\n", stderr: "warning without a token\n"))
    }

    private struct Fixture {
        let dir: URL
        let paths: StandardPortsPaths
        let privileged: FixtureStandardPortsPrivileged
        let ledger: SystemModificationLedger
    }

    private func makeFixture(pfConf: String = "# fixture pf.conf\n", pfEnabled: Bool = false) throws -> Fixture {
        let dir = URL(fileURLWithPath: "/tmp/vaelen-ports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let anchorPath = dir.appendingPathComponent("pf.anchors-dev.vaelen").path
        let pfConfPath = dir.appendingPathComponent("pf.conf").path
        try pfConf.write(toFile: pfConfPath, atomically: true, encoding: .utf8)
        let layout = VaelenFilesystemLayout(rootURL: dir.appendingPathComponent("state"))
        let ledger = SystemModificationLedger(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        let paths = StandardPortsPaths(anchorPath: anchorPath, pfConfPath: pfConfPath)
        return Fixture(dir: dir, paths: paths, privileged: FixtureStandardPortsPrivileged(paths: paths, pfEnabled: pfEnabled), ledger: ledger)
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

    func testInstallRemoveInstallReacquiresPFWithinSameCapabilityLifetime() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let originalConf = StandardPortsForwardingPolicy.addingReference(
            to: "# historical compatible PF configuration\n",
            anchorPath: fixture.paths.anchorPath
        )
        try originalConf.write(toFile: fixture.paths.pfConfPath, atomically: true, encoding: .utf8)
        try StandardPortsForwardingPolicy.writeAnchor(to: fixture.paths.anchorPath)
        let preservedConf = try Data(contentsOf: URL(fileURLWithPath: fixture.paths.pfConfPath))
        let preservedAnchor = try Data(contentsOf: URL(fileURLWithPath: fixture.paths.anchorPath))
        let occupancy = Occupancy(); occupancy.ports = [80, 443]
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)

        let firstActivation = try await capability.install()
        XCTAssertEqual(firstActivation.state, .healthy)
        let disabled = try await capability.remove()
        XCTAssertEqual(disabled.ownership, .external)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.pfConfPath)), preservedConf)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.anchorPath)), preservedAnchor)
        let pfEnabledAfterRemove = await fixture.privileged.isPFEnabled()
        XCTAssertFalse(pfEnabledAfterRemove)

        let secondActivation = try await capability.install()
        XCTAssertEqual(secondActivation.state, .healthy)
        XCTAssertTrue(try XCTUnwrap(try fixture.ledger.standardPortsRecord()).active)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.pfConfPath)), preservedConf)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.anchorPath)), preservedAnchor)
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

    func testReachablePortWithoutFixedIntegrationIsNotMisreportedAsExternalOwnership() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let occupancy = Occupancy(); occupancy.ports = [80]
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        let status = await capability.status()
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertTrue(status.detail?.contains("TCP connection to 80 succeeds") ?? false)
        XCTAssertEqual(status.ownership, .unknown)
        do { _ = try await capability.install(); XCTFail("install must refuse a stolen port") }
        catch let error as StandardPortsError {
            guard case .unavailable = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.anchorPath), "failed install must not create the anchor")
    }

    func testReachablePort443WithoutFixedIntegrationDoesNotClaimExternalOwner() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let occupancy = Occupancy(); occupancy.ports = [443]
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        let status = await capability.status()
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertTrue(status.detail?.contains("TCP connection to 443 succeeds") ?? false)
        do { _ = try await capability.install(); XCTFail("unattributed endpoint must not be adopted") }
        catch let error as StandardPortsError { guard case .unavailable = error else { return XCTFail("unexpected error: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.anchorPath))
        XCTAssertNil(try fixture.ledger.standardPortsRecord())
    }

    func testSuccessfulConnectionsThroughExactCaseBIntegrationAreNotExternalConflict() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        try StandardPortsForwardingPolicy.writeAnchor(to: fixture.paths.anchorPath)
        let original = try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8)
        try StandardPortsForwardingPolicy.addingReference(to: original, anchorPath: fixture.paths.anchorPath)
            .write(toFile: fixture.paths.pfConfPath, atomically: true, encoding: .utf8)
        let occupancy = Occupancy(); occupancy.ports = [80, 443]
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)

        let status = await capability.status()

        XCTAssertEqual(status.state, .unhealthy)
        XCTAssertEqual(status.ownership, .external)
        XCTAssertNil(status.conflict)
        XCTAssertTrue(status.detail?.contains("active forwarding has not been verified") ?? false)
    }

    func testHealthyRequiresBothStandardPortsToRespond() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let occupancy = Occupancy()
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        _ = try await capability.install()
        occupancy.ports = [80]

        let status = await capability.status()

        XCTAssertEqual(status.state, .unhealthy)
    }

    func testPFAlreadyEnabledIsNeverReleasedByVaelen() async throws {
        let fixture = try makeFixture(pfEnabled: true); defer { tearDown(fixture) }
        let capability = makeCapability(fixture, backendHealthy: true)
        _ = try await capability.install()
        XCTAssertNil(try fixture.ledger.standardPortsRecord()?.pfToken)
        _ = try await capability.shutdownCleanup()
        let pfStillEnabled = await fixture.privileged.isPFEnabled()
        XCTAssertTrue(pfStillEnabled)
    }

    func testExternalPfConfDriftBeforeQuitIsNotOverwritten() async throws {
        let fixture = try makeFixture(pfConf: "# original\n"); defer { tearDown(fixture) }
        let occupancy = Occupancy()
        let capability = makeCapability(fixture, occupancy: occupancy, backendHealthy: true)
        _ = try await capability.install()
        occupancy.ports = [80, 443]
        let changed = try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8) + "# external edit\n"
        try changed.write(toFile: fixture.paths.pfConfPath, atomically: true, encoding: .utf8)
        do { _ = try await capability.remove(); XCTFail("drifted pf.conf must not be overwritten") }
        catch let error as StandardPortsError { XCTAssertEqual(error, .ownershipMismatch) }
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8), changed)
        XCTAssertEqual(try fixture.ledger.standardPortsRecord()?.active, true)
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

    func testLegacyMatchingPFFilesCanBeUsedWithoutClaimingOrRemovingPreexistingState() async throws {
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

        _ = try await capability.install()
        let acquired = try XCTUnwrap(try fixture.ledger.standardPortsRecord()?.acquisition)
        XCTAssertFalse(acquired.changedPFConf)
        XCTAssertFalse(acquired.changedAnchor)
        _ = try await capability.remove()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.anchorPath)), anchorBefore)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.paths.pfConfPath)), pfConfBefore)
        XCTAssertEqual(try fixture.ledger.standardPortsRecord()?.active, false)
    }

    func testHistoricalProductionReferenceBlockIsCompatiblePreexistingCaseB() async throws {
        // Use the exact production path without touching the machine files.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-historical-pf-shape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = StandardPortsPaths.live
        let basePFConf = "# com.apple anchor point\nscrub-anchor \"com.apple/*\"\nnat-anchor \"com.apple/*\"\nrdr-anchor \"com.apple/*\"\ndummynet-anchor \"com.apple/*\"\nanchor \"com.apple/*\"\nload anchor \"com.apple\" from \"/etc/pf.anchors/com.apple\"\n"
        let pfConf = StandardPortsForwardingPolicy.addingReference(to: basePFConf, anchorPath: paths.anchorPath)
        XCTAssertEqual(pfConf.components(separatedBy: StandardPortsForwardingPolicy.anchorName).count - 1, 3)

        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("state"))
        let ledger = SystemModificationLedger(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        let privileged = ReadOnlyStandardPortsPrivileged(inspection: .init(anchorContent: StandardPortsForwardingPolicy.anchorRules(), pfConfContent: pfConf, pfEnabled: false, forwardingActive: false))
        let capability = StandardPortsCapability(privileged: privileged, paths: paths, ledger: ledger, portOccupied: { _ in false }, backendHealthy: { false })
        let status = await capability.status()
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(status.ownership, .external)
        XCTAssertNil(try ledger.standardPortsRecord())
    }

    func testReferenceMatcherRejectsDuplicateAndConflictingAnchorDirectives() {
        let anchorPath = StandardPortsForwardingPolicy.anchorPath
        let lines = StandardPortsForwardingPolicy.pfConfReferenceLines(anchorPath: anchorPath)
        let base = "# com.apple anchor point\nanchor \"com.apple/*\"\n"
        let valid = StandardPortsForwardingPolicy.addingReference(to: base, anchorPath: anchorPath)
        XCTAssertTrue(StandardPortsForwardingPolicy.hasExactReference(in: valid, anchorPath: anchorPath))

        XCTAssertFalse(StandardPortsForwardingPolicy.hasExactReference(in: valid + lines[1] + "\n", anchorPath: anchorPath), "duplicate rdr-anchor")
        XCTAssertFalse(StandardPortsForwardingPolicy.hasExactReference(in: valid + lines[2] + "\n", anchorPath: anchorPath), "duplicate load anchor")
        XCTAssertFalse(StandardPortsForwardingPolicy.hasExactReference(in: valid + "rdr-anchor \"\(StandardPortsForwardingPolicy.anchorName)/*\"\n", anchorPath: anchorPath), "conflicting rdr-anchor")
        XCTAssertFalse(StandardPortsForwardingPolicy.hasExactReference(in: valid + "load anchor \"\(StandardPortsForwardingPolicy.anchorName)\" from \"/etc/pf.anchors/other\"\n", anchorPath: anchorPath), "conflicting load path")
        XCTAssertFalse(StandardPortsForwardingPolicy.hasExactReference(in: valid.replacingOccurrences(of: lines[2] + "\n", with: ""), anchorPath: anchorPath), "partial block")
    }

    func testReferenceMatcherIgnoresUnrelatedCommentsMentioningAnchorName() {
        let anchorPath = StandardPortsForwardingPolicy.anchorPath
        let block = StandardPortsForwardingPolicy.addingReference(to: "# unrelated \(StandardPortsForwardingPolicy.anchorName) note\nanchor \"com.apple/*\"\n", anchorPath: anchorPath)
        let withComment = "# another \(StandardPortsForwardingPolicy.anchorName) mention\n" + block
        XCTAssertTrue(StandardPortsForwardingPolicy.hasExactReference(in: withComment, anchorPath: anchorPath))
    }

    func testWrongAnchorContentsRemainConflictWithoutOwnership() async throws {
        let fixture = try makeFixture(); defer { tearDown(fixture) }
        let pfConf = StandardPortsForwardingPolicy.addingReference(to: "# fixture\n", anchorPath: fixture.paths.anchorPath)
        try pfConf.write(toFile: fixture.paths.pfConfPath, atomically: true, encoding: .utf8)
        try "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port 9999\n".write(toFile: fixture.paths.anchorPath, atomically: true, encoding: .utf8)
        let status = await makeCapability(fixture).status()
        XCTAssertEqual(status.state, .conflict)
        XCTAssertEqual(status.ownership, .external)
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
