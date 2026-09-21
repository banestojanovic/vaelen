import Foundation
import ServiceManagement

/// The result of the one platform call authorized by Core.  `unknown` is
/// deliberately distinct from an ordinary rejection: the latter is evidence
/// that the platform declined the request, while the former says that Core
/// cannot safely tell whether a mutation happened.
public enum LifecycleExecutorResultState: String, Codable, Equatable, Sendable {
    case success, rejected, unavailable, timeout, unknown
}

public struct LifecycleExecutorRequest: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let generation: Int64
    public let intent: LifecycleIntent
    public let target: LifecycleTargetIdentity
    public let actor: String
    /// Credentials are minted by Core for exactly one operation dispatch.
    public let nonce: UUID
    public let deadline: Date
    public let sessionBinding: UUID
    /// Ephemeral process evidence used only as a dispatch fence.
    public let processIdentity: LifecycleProcessIdentity?
    /// Core may set this only after a fresh durable ownership check for an
    /// already-enabled registration.  It is never inferred from observation.
    public let allowExistingRegistration: Bool

    public init(operationID: UUID, generation: Int64, intent: LifecycleIntent,
                target: LifecycleTargetIdentity, actor: String,
                nonce: UUID = UUID(), deadline: Date = Date().addingTimeInterval(5),
                 sessionBinding: UUID = UUID(), processIdentity: LifecycleProcessIdentity? = nil,
                 allowExistingRegistration: Bool = false) {
        self.operationID = operationID; self.generation = generation
        self.intent = intent; self.target = target; self.actor = actor
        self.nonce = nonce; self.deadline = deadline; self.sessionBinding = sessionBinding; self.processIdentity = processIdentity
        self.allowExistingRegistration = allowExistingRegistration
    }

    public func authenticationError(expectedSessionBinding: UUID, now: Date = Date()) -> String? {
        guard sessionBinding == expectedSessionBinding else { return "Executor session binding mismatch." }
        guard now < deadline else { return "Executor request expired." }
        return nil
    }
}

/// Evidence-only last-moment check used by the production platform boundary.
public protocol LifecycleDispatchIdentityRevalidator: Sendable {
    func revalidateProcessIdentity(expected: LifecycleProcessIdentity,
                                   target: LifecycleTargetIdentity) async -> ObservationValue

    /// Registration is allowed to begin while the daemon is absent.  This
    /// check therefore validates the non-process boundary instead of turning
    /// process absence into ownership evidence.
    func revalidateOnRegistrationPreconditions(target: LifecycleTargetIdentity,
                                               allowExistingRegistration: Bool) async -> ObservationValue
}

public extension LifecycleDispatchIdentityRevalidator {
    func revalidateOnRegistrationPreconditions(target: LifecycleTargetIdentity,
                                               allowExistingRegistration: Bool) async -> ObservationValue { .unknown }
}

public struct LifecycleExecutorResult: Codable, Equatable, Sendable {
    public let state: LifecycleExecutorResultState
    public let postObservation: LifecycleObservationVector?
    public let detail: String?

    public init(state: LifecycleExecutorResultState,
                postObservation: LifecycleObservationVector? = nil,
                detail: String? = nil) {
        self.state = state; self.postObservation = postObservation; self.detail = detail
    }
}

public protocol LifecyclePlatformExecutor: Sendable {
    func execute(_ request: LifecycleExecutorRequest) async -> LifecycleExecutorResult
}

/// Core records the operation before authorizing the platform side effect. The
/// production adapter will not execute a merely well-formed request.
public protocol CoreIssuedLifecycleExecutor: LifecyclePlatformExecutor {
    func authorize(_ request: LifecycleExecutorRequest) async
    /// Revoke an authorized request which did not complete within Core's
    /// bounded wait (or whose result is otherwise ambiguous).  This removes
    /// permission for any platform call that has not entered the platform.
    /// An already-entered non-cancellable platform call remains ambiguous and
    /// must never be reported as success solely because it later returns.
    func invalidate(operationID: UUID, nonce: UUID) async
}

/// Read-only lifecycle evidence.  The default is deliberately fail-closed;
/// an executor return value is never a platform observation.
public protocol LifecycleObservationProvider: Sendable {
    func observe(operationID: UUID, generation: Int64, intent: LifecycleIntent,
                 target: LifecycleTargetIdentity) async -> LifecycleObservationVector
}

public struct UnavailableLifecycleObservationProvider: LifecycleObservationProvider {
    public init() {}
    public func observe(operationID: UUID, generation: Int64, intent: LifecycleIntent,
                        target: LifecycleTargetIdentity) async -> LifecycleObservationVector {
        .init(source: "unavailable-observation-provider", reason: "No lifecycle observation provider is configured.")
    }
}

/// The production default until the signed bundle and identity contract are
/// available. It cannot cause a platform side effect.
public struct UnavailableLifecycleExecutor: CoreIssuedLifecycleExecutor {
    public init() {}
    public func authorize(_ request: LifecycleExecutorRequest) async {}
    public func invalidate(operationID: UUID, nonce: UUID) async {}
    public func execute(_ request: LifecycleExecutorRequest) async -> LifecycleExecutorResult {
        .init(state: .unavailable, detail: "Platform lifecycle executor is unavailable.")
    }
}

