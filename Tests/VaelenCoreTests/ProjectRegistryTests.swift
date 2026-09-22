import Foundation
import XCTest
@testable import VaelenCore

final class ProjectRegistryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCanonicalPathExpandsAndResolvesExistingSymlinkWithoutLowercasing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("MixedName")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)

        let service = CanonicalPathService()
        XCTAssertEqual(service.canonicalize(link).string, service.canonicalize(project).string)
        XCTAssertTrue(service.canonicalize(project).string.contains("MixedName"))
        XCTAssertEqual(service.availability(of: service.canonicalize(project)), .available)
    }

    func testRegistryPersistsLinksAndParkedPathsAndIsIdempotent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("state"))
        let first = ProjectRegistry(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        let linked = try await first.linkWithCreation(path: project)
        XCTAssertTrue(linked.created)
        let repeatedLink = try await first.linkWithCreation(path: project)
        XCTAssertFalse(repeatedLink.created)
        let parked = try await first.parkWithCreation(path: root)
        XCTAssertTrue(parked.created)
        let repeatedPark = try await first.parkWithCreation(path: root)
        XCTAssertFalse(repeatedPark.created)
        let linkedProjects = try await first.linkedProjects()
        let parkedPaths = try await first.parkedPaths()
        XCTAssertEqual(linkedProjects.count, 1)
        XCTAssertEqual(parkedPaths.count, 1)

        let second = ProjectRegistry(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        let restoredProjects = try await second.linkedProjects()
        let restoredPaths = try await second.parkedPaths()
        XCTAssertEqual(restoredProjects.first?.id, linked.project.id)
        XCTAssertEqual(restoredPaths.count, 1)
    }

    func testRecognizedDiscoveryAndExplicitLinkWins() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["alpha/bootstrap", "alpha/config", "alpha/public", "nested/child/wp-admin", "nested/child/wp-includes", ".hidden/bootstrap", ".hidden/config", ".hidden/public"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for path in ["alpha/artisan", "alpha/public/index.php", "nested/child/wp-config.php", ".hidden/artisan", ".hidden/public/index.php"] {
            try Data("marker".utf8).write(to: root.appendingPathComponent(path))
        }
        try Data("not a project".utf8).write(to: root.appendingPathComponent("file.txt"))
        let symlink = root.appendingPathComponent("linked-child")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root.appendingPathComponent("alpha"))

        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("db.sqlite")))
        _ = try await registry.park(path: root)
        let discovered = try await registry.projectsList()
        XCTAssertEqual(Set(discovered.map(\.name)), Set(["alpha", "child"]))
        XCTAssertTrue(discovered.allSatisfy { $0.id == nil })

        let explicit = try await registry.link(path: root.appendingPathComponent("alpha"), name: "custom")
        let merged = try await registry.projectsList()
        XCTAssertEqual(merged.filter { $0.rootPath == explicit.rootPath }.count, 1)
        XCTAssertEqual(merged.first { $0.rootPath == explicit.rootPath }?.name, "custom")
        XCTAssertEqual(merged.first { $0.rootPath == explicit.rootPath }?.registrationKind, .linked)
    }

    func testUnlinkAndUnparkPreserveSourceAndMissingLink() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: project.appendingPathComponent("DO_NOT_DELETE.txt"))
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("db.sqlite")))
        _ = try await registry.link(path: project)
        try await registry.unlink(path: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("DO_NOT_DELETE.txt").path))

        _ = try await registry.link(path: project)
        try FileManager.default.removeItem(at: project)
        let missing = try await registry.linkedProjects().first
        XCTAssertEqual(missing?.availability, .missing)
        try await registry.unlink(path: project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
    }
}
