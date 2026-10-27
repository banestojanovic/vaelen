import Foundation
import XCTest
@testable import VaelenCore

final class ServiceInstanceCatalogTests: XCTestCase {
    func testInstancesAndClaimsPersistAndRemainIsolated() throws {
        let (root, db, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ServiceInstanceRepository(store: store)
        let project = try projectRecord("project", at: root)
        let otherProject = try projectRecord("other", at: root)
        try ProjectRepository(store: store).upsert(project)
        try ProjectRepository(store: store).upsert(otherProject)
        let mysql = try instance("mysql-a", kind: .mysql, endpoint: .mysql(port: 3307), package: "vendor/mysql@exact+tag", directory: "/data/mysql-a")
        let redis = try instance("mysql-a", kind: .redis, endpoint: .redis(port: 6379), package: "redis://opaque?channel=stable", directory: "/data/redis-a")
        let mail = try instance("mail-a", kind: .mailpit, endpoint: .mailpit(smtpPort: 1026, httpPort: 8026), package: "mailpit#opaque", directory: "/data/mail-a")
        try repository.saveInstance(mysql)
        try repository.saveInstance(redis)
        try repository.saveInstance(mail)
        let firstBinding = try binding("database", kind: .mysql, instance: "mysql-a")
        let mailBinding = try binding("mail", kind: .mailpit, instance: "mail-a")
        try repository.replaceProjectClaims([firstBinding, mailBinding], for: project.id)
        try repository.setManualClaim(for: mysql.id, claimed: true)
        try repository.replaceProjectClaims([firstBinding], for: otherProject.id)
        XCTAssertEqual(Set(try repository.claims(for: mysql.id)), [.manual(instance: mysql.id), .project(projectID: project.id, binding: firstBinding), .project(projectID: otherProject.id, binding: firstBinding)])
        XCTAssertThrowsError(try repository.saveInstance(instance("mysql-a", kind: .mysql, endpoint: .mysql(port: 3308), package: "different", directory: "/data/elsewhere")))
        XCTAssertEqual(mysql.endpoint.loopbackEndpoints, ["mysql": "127.0.0.1:3307"])
        XCTAssertEqual(mail.endpoint.loopbackEndpoints, ["smtp": "127.0.0.1:1026", "http": "127.0.0.1:8026"])

        let reopened = ServiceInstanceRepository(store: try SQLiteStateStore(databaseURL: db))
        XCTAssertEqual(try reopened.instance(mysql.id), mysql)
        XCTAssertEqual(try reopened.instance(redis.id), redis)
        XCTAssertEqual(try reopened.instance(mail.id), mail)
        XCTAssertEqual(try reopened.projectClaims(for: project.id), [firstBinding, mailBinding])
        XCTAssertEqual(try reopened.projectClaims(for: otherProject.id), [firstBinding])
        XCTAssertTrue(try reopened.isManuallyClaimed(mysql.id))
        XCTAssertFalse(try reopened.isManuallyClaimed(mail.id))
        try reopened.setManualClaim(for: mysql.id, claimed: false)
        XCTAssertFalse(try reopened.isManuallyClaimed(mysql.id))
        XCTAssertEqual(try reopened.projectClaims(for: otherProject.id), [firstBinding])
        try reopened.setManualClaim(for: mysql.id, claimed: true)

        try reopened.replaceProjectClaims([], for: project.id)
        XCTAssertEqual(try reopened.projectClaims(for: project.id), [])
        XCTAssertEqual(try reopened.projectClaims(for: otherProject.id), [firstBinding])
        XCTAssertTrue(try reopened.isManuallyClaimed(mysql.id))
        XCTAssertNotNil(try reopened.instance(mail.id))
    }

    func testReplacementRejectsMissingProjectOrInstanceWithoutPartialMutation() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ServiceInstanceRepository(store: store)
        let project = try projectRecord("project", at: root)
        try ProjectRepository(store: store).upsert(project)
        let kept = try instance("kept", kind: .mysql, endpoint: .mysql(port: 3307), package: "pkg", directory: "/data/kept")
        try repository.saveInstance(kept)
        let binding = try binding("database", kind: .mysql, instance: "kept")
        try repository.replaceProjectClaims([binding], for: project.id)
        let absent = try self.binding("missing", kind: .redis, instance: "missing")
        XCTAssertThrowsError(try repository.replaceProjectClaims([absent], for: project.id))
        XCTAssertEqual(try repository.projectClaims(for: project.id), [binding])
        XCTAssertThrowsError(try repository.replaceProjectClaims([binding], for: ProjectID()))
        XCTAssertThrowsError(try repository.replaceProjectClaims([], for: ProjectID()))
        XCTAssertEqual(try repository.projectClaims(for: project.id), [binding])
    }

