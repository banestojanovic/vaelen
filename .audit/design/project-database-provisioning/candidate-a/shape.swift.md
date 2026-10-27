# Proposed type sketch

The named data shape is `DatabaseProvisionAttempt`. Each attempt binds one immutable request to one verified service record, one Keychain item, and explicit confirmed or uncertain effects. This is a signature sketch, not compilable implementation.

```swift
import Foundation

public struct DatabaseProvisionID: Hashable, Sendable {
	public let rawValue: UUID
	public init(_ rawValue: UUID)
}

public struct DatabaseName: Hashable, Sendable {
	public let value: String
	public init(_ value: String) throws
	// ASCII [a-z][a-z0-9_]{0,62}. Refuse reserved engine names at the target boundary.
}

public struct DatabaseUserName: Hashable, Sendable {
	public let value: String
	public init(_ value: String) throws
	// ASCII [a-z][a-z0-9_]{0,31}. Refuse engine-reserved account names.
}

public struct ProjectDatabaseTarget: Equatable, Sendable {
	public let projectID: ProjectID
	public let binding: ProjectServiceBinding
	public var serviceID: ServiceInstanceID { /* derive from binding, never persist a second copy */ }
	public init(projectID: ProjectID, binding: ProjectServiceBinding) throws
	// Only mysql/default or a named postgresql binding. No arbitrary endpoint input.
}

public struct DatabaseProvisionRequest: Equatable, Sendable {
	public let id: DatabaseProvisionID
	public let target: ProjectDatabaseTarget
	public let database: DatabaseName
	public let user: DatabaseUserName
	public init(id: DatabaseProvisionID, target: ProjectDatabaseTarget,
		database: DatabaseName, user: DatabaseUserName)
}

public struct ProjectDatabaseProvisioningStatus: Equatable, Sendable {
	public let request: DatabaseProvisionRequest
	public let endpoint: DatabaseConnectionEndpoint
	public let state: DatabaseProvisionState
	public let credentialAvailability: CredentialAvailability
}

public enum DatabaseProvisionOutcome: Equatable, Sendable {
	case ready(ProjectDatabaseProvisioningStatus)
	case refused(DatabaseProvisionRefusal, partial: ProjectDatabaseProvisioningStatus?)
	case needsAttention(ProjectDatabaseProvisioningStatus)
}

public enum DatabaseProvisionState: Equatable, Sendable {
	case reserved
	case prepared
	case creatingAccount
	case accountCreated
	case creatingDatabase
	case databaseCreated
	case grantingAccess
	case verifying
	case ready
	case needsAttention(confirmed: Set<DatabaseProvisionEffect>, uncertain: DatabaseProvisionEffect?)
}

public enum DatabaseProvisionEffect: Hashable, Sendable {
	case applicationAccount, database, databasePrivileges
}

public enum DatabaseProvisionRefusal: Equatable, Sendable {
	case databaseExists
	case userExists
	case requestIDReused
	case nameReservedByAttempt(DatabaseProvisionID)
	case bindingChanged
	case projectClaimMissing
	case instanceUnavailable
	case unsupportedCredentialTransport
	case credentialStoreUnavailable
}

public struct DatabaseConnectionEndpoint: Equatable, Sendable {
	public let host: String
	public let port: Int
	public let authentication: DatabaseAuthenticationPolicy
}

public enum DatabaseAuthenticationPolicy: Equatable, Sendable {
	case password, localTrust
}

public enum CredentialAvailability: Equatable, Sendable {
	case saved, unavailable
}

public enum PasswordDisclosureIntent: Sendable { case reveal, copy }
public struct DatabasePasswordDisclosureRequest: Sendable {
	public let provisionID: DatabaseProvisionID
	public let intent: PasswordDisclosureIntent
	public init(provisionID: DatabaseProvisionID, intent: PasswordDisclosureIntent)
}

// This type is intentionally neither Codable nor CustomStringConvertible.
// The IPC adapter serializes it only into its dedicated explicit-disclosure response.
public struct DisclosedDatabasePassword: Sendable {
	public let password: String
	internal init(password: String)
}

public final class ProjectDatabaseProvisioner {
	internal init(bindings: ProjectServiceBindings,
		repository: DatabaseProvisionRepository,
		passwords: any ProjectDatabasePasswordStore,
		mysql: MySQLModule?, postgresql: PostgreSQLServiceModule?)

	public func provision(_ request: DatabaseProvisionRequest) throws -> DatabaseProvisionOutcome {
		fatalError("not implemented")
	}
	public func status(projectID: ProjectID) throws -> [ProjectDatabaseProvisioningStatus] {
		fatalError("not implemented")
	}
	public func disclosePassword(_ request: DatabasePasswordDisclosureRequest) throws -> DisclosedDatabasePassword {
		fatalError("not implemented")
	}
}

// Internal ports. Test fakes conform under @testable import.
protocol ProjectDatabasePasswordStore {
	func add(_ secret: DatabaseSecret, for reference: DatabasePasswordReference) throws
	func load(_ reference: DatabasePasswordReference) throws -> DatabaseSecret
}
struct DatabasePasswordReference: Hashable, Sendable {
	let installationID: UUID
	let provisionID: DatabaseProvisionID
}
struct DatabaseSecret: Sendable {
	// Internal bytes only. Random generator produces 32 URL-safe ASCII characters.
	// No Codable, description, equality dump, or error-associated secret value.
	let bytes: Data
}
struct DatabaseProvisionAttempt {
	let request: DatabaseProvisionRequest
	let serviceRecord: ServiceInstanceRecord
	let passwordReference: DatabasePasswordReference
	let state: DatabaseProvisionState
}
protocol DatabaseProvisionRepository {
	func attempt(_ id: DatabaseProvisionID) throws -> DatabaseProvisionAttempt?
	func attempts(projectID: ProjectID) throws -> [DatabaseProvisionAttempt]
	func reserve(_ attempt: DatabaseProvisionAttempt) throws
	func transition(_ id: DatabaseProvisionID, to state: DatabaseProvisionState) throws
}

extension ProjectServiceBindings {
	internal func authorizeDatabaseProvisioning(_ target: ProjectDatabaseTarget) throws -> ServiceInstanceRecord {
		fatalError("not implemented")
		// Verify current declared binding, exact project claim, package, endpoint,
		// data directory and healthy runtime against the selected service record.
	}
}

// Keep engine entrypoints internal. No public executeSQL(sql: String).
// The caller cannot pass a socket path or a different service record.
extension MySQLModule {
	internal func openProvisioningSession(for verified: ServiceInstanceRecord) throws -> MySQLProvisioningSession {
		fatalError("not implemented")
	}
}
extension PostgreSQLServiceModule {
	internal func openProvisioningSession(for verified: ServiceInstanceRecord) throws -> PostgreSQLProvisioningSession {
		fatalError("not implemented")
	}
}

// These are private concrete dialect adapters with the same small capability set.
// They are not a plugin system or a public generic database abstraction.
// Their result parsers map engine output into fixed domain errors.
protocol ProvisioningSession {
	func collision(database: DatabaseName, user: DatabaseUserName) throws -> DatabaseProvisionRefusal?
	func createAccount(user: DatabaseUserName, secret: DatabaseSecret) throws
	func createDatabase(_ database: DatabaseName, user: DatabaseUserName) throws
	func grantApplicationAccess(database: DatabaseName, user: DatabaseUserName) throws
	func verifyAccess(database: DatabaseName, user: DatabaseUserName, secret: DatabaseSecret) throws -> DatabaseAuthenticationPolicy
}
```

`ServiceInstanceID` is currently not `Codable`. Its private SQLite encoding uses existing kind and name columns. New IPC DTOs encode exact binding fields and parse into `ProjectDatabaseTarget`, rather than broadening the existing identity type for persistence convenience.

`authorizeDatabaseProvisioning` also reads the project's current desired binding through the inspector or dispatcher-provided domain snapshot. A persisted claim alone cannot authorize a binding removed from a changed project manifest. A stale caller must receive `bindingChanged`.

A pure internal transition function rejects illegal stage transitions and maps interrupted pending effects to `needsAttention`. It never emits an engine command during recovery. The coordinator checks service identity before starting each new engine session. It never updates service claims.