/// Fail-closed adapter used when a caller supplies an executor that has no
/// Core-issued authorization boundary.  In particular, it never forwards the
/// request to the supplied executor.
public struct RefusingLifecycleExecutor: CoreIssuedLifecycleExecutor {
    public init() {}
    public func authorize(_ request: LifecycleExecutorRequest) async {}
    public func invalidate(operationID: UUID, nonce: UUID) async {}
    public func execute(_ request: LifecycleExecutorRequest) async -> LifecycleExecutorResult {
        .init(state: .rejected, detail: "Lifecycle executor must implement CoreIssuedLifecycleExecutor; platform mutation was withheld.")
    }
}

protocol SMAppServiceLifecyclePlatform: Sendable {
    func register() async throws
    func unregister() async throws
    func unregister(request: LifecycleExecutorRequest) async throws
}

extension SMAppServiceLifecyclePlatform {
    func unregister(request: LifecycleExecutorRequest) async throws { try await unregister() }
}

private struct DefaultSMAppServiceLifecyclePlatform: @unchecked Sendable, SMAppServiceLifecyclePlatform {
    let service: SMAppService

    func register() async throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func unregister(request: LifecycleExecutorRequest) async throws {
        let controller = LifecycleCanonicalIdentity.installedControllerURL
        let envelope = LifecycleControllerMutationRequest(operationID: request.operationID, generation: request.generation, intent: request.intent, target: request.target, nonce: request.nonce, sessionBinding: request.sessionBinding)
        guard LifecycleControllerMutationValidator.validate(envelope, controllerPath: controller.path) else { throw BootstrapError.refused("Controller mutation envelope is not canonical.") }
        let process = Process(); let input = Pipe(); let output = Pipe()
        process.executableURL = controller.appendingPathComponent("Contents/MacOS/Vaelen")
        process.arguments = ["--vaelen-authorized-unregister"]
        process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(try JSONEncoder().encode(envelope)); input.fileHandleForWriting.closeFile()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let response = try? JSONDecoder().decode(LifecycleControllerMutationResponse.self, from: data),
              LifecycleControllerMutationValidator.validate(response, request: envelope), response.success else {
            throw BootstrapError.refused("Signed controller rejected the exact unregister envelope.")
        }
    }
}

