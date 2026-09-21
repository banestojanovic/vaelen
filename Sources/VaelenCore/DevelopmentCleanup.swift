import Foundation
import SQLite3

/// The one known development residue authorized for cleanup. These values are
/// evidence-bound constants, not caller-selectable lifecycle identifiers.
public enum AuthorizedDevelopmentResidue {
    public static let source = "MANUAL DEVELOPMENT ACCEPTANCE CLEANUP"
    public static let promotedReceiptOperationID = "831A332D-8FE8-4F18-A9B6-6DCA334E0623"
    public static let promotedReceiptInvocationID = "BFB58911-CA40-46CB-96AC-43A530C73BEB"
    public static let promotedReceiptArtifactHash = "5d5654f3141b9737b0bc0ef1ee605b7e822cfb2007d2bad8f5b8ba9fee06ced3"
    public static let ownershipOperationID = "7B29610B-33CE-4848-9A7B-C155ECF8FABE"
    public static let offOperationID = "A4A1B503-4768-4791-A919-8D2E924FF1DC"
    public static let ownershipGeneration: Int64 = 1
    public static let offGeneration: Int64 = 2
    public static func matchesPromotedReceipt(_ receipt: BootstrapReceipt) -> Bool {
        receipt.target == LifecycleCanonicalIdentity.target &&
        receipt.operationID.uuidString == promotedReceiptOperationID &&
        receipt.invocationID.uuidString == promotedReceiptInvocationID &&
        receipt.generation == 1 && receipt.phase == .promoted &&
        receipt.preflightProvenance.artifactHash == promotedReceiptArtifactHash
    }
}

public enum AuthorizedDevelopmentCleanupError: Error, Equatable, Sendable {
    case residueMismatch(String)
}

public extension SQLiteStateStore {
    /// Development-only escape hatch for the owner-authorized historical MAC
    /// incompatibility. This is not recovery: it never authenticates, adopts,
    /// or manufactures the receipt. It preserves the raw row and records that
    /// MAC verification was unavailable/rejected.
    func archiveAuthorizedPromotedReceiptWithRejectedMACForDevelopment() throws {
        guard let evidence = try bootstrapReceiptEvidence(),
              AuthorizedDevelopmentResidue.matchesPromotedReceipt(evidence) else {
            throw AuthorizedDevelopmentCleanupError.residueMismatch("raw promoted receipt is not the exact authorized development residue")
        }
        var rawJSON: String?
        try query("SELECT json_object('id',id,'bundle_id',bundle_id,'agent_label',agent_label,'bundle_program',bundle_program,'endpoint',endpoint,'epoch',epoch,'operation_id',operation_id,'nonce',nonce,'invocation_token_hash',invocation_token_hash,'invocation_token',invocation_token,'invocation_user',invocation_user,'invocation_uid',invocation_uid,'invocation_id',invocation_id,'generation',generation,'preflight_provenance_json',preflight_provenance_json,'expires_at',expires_at,'phase',phase,'executor_state',executor_state,'executor_detail',executor_detail,'post_observation_json',post_observation_json,'integrity_digest',integrity_digest) FROM bootstrap_receipts WHERE id=1") { s in rawJSON = columnString(s, 0) }
        guard let rawJSON else { throw AuthorizedDevelopmentCleanupError.residueMismatch("exact promoted receipt raw row is absent") }
        let target = LifecycleCanonicalIdentity.target
        try query("SELECT bundle_id,agent_label,bundle_program,endpoint,operation_id,invocation_id,generation,phase,preflight_provenance_json FROM bootstrap_receipts WHERE id=1") { s in
            guard columnString(s,0) == target.bundleID, columnString(s,1) == target.agentLabel,
                  columnString(s,2) == target.bundleProgram, columnString(s,3) == target.endpoint,
                  columnString(s,4) == AuthorizedDevelopmentResidue.promotedReceiptOperationID,
                  columnString(s,5) == AuthorizedDevelopmentResidue.promotedReceiptInvocationID,
                  sqlite3_column_int64(s,6) == 1, columnString(s,7) == BootstrapReceiptPhase.promoted.rawValue,
                  columnString(s,8)?.contains(AuthorizedDevelopmentResidue.promotedReceiptArtifactHash) == true else {
                throw AuthorizedDevelopmentCleanupError.residueMismatch("raw promoted receipt identity changed before development cleanup")
            }
        }
        guard try LifecycleStateRepository(store: self).ownership() == nil,
              try LifecycleStateRepository(store: self).intent() == nil,
              try LifecycleStateRepository(store: self).operationIsAbsent() else {
            throw AuthorizedDevelopmentCleanupError.residueMismatch("current lifecycle state is not absent")
        }
        let q: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
        try transaction {
            try execute("INSERT INTO bootstrap_receipt_history (source,epoch,operation_id,receipt_json,archived_at) SELECT '\(q(AuthorizedDevelopmentResidue.source))',epoch,operation_id,'\(q(rawJSON))',CURRENT_TIMESTAMP FROM bootstrap_receipts WHERE id=1 AND operation_id='\(AuthorizedDevelopmentResidue.promotedReceiptOperationID)' AND invocation_id='\(AuthorizedDevelopmentResidue.promotedReceiptInvocationID)' AND generation=1 AND phase='promoted'")
            try execute("DELETE FROM bootstrap_receipts WHERE id=1 AND operation_id='\(AuthorizedDevelopmentResidue.promotedReceiptOperationID)' AND invocation_id='\(AuthorizedDevelopmentResidue.promotedReceiptInvocationID)' AND generation=1 AND phase='promoted'")
            var deleted = false
            try query("SELECT changes()") { deleted = sqlite3_column_int($0, 0) == 1 }
            guard deleted else { throw AuthorizedDevelopmentCleanupError.residueMismatch("development receipt barrier changed before archival completed") }
            try recordDiagnostic(.init(correlationID: UUID(), phase: .lifecycle, outcome: "success", detail: AuthorizedDevelopmentResidue.source + ": archived raw promoted receipt; MAC verification unavailable/rejected by production authenticator; owner-authorized development cleanup only", databasePath: databaseURL.path, operationID: UUID(uuidString: AuthorizedDevelopmentResidue.promotedReceiptOperationID)))
        }
    }

