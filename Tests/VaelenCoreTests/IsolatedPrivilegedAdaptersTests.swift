import XCTest
@testable import VaelenCore

final class IsolatedPrivilegedAdaptersTests: XCTestCase {
    func testUpdaterFixtureWithoutTLSMaterialHasAbsentTLSAndStoppedRouter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-updater-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let intents = ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json"))
        try intents.set("caddy", enabled: false)
        XCTAssertFalse(try intents.enabledServices().contains("caddy"))
        let tls = TLSCapability(layout: layout)
        let tlsStatus = await tls.status()
        XCTAssertEqual(tlsStatus.state, .absent)
        let router = CaddyRouter(layout: layout, tls: tls)
        let routerStatus = await router.status()
        XCTAssertEqual(routerStatus.state, .stopped)
    }

    func testUnavailableDNSRejectsAcquisitionAndRestoration() async {
        let helper = UnavailablePrivilegedDNSHelper()
        let snapshot = ResolverFileSnapshot(exists: false, bytes: nil, owner: nil, group: nil, mode: nil, device: nil, inode: nil, fileType: nil)
        do {
            _ = try await helper.installTestResolver(port: 53535, replacing: snapshot)
            XCTFail("Unavailable DNS adapter acquired a resolver")
        } catch {
            XCTAssertEqual(error as? DNSCapabilityError, .privilegeUnavailable)
        }
        do {
            try await helper.removeTestResolver(expected: snapshot, restore: snapshot)
            XCTFail("Unavailable DNS adapter restored a resolver")
        } catch {
            XCTAssertEqual(error as? DNSCapabilityError, .privilegeUnavailable)
        }
    }

    func testUnavailablePortsRejectsAcquisitionAndRestoration() async {
        let helper = UnavailableStandardPortsPrivileged()
        let snapshot = StandardPortsFileSnapshot(exists: false, bytes: nil, owner: nil, group: nil, mode: nil)
        let acquisition = StandardPortsAcquisition(preimagePFConf: snapshot, preimageAnchor: snapshot, writtenPFConf: snapshot, writtenAnchor: snapshot, changedPFConf: true, changedAnchor: true, forwardingWasActive: false, pfToken: "fixture-token")
        do {
            _ = try await helper.installForwarding()
            XCTFail("Unavailable ports adapter acquired forwarding")
        } catch {
            XCTAssertEqual(error as? StandardPortsPrivilegeError, .unavailable)
        }
        do {
            try await helper.removeForwarding(acquisition: acquisition)
            XCTFail("Unavailable ports adapter restored forwarding")
        } catch {
            XCTAssertEqual(error as? StandardPortsPrivilegeError, .unavailable)
        }
    }
}
