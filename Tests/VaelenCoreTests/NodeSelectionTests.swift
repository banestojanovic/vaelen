import Foundation
import XCTest
@testable import VaelenCore

final class NodeSelectionTests: XCTestCase {
    func testExactStableVersionBoundary() throws {
        XCTAssertEqual(try NodeVersion("24.22.1").description, "24.22.1")
        for value in ["24", "v24.22.1", "24.22", "24.22.1-rc.1", "024.22.1", "24.22.1/../x", "24.22.1\n"] {
            XCTAssertThrowsError(try NodeVersion(value), value)
        }
    }

    func testDeepestLinkedRootIsBoundaryAndPathsUseComponents() throws {
        let outer = NodeProjectRecord(id: ProjectID(), name: "outer", path: "/tmp/work", pin: try NodeVersion("24.22.1"))
        let inner = NodeProjectRecord(id: ProjectID(), name: "inner", path: "/tmp/work/child", pin: nil)
        XCTAssertEqual(NodeProjectBoundary.select([outer, inner], workingDirectory: "/tmp/work/child/src")?.id, inner.id)
        XCTAssertNil(NodeProjectBoundary.select([outer], workingDirectory: "/tmp/work-other"))
    }

    func testReaderDoesNotCreateMissingState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let layout = VaelenFilesystemLayout(rootURL: root)
        XCTAssertEqual(try NodeSelectionReader(databaseURL: layout.databaseURL).records(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testIndependentPinsReadOnlyAndMissingPathRemainsClearable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("state.sqlite")
        let store = try SQLiteStateStore(databaseURL: db)
        let repository = ProjectRepository(store: store)
        let first = LinkedProjectRecord(id: ProjectID(), name: "a", canonicalPath: root.appendingPathComponent("missing-a").path, customName: nil)
        let second = LinkedProjectRecord(id: ProjectID(), name: "b", canonicalPath: root.appendingPathComponent("missing-b").path, customName: nil)
        try repository.upsert(first)
        try repository.upsert(second)
        try repository.setNodeOverride(try NodeVersion("24.22.1"), for: first.id)
        try repository.setNodeOverride(try NodeVersion("24.22.1"), for: first.id)
        XCTAssertEqual(try NodeSelectionReader(databaseURL: db).records().filter { $0.pin != nil }.map(\.id), [first.id])
        try repository.setNodeOverride(nil, for: first.id)
        XCTAssertTrue(try NodeSelectionReader(databaseURL: db).records().allSatisfy { $0.pin == nil })
    }

    func testReaderRejectsIncompatibleAndMalformedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("state.sqlite")
        let store = try SQLiteStateStore(databaseURL: db)
        try store.execute("PRAGMA user_version = 7")
        XCTAssertThrowsError(try NodeSelectionReader(databaseURL: db).records())
        try store.execute("PRAGMA user_version = 9")
        try store.execute("INSERT INTO projects (id,name,canonical_path,registration_kind,node_override_version) VALUES ('bad','bad','/tmp/bad','linked','24')")
        XCTAssertThrowsError(try NodeSelectionReader(databaseURL: db).records())
    }

    func testSchemaSevenMigrationPreservesProjectIdentityAndPHPAndRoutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("state.sqlite")
        let id = ProjectID()
        do {
            let store = try SQLiteStateStore(databaseURL: db)
            let repository = ProjectRepository(store: store)
            try repository.upsert(.init(id: id, name: "preserved", canonicalPath: "/tmp/preserved", customName: nil))
            try repository.setPHPOverride("8.4.23", for: id)
            try store.execute("INSERT INTO route_intents (id,route_json,project_id,project_path) VALUES ('route',X'010203','\(id)','/tmp/preserved')")
            try store.execute("ALTER TABLE projects DROP COLUMN node_override_version")
            try store.execute("DROP TABLE project_service_claims")
            try store.execute("DROP TABLE manual_service_claims")
            try store.execute("DROP TABLE service_instances")
            try store.execute("PRAGMA user_version = 7")
        }
        let upgraded = try SQLiteStateStore(databaseURL: db)
        XCTAssertEqual(try upgraded.pragmaVersion(), 9)
        XCTAssertEqual(try ProjectRepository(store: upgraded).all().map(\.id), [id])
        XCTAssertEqual(try ProjectRepository(store: upgraded).phpOverride(for: id), "8.4.23")
        try upgraded.query("SELECT hex(route_json),project_id,project_path FROM route_intents") { statement in
            XCTAssertEqual(upgraded.columnString(statement, 0), "010203")
            XCTAssertEqual(upgraded.columnString(statement, 1), id.description)
            XCTAssertEqual(upgraded.columnString(statement, 2), "/tmp/preserved")
        }
        XCTAssertNil(try NodeSelectionReader(databaseURL: db).records().first?.pin)
    }

    func testSymlinkAliasUsesCanonicalBoundaryAndMissingPinFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let record = NodeProjectRecord(id: ProjectID(), name: "project", path: project.path, pin: try NodeVersion("24.22.1"))
        XCTAssertEqual(NodeProjectBoundary.select([record], workingDirectory: alias.path)?.id, record.id)
        let manager = NodePackageManager(layout: .init(rootURL: root))
        XCTAssertThrowsError(try manager.resolution(records: [record], workingDirectory: alias.path))
        let selection = try XCTUnwrap(manager.selections([record]).first)
        XCTAssertEqual(selection.pinnedVersion?.description, "24.22.1")
        XCTAssertFalse(selection.runtimeAvailable)
        XCTAssertEqual(try manager.resolution(records: [], workingDirectory: alias.path), .invocationPATH)
    }

    func testWALStateIsRejectedWithoutCreatingSidecars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("state.sqlite")
        do {
            let store = try SQLiteStateStore(databaseURL: db)
            try store.execute("PRAGMA journal_mode = WAL")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path + "-shm"))
        XCTAssertThrowsError(try NodeSelectionReader(databaseURL: db).records())
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path + "-wal"))
    }
}
