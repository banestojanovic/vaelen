import XCTest
import SQLite3
@testable import VaelenCore

final class DevelopmentCleanupTests: XCTestCase {
    private func promotedReceipt(operationID: UUID = UUID(uuidString: AuthorizedDevelopmentResidue.promotedReceiptOperationID)!, invocationID: UUID = UUID(uuidString: AuthorizedDevelopmentResidue.promotedReceiptInvocationID)!, hash: String = AuthorizedDevelopmentResidue.promotedReceiptArtifactHash) -> BootstrapReceipt {
        .init(target: LifecycleCanonicalIdentity.target, epoch: UUID(), operationID: operationID, nonce: UUID(), invocationToken: "token", invocationUser: "banes", invocationUID: 501, invocationID: invocationID, generation: 1, preflightProvenance: .init(signingTeam: LifecycleCanonicalIdentity.teamIdentifier, designatedRequirement: "identifier \\\"dev.vaelen.app\\\"", artifactHash: hash, bundleID: LifecycleCanonicalIdentity.target.bundleID, agentLabel: LifecycleCanonicalIdentity.target.agentLabel, bundleProgram: LifecycleCanonicalIdentity.target.bundleProgram), registrationEvidence: nil, expiresAt: Date.distantPast, phase: .promoted, executorState: .success, executorDetail: nil, postObservation: nil, integrityDigest: "")
    }

    func testPromotedReceiptExactMatchAndRefusal() {
        XCTAssertTrue(AuthorizedDevelopmentResidue.matchesPromotedReceipt(promotedReceipt()))
        XCTAssertFalse(AuthorizedDevelopmentResidue.matchesPromotedReceipt(promotedReceipt(operationID: UUID())))
        XCTAssertFalse(AuthorizedDevelopmentResidue.matchesPromotedReceipt(promotedReceipt(hash: "different")))
    }

    private func store() throws -> SQLiteStateStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-development-cleanup-").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
    }

    private func seed(_ store: SQLiteStateStore, operationID: String = AuthorizedDevelopmentResidue.offOperationID) throws {
        let target = LifecycleCanonicalIdentity.target
        try store.execute("INSERT INTO lifecycle_intent VALUES (1,'off',2,'\(operationID)','val','\(target.bundleID)','\(target.agentLabel)','\(target.bundleProgram)','\(target.endpoint)')")
        try store.execute("INSERT INTO lifecycle_ownership VALUES (1,'\(target.bundleID)','\(target.agentLabel)','\(target.bundleProgram)','\(target.endpoint)','TFKZJV643G','identifier \\\"dev.vaelen.app\\\"','obsolete', '\(AuthorizedDevelopmentResidue.ownershipOperationID)',1)")
        try store.execute("INSERT INTO lifecycle_operations (operation_id,generation,kind,state,pre_observation_json,post_observation_json,error,created_at) VALUES ('\(AuthorizedDevelopmentResidue.ownershipOperationID)',1,'register','succeeded','{}',NULL,NULL,CURRENT_TIMESTAMP)")
        try store.execute("INSERT INTO lifecycle_operations (operation_id,generation,kind,state,pre_observation_json,post_observation_json,error,created_at) VALUES ('\(AuthorizedDevelopmentResidue.offOperationID)',2,'unregister','unknown/recovery-required','{}',NULL,'Registration is not durably owned',CURRENT_TIMESTAMP)")
    }

    func testExactKnownResidueIsArchivedAndCleared() throws {
        let store = try store(); try seed(store)
        try store.performAuthorizedDevelopmentCleanup()
        var counts = [Int]()
        for table in ["lifecycle_intent", "lifecycle_operations", "lifecycle_ownership", "lifecycle_development_cleanup_history"] {
            try store.query("SELECT count(*) FROM \(table)") { counts.append(Int(sqlite3_column_int($0, 0))) }
        }
        XCTAssertEqual(counts, [0, 0, 0, 1])
        XCTAssertTrue(try store.diagnostics().contains { $0.detail.contains(AuthorizedDevelopmentResidue.source) })
    }

    func testCleanupRefusesDifferentOperationWithoutMutation() throws {
        let store = try store(); try seed(store, operationID: UUID().uuidString)
        XCTAssertThrowsError(try store.performAuthorizedDevelopmentCleanup())
        var count = 0
        try store.query("SELECT count(*) FROM lifecycle_ownership") { count = Int(sqlite3_column_int($0, 0)) }
        XCTAssertEqual(count, 1)
    }
}
