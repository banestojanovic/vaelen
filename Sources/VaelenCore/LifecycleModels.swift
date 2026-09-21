import Foundation
import SQLite3

public enum LifecycleIntent: String, Codable, Equatable, Sendable { case on, off }
public enum LifecycleOperationKind: String, Codable, Equatable, Sendable { case register, unregister }
public enum LifecycleJournalState: String, Codable, Equatable, Sendable { case pending, inFlight = "in-flight", succeeded, failed, unknownRecoveryRequired = "unknown/recovery-required" }
public enum ObservationValue: String, Codable, Equatable, Sendable { case `true`, `false`, unknown, stale, incompatible }

/// Ephemeral identity evidence used to fence PID reuse; it is not durable ownership.
public struct LifecycleProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32; public let startIdentity: String; public let uid: UInt32; public let executablePath: String
    public init(pid: Int32, startIdentity: String, uid: UInt32, executablePath: String) { self.pid = pid; self.startIdentity = startIdentity; self.uid = uid; self.executablePath = executablePath }
}

/// Two disagreeing observations are ambiguity and must never authorize action.
public enum LifecycleProcessIdentityValidator {
    public static func evaluate(first: LifecycleProcessIdentity?, second: LifecycleProcessIdentity?, expectedPath: String, expectedUID: UInt32, readable: Bool = true) -> ObservationValue {
        guard readable else { return .unknown }
        guard let first, let second else { return first == nil && second == nil ? .false : .unknown }
        guard first == second else { return .unknown }
        return first.uid == expectedUID && first.executablePath == expectedPath ? .true : .false
    }
}

public struct LifecycleTargetIdentity: Codable, Equatable, Sendable {
    public let bundleID: String; public let agentLabel: String; public let bundleProgram: String; public let endpoint: String
    public init(bundleID: String, agentLabel: String, bundleProgram: String, endpoint: String) { self.bundleID = bundleID; self.agentLabel = agentLabel; self.bundleProgram = bundleProgram; self.endpoint = endpoint }
}

/// The only lifecycle identity Core is allowed to persist.  The request model
/// still carries `target` for wire compatibility, but it is never an input to
/// lifecycle state.
public enum LifecycleCanonicalIdentity {
    /// This is the product's trust boundary, not a certificate or build
    /// fingerprint.  Certificates and CodeDirectory hashes may rotate.
    public static let teamIdentifier = "TFKZJV643G"
    public static let daemonIdentifier = "vaelend"
    /// The installed product location is part of the controller-selection
    /// contract.  Bootstrap callers must not ask LaunchServices to resolve a
    /// bundle identifier, since Debug and Release artifacts may coexist.
    public static let installedControllerURL = URL(fileURLWithPath: "/Applications/Vaelen.app", isDirectory: true)
    /// Sole bounded validation exception. This is intentionally not a general
    /// arbitrary-path override or an artifact-discovery facility.
    public static let validationControllerURL = URL(fileURLWithPath: "/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260921-0035.xcarchive/Products/Applications/Vaelen.app", isDirectory: true)
    public static let controllerOverrideEnvironment = "VAELEN_BOOTSTRAP_CONTROLLER_URL"

    public static func bootstrapControllerURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let supplied = environment[controllerOverrideEnvironment] else { return installedControllerURL }
        let candidate = URL(fileURLWithPath: supplied).standardizedFileURL
        // The explicit override is still bounded to the two canonical product
        // locations.  In particular, allowing the installed path here keeps
        // the Release CLI's explicit controller selection equivalent to its
        // no-override default without reopening arbitrary-path discovery.
        guard isAllowedControllerURL(candidate) else { return nil }
        // Preserve the canonical URL representation (including its directory
        // form) rather than returning a normalized caller spelling.
        return candidate.path == installedControllerURL.path ? installedControllerURL : validationControllerURL
    }
    public static func isAllowedControllerURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == installedControllerURL.standardizedFileURL.path || path == validationControllerURL.standardizedFileURL.path
    }
    public static func accepts(appTeam: String?, appIdentifier: String?, daemonTeam: String?, daemonIdentifier: String?, daemonPath: String?, agentLabel: String?, bundleProgram: String?) -> Bool {
        appTeam == teamIdentifier && appIdentifier == target.bundleID &&
        daemonTeam == teamIdentifier && daemonIdentifier == Self.daemonIdentifier &&
        daemonPath == target.bundleProgram && agentLabel == target.agentLabel &&
        bundleProgram == target.bundleProgram
    }
    public static var target: LifecycleTargetIdentity {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let endpoint = support.appendingPathComponent("Vaelen/runtime/sockets/core.sock").path
        return .init(bundleID: "dev.vaelen.app", agentLabel: "dev.vaelen.vaelend",
                     bundleProgram: "Contents/Resources/vaelend", endpoint: endpoint)
    }
}

