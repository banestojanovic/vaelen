import XCTest
@testable import VaelenCore

final class DNSCapabilityTests: XCTestCase {
    func testResponderDiscoveryAcceptsVaelenBuildPathDriftButNotUnrelatedExecutable() {
        let expected = "/Users/banes/Code/apps/vaelen/.build/debug/vaelendns"
        XCTAssertTrue(DNSResponderSupervisor.acceptsExecutablePath("/Users/banes/Code/apps/vaelen/.build/out/Products/Debug/vaelendns", expected: expected))
        XCTAssertFalse(DNSResponderSupervisor.acceptsExecutablePath("/tmp/vaelendns", expected: expected))
        XCTAssertFalse(DNSResponderSupervisor.acceptsExecutablePath("/Users/banes/Code/apps/vaelen/.build/out/Products/Debug/other", expected: expected))
    }

    func testExternalResolverConflictsWithoutMutation() async throws {
        let helper = FixtureDNSHelper(content: "external resolver A\n")
        let capability = makeCapability(helper: helper)
        do { _ = try await capability.install(); XCTFail("expected conflict") } catch { XCTAssertEqual(error as? DNSCapabilityError, .externalConflict) }
        let content = await helper.contentValue()
        XCTAssertEqual(content, "external resolver A\n")
    }

    func testTakeoverCapturesAndRestoresPreviousResolver() async throws {
        let helper = FixtureDNSHelper(content: "external resolver A\n")
        let ledger = try makeLedger()
        let capability = makeCapability(helper: helper, ledger: ledger)
        _ = try await capability.install(takeover: true)
        let installed = await helper.contentValue()
        XCTAssertEqual(installed, "nameserver 127.0.0.1\nport 53535\n")
        XCTAssertEqual(try ledger.dnsRecord()?.previousContent, "external resolver A\n")
        _ = try await capability.remove()
        let restored = await helper.contentValue()
        XCTAssertEqual(restored, "external resolver A\n")
        XCTAssertFalse(try ledger.dnsRecord()?.active ?? true)
    }

    func testExternallyModifiedResolverIsPreservedOnRemoval() async throws {
        let helper = FixtureDNSHelper(content: "external resolver A\n")
        let capability = makeCapability(helper: helper, ledger: try makeLedger())
        _ = try await capability.install(takeover: true)
        await helper.setContent("external resolver C\n")
        do { _ = try await capability.remove(); XCTFail("expected ownership mismatch") } catch { XCTAssertEqual(error as? DNSCapabilityError, .ownershipMismatch) }
        let preserved = await helper.contentValue()
        XCTAssertEqual(preserved, "external resolver C\n")
    }

    func testCleanInstallAndRemoveLeavesNoResolver() async throws {
        let helper = FixtureDNSHelper(content: nil)
        let capability = makeCapability(helper: helper, ledger: try makeLedger())
        _ = try await capability.install()
        _ = try await capability.remove()
        let content = await helper.contentValue()
        XCTAssertNil(content)
    }

    private func makeLedger() throws -> SystemModificationLedger {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return SystemModificationLedger(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state/vaelen.sqlite")))
    }

    private func makeCapability(helper: FixtureDNSHelper, ledger: SystemModificationLedger? = nil) -> DNSCapability {
        DNSCapability(helper: helper, responder: FixtureDNSResponder(), port: 53535, ledger: ledger)
    }
}

private actor FixtureDNSHelper: PrivilegedDNSHelper {
    private var content: String?
    init(content: String?) { self.content = content }
    func contentValue() -> String? { content }
    func setContent(_ value: String?) { content = value }
    func inspectTestResolver() async throws -> ResolverInspection { ResolverInspection(exists: content != nil, content: content, ownership: .unknown) }
    func installTestResolver(port: Int, replacing: ResolverInspection?) async throws { content = "nameserver 127.0.0.1\nport \(port)\n" }
    func removeTestResolver(expectedContent: String, restoreContent: String?) async throws {
        guard content == expectedContent else { throw DNSCapabilityError.ownershipMismatch }
        content = restoreContent
    }
}

private actor FixtureDNSResponder: DNSResponderControlling {
    private var running = false
    func status() async -> (pid: Int32?, running: Bool) { (running ? 1 : nil, running) }
    func start() async throws -> Int32 { running = true; return 1 }
    func stop() async { running = false }
}
