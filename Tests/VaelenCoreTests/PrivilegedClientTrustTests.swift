import XCTest
@testable import VaelenCore

final class PrivilegedClientTrustTests: XCTestCase {
    private let helper = VaelenSigningIdentity(identifier: "dev.vaelen.privileged-helper", teamIdentifier: "TEAM123456")

    func testAcceptsExpectedCoreSignedByHelperTeam() {
        let client = VaelenSigningIdentity(identifier: "vaelend", teamIdentifier: "TEAM123456")
        XCTAssertTrue(VaelenPrivilegedClientTrust.permits(client: client, helper: helper))
    }

    func testRejectsGUIBecauseItDoesNotCallPrivilegedHelper() {
        let gui = VaelenSigningIdentity(identifier: "dev.vaelen.app", teamIdentifier: "TEAM123456")
        XCTAssertFalse(VaelenPrivilegedClientTrust.permits(client: gui, helper: helper))
    }

    func testRejectsSameIdentifierSignedByAnotherTeam() {
        let client = VaelenSigningIdentity(identifier: "vaelend", teamIdentifier: "OTHERTEAM1")
        XCTAssertFalse(VaelenPrivilegedClientTrust.permits(client: client, helper: helper))
    }

    func testRejectsAdHocOrMissingTeamIdentity() {
        let client = VaelenSigningIdentity(identifier: "vaelend", teamIdentifier: "")
        XCTAssertFalse(VaelenPrivilegedClientTrust.permits(client: client, helper: helper))
    }

    func testRejectsUnexpectedIdentifiers() {
        let wrongClient = VaelenSigningIdentity(identifier: "com.other.app", teamIdentifier: "TEAM123456")
        let wrongHelper = VaelenSigningIdentity(identifier: "com.other.helper", teamIdentifier: "TEAM123456")
        let expectedClient = VaelenSigningIdentity(identifier: "vaelend", teamIdentifier: "TEAM123456")
        XCTAssertFalse(VaelenPrivilegedClientTrust.permits(client: wrongClient, helper: helper))
        XCTAssertFalse(VaelenPrivilegedClientTrust.permits(client: expectedClient, helper: wrongHelper))
    }

    func testRejectsMissingSigningInformation() {
        let core = VaelenSigningIdentity(identifier: "vaelend", teamIdentifier: "TEAM123456")
        XCTAssertFalse(VaelenPrivilegedClientTrust.permits(client: nil, helper: helper))
        XCTAssertFalse(VaelenPrivilegedClientTrust.permits(client: core, helper: nil))
    }
}
