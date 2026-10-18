import XCTest
import Darwin
@testable import VaelenCore

/// Regression coverage for the Standard Ports recovery path.
///
/// The machine this candidate was built on had a byte-correct Vaelen anchor whose
/// `/etc/pf.conf` reference had disappeared. `status()` reported a foreign
/// conflict and `install()` refused before asking the helper, so the supported
/// command could never repair it. These tests pin the narrow recovery: restore a
/// missing reference when the anchor is provably Vaelen's own content, and keep
/// refusing genuinely foreign or modified configuration.
final class StandardPortsRepairTests: XCTestCase {
    private struct Fixture {
        let dir: URL
        let paths: StandardPortsPaths
        let privileged: RepairFixturePrivileged
        let ledger: SystemModificationLedger
    }

    /// Mirrors the production helper's acceptance rules exactly.
    private actor RepairFixturePrivileged: StandardPortsPrivileged {
        let paths: StandardPortsPaths
        var pfEnabled = false
        var forwardingActive = false
        private(set) var installCount = 0

        init(paths: StandardPortsPaths, pfEnabled: Bool = false, forwardingActive: Bool = false) {
            self.paths = paths; self.pfEnabled = pfEnabled; self.forwardingActive = forwardingActive
        }

        func inspectForwarding() async throws -> StandardPortsInspection {
            StandardPortsInspection(
                anchorContent: try? String(contentsOfFile: paths.anchorPath, encoding: .utf8),
                pfConfContent: try? String(contentsOfFile: paths.pfConfPath, encoding: .utf8),
                pfEnabled: pfEnabled, forwardingActive: forwardingActive
            )
        }

        func installForwarding() async throws -> StandardPortsAcquisition {
            installCount += 1
            let preConf = try snapshot(paths.pfConfPath), preAnchor = try snapshot(paths.anchorPath)
            let wasActive = forwardingActive
            let pfConf = (try? String(contentsOfFile: paths.pfConfPath, encoding: .utf8)) ?? ""
            let hasAnyReference = pfConf.contains(StandardPortsForwardingPolicy.anchorName) || pfConf.contains(paths.anchorPath)
            let exactExisting = preAnchor.exists && preAnchor.bytes == Data(StandardPortsForwardingPolicy.anchorRules().utf8)
                && StandardPortsForwardingPolicy.hasExactReference(in: pfConf, anchorPath: paths.anchorPath)
            let absent = !preAnchor.exists && !hasAnyReference
            let missingReferenceOnly = preAnchor.exists && preAnchor.bytes == Data(StandardPortsForwardingPolicy.anchorRules().utf8) && !hasAnyReference
            guard exactExisting || absent || missingReferenceOnly else { throw StandardPortsError.ownershipMismatch }
            var changedPFConf = false, changedAnchor = false
            if absent {
                try StandardPortsForwardingPolicy.writeAnchor(to: paths.anchorPath)
                changedAnchor = true
            }
            if absent || missingReferenceOnly {
                try StandardPortsForwardingPolicy.addingReference(to: pfConf, anchorPath: paths.anchorPath)
                    .write(toFile: paths.pfConfPath, atomically: true, encoding: .utf8)
                changedPFConf = true
            }
            let token = pfEnabled ? nil : "fixture-token"
            pfEnabled = true; forwardingActive = true
            return StandardPortsAcquisition(
                preimagePFConf: preConf, preimageAnchor: preAnchor,
                writtenPFConf: try snapshot(paths.pfConfPath), writtenAnchor: try snapshot(paths.anchorPath),
                changedPFConf: changedPFConf, changedAnchor: changedAnchor,
                forwardingWasActive: wasActive, pfToken: token
            )
        }

        func removeForwarding(acquisition: StandardPortsAcquisition) async throws {
            if acquisition.changedPFConf {
                try restore(paths.pfConfPath, expected: acquisition.writtenPFConf, preimage: acquisition.preimagePFConf)
            }
            if acquisition.changedAnchor {
                try restore(paths.anchorPath, expected: acquisition.writtenAnchor, preimage: acquisition.preimageAnchor)
            }
            if acquisition.pfToken != nil { pfEnabled = false }
            forwardingActive = false
        }

        func isPFEnabled() -> Bool { pfEnabled }

        private func snapshot(_ path: String) throws -> StandardPortsFileSnapshot {
            guard FileManager.default.fileExists(atPath: path) else {
                return StandardPortsFileSnapshot(exists: false, bytes: nil, owner: nil, group: nil, mode: nil)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return StandardPortsFileSnapshot(
                exists: true, bytes: try Data(contentsOf: URL(fileURLWithPath: path)),
                owner: (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
                group: (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value,
                mode: (attributes[.posixPermissions] as? NSNumber).map { UInt16($0.uint16Value) }
            )
        }

        private func restore(_ path: String, expected: StandardPortsFileSnapshot?, preimage: StandardPortsFileSnapshot) throws {
            guard let expected else { return }
            guard try snapshot(path) == expected else { throw StandardPortsError.ownershipMismatch }
            if preimage.exists {
                try preimage.bytes!.write(to: URL(fileURLWithPath: path), options: .atomic)
            } else {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private func makeFixture(
        pfConf: String,
        anchor: String?,
        forwardingActive: Bool = false,
        recordLedger: Bool = true
    ) throws -> Fixture {
        let dir = URL(fileURLWithPath: "/tmp/vaelen-ports-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let paths = StandardPortsPaths(anchorPath: dir.appendingPathComponent("pf.anchors-dev.vaelen").path, pfConfPath: dir.appendingPathComponent("pf.conf").path)
        try pfConf.write(toFile: paths.pfConfPath, atomically: true, encoding: .utf8)
        if let anchor { try anchor.write(toFile: paths.anchorPath, atomically: true, encoding: .utf8) }
        let layout = VaelenFilesystemLayout(rootURL: dir.appendingPathComponent("state"))
        let ledger = SystemModificationLedger(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        if recordLedger {
            // Vaelen previously recorded owning this integration, matching the
            // real machine's ledger entry.
            try ledger.recordStandardPorts(anchorRules: StandardPortsForwardingPolicy.anchorRules(), acquisition: StandardPortsAcquisition(
                preimagePFConf: StandardPortsFileSnapshot(exists: true, bytes: Data(pfConf.utf8), owner: 0, group: 0, mode: 0o644),
                preimageAnchor: StandardPortsFileSnapshot(exists: true, bytes: Data((anchor ?? "").utf8), owner: 0, group: 0, mode: 0o644),
                writtenPFConf: StandardPortsFileSnapshot(exists: true, bytes: Data(pfConf.utf8), owner: 0, group: 0, mode: 0o644),
                writtenAnchor: StandardPortsFileSnapshot(exists: true, bytes: Data((anchor ?? "").utf8), owner: 0, group: 0, mode: 0o644),
                changedPFConf: false, changedAnchor: false, forwardingWasActive: true, pfToken: nil
            ))
        }
        let privileged = RepairFixturePrivileged(paths: paths, pfEnabled: true, forwardingActive: forwardingActive)
        return Fixture(dir: dir, paths: paths, privileged: privileged, ledger: ledger)
    }

    private func makeCapability(_ fixture: Fixture, backendHealthy: Bool = true) -> StandardPortsCapability {
        StandardPortsCapability(
            privileged: fixture.privileged,
            paths: fixture.paths,
            ledger: fixture.ledger,
            portOccupied: { _ in true },
            backendHealthy: { backendHealthy }
        )
    }

    // MARK: - Recovery

    /// The real machine's condition: Vaelen's anchor is present and byte-correct
    /// but pf.conf no longer references it. This must be repairable, not reported
    /// as a foreign conflict.
    func testIncompleteConfigurationIsReportedAsRepairable() async throws {
        let fixture = try makeFixture(pfConf: "# system pf.conf\nset skip on lo0\nscrub-anchor \"scrub\"\n", anchor: StandardPortsForwardingPolicy.anchorRules())
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let status = await makeCapability(fixture).status()
        XCTAssertEqual(status.state, .incomplete)
        XCTAssertEqual(status.repairAvailable, true)
        XCTAssertNotNil(status.detail)
        XCTAssertNil(status.conflict, "A repairable Vaelen configuration must not be described as a foreign conflict.")
    }

    /// Repairing must restore the reference and end in a working integration.
    func testRepairRestoresTheMissingReferenceAndReachesHealthy() async throws {
        let originalConf = "# system pf.conf\nset skip on lo0\nscrub-anchor \"scrub\"\n"
        let fixture = try makeFixture(pfConf: originalConf, anchor: StandardPortsForwardingPolicy.anchorRules())
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let capability = makeCapability(fixture)
        let status = try await capability.install()
        XCTAssertNil(status.conflict)
        XCTAssertTrue(status.state == .healthy || status.state == .installed, "Unexpected state: \(status.state.rawValue)")
        XCTAssertEqual(status.ownership, .vaelen, "A completed repair must be owned by Vaelen.")
        let pfConf = try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8)
        XCTAssertTrue(StandardPortsForwardingPolicy.hasExactReference(in: pfConf, anchorPath: fixture.paths.anchorPath))
        // Unrelated system rules are preserved.
        XCTAssertTrue(pfConf.contains("scrub-anchor \"scrub\""))
        XCTAssertTrue(pfConf.contains("set skip on lo0"))
    }

    /// Repair rewrites only pf.conf. The anchor file is untouched, so removal has
    /// nothing to undo there and cannot damage it.
    func testRepairDoesNotRewriteTheAnchorFile() async throws {
        let fixture = try makeFixture(pfConf: "# system pf.conf\n", anchor: StandardPortsForwardingPolicy.anchorRules())
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let before = try Data(contentsOf: URL(fileURLWithPath: fixture.paths.anchorPath))
        _ = try await makeCapability(fixture).install()
        let after = try Data(contentsOf: URL(fileURLWithPath: fixture.paths.anchorPath))
        XCTAssertEqual(before, after, "A reference-only repair must leave the anchor file byte-identical.")
    }

    /// Removal after a repair restores the exact preimage, so the repair is
    /// reversible through the supported path.
    func testRemovalAfterRepairRestoresTheOriginalPFConf() async throws {
        let originalConf = "# system pf.conf\nset skip on lo0\n"
        let fixture = try makeFixture(pfConf: originalConf, anchor: StandardPortsForwardingPolicy.anchorRules())
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let capability = makeCapability(fixture)
        _ = try await capability.install()
        _ = try await capability.remove()
        let restored = try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8)
        XCTAssertEqual(restored, originalConf, "Removal must restore pf.conf exactly; unrelated rules must survive.")
    }

    // MARK: - Foreign state is still refused

    /// A modified anchor is never treated as Vaelen's own content, whether or
    /// not Vaelen previously recorded owning it.
    func testModifiedAnchorIsRefusedAsForeign() async throws {
        let foreignAnchor = "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port 9999\n"
        // With an active Vaelen record, a changed anchor is an ownership mismatch.
        let owned = try makeFixture(pfConf: "# system pf.conf\n", anchor: foreignAnchor)
        defer { try? FileManager.default.removeItem(at: owned.dir) }
        let ownedStatus = await makeCapability(owned).status()
        XCTAssertEqual(ownedStatus.state, .ownershipMismatch)
        XCTAssertNil(ownedStatus.repairAvailable)

        // Without a record it is a foreign conflict, still not repairable.
        let unowned = try makeFixture(pfConf: "# system pf.conf\n", anchor: foreignAnchor, recordLedger: false)
        defer { try? FileManager.default.removeItem(at: unowned.dir) }
        let capability = makeCapability(unowned)
        let status = await capability.status()
        XCTAssertEqual(status.state, .conflict)
        XCTAssertNotEqual(status.repairAvailable, true)
        XCTAssertNotNil(status.conflict)
        do {
            _ = try await capability.install()
            XCTFail("A foreign anchor must not be adopted or overwritten.")
        } catch {
            XCTAssertTrue(error is StandardPortsError, "Unexpected error: \(error)")
        }
        // Untouched.
        let anchor = try String(contentsOfFile: unowned.paths.anchorPath, encoding: .utf8)
        XCTAssertEqual(anchor, foreignAnchor, "A foreign anchor must be left exactly as found.")
    }

    /// A pf.conf that still carries some other directive for this anchor is a
    /// mismatch, not a missing reference, and must not be silently rewritten.
    func testDifferentReferenceDirectiveIsRefused() async throws {
        let fixture = try makeFixture(pfConf: "load anchor \"\(StandardPortsForwardingPolicy.anchorName)\" from \"\(StandardPortsForwardingPolicy.anchorPath)\"\n", anchor: StandardPortsForwardingPolicy.anchorRules())
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let capability = makeCapability(fixture)
        let status = await capability.status()
        XCTAssertNotEqual(status.state, .incomplete, "A present-but-different reference is not a missing reference.")
        XCTAssertNotEqual(status.repairAvailable, true)
        do {
            _ = try await capability.install()
            XCTFail("A different reference directive must not be replaced automatically.")
        } catch {
            XCTAssertTrue(error is StandardPortsError)
        }
    }

    /// The repair does not depend on a prior ledger record. Its safety rests
    /// entirely on observable state: the anchor file is byte-identical to the
    /// fixed policy Vaelen writes, and pf.conf contains no directive for that
    /// anchor, so nothing foreign is present and nothing about the anchor is
    /// overwritten. Removal still requires an active Vaelen record, so this does
    /// not create an ownership claim.
    func testRepairIsOfferedWithoutAPriorLedgerRecord() async throws {
        let fixture = try makeFixture(pfConf: "# system pf.conf\n", anchor: StandardPortsForwardingPolicy.anchorRules(), recordLedger: false)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let capability = makeCapability(fixture)
        let status = await capability.status()
        XCTAssertEqual(status.state, .incomplete)
        XCTAssertEqual(status.repairAvailable, true)
        _ = try await capability.install()
        let pfConf = try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8)
        XCTAssertTrue(StandardPortsForwardingPolicy.hasExactReference(in: pfConf, anchorPath: fixture.paths.anchorPath))
        // Install records the acquisition, so the repair is reversible: removal
        // restores the exact preimage instead of deleting a reference Vaelen
        // cannot prove it wrote.
        _ = try await capability.remove()
        XCTAssertEqual(try String(contentsOfFile: fixture.paths.pfConfPath, encoding: .utf8), "# system pf.conf\n")
    }

    /// A capability without durable Core ownership state changes nothing at all.
    func testMissingLedgerIsRefusedEntirely() async throws {
        let fixture = try makeFixture(pfConf: "# system pf.conf\n", anchor: nil, recordLedger: false)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let capability = StandardPortsCapability(
            privileged: fixture.privileged, paths: fixture.paths, ledger: nil,
            portOccupied: { _ in false }, backendHealthy: { true }
        )
        do {
            _ = try await capability.install()
            XCTFail("Install must refuse without durable ownership state.")
        } catch {
            XCTAssertTrue(error is StandardPortsError)
        }
        let installCount = await fixture.privileged.installCount
        XCTAssertEqual(installCount, 0, "The helper must not be asked to change anything.")
    }

    // MARK: - Presentation

    /// The repairable state is presented as an action, not as an unresolvable
    /// conflict, in both the service list and Settings.
    func testRepairableStatePresentsARepairAction() {
        let status = StandardPortsStatus(
            state: .incomplete,
            detail: "Vaelen's PF anchor is present and correct, but /etc/pf.conf no longer loads it.",
            ownership: .external, forwardingActive: false, repairAvailable: true
        )
        let control = ServiceControlPresentation.standardPorts(status: status, savedOn: true)
        XCTAssertEqual(control.title, "Needs repair")
        XCTAssertEqual(control.action, .retry)
        XCTAssertNotNil(control.detail)
    }

    /// A genuine conflict stays unresolvable in the interface.
    func testForeignConflictDoesNotOfferARepairAction() {
        let status = StandardPortsStatus(state: .conflict, conflict: "Foreign PF anchor claims \(StandardPortsForwardingPolicy.anchorName)", ownership: .external, forwardingActive: false)
        let control = ServiceControlPresentation.standardPorts(status: status, savedOn: true)
        XCTAssertNotEqual(control.title, "Needs repair")
    }
}
