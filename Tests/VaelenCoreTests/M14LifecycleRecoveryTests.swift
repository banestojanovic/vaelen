import XCTest
import SQLite3
@testable import VaelenCore

final class M14LifecycleRecoveryTests: XCTestCase {
    private actor LegacyPlatform: BootstrapPlatform {
         var enabled = true
         var unregisterCalls = 0
         var registerCalls = 0
        func preflight() async -> Bool { true }
        func preflightProvenance() async -> BootstrapReceiptProvenance? {
            .init(signingTeam: LifecycleCanonicalIdentity.teamIdentifier,
                  designatedRequirement: "identifier \"dev.vaelen.app\"",
                  artifactHash: "fresh-artifact")
        }
        func recoveryIdentity() async -> BootstrapReceiptProvenance? { await preflightProvenance() }
        func coreEndpointReachable() async -> Bool { false }
        func registrationObservation() async -> ObservationValue { enabled ? .true : .false }
        func registrationObservationSnapshot() async -> BootstrapRegistrationObservation {
            .init(value: enabled ? .true : .false,
                  detail: enabled ? "status=enabled" : "status=notRegistered",
                  status: enabled ? .enabled : .notRegistered)
        }
        func unregister() async throws { unregisterCalls += 1; enabled = false }
        func register() async throws { registerCalls += 1; enabled = true }
        func calls() -> Int { unregisterCalls }
        func registrations() -> Int { registerCalls }
    }
    private func database() throws -> (SQLiteStateStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-m14-recovery-").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("state.sqlite")
        return (try SQLiteStateStore(databaseURL: url), url)
    }

    func testReopenClassifiesInFlightAsDurableRecoveryRequired() throws {
        let (store, url) = try database()
        let repo = LifecycleStateRepository(store: store)
        let operation = try repo.request(intent: .on, actor: "test", target: repo.canonicalTarget)
        XCTAssertTrue(try repo.markInFlight(operationID: operation.operationID, generation: operation.generation))
        _ = try SQLiteStateStore(databaseURL: url)
        let reopened = try SQLiteStateStore(databaseURL: url)
        XCTAssertEqual(try LifecycleStateRepository(store: reopened).operation()?.state, .unknownRecoveryRequired)
    }

    func testReceiptBarrierDoesNotCallPlatform() async throws {
        let (store, _) = try database()
        let counter = FakeBootstrapPlatform.Counter()
        let platform = FakeBootstrapPlatform(counter: counter)
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-m14-lock-").appendingPathComponent(UUID().uuidString).appendingPathComponent("runtime/sockets/core.sock").path
        let executor = CoreAbsentBootstrapExecutor(store: store, platform: platform, lockEndpoint: lock)
        let authorization = try store.mintBootstrapInvocation()
        _ = try await executor.execute(explicitInvocationToken: authorization.token)
        do { _ = try await executor.execute(explicitInvocationToken: "second"); XCTFail("expected recovery refusal") } catch { }
        let calls = await counter.count()
        XCTAssertEqual(calls, 1)
    }

    func testLegacyPreInvocationRecoveryIsExactOneShotAndLeavesReceiptUntouched() async throws {
        let (store, _) = try database()
        let epoch = LegacyBootstrapRecoveryAuthorization.epoch.uuidString
        let operation = LegacyBootstrapRecoveryAuthorization.operationID.uuidString
        let target = LifecycleCanonicalIdentity.target
        let expiry = String(Date().addingTimeInterval(-60).timeIntervalSince1970)
        // Fixture represents the v9 migration result of a pre-invocation
        // receipt: invocation_id is intentionally empty. Production recovery
        // never performs this write; it only reads this structural shape.
        try store.execute("INSERT INTO bootstrap_receipts (id,bundle_id,agent_label,bundle_program,endpoint,epoch,operation_id,nonce,invocation_token_hash,invocation_token,invocation_user,invocation_uid,invocation_id,generation,preflight_provenance_json,expires_at,phase,executor_state,executor_detail,post_observation_json,integrity_digest) VALUES (1,'\(target.bundleID)','\(target.agentLabel)','\(target.bundleProgram)','\(target.endpoint)','\(epoch)','\(operation)','00000000-0000-0000-0000-000000000000','legacy-hash','legacy-hash','test',501,'',0,'{}','\(expiry)','succeeded',NULL,NULL,NULL,'legacy-digest')")
        let before = try store.legacyBootstrapReceipt()
        let platform = LegacyPlatform()
        let executor = CoreAbsentBootstrapExecutor(store: store, platform: platform,
            lockEndpoint: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("runtime/sockets/core.sock").path)
        let result = try await executor.recoverLegacyPreInvocationOrphan()
        XCTAssertEqual(result.source, LegacyBootstrapRecoveryAuthorization.source)
        XCTAssertEqual(result.state, .succeeded)
        let firstCalls = await platform.calls()
        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(try store.legacyBootstrapReceipt(), before)
        await XCTAssertThrowsErrorAsync { try await executor.recoverLegacyPreInvocationOrphan() }
        let retryCalls = await platform.calls()
        XCTAssertEqual(retryCalls, 1)
    }

