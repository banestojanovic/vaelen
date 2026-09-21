import Foundation
import CryptoKit
import ServiceManagement
import Security
import Darwin
import SQLite3

public enum BootstrapReceiptPhase: String, Codable, Sendable { case reserved, succeeded, failed, unknownRecoveryRequired = "unknown/recovery-required", promoted }
public enum BootstrapRecoveryState: String, Codable, Sendable { case reserved, succeeded, failed }
/// The sole historical exception to the modern invocation-bound receipt
/// contract.  This authorization deliberately has no invocation ID: the
/// pre-invocation-schema receipt did not contain one and must never be made to
/// look like modern provenance.
public struct LegacyBootstrapRecoveryAuthorization: Codable, Equatable, Sendable {
    public static let epoch = UUID(uuidString: "CBBBF353-E0A6-4188-A47F-6FA771974C70")!
    public static let operationID = UUID(uuidString: "9DE859E9-877D-431C-A2AE-C70BD48FC7B9")!
    public static let source = "LEGACY PRE-SCHEMA RECOVERY"
    public let epoch: UUID
    public let operationID: UUID
    public let target: LifecycleTargetIdentity
    public init(epoch: UUID = Self.epoch, operationID: UUID = Self.operationID,
                target: LifecycleTargetIdentity = LifecycleCanonicalIdentity.target) {
        self.epoch = epoch; self.operationID = operationID; self.target = target
    }
    public var isExact: Bool { epoch == Self.epoch && operationID == Self.operationID && target == LifecycleCanonicalIdentity.target }
}
public struct LegacyBootstrapRecoveryRecord: Codable, Equatable, Sendable {
    public let authorization: LegacyBootstrapRecoveryAuthorization
    public let state: BootstrapRecoveryState
    public let detail: String
    public let observedAt: Date
    public let source: String
    public init(authorization: LegacyBootstrapRecoveryAuthorization, state: BootstrapRecoveryState,
                detail: String, observedAt: Date = Date(), source: String = LegacyBootstrapRecoveryAuthorization.source) {
        self.authorization = authorization; self.state = state; self.detail = detail
        self.observedAt = observedAt; self.source = source
    }
}
public struct BootstrapRecoveryAuthorization: Codable, Equatable, Sendable {
    public static let epoch = UUID(uuidString: "CBBBF353-E0A6-4188-A47F-6FA771974C70")!
    public static let operationID = UUID(uuidString: "9DE859E9-877D-431C-A2AE-C70BD48FC7B9")!
    public static let invocationID = UUID(uuidString: "0CFFEE97-A45A-4FAB-8F1E-E722450CDE73")!
    public let epoch: UUID; public let operationID: UUID; public let invocationID: UUID; public let target: LifecycleTargetIdentity
    public init(epoch: UUID = Self.epoch, operationID: UUID = Self.operationID, invocationID: UUID = Self.invocationID, target: LifecycleTargetIdentity = LifecycleCanonicalIdentity.target) { self.epoch = epoch; self.operationID = operationID; self.invocationID = invocationID; self.target = target }
    public var isExact: Bool { epoch == Self.epoch && operationID == Self.operationID && invocationID == Self.invocationID && target == LifecycleCanonicalIdentity.target }
}

/// Exact authorization for the one known modern succeeded receipt left by the
/// failed M14 bootstrap handoff. It is not a general receipt-recovery API.
public struct KnownBootstrapRecoveryAuthorization: Codable, Equatable, Sendable {
    public static let operationID = UUID(uuidString: "72152EC5-3679-4F0C-8757-AD46CF1B28F0")!
    public static let invocationID = UUID(uuidString: "5ECD3491-52C9-4408-934C-725157E8B253")!
    public static let source = "KNOWN M14 SUCCEEDED-RECEIPT RECOVERY"
    public let operationID: UUID
    public let invocationID: UUID
    public let target: LifecycleTargetIdentity
    public init(operationID: UUID = Self.operationID, invocationID: UUID = Self.invocationID,
                target: LifecycleTargetIdentity = LifecycleCanonicalIdentity.target) {
        self.operationID = operationID; self.invocationID = invocationID; self.target = target
    }
    public var isExact: Bool { operationID == Self.operationID && invocationID == Self.invocationID && target == LifecycleCanonicalIdentity.target }
}
public struct BootstrapRecoveryRecord: Codable, Equatable, Sendable {
    public let authorization: BootstrapRecoveryAuthorization; public let state: BootstrapRecoveryState; public let detail: String; public let observedAt: Date; public let source: String
    public init(authorization: BootstrapRecoveryAuthorization, state: BootstrapRecoveryState, detail: String, observedAt: Date = Date(), source: String = "MODERN RECOVERY") { self.authorization = authorization; self.state = state; self.detail = detail; self.observedAt = observedAt; self.source = source }
}
public enum BootstrapError: Error, Equatable, Sendable { case refused(String), recoveryRequired(String), invalidReceipt, coreReachable, platformAmbiguous(String) }

public protocol BootstrapReceiptAuthenticator: Sendable {
    func mac(for data: Data) throws -> String
    func verifies(mac: String, for data: Data) throws -> Bool
    /// Gives platform-backed authenticators the preflight boundary at which
    /// receipt key material may be touched.  Test authenticators may retain
    /// their in-memory behavior.
    func authorize(provenance: BootstrapReceiptProvenance) throws
}
public extension BootstrapReceiptAuthenticator {
    func authorize(provenance: BootstrapReceiptProvenance) throws {}
}

public struct BootstrapReceiptProvenance: Codable, Equatable, Sendable {
    public let signingTeam: String
    public let designatedRequirement: String
    public let artifactHash: String
    public let bundleID: String
    public let agentLabel: String
    public let bundleProgram: String
    public init(signingTeam: String, designatedRequirement: String, artifactHash: String,
                bundleID: String = LifecycleCanonicalIdentity.target.bundleID,
                agentLabel: String = LifecycleCanonicalIdentity.target.agentLabel,
                bundleProgram: String = LifecycleCanonicalIdentity.target.bundleProgram) {
        self.signingTeam = signingTeam; self.designatedRequirement = designatedRequirement; self.artifactHash = artifactHash
        self.bundleID = bundleID; self.agentLabel = agentLabel; self.bundleProgram = bundleProgram
    }
}

/// Controller-owned proof of the one registration mutation.  This is not a
/// ServiceManagement status cache: it is bound to the invocation, operation,
/// generation, exact executable, and signed identity which the controller
/// actually registered.
public struct BootstrapRegistrationEvidence: Codable, Equatable, Sendable {
    public let target: LifecycleTargetIdentity
    public let operationID: UUID
    public let invocationID: UUID
    public let generation: Int64
    public let executablePath: String
    public let uid: UInt32
    public let signingTeam: String
    public let daemonIdentifier: String
    public let observedAt: Date
    public init(target: LifecycleTargetIdentity, operationID: UUID, invocationID: UUID,
                generation: Int64, executablePath: String, uid: UInt32,
                signingTeam: String, daemonIdentifier: String = LifecycleCanonicalIdentity.daemonIdentifier,
                observedAt: Date = Date()) {
        self.target = target; self.operationID = operationID; self.invocationID = invocationID
        self.generation = generation; self.executablePath = executablePath; self.uid = uid
        self.signingTeam = signingTeam; self.daemonIdentifier = daemonIdentifier; self.observedAt = observedAt
    }
}

public struct KeychainBootstrapReceiptAuthenticator: BootstrapReceiptAuthenticator, Sendable {
    public static let shared = Self()
    // Versioned after adding the controller binding.  An item created by the
    // older unbound authenticator is never silently adopted.
    private let service = "dev.vaelen.bootstrap-receipts.v2"
    private let account = NSUserName()
    private let authorization = Authorization()
    public init() {}
    public func mac(for data: Data) throws -> String {
        guard authorization.isAuthorized else { throw BootstrapError.invalidReceipt }
        let key = try secret()
        return HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
    }
    public func verifies(mac: String, for data: Data) throws -> Bool {
        guard authorization.isAuthorized else { throw BootstrapError.invalidReceipt }
        guard mac.count == 64, let supplied = Data(hexString: mac) else { return false }
        let key = try secret()
        let expected = Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        guard supplied.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(supplied, expected) { difference |= a ^ b }
        return difference == 0
    }
    public func authorize(provenance: BootstrapReceiptProvenance) throws {
        guard provenance.bundleID == LifecycleCanonicalIdentity.target.bundleID,
              provenance.agentLabel == LifecycleCanonicalIdentity.target.agentLabel,
              provenance.bundleProgram == LifecycleCanonicalIdentity.target.bundleProgram,
               !provenance.signingTeam.isEmpty, !provenance.designatedRequirement.isEmpty,
               !provenance.artifactHash.isEmpty else { throw BootstrapError.invalidReceipt }
        // Key material is only available after the signed controller has
        // crossed the executor's preflight boundary.  This is deliberately a
        // fail-closed, per-authenticator binding; receipt reads from an
        // unpreflighted process cannot create or query the Keychain secret.
        authorization.markAuthorized()
    }
    private func secret() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecAttrGeneric as String: controllerBinding]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count >= 32 { return data }
        guard status == errSecItemNotFound else { throw BootstrapError.invalidReceipt }
        var bytes = Data(count: 32)
        guard bytes.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { throw BootstrapError.invalidReceipt }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrGeneric as String: controllerBinding, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecValueData as String: bytes]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw BootstrapError.invalidReceipt }
        return bytes
    }
    private var controllerBinding: Data { Data("dev.vaelen.app/controller".utf8) }
    private final class Authorization: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isAuthorized: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func markAuthorized() { lock.lock(); value = true; lock.unlock() }
    }
}

