// Design sketch only. Not a product source file or a compilable implementation.
import Foundation

// Public domain types in VaelenCore. IPC has its own DTOs.
public struct ConnectionConfirmation: Hashable, Sendable {
	private let value: UUID
}

public struct ConnectionRecoveryID: Hashable, Sendable {
	private let value: UUID
}

public enum ConnectionIntent: Sendable {
	case configure(DatabaseOperationID)
	case restore(ConnectionRecoveryID)
	case discard(ConnectionRecoveryID)
}

public enum ConnectionKey: String, CaseIterable, Sendable {
	case connection = "DB_CONNECTION"
	case host = "DB_HOST"
	case port = "DB_PORT"
	case database = "DB_DATABASE"
	case username = "DB_USERNAME"
	case password = "DB_PASSWORD"
}

public enum ConnectionPresentedValue: Equatable, Sendable {
	case destination(String)
	case managedSecret
}

public enum ConnectionEditKind: Sendable { case add, replace }

public struct ConnectionReviewRow: Sendable {
	public let key: ConnectionKey
	public let kind: ConnectionEditKind
	public let proposed: ConnectionPresentedValue
}

public enum ConnectionPresentation: Sendable {
	case configure(project: ProjectEnvironmentIdentity, rows: [ConnectionReviewRow], advisories: [ConnectionAdvisory])
	case restore(project: ProjectEnvironmentIdentity, recovery: ConnectionRecoveryID)
	case discard(project: ProjectEnvironmentIdentity, recovery: ConnectionRecoveryID)
}

public struct ConnectionReview: Sendable {
	public let confirmation: ConnectionConfirmation
	public let expiresAt: Date
	public let presentation: ConnectionPresentation
}

public enum ConnectionAdvisory: Sendable {
	case configCachePresent, alternateEnvironmentFile, databaseURLPresent
}

public enum ConnectionRefusal: Error, Sendable {
	case staleReview, usedReview, projectChanged, targetChanged, credentialChanged
	case unsupportedDotenv(line: Int), duplicateTarget(ConnectionKey, lines: [Int])
	case unsafeFile, unsafeDirectory, fileChanged, recoveryOutstanding
	case externalChange(ConnectionRecoveryID), unsafeRecovery(ConnectionRecoveryID)
	case filesystemUnsupported, ioFailure
}

public enum ConnectionOutcome: Sendable {
	case applied(ConnectionRecoveryID)
	case restored(ConnectionRecoveryID)
	case discarded(ConnectionRecoveryID)
	case needsAttention(ConnectionRecoveryID, ConnectionRefusal)
}

public enum ConnectionRecoveryDisposition: Sendable {
	case preparedAbandoned, interruptedRestored, applied, restored
	case externalChange, unsafeRecovery, needsAttention
}

public struct ConnectionRecoverySummary: Sendable {
	public let id: ConnectionRecoveryID
	public let disposition: ConnectionRecoveryDisposition
	public let canReviewRestore: Bool
	public let canReviewDiscard: Bool
}

public struct ConnectionStatus: Sendable {
	public let retainedRecovery: ConnectionRecoverySummary?
}

// Dispatcher creates this only after resolving the linked project and fresh authority.
// Configuration carries verified database evidence. Restore/discard need only project evidence.
public struct ConnectionContext: Sendable {
	internal let project: VerifiedConnectionProject
	internal let database: VerifiedConnectionDatabase?
}

// One owner, synchronous during filesystem effects, actor-confined in the dispatcher.
public final class ProjectConnectionSetup {
	public func review(_ intent: ConnectionIntent, context: ConnectionContext, now: Date) throws -> ConnectionReview {
		fatalError("not implemented")
	}
	public func apply(_ confirmation: ConnectionConfirmation, context: ConnectionContext, now: Date) throws -> ConnectionOutcome {
		fatalError("not implemented")
	}
	public func status(context: ConnectionContext) throws -> ConnectionStatus {
		fatalError("not implemented")
	}
}

// Internal, non-Codable evidence and secret-bearing document types.
internal struct VerifiedConnectionProject: Sendable {
	let identity: ProjectEnvironmentIdentity
	let root: RootEvidence
	let manifest: FileEvidence
}