    func testLegacyRecoveryRejectsModernReceiptWithoutInvocationIDConfusion() async throws {
        let (store, _) = try database()
        let token = try store.mintBootstrapInvocation()
        let platform = LegacyPlatform()
        let executor = CoreAbsentBootstrapExecutor(store: store, platform: platform,
            lockEndpoint: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("runtime/sockets/core.sock").path)
        await XCTAssertThrowsErrorAsync { _ = try await executor.execute(explicitInvocationToken: token.token) }
        await XCTAssertThrowsErrorAsync { try await executor.recoverLegacyPreInvocationOrphan() }
        let calls = await platform.calls()
        XCTAssertEqual(calls, 0)
    }

    func testSuccessfulLegacyRecoveryArchivesExactReceiptBeforeFreshModernStart() async throws {
        let (store, _) = try database()
        let target = LifecycleCanonicalIdentity.target
        let expiry = String(Date().addingTimeInterval(-60).timeIntervalSince1970)
        try store.execute("INSERT INTO bootstrap_receipts (id,bundle_id,agent_label,bundle_program,endpoint,epoch,operation_id,nonce,invocation_token_hash,invocation_token,invocation_user,invocation_uid,invocation_id,generation,preflight_provenance_json,expires_at,phase,executor_state,executor_detail,post_observation_json,integrity_digest) VALUES (1,'\(target.bundleID)','\(target.agentLabel)','\(target.bundleProgram)','\(target.endpoint)','\(LegacyBootstrapRecoveryAuthorization.epoch.uuidString)','\(LegacyBootstrapRecoveryAuthorization.operationID.uuidString)','11111111-1111-1111-1111-111111111111','legacy-hash','legacy-hash','legacy-user',501,'',7,'legacy-provenance','\(expiry)','succeeded','success','legacy detail','legacy observation','legacy-digest')")
        let platform = LegacyPlatform()
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("runtime/sockets/core.sock").path
        let executor = CoreAbsentBootstrapExecutor(store: store, platform: platform, lockEndpoint: lock)

        _ = try await executor.recoverLegacyPreInvocationOrphan()
        let authorization = try store.mintBootstrapInvocation()
        let modern = try await executor.execute(explicitInvocationToken: authorization.token)

        XCTAssertNotEqual(modern.invocationID, UUID())
        XCTAssertFalse(modern.invocationID.uuidString.isEmpty)
        XCTAssertEqual(modern.phase, .succeeded)
        let unregisters = await platform.calls()
        let registrations = await platform.registrations()
        XCTAssertEqual(unregisters, 1)
        XCTAssertEqual(registrations, 1)
        let current = try store.bootstrapReceipt()
        XCTAssertEqual(current?.operationID, modern.operationID)
        XCTAssertEqual(current?.invocationID, authorization.correlationID)
        var archived = ""
        try store.query("SELECT receipt_json FROM bootstrap_receipt_history WHERE source='\(LegacyBootstrapRecoveryAuthorization.source)' AND epoch='\(LegacyBootstrapRecoveryAuthorization.epoch.uuidString)' AND operation_id='\(LegacyBootstrapRecoveryAuthorization.operationID.uuidString)'") { statement in
            if let text = sqlite3_column_text(statement, 0) { archived = String(cString: text) }
        }
        XCTAssertTrue(archived.contains("legacy detail"))
        XCTAssertTrue(archived.contains("legacy observation"))
        XCTAssertTrue(archived.contains("legacy-provenance"))
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ body: @escaping () async throws -> T) async {
    do { _ = try await body(); XCTFail("expected error") } catch { }
}