/// Non-production authenticator for unit tests. Its key is process-local and
/// never addresses the production Keychain service.
public struct InMemoryBootstrapReceiptAuthenticator: BootstrapReceiptAuthenticator, Sendable {
    private let key = SymmetricKey(data: Data("vaelen-xctest-bootstrap-receipts".utf8))
    public init() {}
    public func mac(for data: Data) throws -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
    }
    public func verifies(mac: String, for data: Data) throws -> Bool {
        guard mac.count == 64, let supplied = Data(hexString: mac) else { return false }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
        return supplied == expected
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var result = Data(); var index = hexString.startIndex
        while index < hexString.endIndex { let next = hexString.index(index, offsetBy: 2); guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }; result.append(byte); index = next }
        self = result
    }
}

public struct BootstrapReceipt: Codable, Equatable, Sendable {
    public let target: LifecycleTargetIdentity
    public let epoch: UUID
    public let operationID: UUID
    public let nonce: UUID
    public let invocationToken: String
    public let invocationUser: String
    public let invocationUID: UInt32
    public let invocationID: UUID
    public let generation: Int64
    public let preflightProvenance: BootstrapReceiptProvenance
    public let registrationEvidence: BootstrapRegistrationEvidence?
    public let expiresAt: Date
    public let phase: BootstrapReceiptPhase
    public let executorState: LifecycleExecutorResultState?
    public let executorDetail: String?
    public let postObservation: LifecycleObservationVector?
    public let integrityDigest: String
}

/// Read-only projection of the pre-invocation receipt shape. It is not a
/// modern BootstrapReceipt and cannot be promoted into modern provenance.
public struct LegacyBootstrapReceipt: Equatable, Sendable {
    public let target: LifecycleTargetIdentity
    public let epoch: UUID
    public let operationID: UUID
    public let expiresAt: Date
    public let phase: BootstrapReceiptPhase
}

/// Non-authoritative handoff coordinates.  A client may use these to address
/// Core after the signed controller has completed the platform call; Core
/// still authenticates and validates the complete receipt before promotion.
public struct BootstrapReceiptHandoff: Sendable, Equatable {
    public let invocationToken: String
    public let epoch: UUID
    public let operationID: UUID
    public let nonce: UUID
    public let phase: BootstrapReceiptPhase
    public init(invocationToken: String, epoch: UUID, operationID: UUID, nonce: UUID, phase: BootstrapReceiptPhase) {
        self.invocationToken = invocationToken; self.epoch = epoch; self.operationID = operationID; self.nonce = nonce; self.phase = phase
    }
}

/// The intentionally small platform boundary for the pre-Core operation.
/// Implementations have one mutation: register. There is no unregister or retry API.
public protocol BootstrapPlatform: Sendable {
    func registrationObservation() async -> ObservationValue
    /// Captures the value and its diagnostic classification from one platform
    /// status read. The detail is diagnostic-only and never lifecycle truth.
    func registrationObservationSnapshot() async -> BootstrapRegistrationObservation
    /// Read-only diagnostic detail for the registration probe. This never
    /// authorizes registration and must not be used as lifecycle truth.
    func registrationObservationDetail() async -> String
    /// Proves that this process is the canonical signed Vaelen app and that
    /// its embedded launch-agent layout is the one being registered.
    func preflight() async -> Bool
    func preflightProvenance() async -> BootstrapReceiptProvenance?
    /// This is deliberately a probe, rather than a value supplied by the
    /// caller.  Bootstrap must make this check immediately before reserving.
    func coreEndpointReachable() async -> Bool
    func register() async throws
    func unregister() async throws
    func recoveryIdentity() async -> BootstrapReceiptProvenance?
}
public extension BootstrapPlatform {
    func registrationObservationSnapshot() async -> BootstrapRegistrationObservation {
        .init(value: await registrationObservation(), detail: await registrationObservationDetail())
    }
    func registrationObservationDetail() async -> String { "observation=\(await registrationObservation().rawValue)" }
    func coreEndpointReachable() async -> Bool { false }
    func unregister() async throws { throw BootstrapError.refused("Bootstrap platform does not authorize unregister.") }
    func recoveryIdentity() async -> BootstrapReceiptProvenance? { await preflightProvenance() }
    // Non-production test doubles which implement the older Bool-only
    // boundary receive explicit test provenance. The production SMAppService
    // implementation overrides this with code-signing-derived evidence.
    func preflightProvenance() async -> BootstrapReceiptProvenance? {
        await preflight() ? .init(signingTeam: "TESTTEAM", designatedRequirement: "identifier \"dev.vaelen.app\"", artifactHash: "hash") : nil
    }
}

public struct BootstrapRegistrationObservation: Sendable, Equatable {
    public let value: ObservationValue
    public let detail: String
    /// ServiceManagement's `notFound` is an absence of a discoverable
    /// registration, but is not the same observation as `notRegistered`.
    /// Keep that distinction at the executor boundary: only the former two
    /// explicit states may enter the first-registration path.
    public let status: BootstrapRegistrationStatus
    public init(value: ObservationValue, detail: String,
                status: BootstrapRegistrationStatus? = nil) {
        self.value = value
        self.detail = detail
        self.status = status ?? BootstrapRegistrationStatus(detail: detail, value: value)
    }
}

public enum BootstrapRegistrationStatus: String, Sendable, Equatable {
    case enabled, notRegistered, notFound, requiresApproval, unknown

    fileprivate init(detail: String, value: ObservationValue) {
        if detail.contains("status=enabled") { self = .enabled }
        else if detail.contains("status=notRegistered") { self = .notRegistered }
        else if detail.contains("status=notFound") { self = .notFound }
        else if detail.contains("status=requiresApproval") { self = .requiresApproval }
        else {
            switch value {
            case .true: self = .enabled
            case .false: self = .notRegistered
            case .unknown, .stale, .incompatible: self = .unknown
            }
        }
    }
}

public actor SMAppServiceBootstrapPlatform: BootstrapPlatform {
    private let service: SMAppService
    private let controllerBundleURL: URL

    /// The platform adapter is deliberately tied to the app bundle which
    /// owns the LaunchAgent.  Keeping this URL explicit makes it impossible
    /// for a caller to substitute a helper/daemon bundle while retaining the
    /// Vaelen identity in the receipt.
    public init(service: SMAppService? = nil, controllerBundleURL: URL = Bundle.main.bundleURL) {
        self.service = service ?? SMAppService.agent(plistName: "dev.vaelen.vaelend.agent.plist")
        self.controllerBundleURL = controllerBundleURL.standardizedFileURL
    }
    public func registrationObservation() async -> ObservationValue {
        await registrationObservationSnapshot().value
    }
    public func registrationObservationDetail() async -> String {
        switch service.status {
        case .enabled: return "status=enabled approvalRequired=false"
        case .notRegistered: return "status=notRegistered approvalRequired=false"
        case .notFound: return "status=notFound approvalRequired=false"
        case .requiresApproval: return "status=requiresApproval approvalRequired=true"
        @unknown default: return "status=unknown approvalRequired=unknown"
        }
    }
    public func registrationObservationSnapshot() async -> BootstrapRegistrationObservation {
        switch service.status {
        case .enabled: return .init(value: .true, detail: "status=enabled approvalRequired=false", status: .enabled)
        case .notRegistered: return .init(value: .false, detail: "status=notRegistered approvalRequired=false", status: .notRegistered)
        case .notFound: return .init(value: .unknown, detail: "status=notFound approvalRequired=false", status: .notFound)
        case .requiresApproval: return .init(value: .unknown, detail: "status=requiresApproval approvalRequired=true", status: .requiresApproval)
        @unknown default: return .init(value: .unknown, detail: "status=unknown approvalRequired=unknown", status: .unknown)
        }
    }
    public func preflight() async -> Bool {
        LifecycleCanonicalIdentity.isAllowedControllerURL(controllerBundleURL) && ArtifactPreflight.validate(appURL: controllerBundleURL) != nil
    }
    public func preflightProvenance() async -> BootstrapReceiptProvenance? {
        guard LifecycleCanonicalIdentity.isAllowedControllerURL(controllerBundleURL),
              let evidence = ArtifactPreflight.validate(appURL: controllerBundleURL) else { return nil }
        return .init(signingTeam: evidence.teamIdentifier,
                     designatedRequirement: evidence.appDesignatedRequirement,
                     artifactHash: evidence.daemonSHA256)
    }
    public func coreEndpointReachable() async -> Bool {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = LifecycleCanonicalIdentity.target.endpoint
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return true }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0) }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { close(fd) }
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 } }
    }
    public func register() async throws { try service.register() }
    public func unregister() async throws { try await service.unregister() }
    public func recoveryIdentity() async -> BootstrapReceiptProvenance? { await preflightProvenance() }
}

public struct FakeBootstrapPlatform: BootstrapPlatform {
    public let initialObservation: ObservationValue
    public let initialRegistrationStatus: BootstrapRegistrationStatus?
    public let registrationError: String?
    public let endpointReachable: Bool
    public let preflightResult: Bool
    private let counter: Counter
    public init(observation: ObservationValue = .false, registrationError: String? = nil, endpointReachable: Bool = false, preflightResult: Bool = true, registrationStatus: BootstrapRegistrationStatus? = nil, counter: Counter = Counter()) { initialObservation = observation; self.initialRegistrationStatus = registrationStatus; self.registrationError = registrationError; self.endpointReachable = endpointReachable; self.preflightResult = preflightResult; self.counter = counter }
    public func preflight() async -> Bool { preflightResult }
    public func preflightProvenance() async -> BootstrapReceiptProvenance? { preflightResult ? .init(signingTeam: "TESTTEAM", designatedRequirement: "identifier \"dev.vaelen.app\"", artifactHash: "test") : nil }
    public func registrationObservation() async -> ObservationValue { initialObservation }
    public func registrationObservationSnapshot() async -> BootstrapRegistrationObservation {
        .init(value: initialObservation, detail: "observation=\(initialObservation.rawValue)", status: initialRegistrationStatus)
    }
    public func coreEndpointReachable() async -> Bool { endpointReachable }
    public func register() async throws { await counter.increment(); if let registrationError { throw BootstrapError.refused(registrationError) } }
    public func unregister() async throws { await counter.increment(); if let registrationError { throw BootstrapError.refused(registrationError) } }
    public func recoveryIdentity() async -> BootstrapReceiptProvenance? { await preflightProvenance() }
    public actor Counter { private var value = 0; public init() {}; public func increment() { value += 1 }; public func count() -> Int { value } }
}

