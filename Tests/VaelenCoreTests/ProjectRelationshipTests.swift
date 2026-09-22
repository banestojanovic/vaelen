import Foundation
import XCTest
@testable import VaelenCore

final class ProjectRelationshipTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaelen-project-relationships-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRelationshipListsAreInitiallyEmpty() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))

        let parkedPaths = try await registry.parkedPaths()
        let linkedProjects = try await registry.linkedProjects()
        XCTAssertTrue(parkedPaths.isEmpty)
        XCTAssertTrue(linkedProjects.isEmpty)
    }

    func testParkIsCanonicalIdempotentValidatedAndNonDestructive() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let alias = root.appendingPathComponent("workspace-alias")
        let file = root.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
        try Data("preserve".utf8).write(to: file)
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))

        let first = try await registry.parkWithCreation(path: workspace)
        let repeated = try await registry.parkWithCreation(path: alias)
        XCTAssertTrue(first.created)
        XCTAssertFalse(repeated.created)
        XCTAssertEqual(repeated.path.id, first.path.id)
        let parkedPaths = try await registry.parkedPaths()
        XCTAssertEqual(parkedPaths.map(\.rootPath.string), [workspace.resolvingSymlinksInPath().standardizedFileURL.path])

        do {
            _ = try await registry.park(path: root.appendingPathComponent("missing"))
            XCTFail("A nonexistent parked root must be rejected")
        } catch {
            XCTAssertEqual(error as? ProjectRegistryError, .pathUnavailable(.missing))
        }
        do {
            _ = try await registry.park(path: file)
            XCTFail("A file must not be accepted as a parked root")
        } catch {
            XCTAssertEqual(error as? ProjectRegistryError, .pathUnavailable(.notDirectory))
        }

        try await registry.unpark(path: alias)
        let pathsAfterUnpark = try await registry.parkedPaths()
        XCTAssertTrue(pathsAfterUnpark.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        do {
            try await registry.unpark(path: workspace)
            XCTFail("A missing parked relationship must be reported")
        } catch {
            XCTAssertEqual(error as? ProjectRegistryError, .parkedPathNotFound)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testExplicitLinkIsCanonicalIdempotentValidatedAndNonDestructive() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let alias = root.appendingPathComponent("project-alias")
        let sentinel = project.appendingPathComponent("DO_NOT_DELETE.txt")
        let file = root.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        try Data("preserve".utf8).write(to: file)
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))

        let first = try await registry.linkWithCreation(path: project)
        let repeated = try await registry.linkWithCreation(path: alias)
        XCTAssertTrue(first.created)
        XCTAssertFalse(repeated.created)
        XCTAssertEqual(repeated.project.id, first.project.id)
        let linkedProjects = try await registry.linkedProjects()
        XCTAssertEqual(linkedProjects.map(\.rootPath.string), [project.resolvingSymlinksInPath().standardizedFileURL.path])

        do {
            _ = try await registry.link(path: root.appendingPathComponent("missing"))
            XCTFail("A nonexistent project link must be rejected")
        } catch {
            XCTAssertEqual(error as? ProjectRegistryError, .pathUnavailable(.missing))
        }
        do {
            _ = try await registry.link(path: file)
            XCTFail("A file must not be accepted as an explicit project link")
        } catch {
            XCTAssertEqual(error as? ProjectRegistryError, .pathUnavailable(.notDirectory))
        }

        try await registry.unlink(path: alias)
        let projectsAfterUnlink = try await registry.linkedProjects()
        XCTAssertTrue(projectsAfterUnlink.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        do {
            try await registry.unlink(path: project)
            XCTFail("A missing explicit relationship must be reported")
        } catch {
            XCTAssertEqual(error as? ProjectRegistryError, .projectNotFound)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testParkAndExplicitLinksPersistAndRemainIndependent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let existingProject = root.appendingPathComponent("existing", isDirectory: true)
        let nestedProject = workspace.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existingProject, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("state/state.sqlite")

        let first = ProjectRegistry(store: try SQLiteStateStore(databaseURL: database))
        let existing = try await first.link(path: existingProject)
        let nested = try await first.link(path: nestedProject)
        let parked = try await first.park(path: workspace)

        let recreated = ProjectRegistry(store: try SQLiteStateStore(databaseURL: database))
        let recreatedProjects = try await recreated.linkedProjects()
        let recreatedPaths = try await recreated.parkedPaths()
        XCTAssertEqual(Set(recreatedProjects.compactMap(\.id)), Set([existing.id, nested.id].compactMap { $0 }))
        XCTAssertEqual(recreatedPaths.map(\.id), [parked.id])

        try await recreated.unpark(path: workspace)
        let projectsAfterUnpark = try await recreated.linkedProjects()
        let pathsAfterUnpark = try await recreated.parkedPaths()
        XCTAssertEqual(Set(projectsAfterUnpark.compactMap(\.id)), Set([existing.id, nested.id].compactMap { $0 }))
        XCTAssertTrue(pathsAfterUnpark.isEmpty)

        _ = try await recreated.park(path: workspace)
        try await recreated.unlink(path: nestedProject)
        let projectsAfterUnlink = try await recreated.linkedProjects()
        let pathsAfterUnlink = try await recreated.parkedPaths()
        XCTAssertEqual(projectsAfterUnlink.compactMap(\.id), [existing.id].compactMap { $0 })
        XCTAssertEqual(pathsAfterUnlink.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedProject.path))
    }

    func testShellStyleTildePathIsExpandedBeforePersistence() async throws {
        let name = ".vaelen-project-relationship-test-\(UUID().uuidString)"
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))

        let linked = try await registry.linkWithCreation(path: "~/\(name)", workingDirectory: "/")

        XCTAssertEqual(linked.project.rootPath.string, directory.standardizedFileURL.path)
        let linkedProjects = try await registry.linkedProjects()
        XCTAssertEqual(linkedProjects.first?.rootPath.string, directory.standardizedFileURL.path)
    }
}