internal struct VerifiedConnectionDatabase: Sendable {
	let readyReceipt: DatabaseProvisionAttempt
	let target: VerifiedDatabaseTarget
	let loadPassword: @Sendable () throws -> ConnectionSecret
}

internal struct ConnectionSecret: Sendable {
	private var bytes: Data
}

internal struct RootEvidence: Equatable, Sendable {
	let device: UInt64
	let inode: UInt64
	let canonicalPath: String
}

internal struct FileEvidence: Equatable, Sendable {
	let device: UInt64
	let inode: UInt64
	let size: UInt64
	let mode: UInt16
	let uid: UInt32
	let gid: UInt32
	let linkCount: UInt64
	let flags: UInt32
	let modifiedTime: FileTimestamp
	let changedTime: FileTimestamp
	let digest: ContentDigest
}

internal struct FileTimestamp: Equatable, Sendable {
	let seconds: Int64
	let nanoseconds: Int64
}

internal struct ContentDigest: Equatable, Sendable { private let bytes: Data }
internal struct ByteSpan: Sendable { let offsets: Range<Int> }

internal struct LosslessConnectionDocument: Sendable {
	private let bytes: Data
	private let targets: [ConnectionKey: RecognizedAssignment]
	static func parse(_ bytes: Data) throws -> Self { fatalError("not implemented") }
	func propose(_ destination: VerifiedConnectionDatabase, password: ConnectionSecret) throws -> ConnectionPatch {
		fatalError("not implemented")
	}
}

internal struct RecognizedAssignment: Sendable {
	let entrySpan: ByteSpan
	let valueSpan: ByteSpan
	let line: Int
}

internal struct ConnectionPatch: Sendable {
	let presentedRows: [ConnectionReviewRow]
	private let original: Data
	private let proposed: Data
}

internal struct ConnectionSession: Sendable {
	let expiresAt: Date
	let reviewedProject: VerifiedConnectionProject
	let intent: ReviewedConnectionIntent
}

internal enum ReviewedConnectionIntent: Sendable {
	case configure(database: VerifiedConnectionDatabase, file: FileEvidence, patch: ConnectionPatch)
	case restore(recovery: RecoveryEvidence, current: FileEvidence, patch: ConnectionPatch)
	case discard(recovery: RecoveryEvidence)
}

// Storage schemas stay private to the transaction implementation.
// Codable on the descriptor serializes metadata only, never a patch or source bytes.
internal struct TransactionDescriptor: Codable, Sendable {
	let version: Int
	let id: UUID
	let operation: JournalOperation
	let project: JournalProjectEvidence
	let before: JournalFileEvidence
	let proposed: JournalFileEvidence
	let createdAt: Date
}

internal enum JournalOperation: Codable, Sendable {
	case configure(receiptID: UUID)
	case restore(parentID: UUID)
}

internal enum JournalIntent: Codable, Sendable {
	case prepared, publishPending, applied, restorePending, restored, discardPending
}

internal enum ObservedTransaction: Sendable {
	case preparationOnly(PreparedArtifacts)
	case originalAtTarget(PreparedArtifacts)
	case originalWithdrawn(CapturedArtifacts)
	case proposedAtTarget(AppliedArtifacts)
	case externalChange(ConflictingArtifacts)
	case unsafeRecovery
}

internal struct ConnectionTransaction {
	static func prepare(_ session: ConnectionSession, at root: OpenProjectDirectory) throws -> Self {
		fatalError("not implemented")
	}
	func commitExclusively() throws -> ConnectionOutcome { fatalError("not implemented") }
	static func reconcile(at root: OpenProjectDirectory) throws -> ConnectionStatus {
		fatalError("not implemented")
	}
	func reviewRestore(current: FileEvidence) throws -> ConnectionSession { fatalError("not implemented") }
	func discardVerifiedArtifacts() throws { fatalError("not implemented") }
}

// Named opaque implementation records. Their fields derive from the transaction table.
internal struct OpenProjectDirectory {}
internal struct RecoveryEvidence: Sendable {}
internal struct JournalProjectEvidence: Codable, Sendable {}
internal struct JournalFileEvidence: Codable, Sendable {}
internal struct PreparedArtifacts {}
internal struct CapturedArtifacts {}
internal struct AppliedArtifacts {}
internal struct ConflictingArtifacts {}