public struct LifecycleObservationVector: Codable, Equatable, Sendable {
    public let bundlePresent: ObservationValue; public let layoutValid: ObservationValue; public let signatureValid: ObservationValue
    public let registrationMatch: ObservationValue; public let processMatch: ObservationValue; public let endpointReachable: ObservationValue
    public let protocolCompatible: ObservationValue; public let coreReady: ObservationValue; public let supervisorObserved: ObservationValue
    /// Signature identity is observation evidence, never caller input. These
    /// fields are optional for older/test observers; ownership promotion must
    /// reject an observation which does not provide them.
    public let signingTeam: String?; public let designatedRequirement: String?; public let artifactHash: String?
    public let processIdentity: LifecycleProcessIdentity?
    public let observedAt: Date; public let source: String; public let reason: String?
    public init(bundlePresent: ObservationValue = .unknown, layoutValid: ObservationValue = .unknown, signatureValid: ObservationValue = .unknown, registrationMatch: ObservationValue = .unknown, processMatch: ObservationValue = .unknown, endpointReachable: ObservationValue = .unknown, protocolCompatible: ObservationValue = .unknown, coreReady: ObservationValue = .unknown, supervisorObserved: ObservationValue = .unknown, signingTeam: String? = nil, designatedRequirement: String? = nil, artifactHash: String? = nil, processIdentity: LifecycleProcessIdentity? = nil, observedAt: Date = Date(), source: String = "core", reason: String? = nil) {
        self.bundlePresent = bundlePresent; self.layoutValid = layoutValid; self.signatureValid = signatureValid; self.registrationMatch = registrationMatch; self.processMatch = processMatch; self.endpointReachable = endpointReachable; self.protocolCompatible = protocolCompatible; self.coreReady = coreReady; self.supervisorObserved = supervisorObserved; self.signingTeam = signingTeam; self.designatedRequirement = designatedRequirement; self.artifactHash = artifactHash; self.processIdentity = processIdentity; self.observedAt = observedAt; self.source = source; self.reason = reason
    }
    public var isReady: Bool { endpointReachable == .true && protocolCompatible == .true && coreReady == .true }
}

/// The only fact the signed controller may contribute to ordinary lifecycle
/// observation.  The controller is an SMAppService read-only witness; this
/// evidence is never an authorization to mutate or to adopt a registration.
public struct LifecycleControllerObservationRequest: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let generation: Int64
    public let intent: LifecycleIntent
    public let target: LifecycleTargetIdentity
    public let nonce: UUID
    public let sessionBinding: UUID
    public init(operationID: UUID, generation: Int64, intent: LifecycleIntent,
                target: LifecycleTargetIdentity, nonce: UUID = UUID(), sessionBinding: UUID) {
        self.operationID = operationID; self.generation = generation; self.intent = intent
        self.target = target; self.nonce = nonce; self.sessionBinding = sessionBinding
    }
}

public struct LifecycleControllerObservationResponse: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let generation: Int64
    public let target: LifecycleTargetIdentity
    public let nonce: UUID
    public let sessionBinding: UUID
    public let registrationMatch: ObservationValue
    public let source: String
    public init(operationID: UUID, generation: Int64, target: LifecycleTargetIdentity,
                nonce: UUID, sessionBinding: UUID, registrationMatch: ObservationValue,
                source: String) {
        self.operationID = operationID; self.generation = generation; self.target = target
        self.nonce = nonce; self.sessionBinding = sessionBinding
        self.registrationMatch = registrationMatch; self.source = source
    }
}

public struct LifecycleControllerMutationRequest: Codable, Equatable, Sendable {
    public let operationID: UUID; public let generation: Int64; public let intent: LifecycleIntent
    public let target: LifecycleTargetIdentity; public let nonce: UUID; public let sessionBinding: UUID
    public init(operationID: UUID, generation: Int64, intent: LifecycleIntent, target: LifecycleTargetIdentity, nonce: UUID, sessionBinding: UUID) {
        self.operationID = operationID; self.generation = generation; self.intent = intent; self.target = target; self.nonce = nonce; self.sessionBinding = sessionBinding
    }
}

public struct LifecycleControllerMutationResponse: Codable, Equatable, Sendable {
    public let operationID: UUID; public let generation: Int64; public let nonce: UUID; public let sessionBinding: UUID; public let success: Bool; public let detail: String?
    public init(operationID: UUID, generation: Int64, nonce: UUID, sessionBinding: UUID, success: Bool, detail: String? = nil) {
        self.operationID = operationID; self.generation = generation; self.nonce = nonce; self.sessionBinding = sessionBinding; self.success = success; self.detail = detail
    }
}