public final class CoreAbsentBootstrapExecutor: @unchecked Sendable {
    private let store: SQLiteStateStore
    private let platform: any BootstrapPlatform
    private let target: LifecycleTargetIdentity
    private let lockEndpoint: String
    private let ttl: TimeInterval
    private let authenticator: any BootstrapReceiptAuthenticator

    public init(store: SQLiteStateStore, platform: any BootstrapPlatform = SMAppServiceBootstrapPlatform(), ttl: TimeInterval = 60, lockEndpoint: String? = nil, authenticator: any BootstrapReceiptAuthenticator = InMemoryBootstrapReceiptAuthenticator()) {
        self.store = store; self.platform = platform; self.target = LifecycleCanonicalIdentity.target; self.ttl = ttl; self.lockEndpoint = lockEndpoint ?? self.target.endpoint; self.authenticator = authenticator
    }

    /// Establishes the signed-controller boundary before any receipt read.
    /// In particular, the production authenticator cannot touch Keychain
    /// material until this method has completed successfully.
    public func validateSignedPreflight() async throws -> BootstrapReceiptProvenance {
        guard await platform.preflight(), let provenance = await platform.preflightProvenance() else {
            throw BootstrapError.refused("Canonical signed app preflight failed.")
        }
        try authenticator.authorize(provenance: provenance)
        return provenance
    }

    /// Executes the only Core-absent mutation. The token is supplied only by an
    /// explicit CLI invocation; callers must never reuse a receipt or token.
    public func execute(explicitInvocationToken token: String, controllerPath: String = LifecycleCanonicalIdentity.installedControllerURL.path, user: String = NSUserName(), coreReachable _: Bool = false, now: Date = Date()) async throws -> BootstrapReceipt {
        guard !token.isEmpty else { throw BootstrapError.refused("An explicit invocation authorization token is required.") }
        let tokenHash = SQLiteStateStore.safeTokenHash(token)
        let invocationID = try? store.bootstrapInvocationID(token: token)
        let correlationID = invocationID ?? UUID()
        func diagnostic(_ phase: LifecycleDiagnosticPhase, _ outcome: String, _ detail: String, operation: UUID? = nil) {
            try? store.recordDiagnostic(.init(correlationID: correlationID, phase: phase, outcome: outcome, detail: detail, databasePath: store.databaseURL.path, invocationID: invocationID, tokenHash: tokenHash, operationID: operation, user: user))
        }
        diagnostic(.preflight, "started", "controller=\(controllerPath)")
        // No receipt read (and therefore no Keychain secret access) occurs
        // until the fixed canonical controller has completed signed preflight.
        _ = try await validateSignedPreflight()
        diagnostic(.preflight, "success", "canonical signed controller validated")
        // The controller owns one exclusive, operation-bound lease.  It is
        // deliberately released after the receipt result is durable; the
        // daemon is a new process and cannot inherit this descriptor.
        let lock = try BootstrapLock.acquireExclusive(endpoint: lockEndpoint)
        defer { lock.release() }
        // The signed controller consumes the CLI-minted authorization before
        // any bootstrap receipt or ServiceManagement operation is reached.
        // Consumption is an atomic, same-user, fixed-target one-time fence.
        try store.consumeBootstrapInvocation(token: token, target: target, controllerPath: controllerPath,
                                              operation: SQLiteStateStore.bootstrapInvocationOperation,
                                              user: user, uid: getuid(), now: now)
        diagnostic(.consume, "success", "one-time invocation consumed")
        let legacyRecoveryCompleted = (try? store.bootstrapRecoveryState()) == .succeeded &&
            (try? store.bootstrapRecoverySource()) == LegacyBootstrapRecoveryAuthorization.source
        // The old boolean is retained for source compatibility but is not an
        // authority.  Probe the canonical endpoint at the last possible point.
        do {
            if legacyRecoveryCompleted {
                // The historical receipt is preserved in the dedicated
                // archive before the singleton current-receipt slot is reused
                // for this new, modern invocation-bound Start.
                try store.archiveLegacyReceiptForFreshBootstrap(now: now)
                let receipt = try await executeNew(token: token, controllerPath: controllerPath, user: user, now: now)
                diagnostic(.platform, receipt.phase.rawValue, "ServiceManagement result recorded after legacy receipt archival", operation: receipt.operationID)
                return receipt
            }
             guard let receipt = try store.bootstrapReceipt(authenticator: authenticator) else { /* first bootstrap */
                let receipt = try await executeNew(token: token, controllerPath: controllerPath, user: user, now: now)
                diagnostic(.platform, receipt.phase.rawValue, "ServiceManagement result recorded", operation: receipt.operationID)
                 return receipt
             }
             if receipt.phase == .promoted,
                let current = try LifecycleStateRepository(store: store, receiptAuthenticator: authenticator).intent(), current.intent == .off,
                let operation = try LifecycleStateRepository(store: store, receiptAuthenticator: authenticator).operation(), operation.kind == .unregister,
                operation.state == .succeeded,
                !(await platform.coreEndpointReachable()) {
                 let registration = await platform.registrationObservationSnapshot()
                 guard registration.status == .notRegistered || registration.status == .notFound else {
                     throw BootstrapError.recoveryRequired("Promoted receipt conflicts with current external lifecycle state.")
                 }
                 try store.archivePromotedReceiptAfterRecoveredOff(receipt, authenticator: authenticator)
                 return try await executeNew(token: token, controllerPath: controllerPath, user: user, now: now)
             }
             // Receipt presence is a durable platform-attempt barrier.  Only a
            // completed receipt may be resumed by the explicit start handoff;
            // this executor never re-registers it.
            if receipt.phase == .succeeded, receipt.expiresAt >= now { throw BootstrapError.recoveryRequired("A succeeded bootstrap receipt requires explicit Core handoff.") }
            throw BootstrapError.recoveryRequired("Bootstrap receipt is \(receipt.phase.rawValue); recovery is required.")
        } catch let error as BootstrapError {
            diagnostic(.platform, "refused", "bootstrap executor refused before receipt", operation: nil)
            throw error
        } catch {
            diagnostic(.platform, "failed", "bootstrap executor failed before receipt", operation: nil)
            throw BootstrapError.recoveryRequired("Bootstrap receipt is malformed; recovery is required.")
        }
    }

    private func executeNew(token: String, controllerPath: String, user: String, now: Date) async throws -> BootstrapReceipt {
        let repository = LifecycleStateRepository(store: store)
        if let recoveryState = try store.bootstrapRecoveryState() {
            guard recoveryState == .succeeded,
                  try store.bootstrapRecoverySource() == LegacyBootstrapRecoveryAuthorization.source else {
                throw BootstrapError.recoveryRequired("A prior recovery record blocks fresh bootstrap.")
            }
        } else {
            guard try store.bootstrapRecoveryRecord() == nil else { throw BootstrapError.recoveryRequired("This fixed recovery operation has already been attempted.") }
        }
        guard try !repository.hasUnresolvedOperation() else {
            throw BootstrapError.recoveryRequired("A lifecycle operation is pending or requires recovery.")
        }
        if let intent = try repository.intent(), intent.intent == .on {
            throw BootstrapError.refused("An existing On intent conflicts with Core-absent bootstrap.")
        }
        // Off is a barrier for implicit recovery only.  This method is the
        // explicitly token-authorized exceptional operation.
        // A first registration may start from either explicit absence state.
        // `notFound` is intentionally not collapsed into `notRegistered`:
        // approval, enabled, and all future/unknown states remain refusals.
        let registration = await platform.registrationObservationSnapshot()
        try? store.recordDiagnostic(.init(correlationID: (try? store.bootstrapInvocationID(token: token)) ?? UUID(), phase: .platform, outcome: "registration-observation", detail: "value=\(registration.value.rawValue) \(registration.detail)", databasePath: store.databaseURL.path, invocationID: try? store.bootstrapInvocationID(token: token), tokenHash: SQLiteStateStore.safeTokenHash(token), user: user))
        guard registration.status == .notRegistered || registration.status == .notFound else {
            if registration.status == .requiresApproval {
                throw BootstrapError.refused("Registration requires approval; bootstrap stopped.")
            }
            throw BootstrapError.refused("Registration observation is neither notRegistered nor notFound; recovery is required.")
        }
        guard await platform.preflight(), let provenance = await platform.preflightProvenance() else { throw BootstrapError.refused("Canonical signed app preflight failed.") }
        // Re-probe under the shared handoff lease at the last possible point;
        // a daemon may have started after the initial Core-absent decision.
        guard !(await platform.coreEndpointReachable()) else { throw BootstrapError.coreReachable }
        try authenticator.authorize(provenance: provenance)
        let invocationID = try store.bootstrapInvocationID(token: token) ?? UUID()
        let priorGeneration = (try? repository.intent())??.generation ?? 0
        let generation = priorGeneration + 1
        let receipt = BootstrapReceipt(target: target, epoch: UUID(), operationID: UUID(), nonce: UUID(), invocationToken: token, invocationUser: user, invocationUID: getuid(), invocationID: invocationID, generation: generation, preflightProvenance: provenance, registrationEvidence: nil, expiresAt: now.addingTimeInterval(ttl), phase: .reserved, executorState: nil, executorDetail: nil, postObservation: nil, integrityDigest: "")
        let reserved = try receipt.withMAC(using: authenticator)
        try store.reserveBootstrapReceipt(reserved, now: now, authenticator: authenticator)
        try? store.recordDiagnostic(.init(correlationID: try store.bootstrapInvocationID(token: token) ?? UUID(), phase: .reserve, outcome: "success", detail: "receipt reserved before platform call", databasePath: store.databaseURL.path, invocationID: try store.bootstrapInvocationID(token: token), tokenHash: SQLiteStateStore.safeTokenHash(token), operationID: receipt.operationID, user: user))
        do {
            try await platform.register()
            let postRegistration = await platform.registrationObservationSnapshot()
            let observation = LifecycleObservationVector(registrationMatch: postRegistration.value, observedAt: Date(), source: "bootstrap", reason: postRegistration.status == .notFound ? "Registration remained notFound after register; recovery is required." : nil)
            // A completed register call is the platform operation's success
            // boundary.  The follow-up observation is retained as evidence;
            // it is not allowed to turn a successful API return into an
            // ambiguous result (some ServiceManagement implementations lag
            // briefly before reporting enabled).
            let registrationConfirmed = postRegistration.status == .enabled && observation.registrationMatch == .true
            let evidence = registrationConfirmed ? BootstrapRegistrationEvidence(target: target, operationID: receipt.operationID, invocationID: receipt.invocationID, generation: receipt.generation, executablePath: URL(fileURLWithPath: controllerPath).appendingPathComponent(target.bundleProgram).path, uid: receipt.invocationUID, signingTeam: provenance.signingTeam, observedAt: observation.observedAt) : nil
            let state: LifecycleExecutorResultState = registrationConfirmed ? .success : .unknown
            let completed = try reserved.updated(phase: registrationConfirmed ? .succeeded : .unknownRecoveryRequired, executorState: state, detail: registrationConfirmed ? nil : (postRegistration.status == .notFound ? "Registration remained notFound after register; recovery is required." : "Registration did not produce a fresh enabled observation; recovery is required."), postObservation: observation, registrationEvidence: evidence).withMAC(using: authenticator)
            do { try store.recordBootstrapReceipt(completed, authenticator: authenticator) }
            catch {
                // The API has already been attempted.  Never turn an
                // uncertain persistence boundary into a retryable failure.
                try? store.recordBootstrapReceipt(reserved.updated(phase: .unknownRecoveryRequired, executorState: .unknown, detail: "Receipt result persistence failed; recovery is required.", postObservation: observation).withMAC(using: authenticator), authenticator: authenticator)
                throw BootstrapError.platformAmbiguous("Bootstrap result persistence failed; recovery is required.")
            }
            return completed
        } catch {
            if case BootstrapError.platformAmbiguous = error { throw error }
            let postRegistration = await platform.registrationObservationSnapshot()
            let observation = LifecycleObservationVector(registrationMatch: postRegistration.value, observedAt: Date(), source: "bootstrap", reason: "ServiceManagement register threw; recovery is required.")
            // A platform exception does not tell us whether ServiceManagement
            // applied the request. Only our explicitly authenticated refusal is
            // a known pre-call rejection; every other exception is recovery
            // required and must not invite a retry.
            let knownRejection: Bool
            if case BootstrapError.refused = error { knownRejection = true } else { knownRejection = false }
            let completed = try reserved.updated(phase: knownRejection ? .failed : .unknownRecoveryRequired,
                                                  executorState: knownRejection ? .rejected : .unknown,
                                                    detail: "ServiceManagement register threw; recovery is required.", postObservation: observation, registrationEvidence: nil).withMAC(using: authenticator)
            do { try store.recordBootstrapReceipt(completed, authenticator: authenticator) }
            catch { throw BootstrapError.platformAmbiguous("Receipt result persistence failed; recovery is required.") }
            return completed
        }
    }

