// Architecture sketch only; not product code.
import Foundation
import VaelenCore

public struct ConnectionConfirmation: Hashable, Sendable { private let id: UUID }
public struct ConnectionRecoveryID: Hashable, Sendable { private let id: UUID }

public enum ConnectionKey: String, CaseIterable, Sendable {
	case driver = "DB_CONNECTION"
	case host = "DB_HOST"
	case port = "DB_PORT"
	case database = "DB_DATABASE"
	case username = "DB_USERNAME"
	case password = "DB_PASSWORD"
}

public enum ConnectionPresentedValue: Equatable, Sendable {
	case literal(String)
	case managedPassword
}

public enum ConnectionEdit: Sendable {
	case add
	case replace
}

public struct ConnectionReviewRow: Sendable {
	public let key: ConnectionKey
	public let edit: ConnectionEdit
	public let value: ConnectionPresentedValue
}

public enum ConnectionAdvisory: Sendable {
	case configurationCachePresent
	case alternateEnvironmentFile
}

public struct ConnectionReview: Sendable {
	public let confirmation: ConnectionConfirmation
	public let project: ProjectEnvironmentIdentity
	public let expiresAt: Date
	public let rows: [ConnectionReviewRow]
	public let advisories: [ConnectionAdvisory]
	public let permissionChange: (from: UInt16, to: UInt16)?
}

public enum ConnectionRecoveryState: Sendable {
	case prepared
	case applied
	case conflict
	case restorePrepared
	case restored
	case needsAttention
}

public struct ConnectionRecoverySummary: Sendable {
	public let id: ConnectionRecoveryID
	public let project: ProjectEnvironmentIdentity
	public let state: ConnectionRecoveryState
	public let restoreReviewAvailable: Bool
	public let discardReviewAvailable: Bool
}

public enum ConnectionApplyOutcome: Sendable {
	case applied(ConnectionRecoverySummary)
	case conflict(ConnectionRecoverySummary)
	case restored(ConnectionRecoverySummary)
	case needsAttention(ConnectionRecoverySummary)
}

// Constructed by Core only after linked project, receipt, and service validation.
struct ValidatedConnectionContext: Sendable {
	let project: ProjectEnvironmentIdentity
	let receipt: DatabaseProvisionAttempt
	let service: ServiceInstanceRecord
	let credential: SecretPassword
}

struct ConnectionReviewSession: Sendable {
	let createdAt: Date
	let context: ValidatedConnectionContext
	let file: ConnectionFileEvidence
	let patch: ConnectionPatch
}

final class ProjectConnectionSetup {
	func review(context: ValidatedConnectionContext, now: Date) throws -> ConnectionReview {
		fatalError("not implemented")
	}
	func apply(_ confirmation: ConnectionConfirmation,
	           freshContext: ValidatedConnectionContext,
	           now: Date) throws -> ConnectionApplyOutcome {
		fatalError("not implemented")
	}
	func status(project: ProjectEnvironmentIdentity) throws -> ConnectionRecoverySummary? {
		fatalError("not implemented")
	}
	func reviewRestore(project: ProjectEnvironmentIdentity,
	                   recovery: ConnectionRecoveryID,
	                   now: Date) throws -> ConnectionReview {
		fatalError("not implemented")
	}
	func reviewDiscard(project: ProjectEnvironmentIdentity,
	                   recovery: ConnectionRecoveryID,
	                   now: Date) throws -> ConnectionReview {
		fatalError("not implemented")
	}
}

// Core-private file and secret evidence. None conforms to Codable or a debug renderer.
struct ConnectionFileEvidence: Codable, Sendable {
	let device: UInt64
	let inode: UInt64
	let size: UInt64
	let owner: UInt32
	let group: UInt32
	let mode: UInt16
	let linkCount: UInt64
	let modifiedSeconds: Int64
	let modifiedNanoseconds: Int64
	let changedSeconds: Int64
	let changedNanoseconds: Int64
	let digest: ConnectionDigest
}

struct ConnectionDigest: Codable, Equatable, Sendable { private let bytes: Data }
struct ConnectionByteSpan: Sendable { let range: Range<Int> }
struct ConnectionPatch: Sendable { private let output: Data; let rows: [ConnectionReviewRow] }
struct ConnectionSecretBytes: Sendable { private var bytes: Data }

struct LosslessDotenvDocument {
	static func parse(_ bytes: Data) throws -> Self { fatalError("not implemented") }
	func patch(_ values: ConnectionValues) throws -> ConnectionPatch { fatalError("not implemented") }
}

struct ConnectionValues {
	init(context: ValidatedConnectionContext) throws { fatalError("not implemented") }
}

struct ConnectionRecoveryArtifacts: Sendable {
	let directory: URL
	let beforeImage: URL
	let stagedReplacement: URL
	let displacedOccupant: URL
	let journal: URL
}

struct ConnectionTransactionJournal: Codable, Sendable {
	let version: UInt16
	let recoveryID: UUID
	let projectID: UUID
	let projectRootIdentity: ConnectionDirectoryIdentity
	let reviewedFile: ConnectionFileEvidence
	let stagedFile: ConnectionFileEvidence
	let replacementDigest: ConnectionDigest
	let displacedFile: ConnectionFileEvidence?
	let state: JournalState
}

enum JournalState: Codable, Sendable {
	case prepared
	case swapAttempted
	case applied
	case conflict
	case restorePrepared
	case restored
	case discardPrepared
}

struct ConnectionDirectoryIdentity: Codable, Sendable {
	let device: UInt64
	let inode: UInt64
}

struct ConnectionFileTransaction {
	func apply(_ session: ConnectionReviewSession) throws -> ConnectionApplyOutcome {
		fatalError("not implemented")
	}
	func reconcile(project: ProjectEnvironmentIdentity) throws -> ConnectionRecoverySummary? {
		fatalError("not implemented")
	}
	func restore(_ session: ConnectionReviewSession) throws -> ConnectionApplyOutcome {
		fatalError("not implemented")
	}
	func discard(_ session: ConnectionReviewSession) throws -> ConnectionApplyOutcome {
		fatalError("not implemented")
	}
}

struct ConnectionFileBoundary {
	func inspect(project: ProjectEnvironmentIdentity) throws -> (Data, ConnectionFileEvidence) {
		fatalError("not implemented")
	}
	func createRecoveryArtifacts(for project: ProjectEnvironmentIdentity,
	                            before: Data,
	                            proposed: Data,
	                            evidence: ConnectionFileEvidence) throws -> ConnectionRecoveryArtifacts {
		fatalError("not implemented")
	}
	func swapOnce(_ artifacts: ConnectionRecoveryArtifacts,
	              reviewed: ConnectionFileEvidence) throws -> ConnectionApplyOutcome {
		fatalError("not implemented")
	}
}
