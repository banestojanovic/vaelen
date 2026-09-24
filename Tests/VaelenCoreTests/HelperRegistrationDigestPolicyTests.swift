import XCTest
@testable import VaelenCore

final class HelperRegistrationDigestPolicyTests: XCTestCase {
    func testUnchangedRegisteredHelperDoesNotChurn() {
        XCTAssertEqual(
            HelperRegistrationDigestPolicy.resolve(serviceEnabled: true, serviceRequiresApproval: false, packagedDigest: "current", registeredDigest: "current", pendingDigest: nil),
            .useCurrentRegistration
        )
    }

    func testPendingCurrentDigestDoesNotRepeatRegistrationChurn() {
        XCTAssertEqual(
            HelperRegistrationDigestPolicy.resolve(serviceEnabled: true, serviceRequiresApproval: false, packagedDigest: "current", registeredDigest: "older", pendingDigest: "current"),
            .useCurrentRegistration
        )
    }

    func testChangedPackagedDigestUsesExistingReconciliationPath() {
        XCTAssertEqual(
            HelperRegistrationDigestPolicy.resolve(serviceEnabled: true, serviceRequiresApproval: false, packagedDigest: "new-helper:new-plist", registeredDigest: "old-helper:new-plist", pendingDigest: nil),
            .reconcile
        )
    }

    func testMatchingHelperAwaitingApprovalDoesNotAttemptMutation() {
        XCTAssertEqual(
            HelperRegistrationDigestPolicy.resolve(serviceEnabled: false, serviceRequiresApproval: true, packagedDigest: "current", registeredDigest: "current", pendingDigest: nil),
            .approvalRequired
        )
    }
}