    /// Archives the one explicitly authorized promoted receipt left by the
    /// stale cleanup race. This is deliberately separate from generalized
    /// receipt recovery and accepts no caller-supplied identifiers.
    func archiveAuthorizedPromotedReceipt() throws {
        let authenticator = KeychainBootstrapReceiptAuthenticator.shared
        guard let evidence = try bootstrapReceiptEvidence(),
              AuthorizedDevelopmentResidue.matchesPromotedReceipt(evidence) else {
            throw AuthorizedDevelopmentCleanupError.residueMismatch("promoted receipt is not the exact authorized stale-cleanup residue")
        }
        try authenticator.authorize(provenance: evidence.preflightProvenance)
        guard let receipt = try bootstrapReceipt(authenticator: authenticator),
              AuthorizedDevelopmentResidue.matchesPromotedReceipt(receipt),
              try LifecycleStateRepository(store: self).ownership() == nil,
              try LifecycleStateRepository(store: self).intent() == nil,
              try LifecycleStateRepository(store: self).operationIsAbsent() else {
            throw AuthorizedDevelopmentCleanupError.residueMismatch("promoted receipt is not the exact authorized stale-cleanup residue")
        }
        let q: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        try transaction {
            try execute("INSERT INTO bootstrap_receipt_history (source,epoch,operation_id,receipt_json,archived_at) VALUES ('\(q(AuthorizedDevelopmentResidue.source))','\(receipt.epoch.uuidString)','\(receipt.operationID.uuidString)','\(q(json))',CURRENT_TIMESTAMP)")
            try execute("DELETE FROM bootstrap_receipts WHERE id=1 AND operation_id='\(AuthorizedDevelopmentResidue.promotedReceiptOperationID)' AND invocation_id='\(AuthorizedDevelopmentResidue.promotedReceiptInvocationID)' AND phase='promoted'")
            var deleted = false
            try query("SELECT changes()") { deleted = sqlite3_column_int($0, 0) == 1 }
            guard deleted else { throw AuthorizedDevelopmentCleanupError.residueMismatch("promoted receipt changed before archival completed") }
            try recordDiagnostic(.init(correlationID: UUID(), phase: .lifecycle, outcome: "success", detail: AuthorizedDevelopmentResidue.source + ": archived exact promoted receipt and cleared stale bootstrap barrier; artifact handoff deferred", databasePath: databaseURL.path, operationID: receipt.operationID))
        }
    }