    /// Compatibility no-op.  The controller lease is released by `execute`
    /// immediately after the durable result, never retained across reconnect.
    public func releaseHandoffLock() {}

    /// Unregisters only the one explicitly authorized, expired orphan receipt.
    /// The historical receipt remains untouched; this is not adoption or
    /// desired-state mutation.
    public func recoverRegisteredOrphan(_ authorization: BootstrapRecoveryAuthorization = .init(), now: Date = Date()) async throws -> BootstrapRecoveryRecord {
        guard authorization.isExact else { throw BootstrapError.refused("Recovery authorization is not the fixed M14 orphan.") }
        let provenance = try await validateSignedPreflight()
        guard provenance.bundleID == target.bundleID, provenance.agentLabel == target.agentLabel,
              provenance.bundleProgram == target.bundleProgram,
              provenance.signingTeam == LifecycleCanonicalIdentity.teamIdentifier else { throw BootstrapError.refused("Canonical controller/service identity failed recovery preflight.") }
        let lock = try BootstrapLock.acquireExclusive(endpoint: lockEndpoint); defer { lock.release() }
        guard !(await platform.coreEndpointReachable()) else { throw BootstrapError.coreReachable }
        let repository = LifecycleStateRepository(store: store)
         guard try repository.ownership() == nil else { throw BootstrapError.refused("Recovery cannot act on owned registration.") }
         if let intent = try repository.intent(), intent.intent == .on { throw BootstrapError.refused("Recovery cannot act while an On intent exists.") }
         guard try !repository.hasUnresolvedOperation() else { throw BootstrapError.recoveryRequired("A current lifecycle journal is unresolved.") }
         if let existingState = try store.bootstrapRecoveryState() {
             guard existingState == .succeeded,
                   try store.bootstrapRecoverySource() == LegacyBootstrapRecoveryAuthorization.source else {
                 throw BootstrapError.recoveryRequired("A different recovery fence already occupies the one-shot recovery boundary.")
             }
             try store.archiveLegacyRecoveryFence()
         }
         guard let receipt = try store.bootstrapReceipt(authenticator: authenticator), receipt.epoch == authorization.epoch,
              receipt.operationID == authorization.operationID, receipt.invocationID == authorization.invocationID,
              receipt.target == target, receipt.expiresAt <= now,
              receipt.phase == .failed || receipt.phase == .unknownRecoveryRequired || receipt.phase == .succeeded else {
            throw BootstrapError.refused("The exact expired terminal orphan receipt was not found.")
        }
        guard let fresh = await platform.recoveryIdentity(), fresh.bundleID == target.bundleID,
              fresh.agentLabel == target.agentLabel, fresh.bundleProgram == target.bundleProgram,
              fresh.signingTeam == LifecycleCanonicalIdentity.teamIdentifier,
              fresh.designatedRequirement == receipt.preflightProvenance.designatedRequirement,
              fresh.artifactHash == receipt.preflightProvenance.artifactHash else { throw BootstrapError.refused("Fresh canonical platform identity is unavailable or mismatched.") }
        guard (await platform.registrationObservationSnapshot()).status == .enabled else { throw BootstrapError.refused("Recovery target is not exactly registered.") }
        try store.recordBootstrapRecovery(.init(authorization: authorization, state: .reserved, detail: "Recovery reserved before ServiceManagement unregister.", observedAt: now))
        do {
            try await platform.unregister()
            let post = await platform.registrationObservationSnapshot()
            guard post.status == .notRegistered || post.status == .notFound else { throw BootstrapError.platformAmbiguous("Recovery unregister did not produce fresh absence.") }
            let record = BootstrapRecoveryRecord(authorization: authorization, state: .succeeded, detail: "Exact canonical orphan unregistered through ServiceManagement.", observedAt: now)
            try store.recordBootstrapRecovery(record)
            return record
        } catch let error as BootstrapError {
            try? store.recordBootstrapRecovery(.init(authorization: authorization, state: .failed, detail: error.localizedDescription, observedAt: now))
            throw error
        } catch {
            let record = BootstrapRecoveryRecord(authorization: authorization, state: .failed, detail: "ServiceManagement unregister failed; no retry was issued.", observedAt: now)
            try? store.recordBootstrapRecovery(record)
            throw error
        }
    }

    /// Archives the exact expired succeeded receipt from the known failed M14
    /// handoff after fresh absence is observed. No unregister is attempted when
    /// ServiceManagement already reports absence; the receipt is preserved in
    /// history and only its singleton current-fence slot is released.
    public func recoverKnownSucceededReceipt(
        _ authorization: KnownBootstrapRecoveryAuthorization = .init(), now: Date = Date()) async throws {
        guard authorization.isExact else { throw BootstrapError.refused("Recovery authorization is not the fixed known M14 receipt.") }
        let provenance = try await validateSignedPreflight()
        guard provenance.bundleID == target.bundleID, provenance.agentLabel == target.agentLabel,
              provenance.bundleProgram == target.bundleProgram,
              provenance.signingTeam == LifecycleCanonicalIdentity.teamIdentifier else {
            throw BootstrapError.refused("Canonical controller/service identity failed recovery preflight.")
        }
        let lock = try BootstrapLock.acquireExclusive(endpoint: lockEndpoint); defer { lock.release() }
        guard !(await platform.coreEndpointReachable()) else { throw BootstrapError.coreReachable }
        let repository = LifecycleStateRepository(store: store)
        guard try repository.intent() == nil, try repository.operationIsAbsent(), try repository.ownership() == nil else {
            throw BootstrapError.recoveryRequired("Known receipt recovery requires no current lifecycle state.")
        }
        guard let receipt = try store.bootstrapReceipt(authenticator: authenticator),
              receipt.target == target,
              receipt.operationID == authorization.operationID,
              receipt.invocationID == authorization.invocationID,
              receipt.phase == .succeeded,
              receipt.expiresAt <= now,
              receipt.preflightProvenance.signingTeam == provenance.signingTeam,
              !receipt.preflightProvenance.designatedRequirement.isEmpty,
              !receipt.preflightProvenance.artifactHash.isEmpty,
              receipt.registrationEvidence?.operationID == receipt.operationID,
              receipt.registrationEvidence?.invocationID == receipt.invocationID else {
            throw BootstrapError.refused("The exact expired known succeeded receipt was not found.")
        }
        let registration = await platform.registrationObservationSnapshot()
        guard registration.status == .notRegistered || registration.status == .notFound else {
            throw BootstrapError.recoveryRequired("Known receipt still has an enabled or ambiguous registration.")
        }
        try store.archiveSucceededReceiptForRecovery(receipt, source: KnownBootstrapRecoveryAuthorization.source,
                                                     authenticator: authenticator)
    }

