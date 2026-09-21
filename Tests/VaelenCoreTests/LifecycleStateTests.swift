import XCTest
@testable import VaelenCore

private struct ThrowingSMAppServicePlatform: SMAppServiceLifecyclePlatform {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "executor failure" }
    }

    func register() async throws { throw Failure() }
    func unregister() async throws { throw Failure() }
}

private struct DispatchIdentityGate: LifecycleDispatchIdentityRevalidator {
    let result: ObservationValue
    func revalidateProcessIdentity(expected: LifecycleProcessIdentity,
                                    target: LifecycleTargetIdentity) async -> ObservationValue { result }
    func revalidateOnRegistrationPreconditions(target: LifecycleTargetIdentity,
                                                allowExistingRegistration: Bool) async -> ObservationValue { result }
}

private actor CountingSMAppServicePlatform: SMAppServiceLifecyclePlatform {
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    func register() async throws { registerCalls += 1 }
    func unregister() async throws { unregisterCalls += 1 }
}

private actor DelayedRegistrationGate: LifecycleDispatchIdentityRevalidator {
    private var continuation: CheckedContinuation<ObservationValue, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var entered = false

    func revalidateProcessIdentity(expected: LifecycleProcessIdentity,
                                   target: LifecycleTargetIdentity) async -> ObservationValue { .true }
    func revalidateOnRegistrationPreconditions(target: LifecycleTargetIdentity,
                                               allowExistingRegistration: Bool) async -> ObservationValue {
        entered = true
        enteredWaiter?.resume(); enteredWaiter = nil
        return await withCheckedContinuation { continuation = $0 }
    }
    func isEntered() -> Bool { entered }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { continuation?.resume(returning: .true); continuation = nil }
}

final class LifecycleStateTests: XCTestCase {
    func testControllerMutationRequiresCanonicalOffEnvelopeAndPreservesBinding() {
        let request = LifecycleControllerMutationRequest(operationID: UUID(), generation: 2, intent: .off, target: LifecycleCanonicalIdentity.target, nonce: UUID(), sessionBinding: UUID())
        XCTAssertTrue(LifecycleControllerMutationValidator.validate(request, controllerPath: LifecycleCanonicalIdentity.installedControllerURL.path))
        XCTAssertFalse(LifecycleControllerMutationValidator.validate(.init(operationID: request.operationID, generation: request.generation, nonce: request.nonce, sessionBinding: UUID(), success: true), request: request))
        let on = LifecycleControllerMutationRequest(operationID: request.operationID, generation: request.generation, intent: .on, target: request.target, nonce: request.nonce, sessionBinding: request.sessionBinding)
        XCTAssertFalse(LifecycleControllerMutationValidator.validate(on, controllerPath: LifecycleCanonicalIdentity.installedControllerURL.path))
        XCTAssertFalse(LifecycleControllerMutationValidator.validate(request, controllerPath: "/tmp/Vaelen.app"))
    }

