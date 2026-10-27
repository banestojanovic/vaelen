import Foundation
import XCTest
import Security
@testable import VaelenCore

final class ProjectDatabaseProvisioningTests: XCTestCase {
    func testProvisioningNamesUseSharedLowercaseGrammar() throws {
        XCTAssertEqual(try DatabaseName("shop_dev").value, "shop_dev")
        XCTAssertEqual(try DatabaseUserName("shop_app").value, "shop_app")
        for invalid in ["", "1shop", "Shop", "shop-name", "shop.name", String(repeating: "a", count: 33)] {
            XCTAssertThrowsError(try DatabaseName(invalid))
            XCTAssertThrowsError(try DatabaseUserName(invalid))
        }
        for reserved in ["mysql", "information_schema", "performance_schema", "sys"] {
            XCTAssertThrowsError(try DatabaseName(reserved))
        }
        for reserved in ["root", "mysql", "admin"] {
            XCTAssertThrowsError(try DatabaseUserName(reserved))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(DatabaseName.self, from: Data("\"Shop\"".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(DatabaseUserName.self, from: Data("\"not-valid\"".utf8)))
    }

    func testAttemptIdIsBoundToImmutableRequestAndReservationsSpanAliases() throws {
        let (root, database, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectDatabaseReceiptRepository(store: store)
        let target = try target(project: ProjectID(), alias: "database", at: "/data/mysql/default", version: nil)
        let request = try creation(operationID: DatabaseOperationID(UUID(uuidString: "CE16AE05-9A07-46EF-B8E8-C9EFC8EBC7B3")!), projectID: target.projectID, alias: "database", version: nil)

        let reserved = try repository.begin(request, target: target, credentialReference: "vaelen.project-database.CE16AE05-9A07-46EF-B8E8-C9EFC8EBC7B3")

        XCTAssertEqual(reserved.request, request)
        XCTAssertEqual(reserved.state, .reserved)
        XCTAssertThrowsError(try repository.begin(creation(operationID: request.operationID, projectID: target.projectID, alias: "database", database: "other_db", version: nil), target: target, credentialReference: "unused")) { error in
            XCTAssertEqual(error as? DatabaseProvisioningError, .operationIDReused)
        }
        let otherAliasTarget = try self.target(project: target.projectID, alias: "other", at: "/data/mysql/default", version: nil)
        let otherAliasRequest = try creation(projectID: target.projectID, alias: "other", version: nil)
        XCTAssertThrowsError(try repository.begin(otherAliasRequest, target: otherAliasTarget, credentialReference: "unused")) { error in
            XCTAssertEqual(error as? DatabaseProvisioningError, .namespaceReserved)
        }

        let reopened = ProjectDatabaseReceiptRepository(store: try SQLiteStateStore(databaseURL: database))
        XCTAssertEqual(try reopened.attempt(request.operationID), reserved)
        XCTAssertNil(try reopened.attempt(request.operationID)?.request.binding.version)
        let raw = try String(contentsOf: database, encoding: .isoLatin1)
        XCTAssertFalse(raw.contains("credentialReference"))
    }

    func testAttemptRecordsConfirmedAndUncertainEffectsWithoutChangingRequest() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectDatabaseReceiptRepository(store: store)
        let target = try target(project: ProjectID(), alias: "database", at: "/data/mysql/default")
        let request = try creation(projectID: target.projectID, alias: "database")
        let attempt = try repository.begin(request, target: target, credentialReference: "credential-ref")

        try repository.record(.prepared, operationID: request.operationID)
        try repository.record(.effectPending(.applicationUser), operationID: request.operationID)
        try repository.record(.effectConfirmed(.applicationUser), operationID: request.operationID)
        try repository.record(.effectPending(.database), operationID: request.operationID)
        try repository.record(.needsAttention(.database, diagnostic: .engineResponseLost), operationID: request.operationID)

        let recovered = try XCTUnwrap(repository.attempt(request.operationID))
        XCTAssertEqual(recovered.request, attempt.request)
        XCTAssertEqual(recovered.confirmedEffects, [.applicationUser])
        XCTAssertEqual(recovered.uncertainEffects, [.database])
        XCTAssertEqual(recovered.state, .needsAttention)
    }

    func testKeychainPasswordIsGenericPasswordAndCreateNeverOverwrites() throws {
        let namespace = "dev.vaelen.tests.project-database.\(UUID().uuidString)"
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: namespace] as CFDictionary) }
        let store = KeychainProjectDatabasePasswordStore(namespace: namespace)
        let operationID = DatabaseOperationID()
        let created = try store.create(for: operationID)
        let loaded = try store.load(for: operationID)
        XCTAssertEqual(try created.withBytes { Data($0) }, try loaded.withBytes { Data($0) })
        XCTAssertThrowsError(try store.create(for: operationID))
    }

    func testPasswordRevealRejectsNonReadyReceiptBeforeKeychainLoad() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ProjectDatabaseReceiptRepository(store: store)
        let target = try target(project: ProjectID(), alias: "database", at: "/data/mysql/default")
        let request = try creation(projectID: target.projectID, alias: "database")
        let attempt = try repository.begin(request, target: target, credentialReference: "credential-ref")
        let passwords = FakePasswordStore(fails: false)
        let module = MySQLModule(layout: VaelenFilesystemLayout(rootURL: root))

        XCTAssertThrowsError(try module.revealDatabasePassword(for: attempt, passwords: passwords)) { error in
            XCTAssertEqual(error as? DatabaseProvisioningError, .targetMismatch)
        }
        XCTAssertEqual(passwords.loadCount, 0)
    }

    func testCollisionAndKeychainFailureNeverReachDDL() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = ProjectDatabaseReceiptRepository(store: store)
        let target = try target(project: ProjectID(), alias: "database", at: "/data/mysql/default")
        let request = try creation(projectID: target.projectID, alias: "database")
        let keychain = FakePasswordStore(fails: false)
        let collisionEngine = FakeMySQLEngine(conflict: .existingDatabase)
        let collision = try ProjectDatabaseProvisioner(receipts: database, passwords: keychain, engine: collisionEngine).create(request, target: target)
        XCTAssertEqual(collision.state, .refused)
        XCTAssertTrue(collisionEngine.writes.isEmpty)
        XCTAssertEqual(keychain.createCount, 0)
        let retryWithFreshOperation = try creation(projectID: target.projectID, alias: "database")
        let acceptedEngine = FakeMySQLEngine()
        let accepted = try ProjectDatabaseProvisioner(receipts: database, passwords: keychain, engine: acceptedEngine).create(retryWithFreshOperation, target: target)
        XCTAssertEqual(accepted.state, .ready)
        XCTAssertEqual(acceptedEngine.writes, DatabaseProvisionEffect.allCases)

        let secondStore = try SQLiteStateStore(databaseURL: root.appendingPathComponent("second.sqlite"))
        let secondKeychain = FakePasswordStore(fails: true)
        let secondEngine = FakeMySQLEngine()
        let failed = try ProjectDatabaseProvisioner(receipts: ProjectDatabaseReceiptRepository(store: secondStore), passwords: secondKeychain, engine: secondEngine).create(request, target: target)
        XCTAssertEqual(failed.state, .failedBeforeDDL)
        XCTAssertTrue(secondEngine.writes.isEmpty)
    }

    func testFailedBeforeDDLRetryReusesAttemptAndCompletesAfterKeychainRecovers() throws {
        let (root, _, store) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try self.target(project: ProjectID(), alias: "database", at: "/data/mysql/default")
        let request = try creation(projectID: target.projectID, alias: "database")
        let repository = ProjectDatabaseReceiptRepository(store: store)
        let passwords = FakePasswordStore(fails: true)
        let engine = FakeMySQLEngine()
        let provisioner = ProjectDatabaseProvisioner(receipts: repository, passwords: passwords, engine: engine)
        let failed = try provisioner.create(request, target: target)
        XCTAssertEqual(failed.state, .failedBeforeDDL)
        XCTAssertTrue(engine.writes.isEmpty)
        passwords.fails = false

        let retried = try provisioner.retry(failed.request, target: failed.target)

        XCTAssertEqual(retried.state, .ready)
        XCTAssertEqual(retried.receiptID, failed.receiptID)
        XCTAssertEqual(retried.request, failed.request)
        XCTAssertEqual(retried.credentialReference, failed.credentialReference)
        XCTAssertEqual(engine.writes, DatabaseProvisionEffect.allCases)
    }

    func testRepeatedFailedBeforeDDLRetryStaysRetryableWithoutEffects() throws {
        let (root, _, store) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try self.target(project: ProjectID(), alias: "database", at: "/data/mysql/default")
        let request = try creation(projectID: target.projectID, alias: "database")
        let repository = ProjectDatabaseReceiptRepository(store: store)
        let passwords = FakePasswordStore(fails: true)
        let engine = FakeMySQLEngine()
        let provisioner = ProjectDatabaseProvisioner(receipts: repository, passwords: passwords, engine: engine)
        let first = try provisioner.create(request, target: target)
        let createReplay = try provisioner.create(first.request, target: first.target)
        XCTAssertEqual(createReplay.state, .failedBeforeDDL, "Create replay must not implicitly retry")
        let repeated = try provisioner.retry(first.request, target: first.target)
        XCTAssertEqual(repeated.state, .failedBeforeDDL)
        XCTAssertEqual(repeated.receiptID, first.receiptID)
        XCTAssertTrue(repeated.confirmedEffects.isEmpty)
        XCTAssertTrue(repeated.uncertainEffects.isEmpty)
        XCTAssertTrue(engine.writes.isEmpty)
    }

    func testRetryRejectsPendingAndUncertainEngineEffects() throws {
        let (root, _, store) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try self.target(project: ProjectID(), alias: "database", at: "/data/mysql/default")
        let request = try creation(projectID: target.projectID, alias: "database")
        let repository = ProjectDatabaseReceiptRepository(store: store)
        _ = try repository.begin(request, target: target, credentialReference: "credential-ref")
        try repository.record(.prepared, operationID: request.operationID)
        try repository.record(.effectPending(.applicationUser), operationID: request.operationID)
        let engine = FakeMySQLEngine()
        let provisioner = ProjectDatabaseProvisioner(receipts: repository, passwords: FakePasswordStore(fails: false), engine: engine)
        XCTAssertThrowsError(try provisioner.retry(request, target: target))
        XCTAssertTrue(engine.writes.isEmpty)

        try repository.record(.effectConfirmed(.applicationUser), operationID: request.operationID)
        try repository.record(.effectPending(.database), operationID: request.operationID)
        try repository.record(.needsAttention(.database, diagnostic: .engineResponseLost), operationID: request.operationID)
        XCTAssertThrowsError(try provisioner.retry(request, target: target))
        XCTAssertEqual(engine.writes, [])
    }

    func testCollisionAppearingBeforeFailedBeforeDDLRetryRefusesAndReleasesReservation() throws {
        let (root, _, store) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try self.target(project: ProjectID(), alias: "database", at: "/data/mysql/default")
        let request = try creation(projectID: target.projectID, alias: "database")
        let repository = ProjectDatabaseReceiptRepository(store: store)
        let passwords = FakePasswordStore(fails: true)
        let engine = FakeMySQLEngine()
        let provisioner = ProjectDatabaseProvisioner(receipts: repository, passwords: passwords, engine: engine)
        let failed = try provisioner.create(request, target: target)
        engine.conflict = .existingUser
        let refused = try provisioner.retry(failed.request, target: failed.target)
        XCTAssertEqual(refused.state, .refused)
        XCTAssertEqual(refused.diagnostic, .existingUser)
        XCTAssertTrue(engine.writes.isEmpty)
        XCTAssertEqual(passwords.createCount, 1)
        let replacement = try creation(projectID: target.projectID, alias: "database")
        let replacementAttempt = try repository.begin(replacement, target: target, credentialReference: "replacement-credential")
        XCTAssertEqual(replacementAttempt.state, .reserved, "refusal must release the name and username reservations")
    }

    func testPreDDLRetryAndAmbiguousDDLBecomeDurableReadOnlyOutcome() throws {
        let (root, databaseURL, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try creation(projectID: ProjectID(), alias: "database")
        let target = try target(project: request.projectID, alias: "database", at: "/data/mysql/default")
        let engine = FakeMySQLEngine(failPreflightOnce: true)
        let passwords = FakePasswordStore(fails: false)
        let provisioner = ProjectDatabaseProvisioner(receipts: ProjectDatabaseReceiptRepository(store: store), passwords: passwords, engine: engine)
        XCTAssertThrowsError(try provisioner.create(request, target: target))
        XCTAssertEqual(try ProjectDatabaseReceiptRepository(store: try SQLiteStateStore(databaseURL: databaseURL)).attempt(request.operationID)?.state, .reserved)
        engine.failingWrite = .applicationUser
        let partial = try provisioner.create(request, target: target)
        XCTAssertEqual(partial.state, .needsAttention)
        XCTAssertEqual(partial.uncertainEffects, [.applicationUser])
        let writes = engine.writes
        let recovered = try provisioner.create(request, target: target)
        XCTAssertEqual(recovered, partial)
        XCTAssertEqual(engine.writes, writes)
    }

    func testPostgreSQLCollisionRefusesDatabaseOrRoleBeforeWrites() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try postgreSQLTarget(project: ProjectID())
        let request = try postgreSQLCreation(projectID: target.projectID)
        let passwords = FakePasswordStore(fails: false)
        let engine = FakePostgreSQLEngine(conflict: .existingUser)

        let result = try ProjectDatabaseProvisioner(receipts: ProjectDatabaseReceiptRepository(store: store), passwords: passwords, engine: engine).create(request, target: target)

        XCTAssertEqual(result.state, .refused)
        XCTAssertEqual(result.diagnostic, .existingUser)
        XCTAssertTrue(engine.writes.isEmpty)
        XCTAssertEqual(passwords.createCount, 0)
    }

    func testPostgreSQLPartialEffectPersistsNeedsAttentionAcrossReopen() throws {
        let (root, databaseURL, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try postgreSQLTarget(project: ProjectID())
        let request = try postgreSQLCreation(projectID: target.projectID)
        let engine = FakePostgreSQLEngine(failingWrite: .database)
        let repository = ProjectDatabaseReceiptRepository(store: store)

        let result = try ProjectDatabaseProvisioner(receipts: repository, passwords: FakePasswordStore(fails: false), engine: engine).create(request, target: target)
        let recovered = try XCTUnwrap(ProjectDatabaseReceiptRepository(store: try SQLiteStateStore(databaseURL: databaseURL)).attempt(request.operationID))

        XCTAssertEqual(result.state, .needsAttention)
        XCTAssertEqual(recovered, result)
        XCTAssertEqual(recovered.confirmedEffects, [.applicationUser])
        XCTAssertEqual(recovered.uncertainEffects, [.database])
        XCTAssertEqual(try ProjectDatabaseProvisioner(receipts: repository, passwords: FakePasswordStore(fails: false), engine: engine).create(request, target: target), recovered)
        XCTAssertEqual(engine.writes, [.applicationUser, .database])
    }

    func testPostgreSQLReceiptRejectsWrongServiceIdentity() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectID()
        let target = try target(project: project, alias: "database", at: "/data/mysql/default")
        let request = try postgreSQLCreation(projectID: project)

        XCTAssertThrowsError(try ProjectDatabaseReceiptRepository(store: store).begin(request, target: target, credentialReference: "unused")) { error in
            XCTAssertEqual(error as? DatabaseProvisioningError, .targetMismatch)
        }
    }

    private func makeStore() throws -> (URL, URL, SQLiteStateStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-project-db-tests-\(UUID().uuidString)", isDirectory: true)
        let database = root.appendingPathComponent("state.sqlite")
        return (root, database, try SQLiteStateStore(databaseURL: database))
    }

    private func target(project: ProjectID, alias: String, at path: String, version: String? = "mysql-8.4.11") throws -> VerifiedDatabaseTarget {
        let name = try ProjectInstanceName("default")
        let binding = try ProjectServiceBinding(alias: ProjectBindingAlias(alias), kind: .mysql, instance: name, version: version)
        let record = try ServiceInstanceRecord(id: ServiceInstanceID(kind: .mysql, name: name), packageIdentifier: "mysql-8.4.11", endpoint: .mysql(port: 3306), dataDirectory: path)
        return VerifiedDatabaseTarget(projectID: project, binding: binding, record: record, clusterIdentity: "server-uuid-1234")
    }

    private func postgreSQLTarget(project: ProjectID) throws -> VerifiedDatabaseTarget {
        let name = try ProjectInstanceName("default")
        let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .postgresql, instance: name, version: PostgreSQLServiceModule.packageIdentifier)
        let record = try ServiceInstanceRecord(id: ServiceInstanceID(kind: .postgresql, name: name), packageIdentifier: PostgreSQLServiceModule.packageIdentifier, endpoint: .postgresql(port: 55432), dataDirectory: "/data/postgresql/default")
        return VerifiedDatabaseTarget(projectID: project, binding: binding, record: record, clusterIdentity: "system-identifier-1234")
    }

    private func postgreSQLCreation(projectID: ProjectID) throws -> ProjectDatabaseCreation {
        ProjectDatabaseCreation(projectID: projectID, binding: try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .postgresql, instance: ProjectInstanceName("default"), version: PostgreSQLServiceModule.packageIdentifier), database: try DatabaseName("shop_dev"), user: try DatabaseUserName("shop_app"))
    }

    private func creation(operationID: DatabaseOperationID = DatabaseOperationID(), projectID: ProjectID, alias: String, database: String = "shop_dev", user: String = "shop_app", version: String? = "mysql-8.4.11") throws -> ProjectDatabaseCreation {
        ProjectDatabaseCreation(operationID: operationID, projectID: projectID, binding: try ProjectServiceBinding(alias: ProjectBindingAlias(alias), kind: .mysql, instance: ProjectInstanceName("default"), version: version), database: try DatabaseName(database), user: try DatabaseUserName(user))
    }

    private final class FakePasswordStore: ProjectDatabasePasswordStore, @unchecked Sendable {
        var fails: Bool
        var createCount = 0
        var loadCount = 0
        private var value: SecretPassword?
        init(fails: Bool) { self.fails = fails }
        func create(for operationID: DatabaseOperationID) throws -> SecretPassword {
            createCount += 1
            if fails { throw DatabaseProvisioningError.secretUnavailable }
            let password = SecretPassword(bytes: Data("fixture-password".utf8))
            value = password
            return password
        }
        func load(for operationID: DatabaseOperationID) throws -> SecretPassword {
            loadCount += 1
            guard let value else { throw DatabaseProvisioningError.credentialMissing }
            return value
        }
    }

    private final class FakeMySQLEngine: MySQLDatabaseProvisioningEngine, @unchecked Sendable {
        var conflict: DatabaseProvisionDiagnostic?
        var failPreflightOnce: Bool
        var failingWrite: DatabaseProvisionEffect?
        var writes: [DatabaseProvisionEffect] = []
        init(conflict: DatabaseProvisionDiagnostic? = nil, failPreflightOnce: Bool = false) { self.conflict = conflict; self.failPreflightOnce = failPreflightOnce }
        func clusterIdentity(for target: VerifiedDatabaseTarget) throws -> String { target.clusterIdentity }
        func checkAbsent(database: DatabaseName, user: DatabaseUserName) throws -> DatabaseProvisionDiagnostic? {
            if failPreflightOnce { failPreflightOnce = false; throw DatabaseProvisioningError.engineFailure }
            return conflict
        }
        func createLockedUser(_ user: DatabaseUserName, password: SecretPassword) throws { try write(.applicationUser) }
        func createDatabase(_ database: DatabaseName) throws { try write(.database) }
        func grantApplicationAccess(database: DatabaseName, user: DatabaseUserName) throws { try write(.privileges) }
        func enableLogin(user: DatabaseUserName) throws { try write(.loginEnablement) }
        func authenticate(database: DatabaseName, user: DatabaseUserName, password: SecretPassword) throws {}
        private func write(_ effect: DatabaseProvisionEffect) throws {
            writes.append(effect)
            if failingWrite == effect { throw DatabaseProvisioningError.engineFailure }
        }
    }

    private final class FakePostgreSQLEngine: ProjectDatabaseProvisioningEngine, @unchecked Sendable {
        let conflict: DatabaseProvisionDiagnostic?
        let failingWrite: DatabaseProvisionEffect?
        var writes: [DatabaseProvisionEffect] = []
        init(conflict: DatabaseProvisionDiagnostic? = nil, failingWrite: DatabaseProvisionEffect? = nil) {
            self.conflict = conflict
            self.failingWrite = failingWrite
        }
        func clusterIdentity(for target: VerifiedDatabaseTarget) throws -> String { target.clusterIdentity }
        func checkAbsent(database: DatabaseName, user: DatabaseUserName) throws -> DatabaseProvisionDiagnostic? { conflict }
        func createLockedUser(_ user: DatabaseUserName, password: SecretPassword) throws { try write(.applicationUser) }
        func createDatabase(_ database: DatabaseName) throws { try write(.database) }
        func grantApplicationAccess(database: DatabaseName, user: DatabaseUserName) throws { try write(.privileges) }
        func enableLogin(user: DatabaseUserName) throws { try write(.loginEnablement) }
        func authenticate(database: DatabaseName, user: DatabaseUserName, password: SecretPassword) throws {}
        private func write(_ effect: DatabaseProvisionEffect) throws {
            writes.append(effect)
            if failingWrite == effect { throw DatabaseProvisioningError.engineFailure }
        }
    }
}
