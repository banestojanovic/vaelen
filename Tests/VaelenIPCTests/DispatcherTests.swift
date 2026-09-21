import XCTest
import Darwin
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

private final class DispatcherTrustFake: @unchecked Sendable, TLSTrustBoundary {
    var trusted = false
    func observe(certificateData: Data) throws -> LocalCATrustService.Observation {
        trusted ? .init(trusted: true, canonical: "trust:empty-array", fingerprint: "empty-fingerprint") : .init(trusted: false, canonical: "trust:nil", fingerprint: nil)
    }
    func trust(certificateData: Data) throws { trusted = true }
    func removeTrust(certificateData: Data) throws { trusted = false }
}

private actor TimeoutRevocationExecutor: CoreIssuedLifecycleExecutor {
    private var authorized: Set<UUID> = []
    private var invalidated: Set<UUID> = []
    private var invalidatedNonces: Set<UUID> = []
    private var platformCalls = 0

    func authorize(_ request: LifecycleExecutorRequest) async {
        authorized.insert(request.operationID)
    }

    func invalidate(operationID: UUID, nonce: UUID) async {
        authorized.remove(operationID)
        invalidated.insert(operationID)
        invalidatedNonces.insert(nonce)
    }

    func execute(_ request: LifecycleExecutorRequest) async -> LifecycleExecutorResult {
        // Model an authorized request which has not entered the platform yet.
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard authorized.contains(request.operationID), !invalidated.contains(request.operationID) else {
            return .init(state: .rejected, detail: "revoked")
        }
        platformCalls += 1
        return .init(state: .success)
    }

    func calls() -> Int { platformCalls }
    func wasInvalidated(operationID: UUID) -> Bool { invalidated.contains(operationID) }
    func invalidatedNonceCount() -> Int { invalidatedNonces.count }
}

private actor DirectLifecycleExecutor: LifecyclePlatformExecutor {
    private var platformCalls = 0

    func execute(_ request: LifecycleExecutorRequest) async -> LifecycleExecutorResult {
        platformCalls += 1
        return .init(state: .success)
    }

    func calls() -> Int { platformCalls }
}

private actor CountingCoreIssuedLifecycleExecutor: CoreIssuedLifecycleExecutor {
    private var authorized: Set<UUID> = []
    private var authorizationCount = 0
    private var executionCount = 0

    func authorize(_ request: LifecycleExecutorRequest) async {
        authorizationCount += 1
        authorized.insert(request.operationID)
    }

    func invalidate(operationID: UUID, nonce: UUID) async {
        authorized.remove(operationID)
    }

    func execute(_ request: LifecycleExecutorRequest) async -> LifecycleExecutorResult {
        guard authorized.remove(request.operationID) != nil else {
            return .init(state: .rejected, detail: "not authorized")
        }
        executionCount += 1
        return .init(state: .success)
    }

    func counts() -> (authorizations: Int, executions: Int) {
        (authorizationCount, executionCount)
    }
}

private struct LifecycleTestObservationProvider: LifecycleObservationProvider {
    func observe(operationID: UUID, generation: Int64, intent: LifecycleIntent, target: LifecycleTargetIdentity) async -> LifecycleObservationVector {
        .init(bundlePresent: .false, layoutValid: .false, signatureValid: .false,
              registrationMatch: .false, processMatch: .false, endpointReachable: .false,
              source: "test")
    }
}

private struct LifecycleSuccessObservationProvider: LifecycleObservationProvider {
    func observe(operationID: UUID, generation: Int64, intent: LifecycleIntent, target: LifecycleTargetIdentity) async -> LifecycleObservationVector {
        .init(bundlePresent: .true, layoutValid: .true, signatureValid: .true,
              registrationMatch: generation == 0 ? .false : .true, processMatch: .false, endpointReachable: .false,
              signingTeam: "TESTTEAM", designatedRequirement: "test-requirement",
              artifactHash: "test-artifact", source: "test")
    }
}

