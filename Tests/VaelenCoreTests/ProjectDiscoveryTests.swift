import Foundation
import XCTest
@testable import VaelenCore

final class ProjectDiscoveryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeLaravel(at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bootstrap"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("public"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env php\n".utf8).write(to: root.appendingPathComponent("artisan"))
        try Data("<?php\n".utf8).write(to: root.appendingPathComponent("public/index.php"))
        try Data(#"{"require":{"php":"^8.4","laravel/framework":"^12"}}"#.utf8).write(to: root.appendingPathComponent("composer.json"))
        return root
    }

    @discardableResult
    private func makeWordPress(at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wp-admin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wp-includes"), withIntermediateDirectories: true)
        try Data("<?php\n".utf8).write(to: root.appendingPathComponent("wp-config.php"))
        return root
    }

    @discardableResult
    private func makeReact(at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"dependencies":{"react":"^19.0.0"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        return root
    }

    private func parked(_ roots: [URL]) -> [ParkedPath] {
        let paths = CanonicalPathService()
        return roots.map { ParkedPath(id: ParkedPathID(), rootPath: paths.canonicalize($0), availability: .available) }
    }

    func testEmptyParkedRootsProduceNoDiscoveries() {
        XCTAssertTrue(ProjectDiscovery().discover(under: []).isEmpty)
    }

    func testRecognizesMultipleSupportedProjectsAndIgnoresOrdinaryDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLaravel(at: root.appendingPathComponent("laravel"))
        try makeWordPress(at: root.appendingPathComponent("wordpress"))
        try makeReact(at: root.appendingPathComponent("react"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("not a project".utf8).write(to: root.appendingPathComponent("notes/readme.txt"))

        let projects = ProjectDiscovery().discover(under: parked([root]))

        XCTAssertEqual(Dictionary(uniqueKeysWithValues: projects.compactMap { project in project.detectedFramework.map { (project.name, $0) } }), [
            "laravel": "Laravel", "wordpress": "WordPress", "react": "React"
        ])
        XCTAssertTrue(projects.allSatisfy { $0.registrationKind == .discovered && $0.visibilitySources == [.parkedFolder] })
    }

    func testIgnoredDependencyCacheAndHiddenDirectoriesAreNotTraversed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [".git", "node_modules", "vendor", ".build", "DerivedData", "Pods", ".cache", "tmp", "temp", ".hidden"] {
            try makeLaravel(at: root.appendingPathComponent(name).appendingPathComponent("false-positive"))
        }

        XCTAssertTrue(ProjectDiscovery().discover(under: parked([root])).isEmpty)
    }

    func testDiscoveryIsBoundedAtDepthTwoAndStopsAtRecognizedRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeLaravel(at: root.appendingPathComponent("direct"))
        try makeWordPress(at: root.appendingPathComponent("group/nested"))
        try makeReact(at: root.appendingPathComponent("one/two/too-deep"))
        try makeWordPress(at: root.appendingPathComponent("direct/child-must-not-appear"))

        let projects = ProjectDiscovery().discover(under: parked([root]))

        XCTAssertEqual(Set(projects.map(\.name)), Set(["direct", "nested"]))
    }

    func testCanonicalAndOverlappingParkedRootsDeduplicateProjects() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appendingPathComponent("group", isDirectory: true)
        let project = try makeLaravel(at: group.appendingPathComponent("project"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("project-alias"), withDestinationURL: project)

        let projects = ProjectDiscovery().discover(under: parked([root, group]))

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.rootPath.string, project.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testProjectSymlinkUsesCanonicalTargetIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parkedRoot = root.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: parkedRoot, withIntermediateDirectories: true)
        let target = try makeWordPress(at: root.appendingPathComponent("target"))
        try FileManager.default.createSymbolicLink(at: parkedRoot.appendingPathComponent("alias"), withDestinationURL: target)

        let projects = ProjectDiscovery().discover(under: parked([parkedRoot]))

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.rootPath.string, target.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    func testExplicitLinkAndParkedDiscoveryPresentOneProjectWithBothSources() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeLaravel(at: root.appendingPathComponent("syncproof"))
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state/vaelen.sqlite")))
        _ = try await registry.link(path: project)
        _ = try await registry.park(path: root)

        let projects = try await registry.projectsList()

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.registrationKind, .linked)
        XCTAssertEqual(projects.first?.detectedFramework, "Laravel")
        XCTAssertEqual(projects.first?.visibilitySources, [.explicitLink, .parkedFolder])
        let links = try await registry.linkedProjects()
        XCTAssertEqual(links.count, 1)

        try await registry.unpark(path: root)
        let afterUnpark = try await registry.projectsList()
        XCTAssertEqual(afterUnpark.count, 1)
        XCTAssertEqual(afterUnpark.first?.registrationKind, .linked)
        XCTAssertEqual(afterUnpark.first?.visibilitySources, [.explicitLink])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
    }

    func testDisappearanceRemovesOnlyDerivedDiscovery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let discovered = try makeLaravel(at: root.appendingPathComponent("discovered"))
        let explicit = try makeWordPress(at: root.appendingPathComponent("explicit"))
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state/vaelen.sqlite")))
        _ = try await registry.park(path: root)
        _ = try await registry.link(path: explicit)
        let initialProjects = try await registry.projectsList()
        XCTAssertEqual(initialProjects.count, 2)

        try FileManager.default.removeItem(at: discovered)
        let projects = try await registry.projectsList()

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.rootPath.string, explicit.path)
        XCTAssertEqual(projects.first?.availability, .available)
    }

    func testDiscoveryDoesNotMutateProjectContents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try makeLaravel(at: root.appendingPathComponent("project"))
        let sentinel = project.appendingPathComponent("sentinel.txt")
        try Data("preserve exactly".utf8).write(to: sentinel)
        let before = try recursiveContents(of: root)

        _ = ProjectDiscovery().discover(under: parked([root]))

        XCTAssertEqual(try recursiveContents(of: root), before)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserve exactly")
    }

    func testDirectChildScanFindsOnlySupportedImmediateProjectsAndSurfacesUnavailableParent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("direct-child", isDirectory: true)
        try makeLaravel(at: child)
        let nested = child.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try makeWordPress(at: nested)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ordinary"), withIntermediateDirectories: true)
        let parked = ParkedPath(id: ParkedPathID(), rootPath: CanonicalPath(url: root), availability: .available)
        let discovered = try ProjectDiscovery().discoverDirectChildren(under: parked)
        XCTAssertEqual(discovered.map(\.rootPath.string), [child.standardizedFileURL.path])

        let unavailable = ParkedPath(id: parked.id, rootPath: CanonicalPath(url: root.appendingPathComponent("missing")), availability: .missing)
        XCTAssertThrowsError(try ProjectDiscovery().discoverDirectChildren(under: unavailable))
    }

    private func recursiveContents(of root: URL) throws -> [String] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])!
        return enumerator.compactMap { value -> String? in
            guard let url = value as? URL else { return nil }
            return url.path.replacingOccurrences(of: root.path + "/", with: "")
        }.sorted()
    }
}
