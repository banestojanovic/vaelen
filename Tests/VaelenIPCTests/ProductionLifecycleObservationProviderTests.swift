import XCTest
@testable import VaelenDaemonSupport
import VaelenCore

final class ProductionLifecycleObservationProviderTests: XCTestCase {
    func testAbsentEndpointIsDefiniteOnlyForReachability() {
        let observation = ProductionLifecycleObservationProvider.EndpointObservationClassification.absent.observation
        XCTAssertEqual(observation.reachable, .false)
        XCTAssertEqual(observation.protocolCompatible, .unknown)
        XCTAssertEqual(observation.coreReady, .false)
    }

    func testWrongPeerAndProtocolAreIncompatibleNotFalse() {
        let observation = ProductionLifecycleObservationProvider.EndpointObservationClassification
            .incompatible("wrong peer").observation
        XCTAssertEqual(observation.reachable, .true)
        XCTAssertEqual(observation.protocolCompatible, .incompatible)
        XCTAssertEqual(observation.coreReady, .incompatible)
        XCTAssertNotEqual(observation.protocolCompatible, .false)
    }

    func testMalformedResponseIsIncompatibleNotFalse() {
        let observation = ProductionLifecycleObservationProvider.EndpointObservationClassification
            .incompatible("malformed response").observation
        XCTAssertEqual(observation.protocolCompatible, .incompatible)
        XCTAssertNotEqual(observation.protocolCompatible, .false)
    }

    func testTransportAmbiguityRemainsUnknown() {
        let observation = ProductionLifecycleObservationProvider.EndpointObservationClassification
            .ambiguous("transport failed after connect").observation
        XCTAssertEqual(observation.reachable, .unknown)
        XCTAssertEqual(observation.protocolCompatible, .unknown)
        XCTAssertEqual(observation.coreReady, .unknown)
    }

    func testReadinessFalseAndUnknownArePreserved() {
        XCTAssertEqual(ProductionLifecycleObservationProvider.observationValue(for: .starting), .false)
        XCTAssertEqual(ProductionLifecycleObservationProvider.observationValue(for: .unavailable), .false)
        XCTAssertEqual(ProductionLifecycleObservationProvider.observationValue(for: .unknown), .unknown)
        XCTAssertEqual(ProductionLifecycleObservationProvider.observationValue(for: .incompatible), .incompatible)
    }

    func testControllerEvidenceIsBoundToOperationAndGeneration() {
        let operation = UUID(); let session = UUID()
        let request = LifecycleControllerObservationRequest(operationID: operation, generation: 7,
            intent: .off, target: LifecycleCanonicalIdentity.target, sessionBinding: session)
        let response = LifecycleControllerObservationResponse(operationID: operation, generation: 7,
            target: request.target, nonce: request.nonce, sessionBinding: session,
            registrationMatch: .false, source: "signed-canonical-controller")
        XCTAssertTrue(LifecycleControllerObservationValidator.validate(response, request: request,
            controllerPath: LifecycleCanonicalIdentity.installedControllerURL.path))
        let stale = LifecycleControllerObservationResponse(operationID: operation, generation: 6,
            target: request.target, nonce: request.nonce, sessionBinding: session,
            registrationMatch: .false, source: "signed-canonical-controller")
        XCTAssertFalse(LifecycleControllerObservationValidator.validate(stale, request: request,
            controllerPath: LifecycleCanonicalIdentity.installedControllerURL.path))
    }

    func testControllerEvidenceRejectsReplayWrongControllerAndCannotAuthorizeMutation() {
        let request = LifecycleControllerObservationRequest(operationID: UUID(), generation: 2,
            intent: .off, target: LifecycleCanonicalIdentity.target, sessionBinding: UUID())
        let response = LifecycleControllerObservationResponse(operationID: request.operationID,
            generation: request.generation, target: request.target, nonce: request.nonce,
            sessionBinding: request.sessionBinding, registrationMatch: .true,
            source: "signed-canonical-controller")
        XCTAssertFalse(LifecycleControllerObservationValidator.validate(response, request: request,
            controllerPath: "/tmp/Vaelen.app"))
        let replay = LifecycleControllerObservationResponse(operationID: request.operationID,
            generation: request.generation, target: request.target, nonce: UUID(),
            sessionBinding: request.sessionBinding, registrationMatch: .true,
            source: "signed-canonical-controller")
        XCTAssertFalse(LifecycleControllerObservationValidator.validate(replay, request: request,
            controllerPath: LifecycleCanonicalIdentity.installedControllerURL.path))
        // A true observation is only evidence; it does not turn a client-side
        // response into an executor authorization envelope.
        XCTAssertEqual(response.registrationMatch, .true)
    }
}
