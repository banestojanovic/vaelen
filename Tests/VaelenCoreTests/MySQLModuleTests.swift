import XCTest
import Darwin
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

    func testOfficialArchiveExtractionOmitsOnlyDebugDaemonAndKeepsLicense() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-mysql-extract-\(UUID().uuidString)", isDirectory: true)
        defer { makeWritableAndRemove(root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let install = source.appendingPathComponent("mysql-8.4.11-macos15-arm64", isDirectory: true)
        let bin = install.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["mysqld", "mysqld-debug", "mysql", "mysqladmin"] {
            try Data(name.utf8).write(to: bin.appendingPathComponent(name))
        }
        try Data("GPL-2.0 license text".utf8).write(to: install.appendingPathComponent("LICENSE"))
        let archive = root.appendingPathComponent("fixture.tar.gz")
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        create.arguments = ["-czf", archive.path, "-C", source.path, "mysql-8.4.11-macos15-arm64"]
        try create.run()
        create.waitUntilExit()
        XCTAssertEqual(create.terminationStatus, 0)

        let destination = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try MySQLModule(layout: VaelenFilesystemLayout(rootURL: root)).extract(archive, to: destination)

        let extracted = destination.appendingPathComponent("mysql-8.4.11-macos15-arm64")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("bin/mysqld").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("bin/mysql").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("bin/mysqladmin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("bin/mysqld-debug").path))
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("LICENSE"), encoding: .utf8), "GPL-2.0 license text")
    }

    func testExistingVerifiedPackagePrunesDebugDaemonWithoutTouchingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-mysql-prune-\(UUID().uuidString)", isDirectory: true)
        defer { makeWritableAndRemove(root) }
        let manifest = MySQLManifest.official8_4_11
        let layout = VaelenFilesystemLayout(rootURL: root)
        let packageURL = layout.mysqlPackagesDirectoryURL.appendingPathComponent(manifest.version, isDirectory: true)
        let bin = packageURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["mysqld", "mysqld-debug", "mysql", "mysqladmin"] {
            let executable = bin.appendingPathComponent(name)
            try Data(name.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: executable.path)
        }
        let package = MySQLPackage(
            version: manifest.version,
            architecture: manifest.architecture,
            packagePath: packageURL.path,
            serverPath: bin.appendingPathComponent("mysqld").path,
            clientPath: bin.appendingPathComponent("mysql").path,
            adminPath: bin.appendingPathComponent("mysqladmin").path,
            source: manifest.artifactURL.absoluteString,
            artifactSHA256: manifest.artifactSHA256,
            signatureURL: manifest.signatureURL.absoluteString,
            license: manifest.license,
            installedAt: Date()
        )
        try JSONEncoder().encode(package).write(to: packageURL.appendingPathComponent(".vaelen-package.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: packageURL.path)
        let sentinel = layout.mysqlInstancesDirectoryURL.appendingPathComponent("default/data/preserved.db")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: sentinel)

        let module = MySQLModule(layout: layout, downloader: FailingDownloader(), port: 33_417)
        _ = try module.use(manifest.version)
        let result = try module.install(requestedVersion: manifest.version)

        XCTAssertEqual(result.serverPath, bin.appendingPathComponent("mysqld").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("mysqld-debug").path))
        for name in ["mysqld", "mysql", "mysqladmin"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent(name).path))
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        XCTAssertEqual(module.selectedVersion(), manifest.version)
        XCTAssertEqual(try (FileManager.default.attributesOfItem(atPath: bin.path)[.posixPermissions] as? NSNumber)?.intValue, 0o555)
    }

    func testRemoveVerifiedPackagePreservesInstanceDataAndClearsSelection() throws {
        guard let source = MySQLModule(layout: .init()).installedVersions().first else { throw XCTSkip("installed MySQL package prerequisite unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-mysql-remove-\(UUID().uuidString)", isDirectory: true)
        defer { makeWritableAndRemove(root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let packageURL = layout.mysqlPackagesDirectoryURL.appendingPathComponent(source.version, isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source.packagePath), to: packageURL)
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod"); chmod.arguments = ["-R", "u+w", packageURL.path]; try chmod.run(); chmod.waitUntilExit()
        let package = MySQLPackage(version: source.version, architecture: source.architecture, packagePath: packageURL.path, serverPath: packageURL.appendingPathComponent("bin/mysqld").path, clientPath: packageURL.appendingPathComponent("bin/mysql").path, adminPath: packageURL.appendingPathComponent("bin/mysqladmin").path, source: source.source, artifactSHA256: source.artifactSHA256, signatureURL: source.signatureURL, license: source.license, installedAt: source.installedAt)
        try JSONEncoder().encode(package).write(to: packageURL.appendingPathComponent(".vaelen-package.json"))
        let module = MySQLModule(layout: layout)
        _ = try module.use(source.version)
        let sentinel = layout.mysqlInstancesDirectoryURL.appendingPathComponent("default/data/preserved-database-sentinel")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: sentinel)

        XCTAssertEqual(module.status().state, .installed)
        XCTAssertTrue(try module.remove(requestedVersion: source.version).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertNil(module.selectedVersion())
        XCTAssertEqual(module.status().state, .notInstalled)
    }

    func testCanonicalDefaultPortIsMySQLPort() {
        XCTAssertEqual(MySQLModule.defaultPort, 3306)
    }

    func testProjectBindingSnapshotRequiresInitializedExactDefaultAndPreservesPort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-mysql-binding-\(UUID().uuidString)")
        defer { makeWritableAndRemove(root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let packageURL = layout.mysqlPackagesDirectoryURL.appendingPathComponent(MySQLManifest.official8_4_11.version, isDirectory: true)
        let bin = packageURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["mysqld", "mysql", "mysqladmin"] {
            let file = bin.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let package = MySQLPackage(version: MySQLManifest.official8_4_11.version, architecture: "arm64", packagePath: packageURL.path, serverPath: "/fixture/mysqld", clientPath: "/fixture/mysql", adminPath: "/fixture/mysqladmin", source: "fixture", artifactSHA256: MySQLManifest.official8_4_11.artifactSHA256, signatureURL: "fixture", license: "GPL-2.0", installedAt: Date())
        let override = MySQLPackage(version: package.version, architecture: package.architecture, packagePath: packageURL.path, serverPath: bin.appendingPathComponent("mysqld").path, clientPath: bin.appendingPathComponent("mysql").path, adminPath: bin.appendingPathComponent("mysqladmin").path, source: package.source, artifactSHA256: package.artifactSHA256, signatureURL: package.signatureURL, license: package.license, installedAt: package.installedAt)
        let module = MySQLModule(layout: layout, manifest: .official8_4_11, downloader: FailingDownloader(), port: 33_417, instanceName: "default", tcpEnabled: true, packageOverride: override)
        let uninitialized = module.projectBindingSnapshot()
        XCTAssertEqual(uninitialized.record?.packageIdentifier, "mysql-8.4.11")
        XCTAssertEqual(uninitialized.record?.endpoint.portNumbers.first, 33_417)
        XCTAssertEqual(uninitialized.health, "not-initialized")
        XCTAssertEqual(uninitialized.record?.dataDirectory, layout.mysqlInstancesDirectoryURL.appendingPathComponent("default/data").path)
    }

    func testDebugPruningRejectsSymlinkedPackageBoundariesWithoutTouchingTargets() throws {
        enum Boundary: CaseIterable { case packagesParent, packages, package, bin }
        for boundary in Boundary.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-mysql-link-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let layout = VaelenFilesystemLayout(rootURL: root)
            let version = MySQLManifest.official8_4_11.version
            let packages = layout.mysqlPackagesDirectoryURL
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

            let actualPackage: URL
            switch boundary {
            case .packagesParent:
                try FileManager.default.createSymbolicLink(at: layout.packagesDirectoryURL, withDestinationURL: outside)
                actualPackage = outside.appendingPathComponent("mysql/\(version)", isDirectory: true)
            case .packages:
                try FileManager.default.createDirectory(at: layout.packagesDirectoryURL, withIntermediateDirectories: true)
                actualPackage = outside.appendingPathComponent(version, isDirectory: true)
                try FileManager.default.createSymbolicLink(at: packages, withDestinationURL: outside)
            case .package:
                try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
                actualPackage = outside.appendingPathComponent(version, isDirectory: true)
                try FileManager.default.createSymbolicLink(at: packages.appendingPathComponent(version), withDestinationURL: actualPackage)
            case .bin:
                try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: packages.appendingPathComponent(version).appendingPathComponent("bin"), withIntermediateDirectories: true)
                actualPackage = packages.appendingPathComponent(version)
                let outsideBin = outside.appendingPathComponent("bin", isDirectory: true)
                try FileManager.default.createDirectory(at: outsideBin, withIntermediateDirectories: true)
                try FileManager.default.removeItem(at: actualPackage.appendingPathComponent("bin"))
                try FileManager.default.createSymbolicLink(at: actualPackage.appendingPathComponent("bin"), withDestinationURL: outsideBin)
            }
            if boundary != .bin { try FileManager.default.createDirectory(at: actualPackage.appendingPathComponent("bin"), withIntermediateDirectories: true) }
            let bin = boundary == .bin ? outside.appendingPathComponent("bin") : actualPackage.appendingPathComponent("bin")
            for name in ["mysqld", "mysql", "mysqladmin"] {
                let file = bin.appendingPathComponent(name)
                try Data("fixture".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            let debug = bin.appendingPathComponent("mysqld-debug")
            try Data("external-debug".utf8).write(to: debug)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: debug.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: bin.path)
            try FileManager.default.createDirectory(at: layout.mysqlInstancesDirectoryURL, withIntermediateDirectories: true)
            let sentinel = layout.mysqlInstancesDirectoryURL.appendingPathComponent("data-sentinel")
            try Data("preserve-instance".utf8).write(to: sentinel)
            let package = MySQLPackage(version: version, architecture: "arm64", packagePath: packages.appendingPathComponent(version).path,
                serverPath: packages.appendingPathComponent("\(version)/bin/mysqld").path,
                clientPath: packages.appendingPathComponent("\(version)/bin/mysql").path,
                adminPath: packages.appendingPathComponent("\(version)/bin/mysqladmin").path,
                source: MySQLManifest.official8_4_11.artifactURL.absoluteString,
                artifactSHA256: MySQLManifest.official8_4_11.artifactSHA256,
                signatureURL: MySQLManifest.official8_4_11.signatureURL.absoluteString, license: "GPL-2.0", installedAt: Date())
            try JSONEncoder().encode(package).write(to: actualPackage.appendingPathComponent(".vaelen-package.json"))
            let module = MySQLModule(layout: layout)
            XCTAssertThrowsError(try module.install(requestedVersion: version), "boundary: \(boundary)")
            XCTAssertEqual(try Data(contentsOf: debug), Data("external-debug".utf8), "boundary: \(boundary)")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: debug.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: bin.path)[.posixPermissions] as? NSNumber)?.intValue, 0o750)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-instance".utf8))
        }
    }

    func testOfficialArchiveInitializesPersistsAndStopsCleanly() throws {
        let archive = URL(fileURLWithPath: "/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/opencode/mysql-8.4.11-macos15-arm64.tar.gz")
        guard FileManager.default.fileExists(atPath: archive.path) else { throw XCTSkip("M5 artifact fixture is not available") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-mysql-\(UUID().uuidString)")
        defer { makeWritableAndRemove(root) }
        let source = MySQLManifest.official8_4_11
        let manifest = MySQLManifest(version: source.version, platform: source.platform, architecture: source.architecture, artifactFile: source.artifactFile, artifactURL: archive, artifactSHA256: source.artifactSHA256, signatureURL: source.signatureURL, license: source.license)
        let module = MySQLModule(layout: VaelenFilesystemLayout(rootURL: root), manifest: manifest, port: try availableLoopbackPort())
        let package = try module.install(requestedVersion: "8.4.11")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: package.serverPath))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: package.clientPath))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: package.adminPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: package.packagePath).appendingPathComponent("bin/mysqld-debug").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: package.packagePath).appendingPathComponent("LICENSE").path))
        let debugBinary = URL(fileURLWithPath: package.packagePath).appendingPathComponent("bin/mysqld-debug")
        let binDirectory = debugBinary.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binDirectory.path)
        try Data("legacy debug daemon placeholder".utf8).write(to: debugBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: debugBinary.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: binDirectory.path)
        _ = try module.use("8.4.11")
        try module.initialize()
        XCTAssertEqual(module.status().state, .stopped)
        _ = try module.start()
        XCTAssertEqual(module.status().health, "healthy")
        _ = try module.install(requestedVersion: "8.4.11")
        XCTAssertTrue(FileManager.default.fileExists(atPath: debugBinary.path), "do not mutate package contents while MySQL is running")
        let credentials = root.appendingPathComponent("instances/mysql/default/client.cnf")
        let query = try run(package.clientPath, ["--defaults-extra-file=\(credentials.path)", "-e", "CREATE DATABASE IF NOT EXISTS m5_acceptance; CREATE TABLE IF NOT EXISTS m5_acceptance.values (value VARCHAR(32)); DELETE FROM m5_acceptance.values; INSERT INTO m5_acceptance.values VALUES ('persisted'); SELECT value FROM m5_acceptance.values;"])
        XCTAssertTrue(query.contains("persisted"))
        _ = try module.stop()
        _ = try module.install(requestedVersion: "8.4.11")
        XCTAssertFalse(FileManager.default.fileExists(atPath: debugBinary.path), "a stopped, verified legacy package should reclaim its unused debug daemon")
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

    private func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: "MySQLModuleTests", code: 1) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw NSError(domain: "MySQLModuleTests", code: 2) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getsockname(descriptor, withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &length) == 0 else { throw NSError(domain: "MySQLModuleTests", code: 3) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private struct FailingDownloader: MySQLArtifactDownloader {
    func download(_ source: URL, to destination: URL) throws { throw MySQLModuleError.validationFailed("download not expected") }
}
