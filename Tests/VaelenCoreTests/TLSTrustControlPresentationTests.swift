import XCTest
@testable import VaelenCore

final class TLSTrustControlPresentationTests: XCTestCase {
    func testObservedTrustWithUnknownProvenanceIsTrustedAndOffersManagementNotRemoval() throws {
        let fingerprint = "4c74cd035220160e58b3f8cde20b327bb14defe2bf5f763b63209ec99ce909dc"
        let path = "/Library/Application Support/Vaelen/tls/certificates/ca.der"
        let status = TLSStatus(state: .trusted, caFingerprint: fingerprint, caCertificatePath: path, trustObserved: true, ownership: .owned, trustProvenance: .none, trustSettingsFingerprint: nil)

        let presentation = TLSTrustControlPresentation(status)

        XCTAssertEqual(presentation.title, "Trusted")
        XCTAssertFalse(presentation.canTrust)
        XCTAssertFalse(presentation.canRemove)
        XCTAssertTrue(presentation.canManageTrust)

        let guidance = try XCTUnwrap(presentation.manageTrustGuidance(caFingerprint: fingerprint, certificatePath: path))
        XCTAssertTrue(guidance.contains("Automatic removal is unavailable"))
        XCTAssertTrue(guidance.contains("Vaelen Local CA"))
        XCTAssertTrue(guidance.contains("SHA-256: \(fingerprint)"))
        XCTAssertTrue(guidance.contains("Certificate file: \(path)"))
        XCTAssertTrue(guidance.contains("Keychain Access > login > Certificates"))
        XCTAssertTrue(guidance.contains("Use System Defaults"))
        XCTAssertTrue(guidance.contains("Do not delete the certificate or change any other certificate"))
    }

    func testUnknownProvenanceGuidanceFailsClosedWithoutFingerprint() {
        let status = TLSStatus(state: .trusted, trustObserved: true, ownership: .owned, trustProvenance: .none)
        let presentation = TLSTrustControlPresentation(status)

        let guidance = presentation.manageTrustGuidance(caFingerprint: nil, certificatePath: nil)

        XCTAssertNotNil(guidance)
        XCTAssertTrue(guidance?.contains("fingerprint is unavailable") == true)
        XCTAssertTrue(guidance?.contains("do not change any Keychain trust setting") == true)
    }

    func testVaelenConfirmedTrustOffersRemoval() {
        let status = TLSStatus(state: .trusted, trustObserved: true, ownership: .owned, trustProvenance: .confirmedByVaelen, trustSettingsFingerprint: "recorded")

        let presentation = TLSTrustControlPresentation(status)

        XCTAssertEqual(presentation.title, "Trusted")
        XCTAssertFalse(presentation.canTrust)
        XCTAssertTrue(presentation.canRemove)
        XCTAssertFalse(presentation.canManageTrust)
        XCTAssertNil(presentation.manageTrustGuidance(caFingerprint: "recorded", certificatePath: "/ca.der"))
    }

    func testUntrustedManagedCAOffersTrustButNotRemoval() {
        let presentation = TLSTrustControlPresentation(TLSStatus(state: .createdButUntrusted, ownership: .owned))

        XCTAssertTrue(presentation.canTrust)
        XCTAssertFalse(presentation.canRemove)
        XCTAssertFalse(presentation.canManageTrust)
    }
}