    /// Recovers exactly one receipt written before invocation IDs were added
    /// to the receipt schema.  This path is intentionally separate from the
    /// modern path: it never constructs, stores, or infers an invocation ID.
    /// The original receipt is read only and remains byte-for-byte untouched.
    public func recoverLegacyPreInvocationOrphan(
        _ authorization: LegacyBootstrapRecoveryAuthorization = .init(), now: Date = Date()) async throws -> LegacyBootstrapRecoveryRecord {
        guard authorization.isExact else { throw BootstrapError.refused("Recovery authorization is not the fixed M14 legacy orphan.") }
        let provenance = try await validateSignedPreflight()
        guard provenance.bundleID == target.bundleID, provenance.agentLabel == target.agentLabel,
              provenance.bundleProgram == target.bundleProgram,
              provenance.signingTeam == LifecycleCanonicalIdentity.teamIdentifier else {
            throw BootstrapError.refused("Canonical controller/service identity failed legacy recovery preflight.")
        }
        let lock = try BootstrapLock.acquireExclusive(endpoint: lockEndpoint); defer { lock.release() }
        guard !(await platform.coreEndpointReachable()) else { throw BootstrapError.coreReachable }
        // A reserved or terminal recovery record is a durable one-shot fence.
        // In particular, a crash after reservation must not replay unregister.
        if let prior = try store.bootstrapRecoveryState() {
            guard try store.bootstrapRecoverySource() == LegacyBootstrapRecoveryAuthorization.source else {
                throw BootstrapError.recoveryRequired("A different recovery record already occupies the recovery fence.")
            }
            throw BootstrapError.recoveryRequired("Legacy recovery was already reserved or completed; no retry is permitted.")
        }
        let repository = LifecycleStateRepository(store: store)
        guard try repository.intent() == nil, try repository.operationIsAbsent(), try repository.ownership() == nil else {
            throw BootstrapError.refused("Legacy recovery requires no intent or current lifecycle journal.")
        }
        guard let legacy = try store.legacyBootstrapReceipt(),
              legacy.epoch == authorization.epoch,
              legacy.operationID == authorization.operationID,
              legacy.target == target,
              legacy.phase == .succeeded,
              legacy.expiresAt <= now else {
            throw BootstrapError.refused("The exact expired terminal legacy receipt was not found.")
        }
        // No receipt provenance is adopted.  Fresh identity is limited to the
        // canonical signed controller and exact enabled registration.
        guard let fresh = await platform.recoveryIdentity(),
              fresh.bundleID == target.bundleID, fresh.agentLabel == target.agentLabel,
              fresh.bundleProgram == target.bundleProgram,
              fresh.signingTeam == LifecycleCanonicalIdentity.teamIdentifier,
              (await platform.registrationObservationSnapshot()).status == .enabled else {
            throw BootstrapError.refused("Fresh canonical registration identity is unavailable or conflicting.")
        }
        let reserved = LegacyBootstrapRecoveryRecord(authorization: authorization, state: .reserved,
            detail: LegacyBootstrapRecoveryAuthorization.source + ": reserved before ServiceManagement unregister.", observedAt: now)
        try store.recordLegacyBootstrapRecovery(reserved)
        do {
            try await platform.unregister()
            let post = await platform.registrationObservationSnapshot()
            guard post.status == .notRegistered || post.status == .notFound else {
                throw BootstrapError.platformAmbiguous("Legacy recovery unregister did not produce fresh absence.")
            }
            let completed = LegacyBootstrapRecoveryRecord(authorization: authorization, state: .succeeded,
                detail: LegacyBootstrapRecoveryAuthorization.source + ": exact canonical orphan unregistered through ServiceManagement.", observedAt: now)
            try store.recordLegacyBootstrapRecovery(completed)
            return completed
        } catch let error as BootstrapError {
            try? store.recordLegacyBootstrapRecovery(LegacyBootstrapRecoveryRecord(authorization: authorization, state: .failed, detail: error.localizedDescription, observedAt: now))
            throw error
        } catch {
            try? store.recordLegacyBootstrapRecovery(LegacyBootstrapRecoveryRecord(authorization: authorization, state: .failed, detail: "ServiceManagement unregister failed; no retry was issued.", observedAt: now))
            throw error
        }
    }

}

public final class BootstrapLock: @unchecked Sendable {
    let fd: Int32
    let path: String
    private var didRelease = false
    private init(fd: Int32, path: String) { self.fd = fd; self.path = path }
    public static func acquire(endpoint: String) throws -> BootstrapLock {
        try acquireExclusive(endpoint: endpoint)
    }
    /// The serving daemon owns the exclusive lifecycle lease for its entire
    /// lifetime. This excludes Core-absent bootstrap during both admission and
    /// serving. Lifecycle work in that same daemon is re-entrant through the
    /// process-local registry below, without creating a second authority.
    public static func acquireServerExclusive(endpoint: String) throws -> BootstrapLock {
        try acquireExclusive(endpoint: endpoint)
    }
    /// Opens an already-created handoff path without creating or replacing
    /// it. Used by Core promotion so a receipt cannot manufacture a lease.
    public static func acquireExisting(endpoint: String) throws -> BootstrapLock {
        try acquire(endpoint: endpoint, exclusive: true, create: false)
    }
    public static func acquireExclusive(endpoint: String) throws -> BootstrapLock {
        return try acquire(endpoint: endpoint, exclusive: true)
    }
    private static func acquire(endpoint: String, exclusive: Bool, create: Bool = true) throws -> BootstrapLock {
        let lockURL = URL(fileURLWithPath: endpoint).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("locks/lifecycle-bootstrap.lock")
        if create { try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
        // The directory entry is persistent; flock is the authority. A stale
        // file left by an exited process must not refuse a new bootstrap.
        let fd = open(lockURL.path, (create ? O_CREAT : 0) | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BootstrapError.refused("Unable to open the lifecycle lock.") }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let lockError = errno
            close(fd)
            throw BootstrapError.refused(lockError == EWOULDBLOCK || lockError == EAGAIN ? "The lifecycle lock is already held." : "Unable to acquire the lifecycle lock.")
        }
        return BootstrapLock(fd: fd, path: lockURL.path)
    }
    public static func lockPath(endpoint: String) -> String {
        URL(fileURLWithPath: endpoint).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("locks/lifecycle-bootstrap.lock").path
    }
    public static func exists(endpoint: String) -> Bool { FileManager.default.fileExists(atPath: lockPath(endpoint: endpoint)) }
    /// Release the advisory lock without removing the shared lock path.
    /// Removing it could unlink a newer daemon/bootstrap owner's file.
    public func release() {
        guard !didRelease else { return }
        didRelease = true
        if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd) }
    }
}

extension BootstrapReceipt {
    private struct EvidenceMAC: Codable {
        let target: LifecycleTargetIdentity; let operationID: UUID; let invocationID: UUID
        let generation: Int64; let executablePath: String; let uid: UInt32
        let signingTeam: String; let daemonIdentifier: String
    }
    func canonicalData() throws -> Data {
        let evidenceFields = registrationEvidence.map { EvidenceMAC(target: $0.target, operationID: $0.operationID, invocationID: $0.invocationID, generation: $0.generation, executablePath: $0.executablePath, uid: $0.uid, signingTeam: $0.signingTeam, daemonIdentifier: $0.daemonIdentifier) }
        return try JSONEncoder.bootstrap().encodeValues(target, epoch, operationID, nonce, SQLiteStateStore.safeTokenHash(invocationToken), invocationUser, invocationUID, invocationID, generation, preflightProvenance, evidenceFields, expiresAt, phase, executorState, executorDetail, postObservation)
    }
    fileprivate func withMAC(using authenticator: any BootstrapReceiptAuthenticator) throws -> BootstrapReceipt { return .init(target: target, epoch: epoch, operationID: operationID, nonce: nonce, invocationToken: invocationToken, invocationUser: invocationUser, invocationUID: invocationUID, invocationID: invocationID, generation: generation, preflightProvenance: preflightProvenance, registrationEvidence: registrationEvidence, expiresAt: expiresAt, phase: phase, executorState: executorState, executorDetail: executorDetail, postObservation: postObservation, integrityDigest: try authenticator.mac(for: canonicalData())) }
    func updated(phase: BootstrapReceiptPhase, executorState: LifecycleExecutorResultState, detail: String?, postObservation: LifecycleObservationVector, registrationEvidence: BootstrapRegistrationEvidence? = nil) -> BootstrapReceipt { .init(target: target, epoch: epoch, operationID: operationID, nonce: nonce, invocationToken: invocationToken, invocationUser: invocationUser, invocationUID: invocationUID, invocationID: invocationID, generation: generation, preflightProvenance: preflightProvenance, registrationEvidence: registrationEvidence, expiresAt: expiresAt, phase: phase, executorState: executorState, executorDetail: detail, postObservation: postObservation, integrityDigest: "") }
}

private extension JSONEncoder {
    static func bootstrap() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .millisecondsSince1970; return e }
    /// Encodes the receipt fields as a canonical sequence.  This must not be
    /// named `encode`: an existential argument would select a variadic
    /// overload again and recurse until the test process crashes (SIGBUS).
    func encodeValues(_ values: any Encodable...) throws -> Data { var data = Data(); for value in values { data.append(try encode(value)); data.append(0x1f) }; return data }
}

extension SQLiteStateStore {
    /// Operation-bound controller evidence for daemon admission. The daemon
    /// must not open the controller's Keychain receipt secret; Core promotion
    /// remains the authenticated receipt boundary. This projection is only
    /// used together with fresh signed runtime identity and exact durable
    /// operation/generation checks.
    public func bootstrapReceiptEvidence() throws -> BootstrapReceipt? {
        try bootstrapReceipt(authenticator: UnverifiedBootstrapReceiptAuthenticator())
    }

    /// Read-only coordinates for reconnect. This intentionally does not
    /// verify or authorize the receipt; only Core promotion does that.
    public func bootstrapReceiptHandoff() throws -> BootstrapReceiptHandoff? {
        var value: BootstrapReceiptHandoff?
         try query("SELECT epoch,operation_id,nonce,invocation_token_hash,phase FROM bootstrap_receipts WHERE id=1") { s in
            guard let epoch = columnString(s, 0).flatMap(UUID.init(uuidString:)),
                  let operation = columnString(s, 1).flatMap(UUID.init(uuidString:)),
                  let nonce = columnString(s, 2).flatMap(UUID.init(uuidString:)),
                  let token = columnString(s, 3),
                  let phase = columnString(s, 4).flatMap({ BootstrapReceiptPhase(rawValue: $0) }) else { throw SQLiteStateError.invalidRecord }
            value = .init(invocationToken: token, epoch: epoch, operationID: operation, nonce: nonce, phase: phase)
        }
        return value
    }