private actor DelayedLifecyclePlatform: SMAppServiceLifecyclePlatform {
    private var registerContinuation: CheckedContinuation<Void, Never>?
    private var registerEntered = false
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    func register() async throws {
        registerCalls += 1
        registerEntered = true
        await withCheckedContinuation { registerContinuation = $0 }
    }

    func unregister() async throws { unregisterCalls += 1 }

    func waitUntilRegisterEntered() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !registerEntered && ContinuousClock.now < deadline {
            await Task.yield()
        }
        return registerEntered
    }

    func releaseRegister() {
        registerContinuation?.resume()
        registerContinuation = nil
    }
}

private actor ThrowingLifecyclePlatform: SMAppServiceLifecyclePlatform {
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "entered platform and failed" }
    }

    func register() async throws {
        registerCalls += 1
        throw Failure()
    }

    func unregister() async throws { unregisterCalls += 1 }
}

private struct LifecycleDispatchGate: LifecycleDispatchIdentityRevalidator {
    func revalidateProcessIdentity(expected: LifecycleProcessIdentity,
                                   target: LifecycleTargetIdentity) async -> ObservationValue { .true }
    func revalidateOnRegistrationPreconditions(target: LifecycleTargetIdentity,
                                               allowExistingRegistration: Bool) async -> ObservationValue { .true }
}

final class DispatcherTests: XCTestCase {
    func testDaemonAdmissionDoesNotReleaseOnHandshakeOrStartingReadiness() throws {
        let handshakeRequest = IPCRequest(method: .handshake)
        let handshakeResponse = IPCResponse(id: handshakeRequest.id,
                                             result: .handshake(.init(protocolVersion: 1, coreVersion: "test", schemaCompatibilityVersion: 1, buildIdentity: "test")))
        XCTAssertFalse(DaemonServer.readinessEstablished(request: handshakeRequest, response: handshakeResponse))

        let readinessRequest = IPCRequest(method: .readiness)
        let startingResponse = IPCResponse(id: readinessRequest.id,
                                           result: .coreReadiness(.init(readiness: .starting, protocolVersion: 1)))
        XCTAssertFalse(DaemonServer.readinessEstablished(request: readinessRequest, response: startingResponse))
    }

    func testDaemonAdmissionReleasesOnlyAfterReadyEvidence() throws {
        let readinessRequest = IPCRequest(method: .readiness)
        let readyResponse = IPCResponse(id: readinessRequest.id,
                                        result: .coreReadiness(.init(readiness: .ready, protocolVersion: 1)))
        XCTAssertTrue(DaemonServer.readinessEstablished(request: readinessRequest, response: readyResponse))
    }

    func testDaemonAdmissionRejectsErrorOrNonCoreReadinessResponses() throws {
        let request = IPCRequest(method: .readiness)
        let error = IPCResponse(id: request.id, error: .init(code: .invalidRequest, message: "not ready"))
        XCTAssertFalse(DaemonServer.readinessEstablished(request: request, response: error))
        let raw = IPCResponse(id: request.id, result: .raw(.string("ready")))
        XCTAssertFalse(DaemonServer.readinessEstablished(request: request, response: raw))
    }