    func testClaimReplacementMaterializesExactRecordAtomically() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ServiceInstanceRepository(store: store)
        let project = try projectRecord("project", at: root)
        try ProjectRepository(store: store).upsert(project)
        let record = try instance("default", kind: .mysql, endpoint: .mysql(port: 33417), package: "mysql-8.4.11", directory: "/data/mysql/default")
        let binding = try binding("database", kind: .mysql, instance: "default")
        let alias = try self.binding("primary", kind: .mysql, instance: "default")
        try repository.replaceProjectClaims([binding, alias], materializing: [record, record], for: project.id)
        XCTAssertEqual(try repository.instance(record.id), record)
        XCTAssertEqual(try repository.projectClaims(for: project.id), [binding, alias])
        let conflict = try instance("default", kind: .mysql, endpoint: .mysql(port: 3306), package: "mysql-8.4.11", directory: "/data/mysql/default")
        XCTAssertThrowsError(try repository.replaceProjectClaims([], materializing: [conflict], for: project.id))
        XCTAssertEqual(try repository.projectClaims(for: project.id), [binding, alias])
    }

    func testFacadeReleasesSingletonAliasesWithoutStoppingAndKeepsOtherOwners() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ServiceInstanceRepository(store: store)
        let project = try projectRecord("project", at: root)
        let other = try projectRecord("other", at: root)
        try ProjectRepository(store: store).upsert(project)
        try ProjectRepository(store: store).upsert(other)
        let record = try instance("default", kind: .mailpit, endpoint: .mailpit(smtpPort: 1025, httpPort: 8025), package: "mailpit-1.31.1", directory: "/data/mailpit/default")
        try repository.saveManuallyClaimedInstance(record)
        let first = try binding("mail", kind: .mailpit, instance: "default")
        let second = try binding("notifications", kind: .mailpit, instance: "default")
        let otherBinding = try binding("mail", kind: .mailpit, instance: "default")
        try repository.replaceProjectClaims([first, second], for: project.id)
        try repository.replaceProjectClaims([otherBinding], for: other.id)
        let facade = ProjectServiceBindings(repository: repository, mysql: nil, postgresql: nil, valkey: nil, mailpit: nil)

        let result = try facade.releaseProjectClaims(projectID: project.id)

        XCTAssertFalse(result.failed)
        XCTAssertEqual(result.releasedBindingCount, 2)
        XCTAssertTrue(result.operations.first?.message.contains("left running") == true)
        XCTAssertEqual(try repository.projectClaims(for: project.id), [])
        XCTAssertEqual(try repository.projectClaims(for: other.id), [otherBinding])
        XCTAssertEqual(try repository.claims(for: record.id), [.manual(instance: record.id), .project(projectID: other.id, binding: otherBinding)])
    }

    func testProjectClaimPreventsBoundedRemovalActionBeforeItRuns() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ServiceInstanceRepository(store: store)
        let project = try projectRecord("project", at: root)
        try ProjectRepository(store: store).upsert(project)
        let record = try instance("default", kind: .mailpit, endpoint: .mailpit(smtpPort: 1025, httpPort: 8025), package: "mailpit-1.31.1", directory: "/data/mailpit/default")
        try repository.saveInstance(record)
        try repository.replaceProjectClaims([binding("mail", kind: .mailpit, instance: "default")], for: project.id)
        var sideEffectRan = false
        XCTAssertThrowsError(try repository.withNoProjectClaims(for: record.id) { sideEffectRan = true })
        XCTAssertFalse(sideEffectRan)
    }

    func testSuccessfulSingletonRemovalClearsOnlyMatchingMetadata() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ServiceInstanceRepository(store: store)
        let mysql = try instance("default", kind: .mysql, endpoint: .mysql(port: 3306), package: "mysql-8.4.11", directory: "/data/mysql/default")
        let mailpit = try instance("default", kind: .mailpit, endpoint: .mailpit(smtpPort: 1025, httpPort: 8025), package: "mailpit-1.31.1", directory: "/data/mailpit/default")
        try repository.saveManuallyClaimedInstance(mysql)
        try repository.saveManuallyClaimedInstance(mailpit)
        var effects = 0

        try repository.removeSingletonAfterSuccessfulAction(id: mysql.id, packageIdentifier: mysql.packageIdentifier) { effects += 1 }

        XCTAssertEqual(effects, 1)
        XCTAssertNil(try repository.instance(mysql.id))
        XCTAssertFalse(try repository.isManuallyClaimed(mysql.id))
        XCTAssertEqual(try repository.instance(mailpit.id), mailpit)
        XCTAssertTrue(try repository.isManuallyClaimed(mailpit.id))
    }

    func testDeniedSingletonRemovalRunsNoCallbackAndRetainsMetadata() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ServiceInstanceRepository(store: store)
        let project = try projectRecord("project", at: root)
        try ProjectRepository(store: store).upsert(project)
        let record = try instance("default", kind: .mailpit, endpoint: .mailpit(smtpPort: 1025, httpPort: 8025), package: "mailpit-1.31.1", directory: "/data/mailpit/default")
        try repository.saveManuallyClaimedInstance(record)
        try repository.replaceProjectClaims([binding("mail", kind: .mailpit, instance: "default")], for: project.id)
        var effects = 0

        XCTAssertThrowsError(try repository.removeSingletonAfterSuccessfulAction(id: record.id, packageIdentifier: record.packageIdentifier) { effects += 1 })

        XCTAssertEqual(effects, 0)
        XCTAssertEqual(try repository.instance(record.id), record)
        XCTAssertTrue(try repository.isManuallyClaimed(record.id))
    }

    func testRemovalExclusionCoversAnotherRepositoryConnection() throws {
        let (root, db, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ServiceInstanceRepository(store: store)
        let project = try projectRecord("project", at: root)
        try ProjectRepository(store: store).upsert(project)
        let record = try instance("default", kind: .mysql, endpoint: .mysql(port: 3306), package: "mysql-8.4.11", directory: "/data/mysql/default")
        try repository.saveInstance(record)
        let second = ServiceInstanceRepository(store: try SQLiteStateStore(databaseURL: db))
        let binding = try binding("database", kind: .mysql, instance: "default")
        var callbackRan = false
        try repository.removeSingletonAfterSuccessfulAction(id: record.id, packageIdentifier: record.packageIdentifier) {
            callbackRan = true
            XCTAssertThrowsError(try second.addProjectClaim(binding, for: project.id))
        }
        XCTAssertTrue(callbackRan)
        XCTAssertEqual(try repository.projectClaims(for: project.id), [])
        XCTAssertNil(try repository.instance(record.id))
    }

    func testInstancesListsEveryServiceTypeOnceInStableIdentityOrder() throws {
        let (root, _, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ServiceInstanceRepository(store: store)
        let saved = [
            try instance("zeta", kind: .valkey, endpoint: .valkey(port: 6379), package: "pkg-valkey", directory: "/data/valkey"),
            try instance("beta", kind: .mysql, endpoint: .mysql(port: 3307), package: "pkg-mysql-b", directory: "/data/mysql-b"),
            try instance("alpha", kind: .mailpit, endpoint: .mailpit(smtpPort: 1025, httpPort: 8025), package: "pkg-mailpit", directory: "/data/mailpit"),
            try instance("alpha", kind: .mysql, endpoint: .mysql(port: 3306), package: "pkg-mysql-a", directory: "/data/mysql-a"),
            try instance("gamma", kind: .redis, endpoint: .redis(port: 6379), package: "pkg-redis", directory: "/data/redis"),
            try instance("delta", kind: .postgresql, endpoint: .postgresql(port: 5432), package: "pkg-postgresql", directory: "/data/postgresql")
        ]
        for record in saved { try repository.saveInstance(record) }

        let expected = saved.sorted {
            ($0.id.kind.rawValue, $0.id.name.value) < ($1.id.kind.rawValue, $1.id.name.value)
        }
        XCTAssertEqual(try repository.instances(), expected)
        XCTAssertEqual(try repository.instances(), expected)
        XCTAssertEqual(try repository.inventorySnapshot().entries.map { "\($0.record.id.kind.rawValue)/\($0.record.id.name.value)" }, expected.map { "\($0.id.kind.rawValue)/\($0.id.name.value)" })
    }

    func testIdentityAndTypedLoopbackEndpointValidation() throws {
        XCTAssertThrowsError(try ProjectInstanceName(" bad"))
        XCTAssertThrowsError(try ServiceInstanceEndpoint.mysql(port: 0))
        XCTAssertThrowsError(try ServiceInstanceEndpoint.mailpit(smtpPort: 1025, httpPort: 1025))
        XCTAssertThrowsError(try ServiceInstanceRecord(id: .init(kind: .mysql, name: ProjectInstanceName("db")), packageIdentifier: "", endpoint: .redis(port: 6379), dataDirectory: "/data/db"))
        let id = ServiceInstanceID(kind: .mysql, name: try ProjectInstanceName("db"))
        for bad in ["pkg\0suffix", "pkg\nname", "pkg\u{7f}name"] {
            XCTAssertThrowsError(try ServiceInstanceRecord(id: id, packageIdentifier: bad, endpoint: .mysql(port: 3306), dataDirectory: "/data/db"))
        }
        for bad in ["relative/path", "/data/db\0suffix", "/data/db\nname", "/data/db\u{7f}name"] {
            XCTAssertThrowsError(try ServiceInstanceRecord(id: id, packageIdentifier: "vendor/mysql@x", endpoint: .mysql(port: 3306), dataDirectory: bad))
        }
        XCTAssertNoThrow(try ServiceInstanceRecord(id: id, packageIdentifier: "vendor/mysql@x", endpoint: .mysql(port: 3306), dataDirectory: "/data/db"))
        XCTAssertNoThrow(try ServiceInstanceRecord(id: id, packageIdentifier: "redis://opaque?channel=stable", endpoint: .mysql(port: 3306), dataDirectory: "/data/db"))
        XCTAssertNoThrow(try ServiceInstanceRecord(id: id, packageIdentifier: "mailpit#opaque", endpoint: .mysql(port: 3306), dataDirectory: "/data/db"))
    }

    func testVersionEightMigrationPreservesExistingStateAndReopenIsIdempotent() throws {
        let (root, db, initial) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try projectRecord("preserved", at: root)
        try ProjectRepository(store: initial).upsert(project)
        try ProjectRepository(store: initial).setPHPOverride("8.4.23", for: project.id)
        try ProjectRepository(store: initial).setNodeOverride(try NodeVersion("24.22.1"), for: project.id)
        try initial.execute("INSERT INTO route_intents (id,route_json,project_id,project_path) VALUES ('route',X'010203','\(project.id)','/tmp/preserved')")
        try initial.saveTLSRecord(.init(fingerprint: "finger", certificatePath: "/ca", keyApplicationTag: "tag", publicKeyFingerprint: nil, ownership: .unverified, trustDomain: "user", trustProvenance: .none, trustSettingsFingerprint: nil))
        try initial.execute("DROP TABLE project_service_claims")
        try initial.execute("DROP TABLE manual_service_claims")
        try initial.execute("DROP TABLE service_instances")
        try initial.execute("PRAGMA user_version = 8")

        let upgraded = try SQLiteStateStore(databaseURL: db)
        XCTAssertEqual(try upgraded.pragmaVersion(), 9)
        XCTAssertEqual(try ProjectRepository(store: upgraded).all().map(\.id), [project.id])
        XCTAssertEqual(try ProjectRepository(store: upgraded).phpOverride(for: project.id), "8.4.23")
        XCTAssertEqual(try ProjectRepository(store: upgraded).nodeRecords().first?.pin?.description, "24.22.1")
        XCTAssertEqual(try upgraded.tlsRecord()?.fingerprint, "finger")
        try upgraded.query("SELECT hex(route_json) FROM route_intents") { XCTAssertEqual(upgraded.columnString($0, 0), "010203") }
        XCTAssertEqual(try SQLiteStateStore(databaseURL: db).pragmaVersion(), 9)
    }

    private func makeStore() throws -> (URL, URL, SQLiteStateStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, root.appendingPathComponent("state.sqlite"), try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
    }

    private func projectRecord(_ name: String, at root: URL) throws -> LinkedProjectRecord {
        LinkedProjectRecord(id: ProjectID(), name: name, canonicalPath: root.appendingPathComponent(name).path)
    }

    private func instance(_ name: String, kind: ProjectServiceKind, endpoint: ServiceInstanceEndpoint, package: String, directory: String) throws -> ServiceInstanceRecord {
        try .init(id: .init(kind: kind, name: ProjectInstanceName(name)), packageIdentifier: package, endpoint: endpoint, dataDirectory: directory)
    }

    private func binding(_ alias: String, kind: ProjectServiceKind, instance: String) throws -> ProjectServiceBinding {
        try .init(alias: ProjectBindingAlias(alias), kind: kind, instance: ProjectInstanceName(instance))
    }
}