    public func bootstrapReceipt(authenticator: any BootstrapReceiptAuthenticator = InMemoryBootstrapReceiptAuthenticator()) throws -> BootstrapReceipt? {
        var result: BootstrapReceipt?
         try query("SELECT bundle_id,agent_label,bundle_program,endpoint,epoch,operation_id,nonce,invocation_token_hash,invocation_user,invocation_uid,invocation_id,generation,preflight_provenance_json,registration_evidence_json,expires_at,phase,executor_state,executor_detail,post_observation_json,integrity_digest FROM bootstrap_receipts WHERE id=1") { s in
             guard let b=columnString(s,0), let l=columnString(s,1), let p=columnString(s,2), let e=columnString(s,3), let epoch=columnString(s,4).flatMap(UUID.init(uuidString:)), let op=columnString(s,5).flatMap(UUID.init(uuidString:)), let nonce=columnString(s,6).flatMap(UUID.init(uuidString:)), let token=columnString(s,7), let user=columnString(s,8), let invocationID=columnString(s,10).flatMap(UUID.init(uuidString:)), let provenanceData=columnString(s,12)?.data(using: .utf8), let provenance=try? JSONDecoder().decode(BootstrapReceiptProvenance.self, from: provenanceData), let expires=columnString(s,14), let date=BootstrapReceiptDateFormatter.date(from: expires), let phase=columnString(s,15).flatMap(BootstrapReceiptPhase.init(rawValue:)), let digest=columnString(s,19) else { throw SQLiteStateError.invalidRecord }
              let observation = columnString(s,18).flatMap {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                return try? decoder.decode(LifecycleObservationVector.self, from: Data($0.utf8))
            }
              let evidence = columnString(s,13).flatMap { try? JSONDecoder().decode(BootstrapRegistrationEvidence.self, from: Data($0.utf8)) }
              result = .init(target: .init(bundleID:b, agentLabel:l, bundleProgram:p, endpoint:e), epoch:epoch, operationID:op, nonce:nonce, invocationToken:token, invocationUser:user, invocationUID: UInt32(sqlite3_column_int64(s,9)), invocationID: invocationID, generation: sqlite3_column_int64(s,11), preflightProvenance: provenance, registrationEvidence: evidence, expiresAt:date, phase:phase, executorState: columnString(s,16).flatMap(LifecycleExecutorResultState.init(rawValue:)), executorDetail: columnString(s,17), postObservation: observation, integrityDigest:digest)
         }
         if let receipt = result {
             var tokenColumnsAgree = false
             try query("SELECT invocation_token_hash = invocation_token FROM bootstrap_receipts WHERE id=1") { tokenColumnsAgree = sqlite3_column_int($0, 0) != 0 }
              guard tokenColumnsAgree, try authenticator.verifies(mac: receipt.integrityDigest, for: receipt.canonicalData()) else { throw BootstrapError.invalidReceipt }
         }
         return result
    }
     fileprivate func reserveBootstrapReceipt(_ receipt: BootstrapReceipt, now: Date, authenticator: any BootstrapReceiptAuthenticator = KeychainBootstrapReceiptAuthenticator.shared) throws { guard try authenticator.verifies(mac: receipt.integrityDigest, for: receipt.canonicalData()) else { throw BootstrapError.invalidReceipt }; try transaction { guard receipt.target == LifecycleCanonicalIdentity.target, receipt.expiresAt > now else { throw BootstrapError.invalidReceipt }; let q = Self.quote; let provenance = q(String(decoding: try JSONEncoder.bootstrap().encode(receipt.preflightProvenance), as: UTF8.self)); let tokenHash = SQLiteStateStore.safeTokenHash(receipt.invocationToken); try execute("INSERT INTO bootstrap_receipts (id,bundle_id,agent_label,bundle_program,endpoint,epoch,operation_id,nonce,invocation_token_hash,invocation_token,invocation_user,invocation_uid,invocation_id,generation,preflight_provenance_json,expires_at,phase,integrity_digest) VALUES (1,'\(q(receipt.target.bundleID))','\(q(receipt.target.agentLabel))','\(q(receipt.target.bundleProgram))','\(q(receipt.target.endpoint))','\(receipt.epoch.uuidString)','\(receipt.operationID.uuidString)','\(receipt.nonce.uuidString)','\(tokenHash)','\(tokenHash)','\(q(receipt.invocationUser))',\(receipt.invocationUID),'\(receipt.invocationID.uuidString)',\(receipt.generation),'\(provenance)','\(BootstrapReceiptDateFormatter.string(from: receipt.expiresAt))','reserved','\(q(receipt.integrityDigest))')") } }
     fileprivate func recordBootstrapReceipt(_ receipt: BootstrapReceipt, authenticator: any BootstrapReceiptAuthenticator = KeychainBootstrapReceiptAuthenticator.shared) throws { guard try authenticator.verifies(mac: receipt.integrityDigest, for: receipt.canonicalData()) else { throw BootstrapError.invalidReceipt }; let q=Self.quote; let obs=receipt.postObservation.flatMap { try? String(decoding: JSONEncoder.bootstrap().encode($0), as: UTF8.self) }.map { "'\(q($0))'" } ?? "NULL"; let evidence=receipt.registrationEvidence.flatMap { try? String(decoding: JSONEncoder.bootstrap().encode($0), as: UTF8.self) }.map { "'\(q($0))'" } ?? "NULL"; try execute("UPDATE bootstrap_receipts SET phase='\(receipt.phase.rawValue)',executor_state='\(receipt.executorState?.rawValue ?? "unknown")',executor_detail=\(receipt.executorDetail.map { "'\(q($0))'" } ?? "NULL"),post_observation_json=\(obs),registration_evidence_json=\(evidence),integrity_digest='\(q(receipt.integrityDigest))' WHERE id=1 AND phase='reserved'") }
      public func recordBootstrapRecovery(_ record: BootstrapRecoveryRecord) throws { let q = Self.quote; let a = record.authorization; try execute("INSERT OR REPLACE INTO bootstrap_recovery (id,epoch,operation_id,invocation_id,bundle_id,agent_label,bundle_program,endpoint,state,detail,observed_at) VALUES (1,'\(a.epoch.uuidString)','\(a.operationID.uuidString)','\(a.invocationID.uuidString)','\(q(a.target.bundleID))','\(q(a.target.agentLabel))','\(q(a.target.bundleProgram))','\(q(a.target.endpoint))','\(record.state.rawValue)','\(q(record.detail))','\(record.observedAt.timeIntervalSince1970)')") }
      /// Preserves an authenticated terminal receipt in history before
      /// releasing the singleton current-receipt barrier. This is the only
      /// durable clearing operation used by the known-receipt recovery path.
       public func archiveSucceededReceiptForRecovery(_ receipt: BootstrapReceipt, source: String, authenticator: any BootstrapReceiptAuthenticator) throws {
          guard receipt.phase == .succeeded, receipt.expiresAt <= Date(),
                try authenticator.verifies(mac: receipt.integrityDigest, for: receipt.canonicalData()) else { throw BootstrapError.invalidReceipt }
          let q = Self.quote
          let json = String(decoding: try JSONEncoder.bootstrap().encode(receipt), as: UTF8.self)
          try transaction {
              try execute("INSERT INTO bootstrap_receipt_history (source,epoch,operation_id,receipt_json,archived_at) VALUES ('\(q(source))','\(receipt.epoch.uuidString)','\(receipt.operationID.uuidString)','\(q(json))',CURRENT_TIMESTAMP)")
              try execute("DELETE FROM bootstrap_receipts WHERE id=1 AND operation_id='\(receipt.operationID.uuidString)' AND invocation_id='\(receipt.invocationID.uuidString)' AND phase='succeeded'")
              var deleted = false
              try query("SELECT changes()") { deleted = sqlite3_column_int($0, 0) == 1 }
              guard deleted else { throw BootstrapError.recoveryRequired("Known receipt changed before archival completed.") }
          }
      }
       public func bootstrapRecoveryRecord() throws -> BootstrapRecoveryRecord? { var result: BootstrapRecoveryRecord?; try query("SELECT epoch,operation_id,invocation_id,bundle_id,agent_label,bundle_program,endpoint,state,detail,observed_at FROM bootstrap_recovery WHERE id=1") { s in guard let e=columnString(s,0).flatMap(UUID.init(uuidString:)), let o=columnString(s,1).flatMap(UUID.init(uuidString:)), let i=columnString(s,2).flatMap(UUID.init(uuidString:)), let b=columnString(s,3), let l=columnString(s,4), let p=columnString(s,5), let endpoint=columnString(s,6), let state=columnString(s,7).flatMap(BootstrapRecoveryState.init(rawValue:)), let detail=columnString(s,8), let observed=Double(columnString(s,9) ?? "") else { throw SQLiteStateError.invalidRecord }; let target = LifecycleTargetIdentity(bundleID:b, agentLabel:l, bundleProgram:p, endpoint:endpoint); result = .init(authorization: .init(epoch:e, operationID:o, invocationID:i, target:target), state:state, detail:detail, observedAt:Date(timeIntervalSince1970: observed)) }; return result }
      public func bootstrapRecoveryState() throws -> BootstrapRecoveryState? {
          var state: BootstrapRecoveryState?
          try query("SELECT state FROM bootstrap_recovery WHERE id=1") { state = columnString($0,0).flatMap(BootstrapRecoveryState.init(rawValue:)) }
          return state
      }
      public func bootstrapRecoverySource() throws -> String? {
          var source: String?
          try query("SELECT source FROM bootstrap_recovery WHERE id=1") { source = columnString($0,0) }
          return source
      }
      /// Archives the exact legacy row before a later explicit fresh Start
      /// needs the singleton current-receipt slot. The historical payload is
      /// retained; this is not deletion of unrelated history.
      public func archiveLegacyReceiptForFreshBootstrap(now: Date = Date()) throws {
          guard try bootstrapRecoveryState() == .succeeded,
                try bootstrapRecoverySource() == LegacyBootstrapRecoveryAuthorization.source else { throw BootstrapError.recoveryRequired("Legacy recovery has not completed.") }
          try transaction {
              var fields = [String: String]()
              try query("SELECT bundle_id,agent_label,bundle_program,endpoint,epoch,operation_id,nonce,invocation_token_hash,invocation_token,invocation_user,invocation_uid,invocation_id,generation,preflight_provenance_json,expires_at,phase,executor_state,executor_detail,post_observation_json,integrity_digest FROM bootstrap_receipts WHERE id=1") { s in
                  guard columnString(s, 0) == LifecycleCanonicalIdentity.target.bundleID,
                        columnString(s, 1) == LifecycleCanonicalIdentity.target.agentLabel,
                        columnString(s, 2) == LifecycleCanonicalIdentity.target.bundleProgram,
                        columnString(s, 3) == LifecycleCanonicalIdentity.target.endpoint,
                        columnString(s, 4) == LegacyBootstrapRecoveryAuthorization.epoch.uuidString,
                        columnString(s, 5) == LegacyBootstrapRecoveryAuthorization.operationID.uuidString,
                        columnString(s, 11)?.isEmpty == true,
                        columnString(s, 14).flatMap(Double.init).map({ $0 <= now.timeIntervalSince1970 }) == true,
                        columnString(s, 15) == BootstrapReceiptPhase.succeeded.rawValue else {
                      throw BootstrapError.recoveryRequired("Current receipt is not the exact expired legacy pre-invocation orphan.")
                  }
                  let names = ["bundle_id","agent_label","bundle_program","endpoint","epoch","operation_id","nonce","invocation_token_hash","invocation_token","invocation_user","invocation_uid","invocation_id","generation","preflight_provenance_json","expires_at","phase","executor_state","executor_detail","post_observation_json","integrity_digest"]
                  for (index,name) in names.enumerated() { fields[name] = columnString(s, Int32(index)) ?? "<NULL>" }
              }
              if fields.isEmpty {
                  // A prior modern Start may have completed archival before
                  // failing later in its own pre-platform checks. Treat the
                  // already-archived exact orphan as idempotently complete;
                  // never delete or rewrite anything in this case.
                  var archived = false
                  try query("SELECT 1 FROM bootstrap_receipt_history WHERE source='\(Self.quote(LegacyBootstrapRecoveryAuthorization.source))' AND epoch='\(LegacyBootstrapRecoveryAuthorization.epoch.uuidString)' AND operation_id='\(LegacyBootstrapRecoveryAuthorization.operationID.uuidString)' LIMIT 1") { archived = sqlite3_column_int($0, 0) == 1 }
                  guard archived else { throw BootstrapError.recoveryRequired("Legacy receipt is absent and its exact historical archive is unavailable.") }
                  return
              }
              let json = String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
              let q=Self.quote
              try execute("INSERT INTO bootstrap_receipt_history (source,epoch,operation_id,receipt_json,archived_at) VALUES ('\(q(LegacyBootstrapRecoveryAuthorization.source))','\(q(fields["epoch"]!))','\(q(fields["operation_id"]!))','\(q(json))',CURRENT_TIMESTAMP)")
              try execute("DELETE FROM bootstrap_receipts WHERE id=1 AND bundle_id='\(q(LifecycleCanonicalIdentity.target.bundleID))' AND agent_label='\(q(LifecycleCanonicalIdentity.target.agentLabel))' AND bundle_program='\(q(LifecycleCanonicalIdentity.target.bundleProgram))' AND endpoint='\(q(LifecycleCanonicalIdentity.target.endpoint))' AND epoch='\(LegacyBootstrapRecoveryAuthorization.epoch.uuidString)' AND operation_id='\(LegacyBootstrapRecoveryAuthorization.operationID.uuidString)' AND invocation_id='' AND phase='succeeded'")
              var deleted = false
              try query("SELECT changes()") { deleted = sqlite3_column_int($0, 0) == 1 }
              guard deleted else { throw BootstrapError.recoveryRequired("Legacy receipt changed before archival completed.") }
          }
      }
      public func legacyBootstrapReceipt() throws -> LegacyBootstrapReceipt? {
          var result: LegacyBootstrapReceipt?
          try query("SELECT bundle_id,agent_label,bundle_program,endpoint,epoch,operation_id,invocation_id,expires_at,phase FROM bootstrap_receipts WHERE id=1") { s in
              guard let b=columnString(s,0), let l=columnString(s,1), let p=columnString(s,2), let e=columnString(s,3),
                    let epoch=columnString(s,4).flatMap(UUID.init(uuidString:)), let op=columnString(s,5).flatMap(UUID.init(uuidString:)),
                    let invocationID=columnString(s,6), invocationID.isEmpty,
                    let expiry=columnString(s,7).flatMap(BootstrapReceiptDateFormatter.date),
                    let phase=columnString(s,8).flatMap({ BootstrapReceiptPhase(rawValue: $0) }) else { throw SQLiteStateError.invalidRecord }
              result = .init(target: .init(bundleID:b,agentLabel:l,bundleProgram:p,endpoint:e), epoch:epoch, operationID:op, expiresAt:expiry, phase:phase)
          }
          return result
      }
       public func recordLegacyBootstrapRecovery(_ record: LegacyBootstrapRecoveryRecord) throws {
          let q=Self.quote; let a=record.authorization
          try execute("INSERT OR REPLACE INTO bootstrap_recovery (id,epoch,operation_id,invocation_id,bundle_id,agent_label,bundle_program,endpoint,state,detail,observed_at,source) VALUES (1,'\(a.epoch.uuidString)','\(a.operationID.uuidString)','', '\(q(a.target.bundleID))','\(q(a.target.agentLabel))','\(q(a.target.bundleProgram))','\(q(a.target.endpoint))','\(record.state.rawValue)','\(q(record.detail))','\(record.observedAt.timeIntervalSince1970)','\(q(record.source))')")
       }
       /// Archives a promoted handoff only after Core has durably completed the
       /// matching Off generation and fresh external absence was observed.
       fileprivate func archivePromotedReceiptAfterRecoveredOff(_ receipt: BootstrapReceipt, authenticator: any BootstrapReceiptAuthenticator) throws {
           guard receipt.phase == .promoted,
                 try authenticator.verifies(mac: receipt.integrityDigest, for: receipt.canonicalData()) else { throw BootstrapError.invalidReceipt }
           let q = Self.quote
           let json = String(decoding: try JSONEncoder.bootstrap().encode(receipt), as: UTF8.self)
           try transaction {
               try execute("INSERT INTO bootstrap_receipt_history (source,epoch,operation_id,receipt_json,archived_at) VALUES ('OFF RECOVERY AFTER FRESH ABSENCE','\(receipt.epoch.uuidString)','\(receipt.operationID.uuidString)','\(q(json))',CURRENT_TIMESTAMP)")
               try execute("DELETE FROM bootstrap_receipts WHERE id=1 AND operation_id='\(receipt.operationID.uuidString)' AND invocation_id='\(receipt.invocationID.uuidString)' AND phase='promoted'")
               var deleted = false
               try query("SELECT changes()") { deleted = sqlite3_column_int($0, 0) == 1 }
               guard deleted else { throw BootstrapError.recoveryRequired("Promoted receipt changed before Off recovery archival.") }
           }
       }
       public func archivePromotedReceiptAfterRecoveredOffWithRejectedMAC(_ receipt: BootstrapReceipt) throws {
           guard receipt.phase == .promoted else { throw BootstrapError.invalidReceipt }
           let q = Self.quote
           let json = String(decoding: try JSONEncoder.bootstrap().encode(receipt), as: UTF8.self)
           try transaction {
               try execute("INSERT INTO bootstrap_receipt_history (source,epoch,operation_id,receipt_json,archived_at) VALUES ('OFF RECOVERY AFTER FRESH ABSENCE (MAC REJECTED)','\(receipt.epoch.uuidString)','\(receipt.operationID.uuidString)','\(q(json))',CURRENT_TIMESTAMP)")
               try execute("DELETE FROM bootstrap_receipts WHERE id=1 AND operation_id='\(receipt.operationID.uuidString)' AND invocation_id='\(receipt.invocationID.uuidString)' AND phase='promoted'")
               var deleted = false
               try query("SELECT changes()") { deleted = sqlite3_column_int($0, 0) == 1 }
               guard deleted else { throw BootstrapError.recoveryRequired("Promoted receipt changed before rejected-MAC archival.") }
           }
       }
       /// Preserves the completed legacy recovery fence before the singleton
       /// current-fence row is reused for the distinct modern orphan.
       public func archiveLegacyRecoveryFence() throws {
           try transaction {
               var values = [String](repeating: "", count: 7)
               try query("SELECT source,epoch,operation_id,invocation_id,state,detail,observed_at FROM bootstrap_recovery WHERE id=1") { s in
                   for index in 0..<7 { values[index] = columnString(s, Int32(index)) ?? "" }
               }
               guard values[0] == LegacyBootstrapRecoveryAuthorization.source,
                     values[1] == LegacyBootstrapRecoveryAuthorization.epoch.uuidString,
                     values[2] == LegacyBootstrapRecoveryAuthorization.operationID.uuidString,
                     values[3].isEmpty,
                     values[4] == BootstrapRecoveryState.succeeded.rawValue else {
                   throw BootstrapError.recoveryRequired("The completed legacy recovery fence is not exact.")
               }
               let q = Self.quote
               try execute("INSERT OR IGNORE INTO bootstrap_recovery_history (source,epoch,operation_id,invocation_id,state,detail,observed_at,archived_at) VALUES ('\(q(values[0]))','\(q(values[1]))','\(q(values[2]))','\(q(values[3]))','\(q(values[4]))','\(q(values[5]))','\(q(values[6]))',CURRENT_TIMESTAMP)")
           }
       }
     fileprivate static func quote(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
}

private struct UnverifiedBootstrapReceiptAuthenticator: BootstrapReceiptAuthenticator {
    func mac(for data: Data) throws -> String { throw BootstrapError.invalidReceipt }
    func verifies(mac: String, for data: Data) throws -> Bool { true }
}

private enum BootstrapReceiptDateFormatter {
    static func string(from date: Date) -> String { String(format: "%.17g", date.timeIntervalSince1970) }
    static func date(from value: String) -> Date? {
        if let seconds = Double(value) { return Date(timeIntervalSince1970: seconds) }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }
}

extension LifecycleStateRepository {
    /// Core establishes its own signed-controller binding from the fresh
    /// production observation before it reads a receipt for promotion.
    public func authorizeBootstrapReceiptAccess(provenance: BootstrapReceiptProvenance) throws {
        guard provenance.bundleID == canonicalTarget.bundleID,
              provenance.agentLabel == canonicalTarget.agentLabel,
              provenance.bundleProgram == canonicalTarget.bundleProgram,
              provenance.signingTeam == LifecycleCanonicalIdentity.teamIdentifier,
              !provenance.designatedRequirement.isEmpty,
              !provenance.artifactHash.isEmpty else { throw BootstrapError.invalidReceipt }
        try receiptAuthenticator?.authorize(provenance: provenance)
    }
    public struct BootstrapPromotionContext: Sendable {
        public let operationID: UUID
        public let generation: Int64
        public init(operationID: UUID, generation: Int64) { self.operationID = operationID; self.generation = generation }
    }
    public func bootstrapPromotionContext(invocationToken: String, epoch: UUID, operationID: UUID, nonce: UUID) throws -> BootstrapPromotionContext {
         guard let receipt = try (receiptAuthenticator.map { try store.bootstrapReceipt(authenticator: $0) } ?? store.bootstrapReceiptEvidence()), receipt.phase == .succeeded,
               receipt.target == canonicalTarget, SQLiteStateStore.safeTokenHash(receipt.invocationToken) == SQLiteStateStore.safeTokenHash(invocationToken),
              receipt.epoch == epoch, receipt.operationID == operationID, receipt.nonce == nonce else { throw BootstrapError.invalidReceipt }
        return .init(operationID: receipt.operationID, generation: (try intent()?.generation ?? 0) + 1)
    }
    /// Core-only handoff. It consumes the one receipt and creates the normal
    /// journal row in the same SQLite transaction; no client may call this
    /// through the ordinary lifecycle On method.
    public func promoteBootstrap(invocationToken: String, observation: LifecycleObservationVector, epoch: UUID, operationID: UUID, nonce: UUID, now: Date = Date(), lockEndpoint: String? = nil) throws -> LifecycleStatusResult {
         guard let receipt = try (receiptAuthenticator.map { try store.bootstrapReceipt(authenticator: $0) } ?? store.bootstrapReceiptEvidence()), receipt.phase == .succeeded,
               receipt.target == canonicalTarget, SQLiteStateStore.safeTokenHash(receipt.invocationToken) == SQLiteStateStore.safeTokenHash(invocationToken),
                epoch == receipt.epoch,
                operationID == receipt.operationID,
                nonce == receipt.nonce,
               receipt.expiresAt >= now,
               let prior = receipt.postObservation, observation.observedAt > prior.observedAt,
                observation.bundlePresent == .true,
                observation.layoutValid == .true,
                observation.endpointReachable == .true,
                observation.protocolCompatible == .true,
                 observation.coreReady == .true,
                 observation.signatureValid == .true,
                 observation.signingTeam != nil,
                 observation.designatedRequirement != nil,
                 observation.artifactHash != nil,
                 receipt.invocationUID == getuid(),
                 receipt.preflightProvenance.signingTeam == observation.signingTeam,
                 receipt.preflightProvenance.designatedRequirement == observation.designatedRequirement,
                 receipt.preflightProvenance.artifactHash == observation.artifactHash,
                (observation.processMatch == .unknown || observation.processMatch == .true),
                 (observation.supervisorObserved == .unknown || observation.supervisorObserved == .true),
                 receipt.registrationEvidence?.operationID == receipt.operationID,
                 receipt.registrationEvidence?.invocationID == receipt.invocationID,
                 receipt.registrationEvidence?.generation == receipt.generation,
                 receipt.registrationEvidence?.uid == getuid(),
                 receipt.registrationEvidence?.signingTeam == receipt.preflightProvenance.signingTeam,
                 (try? intent()?.intent) != .on,
                 ((try? intent())??.generation ?? 0) < receipt.generation,
                   true else { throw BootstrapError.invalidReceipt }
         if let receiptAuthenticator {
             guard try receiptAuthenticator.verifies(mac: receipt.integrityDigest, for: receipt.canonicalData()) else { throw BootstrapError.invalidReceipt }
         }
         // Core joins the shared handoff lease while bootstrap remains alive.
         // This both proves that the persistent handoff path is usable and
         // prevents an ordinary exclusive lifecycle operation from entering.
         // Never unlink the path: it may belong to a newer owner.
         let handoffLock: BootstrapLock
         do { handoffLock = try BootstrapLock.acquireExisting(endpoint: lockEndpoint ?? canonicalTarget.endpoint) }
         catch { throw BootstrapError.invalidReceipt }
         defer { handoffLock.release() }
          let correlation = (try? store.bootstrapInvocationID(token: invocationToken)) ?? UUID()
          try? store.recordDiagnostic(.init(correlationID: correlation, phase: .promotion, outcome: "started", detail: "Core promotion admission", databasePath: store.databaseURL.path, invocationID: correlation, tokenHash: SQLiteStateStore.safeTokenHash(invocationToken), operationID: operationID))
          let result: LifecycleStatusResult = try store.transaction {
            // The receipt is consumed in this same transaction.  Thus an
            // already promoted receipt cannot be replayed, and an explicit
            // bootstrap is the sole operation allowed to fence Off with a
            // newer On generation.
             let generation = receipt.generation
            let q = { (v: String) in v.replacingOccurrences(of: "'", with: "''") }
             let handoffObservation = LifecycleObservationVector(bundlePresent: observation.bundlePresent, layoutValid: observation.layoutValid, signatureValid: observation.signatureValid, registrationMatch: .true, processMatch: observation.processMatch, endpointReachable: observation.endpointReachable, protocolCompatible: observation.protocolCompatible, coreReady: observation.coreReady, supervisorObserved: observation.supervisorObserved, signingTeam: observation.signingTeam, designatedRequirement: observation.designatedRequirement, artifactHash: observation.artifactHash, processIdentity: observation.processIdentity, observedAt: observation.observedAt, source: observation.source, reason: observation.reason)
             let pre = String(decoding: try JSONEncoder().encode(handoffObservation), as: UTF8.self)
            try store.execute("INSERT OR REPLACE INTO lifecycle_intent (id,intent,generation,operation_id,actor,bundle_id,agent_label,bundle_program,endpoint) VALUES (1,'on',\(generation),'\(receipt.operationID.uuidString)','bootstrap','\(q(canonicalTarget.bundleID))','\(q(canonicalTarget.agentLabel))','\(q(canonicalTarget.bundleProgram))','\(q(canonicalTarget.endpoint))')")
             try store.execute("INSERT INTO lifecycle_operations (operation_id,generation,kind,state,pre_observation_json,post_observation_json,created_at) VALUES ('\(receipt.operationID.uuidString)',\(generation),'register','succeeded','\(q(pre))','\(q(pre))',CURRENT_TIMESTAMP)")
              try store.execute("INSERT OR REPLACE INTO lifecycle_ownership (id,bundle_id,agent_label,bundle_program,endpoint,signing_team,designated_requirement,artifact_hash,operation_id,generation) VALUES (1,'\(q(canonicalTarget.bundleID))','\(q(canonicalTarget.agentLabel))','\(q(canonicalTarget.bundleProgram))','\(q(canonicalTarget.endpoint))','\(q(observation.signingTeam!))','\(q(observation.designatedRequirement!))','\(q(observation.artifactHash!))','\(receipt.operationID.uuidString)',\(generation))")
              let promoted: BootstrapReceipt
              let updated = receipt.updated(phase: .promoted, executorState: receipt.executorState ?? .success, detail: receipt.executorDetail, postObservation: receipt.postObservation ?? observation, registrationEvidence: receipt.registrationEvidence)
              if let receiptAuthenticator { promoted = try updated.withMAC(using: receiptAuthenticator) }
              else {
                  promoted = .init(target: updated.target, epoch: updated.epoch, operationID: updated.operationID, nonce: updated.nonce, invocationToken: updated.invocationToken, invocationUser: updated.invocationUser, invocationUID: updated.invocationUID, invocationID: updated.invocationID, generation: updated.generation, preflightProvenance: updated.preflightProvenance, registrationEvidence: updated.registrationEvidence, expiresAt: updated.expiresAt, phase: updated.phase, executorState: updated.executorState, executorDetail: updated.executorDetail, postObservation: updated.postObservation, integrityDigest: receipt.integrityDigest)
              }
             try store.execute("UPDATE bootstrap_receipts SET phase='promoted',integrity_digest='\(q(promoted.integrityDigest))' WHERE id=1 AND phase='succeeded' AND epoch='\(receipt.epoch.uuidString)' AND operation_id='\(receipt.operationID.uuidString)' AND nonce='\(receipt.nonce.uuidString)'")
             return .init(intent: try self.intent(), operation: try self.operation(), observation: handoffObservation, readiness: handoffObservation.isReady ? .ready : .unknown)
        }
         try? store.recordDiagnostic(.init(correlationID: correlation, phase: .promotion, outcome: "success", detail: "Core promotion committed", databasePath: store.databaseURL.path, invocationID: correlation, tokenHash: SQLiteStateStore.safeTokenHash(invocationToken), operationID: operationID))
         return result
    }
}