    func testM13TrustAndUntrustTraverseDispatcherWithParameterlessRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let fake = DispatcherTrustFake()
        let keychain = LocalCAKeychain(tag: "dev.vaelen.ipc.\(UUID().uuidString)")
        defer { try? keychain.removeCAKey() }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let tls = TLSCapability(layout: layout, store: store, keychain: keychain, trustBoundary: fake)
        _ = try await tls.install()
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry, tls: tls)
        let handshake = await dispatcher.dispatch(IPCRequest(method: .handshake, params: .handshake(.init(client: .init(name: "test", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))), handshaken: false)
        XCTAssertTrue(handshake.handshaken)

        let trusted = await dispatcher.dispatch(IPCRequest(method: .tlsTrustLocalCA), handshaken: true)
        guard case .tlsTrust(let trust)? = trusted.response.result else { return XCTFail("missing typed trust response") }
        XCTAssertEqual(trust.result.operation, .confirmed)
        XCTAssertNil(IPCRequest(method: .tlsTrustLocalCA).params)

        let untrusted = await dispatcher.dispatch(IPCRequest(method: .tlsRemoveLocalCATrust), handshaken: true)
        guard case .tlsTrust(let remove)? = untrusted.response.result else { return XCTFail("missing typed untrust response") }
        XCTAssertEqual(remove.result.operation, .removed)
        XCTAssertNil(IPCRequest(method: .tlsRemoveLocalCATrust).params)
    }

    func testDispatcherHandshakeRequiresMatchingSchemaBeforeNormalDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry)

        let old = await dispatcher.dispatch(IPCRequest(method: .handshake, params: .handshake(.init(client: .init(name: "old", version: "0.0.10-dev")))), handshaken: false)
        XCTAssertEqual(old.response.error?.code, .coreIncompatible)
        XCTAssertFalse(old.handshaken)

        let current = await dispatcher.dispatch(IPCRequest(method: .handshake, params: .handshake(.init(client: .init(name: "current", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))), handshaken: false)
        XCTAssertTrue(current.handshaken)
        guard case .handshake(let result) = current.response.result else { return XCTFail("handshake did not return compatibility identity") }
        XCTAssertEqual(result.schemaCompatibilityVersion, VaelenBuildInfo.schemaCompatibilityVersion)
        XCTAssertEqual(result.buildIdentity, VaelenBuildInfo.buildIdentity)
    }

    func testDispatcherRejectsNormalCommandBeforeHandshake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry)

        let result = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: false)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
        XCTAssertEqual(result.response.error?.message, "Handshake is required before other requests.")
    }

    func testCoreReadinessIsASeparateDirectCoreResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry)

        let response = await dispatcher.dispatch(IPCRequest(method: .readiness), handshaken: true)
        guard case .coreReadiness(let readiness) = response.response.result else { return XCTFail("missing Core readiness response") }
        XCTAssertEqual(readiness.readiness, .ready)
        XCTAssertEqual(readiness.protocolVersion, 1)
    }

    func testCoreReadinessCanBeFalseWhileEndpointIsServing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1, isReady: false), registry: registry)

        let response = await dispatcher.dispatch(IPCRequest(method: .readiness), handshaken: true)
        guard case .coreReadiness(let readiness) = response.response.result else { return XCTFail("missing Core readiness response") }
        XCTAssertEqual(readiness.readiness, .starting)
    }

    func testDispatcherRejectsUnknownMethodStructurally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry)

        let result = await dispatcher.dispatch(IPCRequest(rawMethod: "project.future"), handshaken: true)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
    }

    func testLifecycleDispatcherRejectsClientSelectedIdentityAndExposesJournalStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, lifecycleStore: store)
        let bad = LifecycleTargetIdentity(bundleID: "foreign.bundle", agentLabel: "foreign.agent", bundleProgram: "/tmp/foreign", endpoint: "/tmp/foreign.sock")
        let rejected = await dispatcher.dispatch(IPCRequest(method: .lifecycleOn, params: .lifecycle(.init(actor: "client", target: bad))), handshaken: true)
        XCTAssertEqual(rejected.response.error?.code, .invalidRequest)
        XCTAssertNil(try LifecycleStateRepository(store: store).intent())

        let canonical = LifecycleStateRepository(store: store).canonicalTarget
        let accepted = await dispatcher.dispatch(IPCRequest(method: .lifecycleOn, params: .lifecycle(.init(actor: "client", target: canonical))), handshaken: true)
        guard case .lifecycle(let result) = accepted.response.result else { return XCTFail("missing lifecycle result") }
        XCTAssertEqual(result.operation?.state, .unknownRecoveryRequired)
        let status = await dispatcher.dispatch(IPCRequest(method: .lifecycleStatus), handshaken: true)
        guard case .lifecycle(let statusResult) = status.response.result else { return XCTFail("missing lifecycle status") }
        XCTAssertEqual(statusResult.operation?.operationID, result.operation?.operationID)
        XCTAssertEqual(statusResult.readiness, .unknown)
    }

    func testLifecycleExecutorUnknownIsPersistedAsRecoveryRequiredNotFailed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let executor = FakeLifecycleExecutor(result: .init(state: .unknown, detail: "platform throw"))
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test"), registry: registry,
            lifecycleStore: store, lifecycleExecutor: executor,
            lifecycleObservationProvider: LifecycleTestObservationProvider())

        let response = await dispatcher.dispatch(
            IPCRequest(method: .lifecycleOn,
                       params: .lifecycle(.init(actor: "test", target: LifecycleCanonicalIdentity.target))),
            handshaken: true)
        guard case .lifecycle(let result) = response.response.result else {
            return XCTFail("missing lifecycle result")
        }
        XCTAssertEqual(result.operation?.state, .unknownRecoveryRequired)
        XCTAssertNotEqual(result.operation?.state, .failed)
        XCTAssertTrue(result.operation?.error?.contains("platform throw") == true)
        XCTAssertEqual(result.observation.source, "test")
    }

    func testDirectLifecycleExecutorIsRefusedBeforeAnyPlatformCall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let executor = DirectLifecycleExecutor()
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test"), registry: registry,
            lifecycleStore: store, lifecycleExecutor: executor,
            lifecycleObservationProvider: LifecycleTestObservationProvider())

        let response = await dispatcher.dispatch(
            IPCRequest(method: .lifecycleOn,
                       params: .lifecycle(.init(actor: "test", target: LifecycleCanonicalIdentity.target))),
            handshaken: true)

        guard case .lifecycle(let result) = response.response.result else {
            return XCTFail("missing lifecycle result")
        }
        XCTAssertEqual(result.operation?.state, .failed)
        XCTAssertTrue(result.operation?.error?.contains("CoreIssuedLifecycleExecutor") == true)
        let directCalls = await executor.calls()
        XCTAssertEqual(directCalls, 0)
    }

    func testCoreIssuedLifecycleExecutorIsAuthorizedAndDispatched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let executor = CountingCoreIssuedLifecycleExecutor()
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test"), registry: registry,
            lifecycleStore: store, lifecycleExecutor: executor,
            lifecycleObservationProvider: LifecycleSuccessObservationProvider())

        let response = await dispatcher.dispatch(
            IPCRequest(method: .lifecycleOn,
                       params: .lifecycle(.init(actor: "test", target: LifecycleCanonicalIdentity.target))),
            handshaken: true)

        guard case .lifecycle(let result) = response.response.result else {
            return XCTFail("missing lifecycle result")
        }
        XCTAssertEqual(result.operation?.state, .succeeded)
        let counts = await executor.counts()
        XCTAssertEqual(counts.authorizations, 1)
        XCTAssertEqual(counts.executions, 1)
    }

    func testTimedOutUnstartedLifecycleAuthorizationIsRevokedBeforePlatformCall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let executor = TimeoutRevocationExecutor()
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test"), registry: registry,
            lifecycleStore: store, lifecycleExecutor: executor,
            lifecycleObservationProvider: LifecycleTestObservationProvider(),
            lifecycleTimeoutNanoseconds: 1_000_000)

        let response = await dispatcher.dispatch(
            IPCRequest(method: .lifecycleOn,
                       params: .lifecycle(.init(actor: "test", target: LifecycleCanonicalIdentity.target))),
            handshaken: true)
        guard case .lifecycle(let result) = response.response.result else {
            return XCTFail("missing lifecycle result")
        }
        XCTAssertEqual(result.operation?.state, .unknownRecoveryRequired)
        try await Task.sleep(nanoseconds: 75_000_000)
        let calls = await executor.calls()
        guard let operationID = result.operation?.operationID else {
            return XCTFail("missing lifecycle operation identity")
        }
        let wasInvalidated = await executor.wasInvalidated(operationID: operationID)
        let invalidatedNonceCount = await executor.invalidatedNonceCount()
        XCTAssertTrue(wasInvalidated)
        XCTAssertEqual(invalidatedNonceCount, 1)
        XCTAssertEqual(calls, 0)
    }

    func testOffAfterOnCrossesPlatformBoundaryCannotReportStaleAbsenceSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let platform = DelayedLifecyclePlatform()
        let session = UUID()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session, platform: platform,
                                                     identityRevalidator: LifecycleDispatchGate())
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test"), registry: registry,
            lifecycleStore: store, lifecycleExecutor: executor,
            lifecycleObservationProvider: LifecycleTestObservationProvider(),
            lifecycleSessionBinding: session)

        let onTask = Task {
            await dispatcher.dispatch(
                IPCRequest(method: .lifecycleOn,
                           params: .lifecycle(.init(actor: "test", target: LifecycleCanonicalIdentity.target))),
                handshaken: true)
        }
        guard await platform.waitUntilRegisterEntered() else {
            await platform.releaseRegister()
            _ = await onTask.value
            return XCTFail("On did not enter the delayed platform call")
        }

        // Off observes the pre-call absence while On is already inside the
        // platform boundary.  The platform is released only after Off has
        // durably fenced On and returned its own recovery-required result.
        let off = await dispatcher.dispatch(
            IPCRequest(method: .lifecycleOff,
                       params: .lifecycle(.init(actor: "test", target: LifecycleCanonicalIdentity.target))),
            handshaken: true)
        guard case .lifecycle(let offResult) = off.response.result else {
            return XCTFail("missing Off lifecycle result")
        }
        XCTAssertEqual(offResult.operation?.state, .unknownRecoveryRequired)
        XCTAssertNotEqual(offResult.operation?.state, .succeeded)
        XCTAssertEqual(offResult.observation.registrationMatch, .false)
        XCTAssertEqual(offResult.observation.processMatch, .false)
        XCTAssertEqual(offResult.observation.endpointReachable, .false)

        await platform.releaseRegister()
        let on = await onTask.value
        guard case .lifecycle(let onResult) = on.response.result else {
            return XCTFail("missing On lifecycle result")
        }
        XCTAssertEqual(onResult.operation?.state, .unknownRecoveryRequired)
        XCTAssertNotEqual(onResult.operation?.state, .succeeded)
        let registerCalls = await platform.registerCalls
        let unregisterCalls = await platform.unregisterCalls
        XCTAssertEqual(registerCalls, 1)
        XCTAssertEqual(unregisterCalls, 0)
        let repository = LifecycleStateRepository(store: store)
        XCTAssertEqual(try repository.intent()?.intent, .off)
        XCTAssertEqual(try repository.operation()?.operationID, offResult.operation?.operationID)
        XCTAssertEqual(try repository.operation()?.state, .unknownRecoveryRequired)
    }

    func testOffAfterOnPlatformExceptionAndAbsentObservationRemainsRecoveryRequired() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let platform = ThrowingLifecyclePlatform()
        let session = UUID()
        let executor = SMAppServiceLifecycleExecutor(sessionBinding: session, platform: platform,
                                                     identityRevalidator: LifecycleDispatchGate())
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test"), registry: registry,
            lifecycleStore: store, lifecycleExecutor: executor,
            lifecycleObservationProvider: LifecycleTestObservationProvider(),
            lifecycleSessionBinding: session)

        let on = await dispatcher.dispatch(
            IPCRequest(method: .lifecycleOn,
                       params: .lifecycle(.init(actor: "test", target: LifecycleCanonicalIdentity.target))),
            handshaken: true)
        guard case .lifecycle(let onResult) = on.response.result else {
            return XCTFail("missing On lifecycle result")
        }
        XCTAssertEqual(onResult.operation?.state, .unknownRecoveryRequired)

        // The fresh observation is absent, but the exception happened after
        // the platform API was entered. Off must not unregister or adopt.
        let off = await dispatcher.dispatch(
            IPCRequest(method: .lifecycleOff,
                       params: .lifecycle(.init(actor: "test", target: LifecycleCanonicalIdentity.target))),
            handshaken: true)
        guard case .lifecycle(let offResult) = off.response.result else {
            return XCTFail("missing Off lifecycle result")
        }
        XCTAssertEqual(offResult.operation?.state, .unknownRecoveryRequired)
        XCTAssertNotEqual(offResult.operation?.state, .succeeded)
        XCTAssertEqual(offResult.observation.registrationMatch, .false)
        let registerCalls = await platform.registerCalls
        let unregisterCalls = await platform.unregisterCalls
        XCTAssertEqual(registerCalls, 1)
        XCTAssertEqual(unregisterCalls, 0)
        XCTAssertNil(try LifecycleStateRepository(store: store).ownership())
    }

    func testRouteMutationPersistsThroughCoreAndSurvivesDispatcherRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "persisted.test", target: .staticFiles(documentRoot: "/tmp/persisted"), tls: .disabled)
        let intent = RouteIntent(route: route)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry, routeRepository: repository)

        let added = await dispatcher.dispatch(IPCRequest(method: .routeAdd, params: .route(intent)), handshaken: true)
        guard case .routeMutation(let addedIntent) = added.response.result else { return XCTFail("route add did not return the route") }
        XCTAssertEqual(addedIntent, intent)

        let recreated = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 2), registry: registry, routeRepository: repository)
        let listed = await recreated.dispatch(IPCRequest(method: .routeList), handshaken: true)
        guard case .routeList(let result) = listed.response.result else { return XCTFail("route list did not return routes") }
        XCTAssertEqual(result.routes, [intent])

        let removed = await recreated.dispatch(IPCRequest(method: .routeRemove, params: .routeRemove(.init(id: route.id))), handshaken: true)
        guard case .routeList(let afterRemoval) = removed.response.result else { return XCTFail("route remove did not return routes") }
        XCTAssertTrue(afterRemoval.routes.isEmpty)
    }

    func testExplicitRouteAssociationChangesOnlyMetadataAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("public"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("bootstrap"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: projectRoot.appendingPathComponent("artisan"))
        try Data("<?php".utf8).write(to: projectRoot.appendingPathComponent("public/index.php"))
        try Data("{\"require\":{\"laravel/framework\":\"^11.0\",\"php\":\"^8.3\"}}".utf8).write(to: projectRoot.appendingPathComponent("composer.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot)
        guard let projectID = project.id else { return XCTFail("linked project did not receive an ID") }
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "project.test", target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: projectRoot.appendingPathComponent("public").path), tls: .local)
        let intent = RouteIntent(route: route)
        try repository.upsert(intent)
        let router = InMemoryRouter()
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry, router: router, routeRepository: repository)

        let request = IPCRequest(method: .routeProjectAssociationAttach, params: .routeAssociation(.init(routeID: route.id, projectID: projectID)))
        let response = await dispatcher.dispatch(request, handshaken: true)
        guard case .routeAssociation(let association) = response.response.result else { return XCTFail("association did not return typed result") }
        XCTAssertEqual(association.state, .associated)
        XCTAssertEqual(association.route.route, route)
        XCTAssertEqual(try repository.all().first?.projectID, projectID.rawValue)
        XCTAssertEqual(try repository.all().first?.projectPath, projectRoot.path)
        let routerStatus = await router.status()
        XCTAssertEqual(routerStatus.routeCount, 0)

        let second = await dispatcher.dispatch(request, handshaken: true)
        guard case .routeAssociation(let repeated) = second.response.result else { return XCTFail("repeated association did not return typed result") }
        XCTAssertEqual(repeated.state, .satisfied)
        XCTAssertEqual(try repository.all().first?.route, route)
    }

    func testRouteAssociationRejectsExistingDifferentProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let first = try await registry.link(path: firstRoot)
        let second = try await registry.link(path: secondRoot)
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "owned.test", target: .staticFiles(documentRoot: firstRoot.path), tls: .disabled)
        try repository.upsert(RouteIntent(route: route, projectID: first.id?.rawValue, projectPath: firstRoot.path))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry, routeRepository: repository)

        let response = await dispatcher.dispatch(IPCRequest(method: .routeProjectAssociationAttach, params: .routeAssociation(.init(routeID: route.id, projectID: second.id!))), handshaken: true)
        XCTAssertEqual(response.response.error?.code, .invalidRequest)
        XCTAssertEqual(try repository.all().first?.projectID, first.id?.rawValue)
    }

    func testUnlinkPreservesDurableRouteAssociationAsOrphanedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await registry.link(path: projectRoot)
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "orphan.test", target: .staticFiles(documentRoot: projectRoot.path), tls: .disabled)
        try repository.upsert(RouteIntent(route: route, projectID: project.id?.rawValue, projectPath: projectRoot.path))

        try await registry.unlink(path: projectRoot)

        let persisted = try repository.all().first
        XCTAssertEqual(persisted?.projectID, project.id?.rawValue)
        XCTAssertEqual(persisted?.projectPath, projectRoot.path)
    }

    func testDispatcherDoesNotConvertRepositoryFailureIntoEmptyRoutes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        try store.execute("DROP TABLE route_intents")
        let registry = ProjectRegistry(store: store)
        let repository = RouteIntentRepository(store: store)

        XCTAssertThrowsError(try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, routeRepository: repository)) { error in
            XCTAssertNotNil(error as? SQLiteStateError)
        }
    }

    func testDispatcherRejectsMalformedTransitionProvenanceAtStartup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        try store.execute("INSERT INTO route_target_transitions (route_id,project_id,previous_route_json,desired_route_json,previous_provider_json,desired_provider_json,previous_socket,desired_socket,state) VALUES ('bad','bad',X'00',X'00',X'00',X'00','a','b','providerPending')")
        let registry = ProjectRegistry(store: store)
        XCTAssertThrowsError(try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, routeRepository: RouteIntentRepository(store: store))) { error in
            XCTAssertEqual(error as? SQLiteStateError, .invalidRecord)
        }
    }

    func testProjectReconciliationRejectsDiscoveredProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("discovered")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        _ = try await registry.park(path: root)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry)

        let result = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: "discovered", workingDirectory: root.path))), handshaken: true)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
        XCTAssertEqual(result.response.error?.message, "Project reconciliation requires a registered linked project.")
    }

    func testProjectActivationStartsAndThenReusesAnIsolatedMailpit() async throws {
        guard let package = MailpitModule().installedVersions().first else { throw XCTSkip("Mailpit package prerequisite unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { removeTestRoot(root) }
        let configuration = MailpitRuntimeConfiguration(smtpPort: try availablePort(), httpPort: try availablePort())
        try Data("version: 1\nservices:\n  mailpit: true\n".utf8).write(to: projectRoot.appendingPathComponent("vaelen.yml"))
        try Data("MAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PORT=\(configuration.smtpPort)\nMAIL_PASSWORD=null\n".utf8).write(to: projectRoot.appendingPathComponent(".env"))

        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("vaelen"))
        let finalPackage = layout.mailpitPackagesDirectoryURL.appendingPathComponent(package.version, isDirectory: true)
        try FileManager.default.createDirectory(at: layout.mailpitPackagesDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: package.packagePath), to: finalPackage)
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod"); chmod.arguments = ["-R", "u+w", finalPackage.path]; try chmod.run(); chmod.waitUntilExit()
        let copiedPackage = MailpitPackage(version: package.version, architecture: package.architecture, packagePath: finalPackage.path, executablePath: finalPackage.appendingPathComponent("mailpit").path, source: package.source, artifactSHA256: package.artifactSHA256, license: package.license, installedAt: package.installedAt)
        try JSONEncoder().encode(copiedPackage).write(to: finalPackage.appendingPathComponent(".vaelen-package.json"), options: .atomic)
        let mailpit = MailpitModule(layout: layout, configuration: configuration)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: mailpit.instanceDatabasePath()).deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mailpit.instanceDatabasePath(), contents: Data())
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        _ = try await registry.link(path: projectRoot)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry, mailpit: mailpit, router: InMemoryRouter(), routeRepository: RouteIntentRepository(store: try SQLiteStateStore(databaseURL: layout.databaseURL.appendingPathExtension("routes"))))

        let planResponse = await dispatcher.dispatch(IPCRequest(method: .projectPlan, params: .projectEnvironment(.init(selector: projectRoot.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectPlan(let planResult) = planResponse.response.result else { return XCTFail("project plan did not return a plan") }
        XCTAssertEqual(planResult.plan.state, .actionable)
        XCTAssertEqual(planResult.plan.operations.first?.id, "mailpit.start")

        let activationResponse = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: projectRoot.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectActivation(let activationResult) = activationResponse.response.result else { return XCTFail("project activation did not return an execution result") }
        XCTAssertEqual(activationResult.execution.state, .succeeded)
        let firstPID = mailpit.status().pid
        XCTAssertEqual(mailpit.status().state, .running)

        let secondResponse = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: projectRoot.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectActivation(let secondResult) = secondResponse.response.result else { return XCTFail("second activation did not return an execution result") }
        XCTAssertEqual(secondResult.execution.state, .succeeded)
        XCTAssertEqual(mailpit.status().pid, firstPID)
        _ = try mailpit.stop()
    }

    private func removeTestRoot(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod"); process.arguments = ["-R", "u+w", root.path]; try? process.run(); process.waitUntilExit(); try? FileManager.default.removeItem(at: root)
    }

    private func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MailpitModuleError.processFailed("socket") }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw MailpitModuleError.processFailed("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard result == 0 else { throw MailpitModuleError.processFailed("getsockname") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
