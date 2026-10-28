// Design signatures only. This file is outside product sources.
import Foundation
import VaelenCore

public enum ConnectionKey: String, CaseIterable, Sendable {
	case driver = "DB_CONNECTION"
	case host = "DB_HOST"
	case port = "DB_PORT"
	case database = "DB_DATABASE"
	case username = "DB_USERNAME"
	case password = "DB_PASSWORD"
}

public struct ConnectionConfirmation: Hashable, Sendable {
	private let value: UUID
}
public struct ConnectionRecoveryID: Hashable, Sendable {
	private let value: UUID
}
public enum ConnectionDisplayedValue: Equatable, Sendable {
	case literal(String)
	case managedPassword
}
public enum ConnectionFieldAction: Sendable {
	case replace
	case append
}
public struct ConnectionFieldReview: Sendable {
	public let key: ConnectionKey
	public let action: ConnectionFieldAction
	public let proposed: ConnectionDisplayedValue
}
public enum ConnectionReviewOperation: Sendable {
	case configure(databaseOperation: DatabaseOperationID, fields: [ConnectionFieldReview])
	case restore(recovery: ConnectionRecoveryID)
}
public struct ConnectionReview: Sendable {
	public let confirmation: ConnectionConfirmation
	public let project: ProjectEnvironmentIdentity
	public let expiresAt: Date
	public let operation: ConnectionReviewOperation
	public let addsSeparatorNewline: Bool
	public let configurationCachePresent: Bool
}
public enum ConnectionRecoveryState: Sendable {
	case prepared
	case notApplied
	case applied
	case restorePrepared
	case restored
	case conflict
	case discarding
}
public struct ConnectionRecovery: Sendable {
	public let id: ConnectionRecoveryID
	public let project: ProjectEnvironmentIdentity
	public let state: ConnectionRecoveryState
	public let restoreEligible: Bool
}
public enum ConnectionApplyOutcome: Sendable {
	case applied(ConnectionRecovery)
	case restored(ConnectionRecovery)
	case reconciliationRequired(ConnectionRecoveryID)
}

// Constructed by the dispatcher only after its existing target validation.
// Exact evidence is internal to Core, never accepted as proof from IPC callers.
struct ValidatedConnectionTarget: Sendable {
	let project: ProjectEnvironmentIdentity
	let receipt: DatabaseProvisionAttempt
	let service: ServiceInstanceRecord
}

// New evidence crosses a live system boundary on every apply.
enum CurrentConnectionEvidence: Sendable {
	case configuration(ValidatedConnectionTarget)
	case restoration(ProjectEnvironmentIdentity)
}

final class ProjectConnectionSetup {
	init(recoveryRootPolicy: ConnectionRecoveryRootPolicy,
	     passwords: any ProjectDatabasePasswordStore,
	     files: ConnectionFileBoundary,
	     now: @escaping () -> Date) { fatalError("not implemented") }

	func review(target: ValidatedConnectionTarget) throws -> ConnectionReview {
		fatalError("not implemented")
	}
	func reviewRestore(target: ProjectEnvironmentIdentity,
	                   recoveryID: ConnectionRecoveryID) throws -> ConnectionReview {
		fatalError("not implemented")
	}
	func apply(confirmation: ConnectionConfirmation,
	           current: CurrentConnectionEvidence) throws -> ConnectionApplyOutcome {
		fatalError("not implemented")
	}
	func status(project: ProjectEnvironmentIdentity) throws -> ConnectionRecovery? {
		fatalError("not implemented")
	}
	func discard(project: ProjectEnvironmentIdentity,
	             recoveryID: ConnectionRecoveryID) throws {
		fatalError("not implemented")
	}
	func reconcileOnStartup() throws { fatalError("not implemented") }
}

// The following types remain internal in the implementation module.
struct ConnectionRecoveryRootPolicy { /* validated same-volume private directory policy */ }
struct FileEvidence { /* device, inode, bytes digest, metadata, pinned parent identity */ }
struct BytePatch { /* ordered non-overlapping byte ranges and replacement bytes */ }
struct ConnectionFileSnapshot { /* private bytes and FileEvidence, never Codable */ }
struct ProtectedPreparedReplacement { /* private descriptor, durable header, before-image */ }

struct DotenvConnectionDocument {
	init(bytes: Data) throws { fatalError("not implemented") }
	func plan(values: ConnectionLiteralValues) throws -> BytePatch {
		fatalError("not implemented")
	}
}
struct ConnectionLiteralValues {
	// Exact six literal values. Password storage is private and non-Codable.
	init(target: ValidatedConnectionTarget, password: SecretPassword) throws {
		fatalError("not implemented")
	}
}

struct ConnectionFileBoundary {
	func inspect(project: ProjectEnvironmentIdentity) throws -> ConnectionFileSnapshot {
		fatalError("not implemented")
	}
	func prepare(original: ConnectionFileSnapshot,
	             patch: BytePatch,
	             recoveryID: ConnectionRecoveryID) throws -> ProtectedPreparedReplacement {
		fatalError("not implemented")
	}
	// Revalidates immediately before atomic publication. This is not filesystem CAS.
	// An uncoordinated external write after the final check remains outside the guarantee.
	func publishAfterRevalidation(_ prepared: ProtectedPreparedReplacement,
	                              expected: FileEvidence) throws -> ConnectionRecovery {
		fatalError("not implemented")
	}
}
