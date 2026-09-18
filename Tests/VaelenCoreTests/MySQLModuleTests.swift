import XCTest
@testable import VaelenCore

final class MySQLModuleTests: XCTestCase {
    func testOfficialManifestPinsAcceptedArtifactAndVersion() {
        let manifest = MySQLManifest.official8_4_11
        XCTAssertEqual(manifest.version, "8.4.11")
        XCTAssertEqual(manifest.architecture, "arm64")
        XCTAssertEqual(manifest.artifactSHA256.count, 64)
        XCTAssertEqual(manifest.artifactFile, "mysql-8.4.11-macos15-arm64.tar.gz")
    }

    func testInstallRejectsUnsupportedVersionWithoutCreatingPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-mysql-\(UUID().uuidString)")
        defer { makeWritableAndRemove(root) }
        let module = MySQLModule(layout: VaelenFilesystemLayout(rootURL: root), downloader: FailingDownloader())
        XCTAssertThrowsError(try module.install(requestedVersion: "8.0.46")) { error in
            XCTAssertEqual(error as? MySQLModuleError, .unsupportedVersion("8.0.46"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaelenFilesystemLayout(rootURL: root).mysqlPackagesDirectoryURL.path))
    }

    func testPackageAndDataPathsAreSeparate() {
        let layout = VaelenFilesystemLayout(rootURL: URL(fileURLWithPath: "/tmp/vaelen-mysql-test"))
        XCTAssertNotEqual(layout.mysqlPackagesDirectoryURL.path, layout.mysqlInstancesDirectoryURL.path)
        XCTAssertTrue(layout.mysqlInstancesDirectoryURL.path.contains("instances/mysql"))
        XCTAssertTrue(layout.mysqlPackagesDirectoryURL.path.contains("packages/mysql"))
    }

    func testOfficialArchiveInitializesPersistsAndStopsCleanly() throws {
        let archive = URL(fileURLWithPath: "/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/mysql-8.4.11-macos15-arm64.tar.gz")
        guard FileManager.default.fileExists(atPath: archive.path) else { throw XCTSkip("M5 artifact fixture is not available") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-mysql-\(UUID().uuidString)")
        defer { makeWritableAndRemove(root) }
        let source = MySQLManifest.official8_4_11
        let manifest = MySQLManifest(version: source.version, platform: source.platform, architecture: source.architecture, artifactFile: source.artifactFile, artifactURL: archive, artifactSHA256: source.artifactSHA256, signatureURL: source.signatureURL, license: source.license)
        let module = MySQLModule(layout: VaelenFilesystemLayout(rootURL: root), manifest: manifest)
        let package = try module.install(requestedVersion: "8.4.11")
        _ = try module.use("8.4.11")
        try module.initialize()
        XCTAssertEqual(module.status().state, .stopped)
        _ = try module.start()
        XCTAssertEqual(module.status().health, "healthy")
        let credentials = root.appendingPathComponent("instances/mysql/default/client.cnf")
        let query = try run(package.clientPath, ["--defaults-extra-file=\(credentials.path)", "-e", "CREATE DATABASE IF NOT EXISTS m5_acceptance; CREATE TABLE IF NOT EXISTS m5_acceptance.values (value VARCHAR(32)); DELETE FROM m5_acceptance.values; INSERT INTO m5_acceptance.values VALUES ('persisted'); SELECT value FROM m5_acceptance.values;"])
        XCTAssertTrue(query.contains("persisted"))
        _ = try module.stop()
        _ = try module.start()
        let persisted = try run(package.clientPath, ["--defaults-extra-file=\(credentials.path)", "-e", "SELECT value FROM m5_acceptance.values;"])
        XCTAssertTrue(persisted.contains("persisted"))
        _ = try module.stop()
        XCTAssertEqual(module.status().state, .stopped)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); let output = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = output; process.standardError = output; try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0, String(data: data, encoding: .utf8) ?? ""); return String(data: data, encoding: .utf8) ?? ""
    }

    private func makeWritableAndRemove(_ root: URL) {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let entry as URL in entries {
            let directory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            try? FileManager.default.setAttributes([.posixPermissions: directory ? 0o755 : 0o644], ofItemAtPath: entry.path)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct FailingDownloader: MySQLArtifactDownloader {
    func download(_ source: URL, to destination: URL) throws { throw MySQLModuleError.validationFailed("download not expected") }
}
