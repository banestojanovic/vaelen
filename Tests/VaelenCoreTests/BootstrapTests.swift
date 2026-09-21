import XCTest
@testable import VaelenCore
import Darwin
import CryptoKit

final class BootstrapTests: XCTestCase {
    private final class AuthorizationProbe: @unchecked Sendable {
        var authorized = false
    }
    private struct ProbeAuthenticator: BootstrapReceiptAuthenticator {
        let probe: AuthorizationProbe
        func mac(for data: Data) throws -> String {
            guard probe.authorized else { throw BootstrapError.invalidReceipt }
            return String(repeating: "0", count: 64)
        }
        func verifies(mac: String, for data: Data) throws -> Bool { probe.authorized }
        func authorize(provenance: BootstrapReceiptProvenance) throws { probe.authorized = true }
    }
    private struct FixedAuthenticator: BootstrapReceiptAuthenticator {
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        func mac(for data: Data) throws -> String { HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined() }
        func verifies(mac: String, for data: Data) throws -> Bool { try mac == self.mac(for: data) }
    }
    private actor Platform: BootstrapPlatform {
        var observation: ObservationValue = .false
        let reachable: Bool; let failure: Bool
        init(reachable: Bool = false, failure: Bool = false) { self.reachable = reachable; self.failure = failure }
        func registrationObservation() async -> ObservationValue { observation }
        func preflight() async -> Bool { true }
        func coreEndpointReachable() async -> Bool { reachable }
        func register() async throws { if failure { throw TestError.failure }; observation = .true }
    }
    private actor RacePlatform: BootstrapPlatform {
        var reachable = false
        var registerCalls = 0
        let observation: ObservationValue
        init(observation: ObservationValue = .false) { self.observation = observation }
        func registrationObservation() async -> ObservationValue { observation }
        func preflight() async -> Bool { reachable = true; return true }
        func coreEndpointReachable() async -> Bool { reachable }
        func register() async throws { registerCalls += 1 }
        func calls() -> Int { registerCalls }
    }
    private enum TestError: Error { case failure }
    private func store() throws -> SQLiteStateStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-bootstrap-").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
    }
    private func lock() -> String { FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-bootstrap-lock-").appendingPathComponent(UUID().uuidString).appendingPathComponent("runtime/sockets/core.sock").path }
    private func token(_ store: SQLiteStateStore) throws -> String { try store.mintBootstrapInvocation().token }
    private func observation(_ date: Date = Date().addingTimeInterval(1), process: LifecycleProcessIdentity? = nil, artifact: String = "hash", registration: ObservationValue = .true) -> LifecycleObservationVector { .init(bundlePresent: .true, layoutValid: .true, signatureValid: .true, registrationMatch: registration, processMatch: .true, endpointReachable: .true, protocolCompatible: .true, coreReady: .true, signingTeam: "TESTTEAM", designatedRequirement: "identifier \"dev.vaelen.app\"", artifactHash: artifact, processIdentity: process ?? .init(pid: getpid(), startIdentity: "test", uid: getuid(), executablePath: "/Vaelen.app/Contents/Resources/vaelend"), observedAt: date, source: "client-forged") }
    private func assertAsyncThrows<T>(_ body: @escaping () async throws -> T) async { do { _ = try await body(); XCTFail("Expected throw") } catch {} }

    func testReservationIsDurableBeforePlatformCall() async throws {
        let s = try store(), l = lock(), e = CoreAbsentBootstrapExecutor(store: s, platform: FakeBootstrapPlatform(), lockEndpoint: l)
        let r = try await e.execute(explicitInvocationToken: try token(s))
        XCTAssertEqual(r.phase, .unknownRecoveryRequired); XCTAssertEqual(try s.bootstrapReceipt()?.phase, .unknownRecoveryRequired)
        e.releaseHandoffLock()
    }

    func testResumePreflightMustAuthorizeReceiptAuthenticatorFirst() async throws {
        let s = try store(), probe = AuthorizationProbe()
        let executor = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: lock(), authenticator: ProbeAuthenticator(probe: probe))
        _ = try await executor.validateSignedPreflight()
        XCTAssertTrue(probe.authorized)
        executor.releaseHandoffLock()
    }

    func testProductionAuthenticatorFailsClosedBeforeSignedPreflight() throws {
        XCTAssertThrowsError(try KeychainBootstrapReceiptAuthenticator().mac(for: Data("receipt".utf8)))
    }
    func testDuplicateReceiptAndReplayAreRefused() async throws {
        let s = try store(), l = lock(), e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l); let r = try await e.execute(explicitInvocationToken: try token(s))
        await assertAsyncThrows { try await e.execute(explicitInvocationToken: "again") }
        let repo = LifecycleStateRepository(store: s)
        _ = try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: observation(), epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l)
        e.releaseHandoffLock()
        XCTAssertThrowsError(try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: observation(Date().addingTimeInterval(2)), epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l))
    }
    func testDurableOffCanBeExplicitlyPromotedToOn() async throws {
        let s = try store(), l = lock(), repo = LifecycleStateRepository(store: s)
        let off = try repo.request(intent: .off, actor: "test", target: repo.canonicalTarget)
        XCTAssertTrue(try repo.markInFlight(operationID: off.operationID, generation: off.generation))
        try repo.complete(operationID: off.operationID, generation: off.generation, state: .failed, error: "already off")
        let e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l)
        let r = try await e.execute(explicitInvocationToken: try token(s))
        let result = try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: observation(), epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l)
        e.releaseHandoffLock()
        XCTAssertEqual(result.intent?.intent, .on); XCTAssertEqual(result.intent?.generation, 2); XCTAssertEqual(result.intent?.actor, "bootstrap")
    }
    func testCoreReachableRefusesBeforeReservation() async throws {
        let s = try store(); await assertAsyncThrows { try await CoreAbsentBootstrapExecutor(store: s, platform: Platform(reachable: true), lockEndpoint: self.lock()).execute(explicitInvocationToken: try self.token(s)) }; XCTAssertNil(try s.bootstrapReceipt())
    }

    func testRegistrationObservationMustBeExactlyFalse() async throws {
        for value in [ObservationValue.unknown, .true] {
            let s = try store(), counter = FakeBootstrapPlatform.Counter()
            let platform = FakeBootstrapPlatform(observation: value, counter: counter)
            await assertAsyncThrows {
                try await CoreAbsentBootstrapExecutor(store: s, platform: platform, lockEndpoint: self.lock()).execute(explicitInvocationToken: try self.token(s))
            }
            XCTAssertNil(try s.bootstrapReceipt())
            let calls = await counter.count()
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(try s.diagnostics().contains { $0.phase == .platform && $0.outcome == "registration-observation" && $0.detail.contains("value=\(value.rawValue)") })
        }
    }

    func testNotFoundIsADistinctFirstRegistrationPreconditionAndAttemptsOnce() async throws {
        let s = try store(), counter = FakeBootstrapPlatform.Counter()
        let platform = FakeBootstrapPlatform(observation: .unknown, registrationStatus: .notFound, counter: counter)
        let executor = CoreAbsentBootstrapExecutor(store: s, platform: platform, lockEndpoint: lock())
        let receipt = try await executor
            .execute(explicitInvocationToken: try token(s))

        XCTAssertEqual(receipt.phase, .unknownRecoveryRequired,
                       "notFound after the call must fail closed rather than claim registration")
        let registerCalls = await counter.count()
        XCTAssertEqual(registerCalls, 1)
        XCTAssertTrue(receipt.executorDetail?.contains("remained notFound") == true)
        await assertAsyncThrows {
            try await executor.execute(explicitInvocationToken: try self.token(s))
        }
        let replayCalls = await counter.count()
        XCTAssertEqual(replayCalls, 1, "a durable notFound result must not be replayed")
    }

    func testNotFoundRegisterThrowFailsClosedAndCannotBeRetried() async throws {
        let s = try store(), counter = FakeBootstrapPlatform.Counter()
        let platform = FakeBootstrapPlatform(observation: .unknown, registrationError: "platform refusal",
                                              registrationStatus: .notFound, counter: counter)
        let executor = CoreAbsentBootstrapExecutor(store: s, platform: platform, lockEndpoint: lock())
        let receipt = try await executor.execute(explicitInvocationToken: try token(s))
        XCTAssertEqual(receipt.phase, BootstrapReceiptPhase.failed)
        XCTAssertEqual(receipt.executorState, LifecycleExecutorResultState.rejected)
        let firstCalls = await counter.count()
        XCTAssertEqual(firstCalls, 1)
        await assertAsyncThrows {
            try await executor.execute(explicitInvocationToken: try self.token(s))
        }
        let retryCalls = await counter.count()
        XCTAssertEqual(retryCalls, 1)
    }

    func testRequiresApprovalRemainsTruthfulAndDoesNotRegister() async throws {
        let s = try store(), counter = FakeBootstrapPlatform.Counter()
        let platform = FakeBootstrapPlatform(observation: .unknown, registrationStatus: .requiresApproval, counter: counter)
        await assertAsyncThrows {
            try await CoreAbsentBootstrapExecutor(store: s, platform: platform, lockEndpoint: self.lock())
                .execute(explicitInvocationToken: try self.token(s))
        }
        let registerCalls = await counter.count()
        XCTAssertEqual(registerCalls, 0)
        XCTAssertNil(try s.bootstrapReceipt())
    }

    func testRegistrationObservationSnapshotKeepsValueAndDetailTogether() async throws {
        let platform = FakeBootstrapPlatform(observation: .unknown)
        let snapshot = await platform.registrationObservationSnapshot()
        XCTAssertEqual(snapshot, .init(value: .unknown, detail: "observation=unknown"))
    }

    func testEndpointIsReprobedUnderLeaseImmediatelyBeforeReservation() async throws {
        let s = try store(), platform = RacePlatform()
        await assertAsyncThrows {
            try await CoreAbsentBootstrapExecutor(store: s, platform: platform, lockEndpoint: self.lock()).execute(explicitInvocationToken: try self.token(s))
        }
        XCTAssertNil(try s.bootstrapReceipt())
        let calls = await platform.calls()
        XCTAssertEqual(calls, 0)
    }

    func testLifecycleReceiptBarrierBlocksBeforeJournalSupersession() async throws {
        let s = try store(), endpoint = lock()
        let bootstrap = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: endpoint)
        _ = try await bootstrap.execute(explicitInvocationToken: try token(s))
        let repository = LifecycleStateRepository(store: s)
        XCTAssertThrowsError(try repository.requireBootstrapPromotion()) { error in
            guard case BootstrapError.recoveryRequired = error else { return XCTFail("wrong barrier error: \(error)") }
        }
        XCTAssertNil(try repository.intent())
        bootstrap.releaseHandoffLock()
    }

    func testUnresolvedJournalRefusesBeforeAnyPlatformCall() async throws {
        let s = try store(), l = lock(), counter = FakeBootstrapPlatform.Counter()
        let repository = LifecycleStateRepository(store: s)
        _ = try repository.request(intent: .on, actor: "test", target: repository.canonicalTarget)
        let platform = FakeBootstrapPlatform(counter: counter)
        await assertAsyncThrows {
            try await CoreAbsentBootstrapExecutor(store: s, platform: platform, lockEndpoint: l)
                .execute(explicitInvocationToken: try self.token(s))
        }
        let calls = await counter.count()
        XCTAssertEqual(calls, 0)
    }

    func testFreshObservationMustMatchSucceededReceiptProvenance() async throws {
        let s = try store(), l = lock(), e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l)
        _ = try await e.execute(explicitInvocationToken: try token(s))
        XCTAssertThrowsError(try LifecycleStateRepository(store: s).validateDaemonAdmission(observation: observation(Date(), artifact: "different")))
        e.releaseHandoffLock()
    }

    func testExpiredSucceededReceiptIsRejectedDespiteFreshObservation() async throws {
        let s = try store(), l = lock(), e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), ttl: 1, lockEndpoint: l)
        _ = try await e.execute(explicitInvocationToken: try token(s))
        XCTAssertThrowsError(try LifecycleStateRepository(store: s).validateDaemonAdmission(observation: observation(Date()), now: Date().addingTimeInterval(10)))
        e.releaseHandoffLock()
    }

    func testAdmissionRejectsWrongCurrentProcessIdentity() async throws {
        let s = try store(), l = lock(), e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l)
        _ = try await e.execute(explicitInvocationToken: try token(s))
        let wrong = LifecycleProcessIdentity(pid: getpid() + 1, startIdentity: "test", uid: getuid(), executablePath: "/Vaelen.app/Contents/Resources/vaelend")
        XCTAssertThrowsError(try LifecycleStateRepository(store: s).validateDaemonAdmission(observation: observation(Date(), process: wrong)))
        e.releaseHandoffLock()
    }

    func testOffFenceRejectsAdmissionWithoutExplicitBootstrapReceipt() throws {
        let s = try store(), repository = LifecycleStateRepository(store: s)
        _ = try repository.request(intent: .off, actor: "test", target: repository.canonicalTarget)
        XCTAssertThrowsError(try repository.validateDaemonAdmission(observation: observation(Date())))
    }

    func testPromotedCurrentOnMustMatchFreshOwnershipProvenance() async throws {
        let s = try store(), l = lock(), e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l)
        let receipt = try await e.execute(explicitInvocationToken: try token(s)), repository = LifecycleStateRepository(store: s)
        _ = try repository.promoteBootstrap(invocationToken: receipt.invocationToken, observation: observation(), epoch: receipt.epoch, operationID: receipt.operationID, nonce: receipt.nonce, lockEndpoint: l)
        XCTAssertThrowsError(try repository.validateDaemonAdmission(observation: observation(Date(), artifact: "different")))
        e.releaseHandoffLock()
    }

    func testMalformedJournalRefusesBeforeAnyPlatformCall() async throws {
        let s = try store(), l = lock(), counter = FakeBootstrapPlatform.Counter()
        let repository = LifecycleStateRepository(store: s)
        let operation = try repository.request(intent: .on, actor: "test", target: repository.canonicalTarget)
        try s.execute("UPDATE lifecycle_operations SET pre_observation_json = 'malformed' WHERE operation_id = '\(operation.operationID.uuidString)'")
        let platform = FakeBootstrapPlatform(counter: counter)
        await assertAsyncThrows {
            try await CoreAbsentBootstrapExecutor(store: s, platform: platform, lockEndpoint: l)
                .execute(explicitInvocationToken: try self.token(s))
        }
        let calls = await counter.count()
        XCTAssertEqual(calls, 0)
    }

    func testFailedPreflightRefusesBeforePlatformRegister() async throws {
        let s = try store(), l = lock(), counter = FakeBootstrapPlatform.Counter()
        let platform = FakeBootstrapPlatform(preflightResult: false, counter: counter)
        await assertAsyncThrows {
            try await CoreAbsentBootstrapExecutor(store: s, platform: platform, lockEndpoint: l)
                .execute(explicitInvocationToken: try self.token(s))
        }
        let calls = await counter.count()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(try s.bootstrapReceipt())
    }

    func testStaleLockFileDoesNotBlockButHeldLockDoes() async throws {
        let s = try store(), l = lock(), lockURL = URL(fileURLWithPath: BootstrapLock.lockPath(endpoint: l))
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]))

        let bootstrap = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l)
        let receipt = try await bootstrap.execute(explicitInvocationToken: try token(s))
        XCTAssertEqual(receipt.phase, .succeeded)
        bootstrap.releaseHandoffLock()

        let heldFD = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(heldFD, 0)
        defer { _ = flock(heldFD, LOCK_UN); close(heldFD) }
        XCTAssertEqual(flock(heldFD, LOCK_EX | LOCK_NB), 0)
        let blockedStore = try store()
        await assertAsyncThrows {
            try await CoreAbsentBootstrapExecutor(store: blockedStore, platform: Platform(), lockEndpoint: l).execute(explicitInvocationToken: try self.token(blockedStore))
        }
    }

    func testBootstrapUsesDedicatedLockAndDoesNotBlockDaemonLock() async throws {
        let s = try store(), endpoint = lock()
        let bootstrapPath = BootstrapLock.lockPath(endpoint: endpoint)
        let daemonPath = URL(fileURLWithPath: endpoint).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("locks/vaelend.lock").path
        XCTAssertNotEqual(bootstrapPath, daemonPath)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: daemonPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        let daemonFD = open(daemonPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(daemonFD, 0)
        defer { _ = flock(daemonFD, LOCK_UN); close(daemonFD) }
        XCTAssertEqual(flock(daemonFD, LOCK_EX | LOCK_NB), 0)

        let bootstrap = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: endpoint)
        let receipt = try await bootstrap.execute(explicitInvocationToken: try token(s))
        XCTAssertEqual(receipt.phase, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bootstrapPath))
        bootstrap.releaseHandoffLock()
    }

    func testSecondBootstrapCannotEnterExclusiveHandoff() throws {
        let endpoint = lock()
        let first = try BootstrapLock.acquireExclusive(endpoint: endpoint)
        defer { first.release() }
        XCTAssertThrowsError(try BootstrapLock.acquireExclusive(endpoint: endpoint))
    }

    func testServingDaemonAdmissionLeaseIsReleasedBeforeLifecycleDispatch() throws {
        let endpoint = lock()
        let server = try BootstrapLock.acquireServerExclusive(endpoint: endpoint)
        server.release()
        let lifecycle = try BootstrapLock.acquireExclusive(endpoint: endpoint)
        lifecycle.release()
    }

    func testServingDaemonLeaseBlocksCoreAbsentBootstrap() throws {
        let endpoint = lock()
        let server = try BootstrapLock.acquireServerExclusive(endpoint: endpoint)
        defer { server.release() }
        XCTAssertThrowsError(try BootstrapLock.acquireExclusive(endpoint: endpoint))
    }

    func testLockAloneNeverProvesDaemonOwnership() throws {
        let endpoint = lock()
        let lease = try BootstrapLock.acquireExclusive(endpoint: endpoint)
        defer { lease.release() }
        let s = try store()
        XCTAssertThrowsError(try LifecycleStateRepository(store: s).validateDaemonAdmission(observation: observation(Date())))
    }

    func testDaemonAdmissionRejectsOffAndMissingGeneration() throws {
        let s = try store()
        let repository = LifecycleStateRepository(store: s)
        XCTAssertThrowsError(try repository.validateDaemonAdmission(observation: observation(Date())))
        _ = try repository.request(intent: .off, actor: "test", target: repository.canonicalTarget)
        XCTAssertThrowsError(try repository.validateDaemonAdmission(observation: observation(Date())))
    }

    func testSucceededReceiptAuthorizesOnlyTheOperationBoundAdmissionWindow() async throws {
        let s = try store(), endpoint = lock()
        let executor = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: endpoint)
        let receipt = try await executor.execute(explicitInvocationToken: try token(s))
        XCTAssertEqual(receipt.phase, .succeeded)
        XCTAssertNoThrow(try LifecycleStateRepository(store: s).validateDaemonAdmission(observation: observation(Date())))
        executor.releaseHandoffLock()
    }

    func testDaemonAdmissionAcceptsControllerOwnedUnknownRegistrationObservation() async throws {
        let s = try store(), endpoint = lock()
        let executor = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: endpoint)
        let receipt = try await executor.execute(explicitInvocationToken: try token(s))
        XCTAssertNoThrow(try LifecycleStateRepository(store: s).validateDaemonAdmission(observation: observation(Date(), registration: .unknown)))
        XCTAssertEqual(receipt.phase, .succeeded)
        executor.releaseHandoffLock()
    }

    func testPromotedAdmissionUsesCurrentGenerationAfterReceiptExpiry() async throws {
        let s = try store(), endpoint = lock()
        let executor = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), ttl: 1, lockEndpoint: endpoint)
        let receipt = try await executor.execute(explicitInvocationToken: try token(s))
        let repository = LifecycleStateRepository(store: s)
        _ = try repository.promoteBootstrap(invocationToken: receipt.invocationToken, observation: observation(), epoch: receipt.epoch, operationID: receipt.operationID, nonce: receipt.nonce, now: Date(), lockEndpoint: endpoint)
        XCTAssertNoThrow(try repository.validateDaemonAdmission(observation: observation(Date()), now: Date().addingTimeInterval(10)))
        executor.releaseHandoffLock()
    }

    func testBootstrapLeaseBlocksDaemonAdmission() throws {
        let endpoint = lock()
        let bootstrap = try BootstrapLock.acquire(endpoint: endpoint)
        defer { bootstrap.release() }
        XCTAssertThrowsError(try BootstrapLock.acquireServerExclusive(endpoint: endpoint))
    }

    func testPlatformExceptionIsUnknownAndCannotBeBlindlyRetried() async throws {
        let s = try store(), l = lock(); let first = try await CoreAbsentBootstrapExecutor(store: s, platform: Platform(failure: true), lockEndpoint: l).execute(explicitInvocationToken: try token(s))
        XCTAssertEqual(first.phase, .unknownRecoveryRequired)
        await assertAsyncThrows { try await CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l).execute(explicitInvocationToken: "again") }
    }
    func testMalformedAndDigestMismatchRefusePromotion() async throws {
        let s = try store(), l = lock(), e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l), r = try await e.execute(explicitInvocationToken: try token(s)), repo = LifecycleStateRepository(store: s)
        let malformed = LifecycleObservationVector(registrationMatch: .true, observedAt: Date().addingTimeInterval(1), source: "not-core")
        XCTAssertThrowsError(try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: malformed, epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l)); try s.execute("UPDATE bootstrap_receipts SET integrity_digest = 'malformed'"); XCTAssertThrowsError(try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: observation(), epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l))
    }
    func testReceiptMACMismatchFailsClosedOnReadAndPromotion() async throws {
        let s = try store(), l = lock(), auth = FixedAuthenticator()
        let e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l, authenticator: auth)
        let r = try await e.execute(explicitInvocationToken: try token(s))
        try s.execute("UPDATE bootstrap_receipts SET invocation_token = 'forged'")
        XCTAssertThrowsError(try s.bootstrapReceipt(authenticator: auth))
        let repo = LifecycleStateRepository(store: s, receiptAuthenticator: auth)
        XCTAssertThrowsError(try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: observation(), epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l))
        e.releaseHandoffLock()
    }

    func testAuthenticatedReceiptReopensAndAnyDurableFieldTamperFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-bootstrap-reopen-").appendingPathComponent(UUID().uuidString)
        let database = root.appendingPathComponent("state.sqlite")
        let store = try SQLiteStateStore(databaseURL: database)
        let auth = FixedAuthenticator()
        let executor = CoreAbsentBootstrapExecutor(store: store, platform: Platform(), lockEndpoint: lock(), authenticator: auth)
        let receipt = try await executor.execute(explicitInvocationToken: try store.mintBootstrapInvocation().token)
        XCTAssertEqual(try SQLiteStateStore(databaseURL: database).bootstrapReceipt(authenticator: auth)?.operationID, receipt.operationID)
        try store.execute("UPDATE bootstrap_receipts SET endpoint = '/tmp/forged.sock'")
        XCTAssertThrowsError(try SQLiteStateStore(databaseURL: database).bootstrapReceipt(authenticator: auth))
        executor.releaseHandoffLock()
        try? FileManager.default.removeItem(at: root)
    }
    func testPromotedReceiptRetainsAuthenticatedPhase() async throws {
        let s = try store(), l = lock(), auth = FixedAuthenticator()
        let e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l, authenticator: auth)
        let r = try await e.execute(explicitInvocationToken: try token(s))
        let repo = LifecycleStateRepository(store: s, receiptAuthenticator: auth)
        _ = try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: observation(), epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l)
        XCTAssertEqual(try s.bootstrapReceipt(authenticator: auth)?.phase, .promoted)
        e.releaseHandoffLock()
    }
    func testPromotionRequiresFreshCoreObservation() async throws {
        let s = try store(), l = lock(), e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l), r = try await e.execute(explicitInvocationToken: try token(s)), repo = LifecycleStateRepository(store: s)
        XCTAssertThrowsError(try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: r.postObservation!, epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l)); XCTAssertEqual(try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: observation(), epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l).intent?.intent, .on)
        e.releaseHandoffLock()
    }

    func testPromotionRejectsFreshObservationWithDifferentSignedIdentity() async throws {
        let s = try store(), l = lock(), e = CoreAbsentBootstrapExecutor(store: s, platform: Platform(), lockEndpoint: l)
        let r = try await e.execute(explicitInvocationToken: try token(s))
        let repo = LifecycleStateRepository(store: s)
        let mismatched = LifecycleObservationVector(bundlePresent: .true, layoutValid: .true, signatureValid: .true,
            registrationMatch: .true, endpointReachable: .true, protocolCompatible: .true, coreReady: .true,
            signingTeam: "OTHERTEAM", designatedRequirement: "identifier \"dev.vaelen.app\"", artifactHash: "hash",
            observedAt: Date().addingTimeInterval(1), source: "production-observer")
        XCTAssertThrowsError(try repo.promoteBootstrap(invocationToken: r.invocationToken, observation: mismatched,
            epoch: r.epoch, operationID: r.operationID, nonce: r.nonce, lockEndpoint: l))
        e.releaseHandoffLock()
    }
}