    private func store() throws -> SQLiteStateStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-lifecycle-").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
    }

    func testOnThenOffAdvancesGenerationAndFencesDelayedOn() throws {
        let repository = LifecycleStateRepository(store: try store())
        let target = LifecycleTargetIdentity(bundleID: "dev.vaelen", agentLabel: "dev.vaelen.agent", bundleProgram: "Contents/Resources/vaelend", endpoint: "/tmp/core.sock")
        let on = try repository.request(intent: .on, actor: "test", target: target)
        let off = try repository.request(intent: .off, actor: "test", target: target)
        XCTAssertEqual(on.generation, 1)
        XCTAssertEqual(off.generation, 2)
        XCTAssertFalse(try repository.accepts(operationID: on.operationID, generation: on.generation))
        XCTAssertTrue(try repository.accepts(operationID: off.operationID, generation: off.generation))
        XCTAssertEqual(try repository.intent()?.intent, .off)
    }

    func testReadinessRequiresAllThreeExplicitPredicates() {
        let incomplete = LifecycleObservationVector(endpointReachable: .true, protocolCompatible: .true, coreReady: .unknown)
        XCTAssertFalse(incomplete.isReady)
        let complete = LifecycleObservationVector(endpointReachable: .true, protocolCompatible: .true, coreReady: .true)
        XCTAssertTrue(complete.isReady)
    }

    func testCorePersistsCanonicalIdentityAndJournalSurvivesReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("state.sqlite")
        let first = try SQLiteStateStore(databaseURL: url)
        let repository = LifecycleStateRepository(store: first)
        let operation = try repository.request(intent: .on, actor: "test", target: .init(bundleID: "attacker", agentLabel: "bad", bundleProgram: "bad", endpoint: "/bad"))
        XCTAssertEqual(try repository.intent()?.target, repository.canonicalTarget)
        XCTAssertEqual(try repository.operation()?.operationID, operation.operationID)
        _ = try? first.pragmaVersion()
        let reopened = try SQLiteStateStore(databaseURL: url)
        let reopenedRepository = LifecycleStateRepository(store: reopened)
        XCTAssertEqual(try reopenedRepository.operation()?.operationID, operation.operationID)
        XCTAssertEqual(try reopenedRepository.intent()?.generation, 1)
    }

    func testCompletionIsFencedAndTerminalRowsCannotBeOverwritten() throws {
        let repository = LifecycleStateRepository(store: try store())
        let target = repository.canonicalTarget
        let on = try repository.request(intent: .on, actor: "test", target: target)
        XCTAssertTrue(try repository.markInFlight(operationID: on.operationID, generation: on.generation))
        try repository.complete(operationID: on.operationID, generation: on.generation, state: .succeeded, postObservation: .init(endpointReachable: .true, protocolCompatible: .true, coreReady: .true))
        try repository.complete(operationID: on.operationID, generation: on.generation, state: .failed, error: "late")
        XCTAssertEqual(try repository.operation()?.state, .succeeded)
        let off = try repository.request(intent: .off, actor: "test", target: target)
        try repository.complete(operationID: on.operationID, generation: on.generation, state: .failed, error: "stale")
        XCTAssertEqual(try repository.operation()?.operationID, off.operationID)
    }

    func testMalformedJournalFailsClosed() throws {
        let store = try store()
        let repository = LifecycleStateRepository(store: store)
        let operation = try repository.request(intent: .on, actor: "test", target: repository.canonicalTarget)
        try store.execute("UPDATE lifecycle_operations SET pre_observation_json = 'not-json' WHERE operation_id = '\(operation.operationID.uuidString)'")
        XCTAssertThrowsError(try repository.operation()) { XCTAssertEqual($0 as? SQLiteStateError, .invalidRecord) }
    }

    func testExecutorBindingIsDurableBeforeOffCanBeDispatched() throws {
        let store = try store()
        let repository = LifecycleStateRepository(store: store)
        let nonce = UUID()
        let session = UUID()
        let identity = LifecycleProcessIdentity(pid: 42, startIdentity: "start", uid: 501, executablePath: "/Applications/Vaelen.app/Contents/Resources/vaelend")
        let off = try repository.request(intent: .off, actor: "test", target: repository.canonicalTarget,
                                         operationID: UUID(), nonce: nonce, sessionBinding: session,
                                         processIdentity: identity)
        let reopened = LifecycleStateRepository(store: try SQLiteStateStore(databaseURL: store.databaseURL))
        let evidence = try reopened.operation()
        XCTAssertEqual(evidence?.operationID, off.operationID)
        XCTAssertEqual(evidence?.generation, off.generation)
        XCTAssertEqual(evidence?.nonce, nonce)
        XCTAssertEqual(evidence?.sessionBinding, session)
        XCTAssertEqual(evidence?.processIdentity, identity)
    }

    func testOffRecoveryCommitsFreshAbsenceWithoutReplay() throws {
        let store = try store()
        let repository = LifecycleStateRepository(store: store)
        let off = try repository.request(intent: .off, actor: "test", target: repository.canonicalTarget,
                                         nonce: UUID(), sessionBinding: UUID())
        XCTAssertTrue(try repository.markInFlight(operationID: off.operationID, generation: off.generation))
        try repository.complete(operationID: off.operationID, generation: off.generation, state: .unknownRecoveryRequired,
                                postObservation: .init(source: "production-observer"))
        let absence = LifecycleObservationVector(bundlePresent: .true, layoutValid: .true,
                                                   signatureValid: .true, registrationMatch: .false,
                                                   processMatch: .false, endpointReachable: .false,
                                                   source: "production-observer")
        XCTAssertTrue(try repository.recoverOffAfterFreshAbsence(absence))
        XCTAssertEqual(try repository.operation()?.state, .succeeded)
        XCTAssertNil(try repository.ownership())
    }

    func testSchemaSixReopensThroughLifecycleMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("state.sqlite")
        do {
            let store = try SQLiteStateStore(databaseURL: url)
            try store.execute("DROP TABLE lifecycle_ownership")
            try store.execute("DROP TABLE lifecycle_operations")
            try store.execute("DROP TABLE lifecycle_intent")
            try store.execute("PRAGMA user_version = 6")
        }
        let reopened = try SQLiteStateStore(databaseURL: url)
        XCTAssertEqual(try reopened.pragmaVersion(), SQLiteStateStore.schemaVersion)
        let repository = LifecycleStateRepository(store: reopened)
        XCTAssertEqual(try repository.request(intent: .off, actor: "restart", target: repository.canonicalTarget).generation, 1)
    }

    func testExecutorExposesSuccessFailureAndAmbiguousStatesWithoutMutation() async {
        for state in [LifecycleExecutorResultState.success, .rejected, .unavailable, .timeout, .unknown] {
            let fake = FakeLifecycleExecutor(result: .init(state: state))
            let operation = LifecycleExecutorRequest(operationID: UUID(), generation: 7, intent: .off,
                                                     target: LifecycleCanonicalIdentity.target, actor: "test")
            let result = await fake.execute(operation)
            XCTAssertEqual(result.state, state)
            let requests = await fake.requests()
            XCTAssertEqual(requests.first, operation)
        }
    }

    func testExecutorRejectsExpiredMismatchedAndReplayedCredentials() async {
        let session = UUID()
        let fake = FakeLifecycleExecutor(expectedSessionBinding: session)
        let base = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .on,
                                             target: LifecycleCanonicalIdentity.target, actor: "test",
                                             nonce: UUID(), deadline: Date().addingTimeInterval(30), sessionBinding: session)
        let first = await fake.execute(base)
        XCTAssertEqual(first.state, .unavailable)
        let replay = await fake.execute(base)
        XCTAssertEqual(replay.state, .rejected)
        let mismatch = LifecycleExecutorRequest(operationID: UUID(), generation: 2, intent: .off,
                                                target: LifecycleCanonicalIdentity.target, actor: "test",
                                                deadline: Date().addingTimeInterval(30), sessionBinding: UUID())
        let mismatched = await fake.execute(mismatch)
        XCTAssertEqual(mismatched.state, .rejected)
        let expired = LifecycleExecutorRequest(operationID: UUID(), generation: 3, intent: .off,
                                               target: LifecycleCanonicalIdentity.target, actor: "test",
                                               deadline: Date().addingTimeInterval(-1), sessionBinding: session)
        let expiredResult = await fake.execute(expired)
        XCTAssertEqual(expiredResult.state, .rejected)
    }

    func testInFlightAndTerminalFencesRejectStaleOffReversal() throws {
        let repository = LifecycleStateRepository(store: try store())
        let on = try repository.request(intent: .on, actor: "test", target: repository.canonicalTarget)
        XCTAssertTrue(try repository.markInFlight(operationID: on.operationID, generation: on.generation))
        let off = try repository.request(intent: .off, actor: "test", target: repository.canonicalTarget)
        XCTAssertFalse(try repository.markInFlight(operationID: on.operationID, generation: on.generation))
        XCTAssertTrue(try repository.markInFlight(operationID: off.operationID, generation: off.generation))
        try repository.complete(operationID: off.operationID, generation: off.generation, state: .failed,
                                postObservation: .init(reason: "executor rejected"))
        try repository.complete(operationID: on.operationID, generation: on.generation, state: .succeeded,
                                postObservation: .init(endpointReachable: .true, protocolCompatible: .true, coreReady: .true))
        XCTAssertEqual(try repository.operation()?.operationID, off.operationID)
        XCTAssertEqual(try repository.operation()?.state, .failed)
    }

    func testSuccessWithIncompleteObservationNeverReportsReadiness() {
        let observation = LifecycleObservationVector(endpointReachable: .true, protocolCompatible: .true, coreReady: .unknown)
        let result = LifecycleExecutorResult(state: .success, postObservation: observation)
        XCTAssertFalse(result.postObservation?.isReady ?? true)
    }

    func testProductionCanonicalIdentityMatchesSupportedAppAndEndpoint() {
        let target = LifecycleCanonicalIdentity.target
        XCTAssertEqual(target.bundleID, "dev.vaelen.app")
        XCTAssertEqual(target.agentLabel, "dev.vaelen.vaelend")
        XCTAssertEqual(target.bundleProgram, "Contents/Resources/vaelend")
        XCTAssertTrue(target.endpoint.hasSuffix("Vaelen/runtime/sockets/core.sock"))
    }

    func testSMAppServiceExecutorRejectsUnissuedAndWrongIdentityRequestsWithoutMutation() async {
        let session = UUID()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session)
        let wrong = LifecycleTargetIdentity(bundleID: "foreign.app", agentLabel: "foreign.agent", bundleProgram: "bad", endpoint: "/bad")
        let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .on,
                                               target: wrong, actor: "test", deadline: Date().addingTimeInterval(30),
                                               sessionBinding: session)
        let result = await executor.execute(request)
        XCTAssertEqual(result.state, .rejected)
        let expired = LifecycleExecutorRequest(operationID: UUID(), generation: 2, intent: .off,
                                                target: LifecycleCanonicalIdentity.target, actor: "test",
                                                deadline: Date().addingTimeInterval(-1), sessionBinding: session)
        let expiredResult = await executor.execute(expired)
        XCTAssertEqual(expiredResult.state, .rejected)
    }

    func testSMAppServiceExecutorThrowIsUnknownRatherThanFalseTerminalRejection() async {
        for intent in [LifecycleIntent.on, .off] {
            let session = UUID()
            let executor = SMAppServiceLifecycleExecutor(sessionBinding: session, platform: ThrowingSMAppServicePlatform(),
                identityRevalidator: DispatchIdentityGate(result: .true))
            let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: intent,
                                                   target: LifecycleCanonicalIdentity.target, actor: "test",
                                                   deadline: Date().addingTimeInterval(30), sessionBinding: session,
                                                   processIdentity: intent == .off ? .init(pid: 42, startIdentity: "1.2", uid: 501, executablePath: "/Applications/Vaelen.app/Contents/Resources/vaelend") : nil)

            await executor.authorize(request)
            let result = await executor.execute(request)

            XCTAssertEqual(result.state, .unknown, "unexpected state for \(intent)")
            XCTAssertTrue(result.detail?.contains("executor failure") == true)
            XCTAssertNil(result.postObservation)
        }
    }

    func testSMAppServiceDispatchRecheckRejectsReplacementAndAllIdentityDrift() async {
        let expected = LifecycleProcessIdentity(pid: 42, startIdentity: "1.2", uid: 501, executablePath: "/Applications/Vaelen.app/Contents/Resources/vaelend")
        for drift in [ObservationValue.unknown, .false, .incompatible] {
            let session = UUID()
            let executor = SMAppServiceLifecycleExecutor(sessionBinding: session,
                platform: ThrowingSMAppServicePlatform(), identityRevalidator: DispatchIdentityGate(result: drift))
            let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .off,
                target: LifecycleCanonicalIdentity.target, actor: "test", deadline: Date().addingTimeInterval(30),
                sessionBinding: session, processIdentity: expected)
            await executor.authorize(request)
            let result = await executor.execute(request)
            XCTAssertEqual(result.state, .rejected, "identity drift must withhold the platform call")
        }
    }

    func testSMAppServiceDispatchRecheckRequiresEvidenceAndAllowsStableEvidenceToReachPlatform() async {
        let session = UUID()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session,
            platform: ThrowingSMAppServicePlatform(), identityRevalidator: DispatchIdentityGate(result: .true))
        let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .on,
            target: LifecycleCanonicalIdentity.target, actor: "test", deadline: Date().addingTimeInterval(30),
            sessionBinding: session,
            processIdentity: .init(pid: 42, startIdentity: "1.2", uid: 501, executablePath: "/Applications/Vaelen.app/Contents/Resources/vaelend"))
        await executor.authorize(request)
        let result = await executor.execute(request)
        XCTAssertEqual(result.state, .unknown, "stable recheck must permit the single platform call")
        XCTAssertTrue(result.detail?.contains("executor failure") == true)
    }

    func testSMAppServiceOnAllowsAbsentProcessWithValidRegistrationPreconditions() async {
        let session = UUID()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session,
            platform: ThrowingSMAppServicePlatform(), identityRevalidator: DispatchIdentityGate(result: .true))
        let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .on,
            target: LifecycleCanonicalIdentity.target, actor: "test", deadline: Date().addingTimeInterval(30),
            sessionBinding: session, processIdentity: nil)
        await executor.authorize(request)
        let result = await executor.execute(request)
        XCTAssertEqual(result.state, .unknown, "valid non-process preconditions must reach the single platform call")
        XCTAssertTrue(result.detail?.contains("executor failure") == true)
    }

    func testSMAppServiceOnWithoutRevalidatorRejectsBeforePlatformCall() async {
        let session = UUID()
        let platform = CountingSMAppServicePlatform()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session, platform: platform)
        let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .on,
            target: LifecycleCanonicalIdentity.target, actor: "test", deadline: Date().addingTimeInterval(30),
            sessionBinding: session)

        await executor.authorize(request)
        let result = await executor.execute(request)

        XCTAssertEqual(result.state, .rejected)
        let registerCalls = await platform.registerCalls
        let unregisterCalls = await platform.unregisterCalls
        XCTAssertEqual(registerCalls, 0)
        XCTAssertEqual(unregisterCalls, 0)
    }

    func testRevokedInFlightOnCannotReachPlatformAfterNewerOff() async {
        let session = UUID()
        let platform = CountingSMAppServicePlatform()
        let gate = DelayedRegistrationGate()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session, platform: platform,
                                                     identityRevalidator: gate)
        let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .on,
            target: LifecycleCanonicalIdentity.target, actor: "test",
            deadline: Date().addingTimeInterval(30), sessionBinding: session)
        await executor.authorize(request)
        let task = Task { await executor.execute(request) }
        await gate.waitUntilEntered()

        // This models the durable Off superseding the suspended On.  The
        // tombstone is checked again after the delayed precondition probe and
        // before the sole platform mutation boundary.
        await executor.invalidate(operationID: request.operationID, nonce: request.nonce)
        await gate.release()
        let result = await task.value
        XCTAssertEqual(result.state, .rejected)
        let registerCalls = await platform.registerCalls
        XCTAssertEqual(registerCalls, 0)
    }

    func testSMAppServiceOffRejectsMissingProcessIdentityBeforePlatformCall() async {
        let session = UUID()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session,
            platform: ThrowingSMAppServicePlatform(), identityRevalidator: DispatchIdentityGate(result: .true))
        let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .off,
            target: LifecycleCanonicalIdentity.target, actor: "test", deadline: Date().addingTimeInterval(30),
            sessionBinding: session)
        await executor.authorize(request)
        let result = await executor.execute(request)
        XCTAssertEqual(result.state, .rejected)
        XCTAssertTrue(result.detail?.contains("process identity") == true)
    }

    func testSMAppServiceDispatchRecheckRejectsUnavailableIdentity() async {
        let session = UUID()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session,
            platform: ThrowingSMAppServicePlatform(), identityRevalidator: DispatchIdentityGate(result: .unknown))
        let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .off,
            target: LifecycleCanonicalIdentity.target, actor: "test", deadline: Date().addingTimeInterval(30),
            sessionBinding: session)
        await executor.authorize(request)
        let result = await executor.execute(request)
        XCTAssertEqual(result.state, .rejected)
    }

    func testOwnershipRequiresSucceededRegisterAndFreshMatchingObservation() throws {
        let repository = LifecycleStateRepository(store: try store())
        let operation = try repository.request(intent: .on, actor: "test", target: repository.canonicalTarget)
        XCTAssertFalse(try repository.hasValidOwnership(for: repository.canonicalTarget,
                                                        observation: .init(registrationMatch: .true, source: "test")))
        XCTAssertTrue(try repository.markInFlight(operationID: operation.operationID, generation: operation.generation))
        let post = LifecycleObservationVector(bundlePresent: .true, layoutValid: .true, signatureValid: .true,
                                               registrationMatch: .true, processMatch: .false, signingTeam: "TESTTEAM",
                                               designatedRequirement: "identifier \"dev.vaelen.app\"",
                                               artifactHash: "hash", source: "test")
        try repository.complete(operationID: operation.operationID, generation: operation.generation,
                                state: .succeeded, postObservation: post)
        try repository.saveOwnership(.init(target: repository.canonicalTarget, signingTeam: "TESTTEAM",
                                           designatedRequirement: "identifier \"dev.vaelen.app\"", artifactHash: "hash",
                                           operationID: operation.operationID, generation: operation.generation))
        XCTAssertTrue(try repository.hasValidOwnership(for: repository.canonicalTarget, observation: post))
    }

    func testSMAppServiceAuthorizationBindsEveryEnvelopeField() async {
        let session = UUID()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session)
        let request = LifecycleExecutorRequest(operationID: UUID(), generation: 1, intent: .on,
                                               target: LifecycleCanonicalIdentity.target, actor: "core",
                                               nonce: UUID(), deadline: Date().addingTimeInterval(30),
                                               sessionBinding: session)
        await executor.authorize(request)
        let altered = LifecycleExecutorRequest(operationID: request.operationID, generation: request.generation,
                                               intent: request.intent, target: request.target, actor: "forged",
                                               nonce: request.nonce, deadline: request.deadline,
                                               sessionBinding: request.sessionBinding)
        let alteredResult = await executor.execute(altered)
        XCTAssertEqual(alteredResult.state, .rejected)
    }
}
