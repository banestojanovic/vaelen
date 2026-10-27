struct DatabaseName: Hashable, Sendable {
    let value: String
    init(_ input: String) throws
}
struct DatabaseUserName: Hashable, Sendable {
    let value: String
    init(_ input: String) throws
}
struct DatabaseOperationID: Hashable, Sendable { let rawValue: UUID }
struct DatabaseReceiptID: Hashable, Sendable { let rawValue: UUID }
struct ProjectDatabaseCreation: Sendable {
    let operationID: DatabaseOperationID
    let projectID: ProjectID
    let binding: ProjectServiceBinding
    let database: DatabaseName
    let user: DatabaseUserName
}
internal struct VerifiedDatabaseTarget {
    let projectID: ProjectID
    let binding: ProjectServiceBinding
    let record: ServiceInstanceRecord
    var instanceID: ServiceInstanceID { record.id }
}
struct ProjectDatabaseConnection: Sendable {
    let database: DatabaseName
    let user: DatabaseUserName
    let host: String
    let port: Int
    let authentication: DatabaseAuthentication
    let binding: ProjectServiceBinding
    let instanceID: ServiceInstanceID
}
enum DatabaseReceiptState: Sendable {
    case ready(ProjectDatabaseConnection, credential: CredentialAvailability)
    case refused(DatabaseConflict)
    case failedWithoutEngineChanges(DatabaseFailure)
    case retainedPartial(DatabasePartialResult)
}
struct ProjectDatabaseReceipt: Sendable {
    let id: DatabaseReceiptID
    let operationID: DatabaseOperationID
    let projectID: ProjectID
    let state: DatabaseReceiptState
}
struct DatabasePartialResult: Sendable {
    let confirmed: Set<DatabaseResource>
    let uncertain: Set<DatabaseResource>
    let reason: DatabaseFailure
}
enum DatabaseResource: Hashable, Sendable { case applicationUser, database, privileges, loginEnablement }
enum DatabaseAuthentication: Sendable { case password, localTrust }
enum CredentialAvailability: Sendable { case saved, unavailable }
enum PasswordAccessIntent: Sendable { case reveal, copy }
struct SecretPassword: Sendable {
    private let storage: SecretBytes
    func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T
}
final class ProjectDatabaseProvisioner {
    func create(_ request: ProjectDatabaseCreation) throws -> ProjectDatabaseReceipt
    func receipts(projectID: ProjectID, binding: ProjectServiceBinding) throws -> [ProjectDatabaseReceipt]
    func password(receipt: DatabaseReceiptID, intent: PasswordAccessIntent) throws -> SecretPassword
}
protocol ProjectDatabasePasswordStore: Sendable {
    func create(for id: DatabaseOperationID) throws -> SecretPassword
    func load(for id: DatabaseOperationID) throws -> SecretPassword
}
final class KeychainProjectDatabasePasswordStore: ProjectDatabasePasswordStore {
    init(namespace: KeychainNamespace)
    func create(for id: DatabaseOperationID) throws -> SecretPassword
    func load(for id: DatabaseOperationID) throws -> SecretPassword
}
final class ProjectDatabaseReceiptRepository {
    func begin(_ request: ProjectDatabaseCreation, target: VerifiedDatabaseTarget) throws -> StoredDatabaseAttempt
    func record(_ event: DatabaseAttemptEvent, for id: DatabaseOperationID) throws
    func find(_ id: DatabaseOperationID) throws -> StoredDatabaseAttempt?
    func interruptedAttempts() throws -> [StoredDatabaseAttempt]
}
extension MySQLModule {
    internal func withVerifiedDatabaseAdmin<T>(
        expected: ServiceInstanceRecord,
        _ action: (MySQLDatabaseAdmin) throws -> T
    ) throws -> T
}
extension PostgreSQLServiceModule {
    internal func withVerifiedDatabaseAdmin<T>(
        expected: ServiceInstanceRecord,
        _ action: (PostgreSQLDatabaseAdmin) throws -> T
    ) throws -> T
}
internal struct MySQLDatabaseAdmin {
    func checkAbsent(database: DatabaseName, user: DatabaseUserName) throws
    func createLockedUser(_ user: DatabaseUserName, password: SecretPassword) throws
    func createDatabase(_ database: DatabaseName) throws
    func grantApplicationAccess(database: DatabaseName, user: DatabaseUserName) throws
    func enableLogin(user: DatabaseUserName) throws
    func verify(database: DatabaseName, user: DatabaseUserName) throws -> EngineProof
}
internal struct PostgreSQLDatabaseAdmin {
    func checkAbsent(database: DatabaseName, user: DatabaseUserName) throws
    func createNonLoginRole(_ user: DatabaseUserName, password: SecretPassword) throws
    func createDatabase(_ database: DatabaseName, owner: DatabaseUserName) throws
    func restrictDatabaseAccess(database: DatabaseName, owner: DatabaseUserName) throws
    func enableLogin(user: DatabaseUserName) throws
    func verify(database: DatabaseName, user: DatabaseUserName) throws -> EngineProof
}