public enum LifecycleControllerMutationValidator {
    public static func validate(_ request: LifecycleControllerMutationRequest, controllerPath: String) -> Bool {
        request.target == LifecycleCanonicalIdentity.target && request.intent == .off &&
        LifecycleCanonicalIdentity.isAllowedControllerURL(URL(fileURLWithPath: controllerPath))
    }
    public static func validate(_ response: LifecycleControllerMutationResponse, request: LifecycleControllerMutationRequest) -> Bool {
        response.operationID == request.operationID && response.generation == request.generation &&
        response.nonce == request.nonce && response.sessionBinding == request.sessionBinding
    }
}

public enum LifecycleControllerObservationValidator {
    /// Validates the complete Core-issued binding before any controller fact
    /// is admitted into an observation vector.  In particular, a response
    /// cannot be replayed for another generation or supplied by another app.
    public static func validate(_ response: LifecycleControllerObservationResponse,
                                request: LifecycleControllerObservationRequest,
                                controllerPath: String) -> Bool {
        response.operationID == request.operationID &&
        response.generation == request.generation &&
        response.target == request.target && response.target == LifecycleCanonicalIdentity.target &&
        response.nonce == request.nonce && response.sessionBinding == request.sessionBinding &&
        response.source == "signed-canonical-controller" &&
        LifecycleCanonicalIdentity.isAllowedControllerURL(URL(fileURLWithPath: controllerPath))
    }
}

public struct LifecycleIntentRecord: Codable, Equatable, Sendable {
    public let intent: LifecycleIntent; public let generation: Int64; public let operationID: UUID; public let actor: String; public let target: LifecycleTargetIdentity
    public init(intent: LifecycleIntent, generation: Int64, operationID: UUID, actor: String, target: LifecycleTargetIdentity) { self.intent = intent; self.generation = generation; self.operationID = operationID; self.actor = actor; self.target = target }
}

public struct LifecycleOperationEvidence: Codable, Equatable, Sendable {
    public let operationID: UUID; public let generation: Int64; public let kind: LifecycleOperationKind; public let state: LifecycleJournalState
    public let preObservation: LifecycleObservationVector; public let postObservation: LifecycleObservationVector?; public let error: String?
    /// These credentials are durably bound before a platform mutation. They
    /// are intentionally evidence, not a new source of lifecycle authority.
    public let nonce: UUID?
    public let sessionBinding: UUID?
    public let processIdentity: LifecycleProcessIdentity?
    public init(operationID: UUID, generation: Int64, kind: LifecycleOperationKind, state: LifecycleJournalState, preObservation: LifecycleObservationVector, postObservation: LifecycleObservationVector? = nil, error: String? = nil, nonce: UUID? = nil, sessionBinding: UUID? = nil, processIdentity: LifecycleProcessIdentity? = nil) { self.operationID = operationID; self.generation = generation; self.kind = kind; self.state = state; self.preObservation = preObservation; self.postObservation = postObservation; self.error = error; self.nonce = nonce; self.sessionBinding = sessionBinding; self.processIdentity = processIdentity }
}
public struct LifecycleOwnershipRecord: Codable, Equatable, Sendable {
    public let target: LifecycleTargetIdentity; public let signingTeam: String?; public let designatedRequirement: String?; public let artifactHash: String?; public let operationID: UUID; public let generation: Int64
    public init(target: LifecycleTargetIdentity, signingTeam: String? = nil, designatedRequirement: String? = nil, artifactHash: String? = nil, operationID: UUID, generation: Int64) { self.target = target; self.signingTeam = signingTeam; self.designatedRequirement = designatedRequirement; self.artifactHash = artifactHash; self.operationID = operationID; self.generation = generation }
}

public enum CoreReadiness: String, Codable, Equatable, Sendable { case ready, starting, unavailable, incompatible, unknown }
public struct LifecycleStatusResult: Codable, Equatable, Sendable {
    public let intent: LifecycleIntentRecord?; public let operation: LifecycleOperationEvidence?; public let observation: LifecycleObservationVector; public let readiness: CoreReadiness
    public init(intent: LifecycleIntentRecord?, operation: LifecycleOperationEvidence?, observation: LifecycleObservationVector, readiness: CoreReadiness) { self.intent = intent; self.operation = operation; self.observation = observation; self.readiness = readiness }
}

