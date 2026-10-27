import XCTest
@testable import VaelenCore

final class ProjectAdoptionApplyTests: XCTestCase {
    func testManifestCreationPreservesEnvAndRefusesOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let originalEnv = Data("DB_PASSWORD=do-not-read-or-change\n".utf8)
        try originalEnv.write(to: env)
        let spec = try ProjectEnvironmentSpec(version: 2, php: try PHPRequirement(value: "8.3"))
        try ProjectAdoptionManifestWriter.create(spec: spec, at: root.path, expectedManifest: nil)
        let manifest = root.appendingPathComponent("vaelen.yml")
        let originalManifest = try Data(contentsOf: manifest)
        XCTAssertThrowsError(try ProjectAdoptionManifestWriter.create(spec: spec, at: root.path, expectedManifest: originalManifest))
        XCTAssertEqual(try Data(contentsOf: manifest), originalManifest)
        XCTAssertEqual(try Data(contentsOf: env), originalEnv)
    }

    func testManifestWriterRejectsVersionOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = try ProjectEnvironmentSpec(version: 1)
        XCTAssertThrowsError(try ProjectAdoptionManifestWriter.create(spec: spec, at: root.path, expectedManifest: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("vaelen.yml").path))
    }

    func testManifestWriterRoundTripsV2ThroughProjectEnvironmentInspector() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(id: ProjectID(), name: root.lastPathComponent, rootPath: CanonicalPath(url: root), registrationKind: .linked, availability: .available)
        let empty = try ProjectEnvironmentSpec(version: 2)
        try ProjectAdoptionManifestWriter.create(spec: empty, at: root.path, expectedManifest: nil)
        XCTAssertEqual(inspect(project).projectSpec, empty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("vaelen.yml"))

        let service = try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .postgresql, instance: ProjectInstanceName("primary"), version: "16.4")
        let spec = try ProjectEnvironmentSpec(version: 2, php: PHPRequirement(value: "8.3"), node: NodeRequirement(value: "22"), web: ProjectWebRequirement(host: "app.test", documentRoot: "public", secure: true), services: [service])
        try ProjectAdoptionManifestWriter.create(spec: spec, at: root.path, expectedManifest: nil)
        XCTAssertEqual(inspect(project).projectSpec, spec)
    }

    private func inspect(_ project: Project) -> ProjectEnvironmentReport {
        ProjectEnvironmentInspector().inspect(project: project, routes: [], phpPackages: [], phpStatuses: [], phpDefault: nil,
            mysql: MySQLStatus(state: .stopped, health: "stopped", installedVersion: nil, selectedVersion: nil, pid: nil, port: 3306, socket: "", datadir: "", executablePath: ""),
            mailpit: MailpitStatus(state: .stopped, health: "stopped", installedVersion: nil, pid: nil, smtpPort: 1025, httpPort: 8025, database: "", uiEndpoint: "", executablePath: ""),
            router: RouterStatus(provider: "test", state: .stopped, health: .unknown, routeCount: 0), dns: DNSStatus(state: .installed, ownership: .vaelen, health: "healthy"), tls: TLSStatus(state: .absent), standardPorts: StandardPortsStatus(state: .absent))
    }
}