/// The only production ServiceManagement boundary. It has no client ingress:
/// Core must authorize an exact operation immediately before dispatch.
public actor SMAppServiceLifecycleExecutor: CoreIssuedLifecycleExecutor {
    private struct Authorization: Sendable {
        let request: LifecycleExecutorRequest
    }
    private let sessionBinding: UUID
    private var authorized: [UUID: Authorization] = [:]
    private var consumed: Set<UUID> = []
    private var consumedNonces: Set<UUID> = []
    private var invalidated: Set<UUID> = []
    private var invalidatedNonces: Set<UUID> = []
    /// ServiceManagement mutations are serialized even though the adapter
    /// protocol is async.  A newer Off may fence a not-yet-entered On, but it
    /// must never interleave a second platform mutation with an already
    /// entered call; that boundary is unknown/recovery-required instead.
    private var platformMutationInProgress = false
    private let platform: any SMAppServiceLifecyclePlatform
    private let identityRevalidator: (any LifecycleDispatchIdentityRevalidator)?

    public init(sessionBinding: UUID, service: SMAppService? = nil,
                identityRevalidator: (any LifecycleDispatchIdentityRevalidator)? = nil) {
        self.sessionBinding = sessionBinding
        self.platform = DefaultSMAppServiceLifecyclePlatform(service: service ?? SMAppService.agent(plistName: "dev.vaelen.vaelend.agent.plist"))
        self.identityRevalidator = identityRevalidator
    }

    init(sessionBinding: UUID, platform: any SMAppServiceLifecyclePlatform,
         identityRevalidator: (any LifecycleDispatchIdentityRevalidator)? = nil) {
        self.sessionBinding = sessionBinding
        self.platform = platform
        self.identityRevalidator = identityRevalidator
    }

    public func authorize(_ request: LifecycleExecutorRequest) async {
        guard request.sessionBinding == self.sessionBinding,
              request.target == LifecycleCanonicalIdentity.target,
              request.intent == .on || request.intent == .off,
              !invalidated.contains(request.operationID),
              !invalidatedNonces.contains(request.nonce),
              !consumedNonces.contains(request.nonce),
              request.authenticationError(expectedSessionBinding: self.sessionBinding) == nil else { return }
        authorized[request.operationID] = Authorization(request: request)
    }

    public func invalidate(operationID: UUID, nonce: UUID) async {
        // Keep the tombstones as well as removing the pending authorization:
        // an executor task may already have consumed the authorization and be
        // suspended inside a non-cancellable platform call.
        authorized.removeValue(forKey: operationID)
        invalidated.insert(operationID)
        invalidatedNonces.insert(nonce)
    }

    public func execute(_ request: LifecycleExecutorRequest) async -> LifecycleExecutorResult {
        guard request.target == LifecycleCanonicalIdentity.target else { return .init(state: .rejected, detail: "Non-canonical lifecycle identity.") }
        guard request.sessionBinding == sessionBinding, Date() < request.deadline else { return .init(state: .rejected, detail: "Invalid or expired Core executor request.") }
        guard !invalidated.contains(request.operationID), !invalidatedNonces.contains(request.nonce) else {
            return .init(state: .rejected, detail: "Core revoked this lifecycle request before platform execution.")
        }
        guard let auth = authorized.removeValue(forKey: request.operationID), !consumed.contains(request.operationID),
              auth.request == request else {
            return .init(state: .rejected, detail: "Request was not issued for this Core operation or was replayed.")
        }
        consumed.insert(request.operationID)
        consumedNonces.insert(request.nonce)
        if request.intent == .off {
            // Unregister is destructive: absence, drift, and an unavailable
            // revalidator must never be treated as proof that the target is
            // still the process Core observed.
            guard let identityRevalidator, let expected = request.processIdentity else {
                return .init(state: .rejected, detail: "Core did not provide a revalidatable process identity for destructive lifecycle mutation.")
            }
            guard await identityRevalidator.revalidateProcessIdentity(expected: expected, target: request.target) == .true else {
                return .init(state: .rejected, detail: "Canonical process identity changed or could not be revalidated; platform mutation withheld.")
            }
        } else {
            // On may legitimately start from process absent.  Its dispatch
            // fence is canonical bundle/layout/signature/registration state,
            // never an invented or adopted process identity.  The revalidator
            // is mandatory: without it there is no evidence for that fence.
            guard let identityRevalidator else {
                return .init(state: .rejected, detail: "Canonical registration preconditions cannot be revalidated; platform mutation withheld.")
            }
            guard await identityRevalidator.revalidateOnRegistrationPreconditions(
                target: request.target,
                allowExistingRegistration: request.allowExistingRegistration) == .true else {
                return .init(state: .rejected, detail: "Canonical registration preconditions could not be revalidated; platform mutation withheld.")
            }
        }
        if request.intent == .off || identityRevalidator != nil {
            // The recheck suspends the executor actor.  A timeout or newer
            // intent may revoke the envelope while it is suspended; never
            // cross the platform boundary with a revoked authorization.
            guard !invalidated.contains(request.operationID), !invalidatedNonces.contains(request.nonce) else {
                return .init(state: .rejected, detail: "Core revoked this lifecycle request during identity revalidation.")
            }
        }
        guard !platformMutationInProgress else {
            return .init(state: .unknown, detail: "Another platform lifecycle call is in progress; recovery observation is required.")
        }
        platformMutationInProgress = true
        defer { platformMutationInProgress = false }
        do {
            switch request.intent {
            case .on: try await platform.register()
            case .off: try await platform.unregister(request: request)
            }
            if invalidated.contains(request.operationID) || invalidatedNonces.contains(request.nonce) {
                return .init(state: .unknown, detail: "Platform lifecycle call was already entered when Core revoked the request; recovery observation is required.")
            }
            return .init(state: .success)
        } catch {
            // Once the external call has been entered, an exception does not
            // establish whether the platform mutated state before throwing.
            // Only the guards above are pre-call refusals and may be rejected.
            return .init(state: .unknown, detail: "SMAppService lifecycle call threw after authorization: \(error.localizedDescription)")
        }
    }
}

/// Deterministic executor for Core tests. It records every authenticated,
/// operation-bound request and never performs a real lifecycle mutation.
public actor FakeLifecycleExecutor: CoreIssuedLifecycleExecutor {
    private var configured: LifecycleExecutorResult
    private var recorded: [LifecycleExecutorRequest] = []
    private let expectedSessionBinding: UUID?
    private var consumedNonces: Set<UUID> = []

    public init(result: LifecycleExecutorResult = .init(state: .unavailable), expectedSessionBinding: UUID? = nil) {
        configured = result; self.expectedSessionBinding = expectedSessionBinding
    }
    public func setResult(_ result: LifecycleExecutorResult) { configured = result }
    public func requests() -> [LifecycleExecutorRequest] { recorded }
    public func authorize(_ request: LifecycleExecutorRequest) async {}
    public func invalidate(operationID: UUID, nonce: UUID) async {}
    public func execute(_ request: LifecycleExecutorRequest) async -> LifecycleExecutorResult {
        if let expectedSessionBinding,
           let error = request.authenticationError(expectedSessionBinding: expectedSessionBinding) {
            return .init(state: .rejected, detail: error)
        }
        guard consumedNonces.insert(request.nonce).inserted else {
            return .init(state: .rejected, detail: "Executor request nonce was replayed.")
        }
        recorded.append(request); return configured
    }
}
