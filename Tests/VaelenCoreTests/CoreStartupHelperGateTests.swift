import XCTest
@testable import VaelenCore

final class CoreStartupHelperGateTests: XCTestCase {
    @MainActor
    func testChangedPackagedHelperReconcilesBeforeCoreStarts() async throws {
        var events = [String]()
        var registrationCount = 0

        let started = try await CoreStartupHelperGate.run(
            reconcileHelper: {
                events.append("reconcile")
                let resolution = HelperRegistrationDigestPolicy.resolve(
                    serviceEnabled: true,
                    serviceRequiresApproval: false,
                    packagedDigest: "new-helper:new-plist",
                    registeredDigest: "old-helper:new-plist",
                    pendingDigest: nil
                )
                if resolution == .reconcile { registrationCount += 1 }
                return true
            },
            startCore: { events.append("core-start") }
        )

        XCTAssertTrue(started)
        XCTAssertEqual(registrationCount, 1)
        XCTAssertEqual(events, ["reconcile", "core-start"])
    }

    @MainActor
    func testUnchangedHelperAvoidsRegistrationChurnAndThenStartsCore() async throws {
        var events = [String]()
        var registrationCount = 0

        let started = try await CoreStartupHelperGate.run(
            reconcileHelper: {
                events.append("check-helper")
                let resolution = HelperRegistrationDigestPolicy.resolve(
                    serviceEnabled: true,
                    serviceRequiresApproval: false,
                    packagedDigest: "current",
                    registeredDigest: "current",
                    pendingDigest: nil
                )
                if resolution == .reconcile { registrationCount += 1 }
                return true
            },
            startCore: { events.append("core-start") }
        )

        XCTAssertTrue(started)
        XCTAssertEqual(registrationCount, 0)
        XCTAssertEqual(events, ["check-helper", "core-start"])
    }

    @MainActor
    func testApprovalOrIncompleteReconciliationPreventsCoreStart() async throws {
        var events = [String]()

        let started = try await CoreStartupHelperGate.run(
            reconcileHelper: {
                events.append("helper-needs-approval")
                return false
            },
            startCore: { events.append("core-start") }
        )

        XCTAssertFalse(started)
        XCTAssertEqual(events, ["helper-needs-approval"])
    }
}
