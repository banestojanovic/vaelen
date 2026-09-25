import XCTest
@testable import VaelenCore

final class TLSTrustControlPresentationTests: XCTestCase {
    func testObservedTrustWithUnknownProvenanceDoesNotOfferRemovalOrRetryTrust() {
        let status = TLSStatus(state: .trusted, trustObserved: true, ownership: .owned, trustProvenance: .none, trustSettingsFingerprint: nil)

        let presentation = TLSTrustControlPresentation(status)

        XCTAssertEqual(presentation.title, "Trusted (origin unknown)")
        XCTAssertFalse(presentation.canTrust)
        XCTAssertFalse(presentation.canRemove)
    }

    func testVaelenConfirmedTrustOffersRemoval() {
        let status = TLSStatus(state: .trusted, trustObserved: true, ownership: .owned, trustProvenance: .confirmedByVaelen, trustSettingsFingerprint: "recorded")

        let presentation = TLSTrustControlPresentation(status)

        XCTAssertEqual(presentation.title, "Trusted")
        XCTAssertFalse(presentation.canTrust)
        XCTAssertTrue(presentation.canRemove)
    }

    func testUntrustedManagedCAOffersTrustButNotRemoval() {
        let presentation = TLSTrustControlPresentation(TLSStatus(state: .createdButUntrusted, ownership: .owned))

        XCTAssertTrue(presentation.canTrust)
        XCTAssertFalse(presentation.canRemove)
    }
}