public final class LifecycleStateRepository: @unchecked Sendable {
    let store: SQLiteStateStore
    /// Core may provide its authenticated receipt boundary. The daemon leaves
    /// this nil and consumes only controller-authenticated, operation-bound
    /// durable evidence plus its fresh signed runtime identity; it never reads
    /// the controller Keychain secret.
    let receiptAuthenticator: (any BootstrapReceiptAuthenticator)?
    public init(store: SQLiteStateStore, receiptAuthenticator: (any BootstrapReceiptAuthenticator)? = InMemoryBootstrapReceiptAuthenticator()) { self.store = store; self.receiptAuthenticator = receiptAuthenticator }
    public var canonicalTarget: LifecycleTargetIdentity { LifecycleCanonicalIdentity.target }
    /// Admission is an operation-bound durable gate, not ownership proof from
    /// the lock.  A daemon may enter serving only for a fresh On generation
    /// whose journal and provenance already exist; Core still performs fresh
    /// platform/runtime observation after the endpoint is established.
    /// Admission always consumes the daemon's just-observed platform evidence.
    /// Durable post-observations are handoff provenance only; they are never a
    /// substitute for observing the currently running process.
    public func validateDaemonAdmission(observation: LifecycleObservationVector, now: Date = Date()) throws {
        guard observation.observedAt <= now,
              now.timeIntervalSince(observation.observedAt) <= 30,
              observation.source != "core", observation.source != "synthetic",
              observation.bundlePresent == .true,
              observation.layoutValid == .true,
              observation.signatureValid == .true,
              // Registration is controller-owned evidence. The production
              // daemon observer intentionally reports `.unknown` because it
              // does not query SMAppService; the operation-bound receipt below
              // supplies that evidence at admission.
              (observation.registrationMatch == .true || observation.registrationMatch == .unknown),
              observation.processMatch == .true,
              let process = observation.processIdentity,
              process.pid == getpid(),
              process.uid == getuid(),
              Array(URL(fileURLWithPath: process.executablePath).standardizedFileURL.pathComponents.suffix(canonicalTarget.bundleProgram.split(separator: "/").count)) == canonicalTarget.bundleProgram.split(separator: "/").map(String.init),
              let team = observation.signingTeam,
              let requirement = observation.designatedRequirement,
              let artifact = observation.artifactHash,
              !team.isEmpty, !requirement.isEmpty, !artifact.isEmpty else {
            throw BootstrapError.refused("Daemon admission requires fresh, canonical runtime evidence.")
        }
        let receipt = try receiptAuthenticator.map { try store.bootstrapReceipt(authenticator: $0) } ?? store.bootstrapReceiptEvidence()
        if let receipt {
            guard receipt.target == canonicalTarget else {
                throw BootstrapError.recoveryRequired("Bootstrap receipt is missing, stale, or ambiguous.")
            }
            // A launchd daemon starts between the controller's durable result
            // and Core promotion.  The succeeded receipt is the sole
            // operation-bound admission proof for that narrow interval.
             if receipt.phase == .succeeded {
                guard receipt.expiresAt > now,
                      receipt.expiresAt.timeIntervalSince(now) <= 24 * 60 * 60,
                      receipt.preflightProvenance.bundleID == canonicalTarget.bundleID,
                      receipt.preflightProvenance.agentLabel == canonicalTarget.agentLabel,
                      receipt.preflightProvenance.bundleProgram == canonicalTarget.bundleProgram,
                      !receipt.preflightProvenance.signingTeam.isEmpty,
                      !receipt.preflightProvenance.designatedRequirement.isEmpty,
                      !receipt.preflightProvenance.artifactHash.isEmpty,
                       let post = receipt.postObservation,
                       let evidence = receipt.registrationEvidence,
                       evidence.target == canonicalTarget,
                       evidence.operationID == receipt.operationID,
                       evidence.invocationID == receipt.invocationID,
                       evidence.generation == receipt.generation,
                       evidence.uid == getuid(),
                       (observation.source != "production-observer" || evidence.executablePath == process.executablePath),
                       evidence.signingTeam == receipt.preflightProvenance.signingTeam,
                       evidence.daemonIdentifier == LifecycleCanonicalIdentity.daemonIdentifier else {
                     throw BootstrapError.recoveryRequired("Bootstrap receipt is stale or expired.")
                 }
                guard receipt.executorState == .success,
                      post.registrationMatch == .true,
                      observation.signingTeam == receipt.preflightProvenance.signingTeam,
                      observation.designatedRequirement == receipt.preflightProvenance.designatedRequirement,
                      observation.artifactHash == receipt.preflightProvenance.artifactHash else {
                    throw BootstrapError.recoveryRequired("Bootstrap result is ambiguous.")
                }
                 guard (try intent() == nil || intent()?.intent == .off),
                       (try intent()?.generation ?? 0) < receipt.generation,
                       (try store.bootstrapInvocationIDHash(receipt.invocationToken)) == receipt.invocationID else {
                     throw BootstrapError.recoveryRequired("Bootstrap receipt conflicts with a current lifecycle generation.")
                 }
                return
            }
            guard receipt.phase == .promoted else {
                throw BootstrapError.recoveryRequired("Bootstrap receipt is stale or unresolved.")
            }
            // Promoted receipts are historical handoff evidence.  Their
            // expiry is not a lease on the daemon; current On journal and
            // ownership below remain authoritative after restart.
            guard let currentIntent = try intent(), currentIntent.intent == .on,
                  currentIntent.operationID == receipt.operationID,
                  let operation = try operation(), operation.operationID == currentIntent.operationID,
                  operation.generation == currentIntent.generation,
                  operation.kind == .register, operation.state == .succeeded,
                  let ownership = try ownership(), ownership.target == canonicalTarget,
                  ownership.operationID == operation.operationID,
                  ownership.generation == operation.generation,
                  ownership.signingTeam == receipt.preflightProvenance.signingTeam,
                  ownership.designatedRequirement == receipt.preflightProvenance.designatedRequirement,
                  ownership.artifactHash == receipt.preflightProvenance.artifactHash,
                   operation.postObservation != nil,
                   observation.signingTeam == ownership.signingTeam,
                   observation.designatedRequirement == ownership.designatedRequirement,
                   observation.artifactHash == ownership.artifactHash else {
                throw BootstrapError.refused("Promoted bootstrap provenance is not current and unambiguous.")
            }
        }
        guard let intent = try intent(), intent.intent == .on,
              let operation = try operation(), operation.operationID == intent.operationID,
              operation.generation == intent.generation,
              operation.kind == .register, operation.state == .succeeded,
              let ownership = try ownership(), ownership.target == canonicalTarget,
              ownership.operationID == operation.operationID,
              ownership.generation == operation.generation,
               observation.signingTeam == ownership.signingTeam,
               observation.designatedRequirement == ownership.designatedRequirement,
               observation.artifactHash == ownership.artifactHash else {
            throw BootstrapError.refused("Daemon admission is not authorized by a current On generation.")
        }
    }
    /// A bootstrap receipt is a Core-wide platform-attempt barrier.  Ordinary
    /// lifecycle requests may only proceed once the receipt has been promoted;
    /// checking this while holding the exclusive handoff lease also prevents a
    /// concurrent bootstrap from being superseded between the read and the
    /// journal write.
    public func requireBootstrapPromotion() throws {
        do {
            let receipt = try receiptAuthenticator.map { try store.bootstrapReceipt(authenticator: $0) } ?? store.bootstrapReceiptEvidence()
            guard let receipt else { return }
            guard receipt.phase == .promoted else {
                throw BootstrapError.recoveryRequired("Bootstrap receipt is \(receipt.phase.rawValue); recovery is required before lifecycle changes.")
            }
        } catch let error as BootstrapError {
            throw error
        } catch {
            throw BootstrapError.recoveryRequired("Bootstrap receipt is malformed; recovery is required before lifecycle changes.")
        }
    }
    public func intent() throws -> LifecycleIntentRecord? {
        var result: LifecycleIntentRecord?
        try store.query("SELECT intent,generation,operation_id,actor,bundle_id,agent_label,bundle_program,endpoint FROM lifecycle_intent WHERE id=1") { s in
            guard let intent = store.columnString(s,0).flatMap(LifecycleIntent.init(rawValue:)), let op = store.columnString(s,2).flatMap(UUID.init(uuidString:)), let actor = store.columnString(s,3), let b = store.columnString(s,4), let l = store.columnString(s,5), let p = store.columnString(s,6), let e = store.columnString(s,7) else { throw SQLiteStateError.invalidRecord }
            let target = LifecycleTargetIdentity(bundleID:b, agentLabel:l, bundleProgram:p, endpoint:e)
            guard target == canonicalTarget else { throw SQLiteStateError.invalidRecord }
            result = .init(intent: intent, generation: Int64(sqlite3_column_int64(s,1)), operationID: op, actor: actor, target: target)
        }; return result
    }
    public func request(intent: LifecycleIntent, actor: String, target: LifecycleTargetIdentity, preObservation: LifecycleObservationVector = .init(), operationID: UUID = UUID(), nonce: UUID? = nil, sessionBinding: UUID? = nil, processIdentity: LifecycleProcessIdentity? = nil) throws -> LifecycleOperationEvidence {
        try store.transaction {
            let generation = (try self.intent()?.generation ?? 0) + 1; let id = operationID; let q = { (v: String) in v.replacingOccurrences(of: "'", with: "''") }
            let canonical = self.canonicalTarget
            // A newer intent makes any older dispatched work recovery-required;
            // it must not remain indistinguishable from active work after the
            // fence is installed.
            try store.execute("UPDATE lifecycle_operations SET state='unknown/recovery-required', error='Superseded by a newer lifecycle intent' WHERE state='in-flight'")
            try store.execute("INSERT OR REPLACE INTO lifecycle_intent (id,intent,generation,operation_id,actor,bundle_id,agent_label,bundle_program,endpoint) VALUES (1,'\(intent.rawValue)',\(generation),'\(id.uuidString)','\(q(actor))','\(q(canonical.bundleID))','\(q(canonical.agentLabel))','\(q(canonical.bundleProgram))','\(q(canonical.endpoint))')")
            let kind: LifecycleOperationKind = intent == .on ? .register : .unregister
            let nonceSQL = nonce.map { "'\($0.uuidString)'" } ?? "NULL"
            let sessionSQL = sessionBinding.map { "'\($0.uuidString)'" } ?? "NULL"
            let processSQL = processIdentity.flatMap { try? String(decoding: IPCJSON.encode($0), as: UTF8.self) }.map { "'\(q($0))'" } ?? "NULL"
            try store.execute("INSERT INTO lifecycle_operations (operation_id,generation,kind,state,pre_observation_json,created_at,nonce,session_binding,process_identity_json) VALUES ('\(id.uuidString)',\(generation),'\(kind.rawValue)','pending','\(q(String(decoding: try IPCJSON.encode(preObservation), as: UTF8.self)))',CURRENT_TIMESTAMP,\(nonceSQL),\(sessionSQL),\(processSQL))")
            return .init(operationID:id, generation:generation, kind:kind, state:.pending, preObservation:preObservation, nonce: nonce, sessionBinding: sessionBinding, processIdentity: processIdentity)
        }
    }
    public func accepts(operationID: UUID, generation: Int64) throws -> Bool {
        guard let current = try intent(), current.operationID == operationID, current.generation == generation else { return false }
        guard let operation = try operation() else { return false }
        return operation.state == .pending || operation.state == .inFlight
    }
    /// Atomically claims a pending operation for dispatch. A false result is
    /// a generation/terminal fence; the caller must not invoke the executor.
    @discardableResult
    public func markInFlight(operationID: UUID, generation: Int64) throws -> Bool {
        try store.execute("UPDATE lifecycle_operations SET state='in-flight' WHERE operation_id='\(operationID.uuidString)' AND generation=\(generation) AND state='pending' AND EXISTS (SELECT 1 FROM lifecycle_intent WHERE id=1 AND operation_id='\(operationID.uuidString)' AND generation=\(generation))")
        return try accepts(operationID: operationID, generation: generation)
    }
    public func operation() throws -> LifecycleOperationEvidence? {
        guard let current = try intent() else { return nil }
        var result: LifecycleOperationEvidence?
        try store.query("SELECT operation_id,generation,kind,state,pre_observation_json,post_observation_json,error,nonce,session_binding,process_identity_json FROM lifecycle_operations WHERE operation_id=? AND generation=?", bind: { s in
            store.bind(current.operationID.uuidString, to: s, index: 1); sqlite3_bind_int64(s, 2, current.generation)
        }) { s in
            guard let id = store.columnString(s, 0).flatMap(UUID.init(uuidString:)), let kind = store.columnString(s, 2).flatMap(LifecycleOperationKind.init(rawValue:)), let state = store.columnString(s, 3).flatMap(LifecycleJournalState.init(rawValue:)), let pre = store.columnString(s, 4), let preData = pre.data(using: .utf8), let preObservation = try? JSONDecoder().decode(LifecycleObservationVector.self, from: preData) else { throw SQLiteStateError.invalidRecord }
            var post: LifecycleObservationVector?
            if let raw = store.columnString(s, 5) { guard let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode(LifecycleObservationVector.self, from: data) else { throw SQLiteStateError.invalidRecord }; post = decoded }
             let process: LifecycleProcessIdentity?
             if let raw = store.columnString(s, 9), let data = raw.data(using: .utf8) { process = try? JSONDecoder().decode(LifecycleProcessIdentity.self, from: data) } else { process = nil }
             result = .init(operationID: id, generation: sqlite3_column_int64(s, 1), kind: kind, state: state, preObservation: preObservation, postObservation: post, error: store.columnString(s, 6), nonce: store.columnString(s, 7).flatMap(UUID.init(uuidString:)), sessionBinding: store.columnString(s, 8).flatMap(UUID.init(uuidString:)), processIdentity: process)
        }
        return result
    }
    /// True when there is no current lifecycle journal row at all.  Legacy
    /// orphan recovery may not reinterpret a historical terminal row.
    public func operationIsAbsent() throws -> Bool {
        try operation() == nil
    }
    /// Validates every durable journal row before a Core-absent handoff may
    /// touch ServiceManagement.  Looking only at the current operation would
    /// allow an orphaned or malformed older row to be mistaken for a clean
    /// recovery boundary.
    public func hasUnresolvedOperation() throws -> Bool {
        var unresolved = false
        try store.query("SELECT operation_id,generation,kind,state,pre_observation_json,post_observation_json FROM lifecycle_operations") { s in
            guard store.columnString(s, 0).flatMap(UUID.init(uuidString:)) != nil,
                  sqlite3_column_type(s, 1) != SQLITE_NULL,
                  store.columnString(s, 2).flatMap(LifecycleOperationKind.init(rawValue:)) != nil,
                  let state = store.columnString(s, 3).flatMap(LifecycleJournalState.init(rawValue:)),
                  let pre = store.columnString(s, 4), let preData = pre.data(using: .utf8),
                  (try? JSONDecoder().decode(LifecycleObservationVector.self, from: preData)) != nil else {
                throw SQLiteStateError.invalidRecord
            }
            if let post = store.columnString(s, 5) {
                guard let data = post.data(using: .utf8),
                      (try? JSONDecoder().decode(LifecycleObservationVector.self, from: data)) != nil else {
                    throw SQLiteStateError.invalidRecord
                }
            }
            unresolved = unresolved || state == .pending || state == .inFlight || state == .unknownRecoveryRequired
        }
        return unresolved
    }
    /// Unknown register outcomes remain a durable platform-attempt fence.
    /// Absence cannot prove that an ambiguous registration did not happen.
    public func hasAmbiguousOnOperation() throws -> Bool {
        var ambiguous = false
        try store.query("SELECT operation_id,generation,kind,state,pre_observation_json,post_observation_json FROM lifecycle_operations") { s in
            guard store.columnString(s, 0).flatMap(UUID.init(uuidString:)) != nil,
                  sqlite3_column_type(s, 1) != SQLITE_NULL,
                  let kind = store.columnString(s, 2).flatMap(LifecycleOperationKind.init(rawValue:)),
                  let state = store.columnString(s, 3).flatMap(LifecycleJournalState.init(rawValue:)),
                  let pre = store.columnString(s, 4), let preData = pre.data(using: .utf8),
                  (try? JSONDecoder().decode(LifecycleObservationVector.self, from: preData)) != nil else {
                throw SQLiteStateError.invalidRecord
            }
            if let post = store.columnString(s, 5) {
                guard let data = post.data(using: .utf8),
                      (try? JSONDecoder().decode(LifecycleObservationVector.self, from: data)) != nil else {
                    throw SQLiteStateError.invalidRecord
                }
            }
            ambiguous = ambiguous || (kind == .register && state == .unknownRecoveryRequired)
        }
        return ambiguous
    }
    public func saveOwnership(_ ownership: LifecycleOwnershipRecord) throws {
        let q = { (v: String) in v.replacingOccurrences(of: "'", with: "''") }
        let team = ownership.signingTeam.map { "'\(q($0))'" } ?? "NULL"; let req = ownership.designatedRequirement.map { "'\(q($0))'" } ?? "NULL"; let hash = ownership.artifactHash.map { "'\(q($0))'" } ?? "NULL"
        guard ownership.target == canonicalTarget,
              let operation = try operation(), operation.operationID == ownership.operationID,
              operation.generation == ownership.generation,
              operation.kind == .register, operation.state == .succeeded,
              let post = operation.postObservation,
               post.bundlePresent == .true, post.layoutValid == .true,
               post.signatureValid == .true,
               post.registrationMatch == .true,
               post.signingTeam != nil, post.designatedRequirement != nil, post.artifactHash != nil,
               ownership.signingTeam == post.signingTeam,
               ownership.designatedRequirement == post.designatedRequirement,
               ownership.artifactHash == post.artifactHash,
              post.observedAt <= Date(), Date().timeIntervalSince(post.observedAt) <= 30,
              post.source != "core", post.source != "synthetic" else { throw SQLiteStateError.invalidRecord }
        try store.execute("INSERT OR REPLACE INTO lifecycle_ownership (id,bundle_id,agent_label,bundle_program,endpoint,signing_team,designated_requirement,artifact_hash,operation_id,generation) SELECT 1,'\(q(ownership.target.bundleID))','\(q(ownership.target.agentLabel))','\(q(ownership.target.bundleProgram))','\(q(ownership.target.endpoint))',\(team),\(req),\(hash),'\(ownership.operationID.uuidString)',\(ownership.generation) WHERE EXISTS (SELECT 1 FROM lifecycle_intent WHERE id=1 AND operation_id='\(ownership.operationID.uuidString)' AND generation=\(ownership.generation)) AND EXISTS (SELECT 1 FROM lifecycle_operations WHERE operation_id='\(ownership.operationID.uuidString)' AND generation=\(ownership.generation) AND state = 'succeeded')")
    }
    /// Reads durable ownership and revalidates its provenance against the
    /// succeeded register operation and a fresh matching observation. A
    /// matching platform registration alone is never ownership evidence.
    public func ownership() throws -> LifecycleOwnershipRecord? {
        var result: LifecycleOwnershipRecord?
        try store.query("SELECT bundle_id,agent_label,bundle_program,endpoint,signing_team,designated_requirement,artifact_hash,operation_id,generation FROM lifecycle_ownership WHERE id=1") { s in
            guard let b = store.columnString(s, 0), let l = store.columnString(s, 1), let p = store.columnString(s, 2), let e = store.columnString(s, 3), let id = store.columnString(s, 7).flatMap(UUID.init(uuidString:)) else { throw SQLiteStateError.invalidRecord }
            let target = LifecycleTargetIdentity(bundleID: b, agentLabel: l, bundleProgram: p, endpoint: e)
            guard target == canonicalTarget else { throw SQLiteStateError.invalidRecord }
            result = .init(target: target, signingTeam: store.columnString(s, 4), designatedRequirement: store.columnString(s, 5), artifactHash: store.columnString(s, 6), operationID: id, generation: sqlite3_column_int64(s, 8))
        }
        return result
    }
    public func hasValidOwnership(for target: LifecycleTargetIdentity, observation: LifecycleObservationVector, maxAge: TimeInterval = 30) throws -> Bool {
        guard target == canonicalTarget, let ownership = try ownership(), ownership.target == target,
              let op = try operation(), op.operationID == ownership.operationID, op.generation == ownership.generation,
              op.kind == .register, op.state == .succeeded,
               observation.bundlePresent == .true, observation.layoutValid == .true,
               observation.signatureValid == .true,
               observation.registrationMatch == .true,
               observation.signingTeam != nil, observation.designatedRequirement != nil, observation.artifactHash != nil,
               ownership.signingTeam == observation.signingTeam,
               ownership.designatedRequirement == observation.designatedRequirement,
               ownership.artifactHash == observation.artifactHash,
              observation.observedAt <= Date(), Date().timeIntervalSince(observation.observedAt) <= maxAge,
              observation.source != "core", observation.source != "synthetic" else { return false }
        return true
    }
    public func complete(operationID: UUID, generation: Int64, state: LifecycleJournalState, postObservation: LifecycleObservationVector? = nil, error: String? = nil) throws {
        guard state == .succeeded || state == .failed || state == .unknownRecoveryRequired else { throw SQLiteStateError.invalidRecord }
        guard state != .succeeded || postObservation != nil else { throw SQLiteStateError.invalidRecord }
        let q = { (v: String) in v.replacingOccurrences(of: "'", with: "''") }
        let post = postObservation.flatMap { try? String(decoding: IPCJSON.encode($0), as: UTF8.self) }.map { "'\(q($0))'" } ?? "NULL"
        let detail = error.map { "'\(q($0))'" } ?? "NULL"
        // The current-intent predicate is deliberately in the same UPDATE as
        // the state write. A callback cannot pass a preceding read and then
        // mutate a newer generation.
        try store.execute("UPDATE lifecycle_operations SET state='\(state.rawValue)', post_observation_json=\(post), error=\(detail) WHERE operation_id='\(operationID.uuidString)' AND generation=\(generation) AND state='in-flight' AND EXISTS (SELECT 1 FROM lifecycle_intent WHERE id=1 AND operation_id='\(operationID.uuidString)' AND generation=\(generation))")
    }