    /// Archives and removes only the exact known residue above. The signed
    /// product verifies external absence before invoking this method.
    func performAuthorizedDevelopmentCleanup() throws {
        let target = LifecycleCanonicalIdentity.target
        let q: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
        var intent: (String, Int64, String, String, String, String, String, String)?
        try query("SELECT intent,generation,operation_id,actor,bundle_id,agent_label,bundle_program,endpoint FROM lifecycle_intent WHERE id=1") { s in
            intent = (columnString(s,0) ?? "", sqlite3_column_int64(s,1), columnString(s,2) ?? "", columnString(s,3) ?? "", columnString(s,4) ?? "", columnString(s,5) ?? "", columnString(s,6) ?? "", columnString(s,7) ?? "")
        }
        guard let intent, intent.0 == "off", intent.1 == AuthorizedDevelopmentResidue.offGeneration,
              intent.2 == AuthorizedDevelopmentResidue.offOperationID,
              intent.4 == target.bundleID, intent.5 == target.agentLabel,
              intent.6 == target.bundleProgram, intent.7 == target.endpoint else {
            throw AuthorizedDevelopmentCleanupError.residueMismatch("intent is not the exact known Off generation")
        }
        var ownership: (String, String, String, String, String?, String?, String?, String, Int64)?
        try query("SELECT bundle_id,agent_label,bundle_program,endpoint,signing_team,designated_requirement,artifact_hash,operation_id,generation FROM lifecycle_ownership WHERE id=1") { s in
            ownership = (columnString(s,0) ?? "", columnString(s,1) ?? "", columnString(s,2) ?? "", columnString(s,3) ?? "", columnString(s,4), columnString(s,5), columnString(s,6), columnString(s,7) ?? "", sqlite3_column_int64(s,8))
        }
        guard let ownership, ownership.0 == target.bundleID, ownership.1 == target.agentLabel,
              ownership.2 == target.bundleProgram, ownership.3 == target.endpoint,
              ownership.7 == AuthorizedDevelopmentResidue.ownershipOperationID,
              ownership.8 == AuthorizedDevelopmentResidue.ownershipGeneration else {
            throw AuthorizedDevelopmentCleanupError.residueMismatch("ownership is not the exact known generation-1 residue")
        }
        var operations = [(String, Int64, String, String, String?)]()
        try query("SELECT operation_id,generation,kind,state,error FROM lifecycle_operations ORDER BY generation") { s in
            operations.append((columnString(s,0) ?? "", sqlite3_column_int64(s,1), columnString(s,2) ?? "", columnString(s,3) ?? "", columnString(s,4)))
        }
        guard operations.count == 2,
              operations.contains(where: { $0.0 == AuthorizedDevelopmentResidue.ownershipOperationID && $0.1 == 1 && $0.2 == "register" && $0.3 == "succeeded" }),
              operations.contains(where: { $0.0 == AuthorizedDevelopmentResidue.offOperationID && $0.1 == 2 && $0.2 == "unregister" && $0.3 == "unknown/recovery-required" }) else {
            throw AuthorizedDevelopmentCleanupError.residueMismatch("lifecycle journal is not the exact known two-operation residue")
        }
        let detail = "\(AuthorizedDevelopmentResidue.source): archived intent=\(intent.2)/\(intent.1), ownership=\(ownership.7)/\(ownership.8), operations=\(operations.map { $0.0 }.joined(separator: ",")); exact canonical target; external absence verified by signed product"
        let targetJSON = "{\"bundle_id\":\"\(q(target.bundleID))\",\"agent_label\":\"\(q(target.agentLabel))\",\"bundle_program\":\"\(q(target.bundleProgram))\",\"endpoint\":\"\(q(target.endpoint))\"}"
        let intentJSON = "{\"intent\":\"\(q(intent.0))\",\"generation\":\(intent.1),\"operation_id\":\"\(q(intent.2))\",\"actor\":\"\(q(intent.3))\"}"
        let ownershipJSON = "{\"operation_id\":\"\(q(ownership.7))\",\"generation\":\(ownership.8),\"artifact_hash\":\"\(q(ownership.6 ?? ""))\"}"
        let operationsJSON = "[" + operations.map { "{\"operation_id\":\"\(q($0.0))\",\"generation\":\($0.1),\"kind\":\"\(q($0.2))\",\"state\":\"\(q($0.3))\",\"error\":\"\(q($0.4 ?? ""))\"}" }.joined(separator: ",") + "]"
        try transaction {
            try execute("INSERT INTO lifecycle_development_cleanup_history (source,target_json,intent_json,ownership_json,operations_json,evidence,created_at) VALUES ('\(q(AuthorizedDevelopmentResidue.source))','\(q(targetJSON))','\(q(intentJSON))','\(q(ownershipJSON))','\(q(operationsJSON))','exact canonical target; external absence verified by signed product before durable mutation',CURRENT_TIMESTAMP)")
            try recordDiagnostic(.init(correlationID: UUID(), phase: .lifecycle, outcome: "success", detail: detail, databasePath: databaseURL.path, operationID: UUID(uuidString: AuthorizedDevelopmentResidue.offOperationID)))
            try execute("DELETE FROM lifecycle_ownership WHERE id=1")
            try execute("DELETE FROM lifecycle_operations WHERE operation_id IN ('\(AuthorizedDevelopmentResidue.ownershipOperationID)','\(AuthorizedDevelopmentResidue.offOperationID)')")
            try execute("DELETE FROM lifecycle_intent WHERE id=1")
        }
    }
}