    /// Completes an unregister which crossed the platform boundary while the
    /// daemon was being terminated by launchd. This is recovery, never replay:
    /// it accepts only the current Off generation, an already ambiguous
    /// unregister row, and a fresh canonical absence observation.
    @discardableResult
    public func recoverOffAfterFreshAbsence(_ observation: LifecycleObservationVector) throws -> Bool {
        guard observation.source != "core", observation.source != "synthetic",
              observation.registrationMatch == .false,
              observation.processMatch == .false,
              observation.endpointReachable == .false,
              let current = try intent(), current.intent == .off,
              let operation = try operation(), operation.operationID == current.operationID,
              operation.generation == current.generation,
              operation.kind == .unregister,
              operation.state == .unknownRecoveryRequired || operation.state == .inFlight || operation.state == .succeeded else { return false }
        if operation.state == .succeeded { return true }
        let post = try String(decoding: IPCJSON.encode(observation), as: UTF8.self)
        let q = { (v: String) in v.replacingOccurrences(of: "'", with: "''") }
        try store.transaction {
            try store.execute("UPDATE lifecycle_operations SET state='succeeded', post_observation_json='\(q(post))', error=NULL WHERE operation_id='\(current.operationID.uuidString)' AND generation=\(current.generation) AND state IN ('in-flight','unknown/recovery-required') AND EXISTS (SELECT 1 FROM lifecycle_intent WHERE id=1 AND intent='off' AND operation_id='\(current.operationID.uuidString)' AND generation=\(current.generation))")
            try store.execute("DELETE FROM lifecycle_ownership WHERE id=1")
            try store.recordDiagnostic(.init(correlationID: UUID(), phase: .reconnect, outcome: "success", detail: "Recovered exact Off after fresh canonical absence; unregister was not replayed.", databasePath: store.databaseURL.path, operationID: current.operationID))
        }
        return true
    }
}

private enum IPCJSON { static func encode<T: Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(value) } }
