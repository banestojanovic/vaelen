import Foundation
import XCTest
@testable import VaelenCore

/// A real managed PHP executable with all Vaelen-owned runtime state isolated
/// beneath a unique temporary support root. The package binary is only read;
/// metadata, config, logs, records, defaults, and sockets remain temporary.
struct IsolatedPHPFixture {
    let root: URL
    let layout: VaelenFilesystemLayout
    let package: PHPPackage
    let module: PHPModule

    init(installedPackage: PHPPackage, root: URL = URL(fileURLWithPath: "/private/var/tmp/vp-\(UUID().uuidString.prefix(8))", isDirectory: true)) throws {
        self.root = root
        let isolatedLayout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true), logsDirectoryURL: root.appendingPathComponent("logs", isDirectory: true))
        self.layout = isolatedLayout
        try FileManager.default.createDirectory(at: isolatedLayout.configurationDirectoryURL, withIntermediateDirectories: true)
        let packageDirectory = isolatedLayout.phpPackagesDirectoryURL.appendingPathComponent(installedPackage.version, isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        self.package = PHPPackage(
            version: installedPackage.version,
            architecture: installedPackage.architecture,
            packagePath: packageDirectory.path,
            cliPath: installedPackage.cliPath,
            fpmPath: installedPackage.fpmPath,
            source: installedPackage.source,
            cliSHA256: installedPackage.cliSHA256,
            fpmSHA256: installedPackage.fpmSHA256,
            installedAt: installedPackage.installedAt
        )
        try JSONEncoder().encode(package).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: package.version, platform: "macos", architecture: package.architecture, artifacts: [:], verification: .init(algorithm: "sha256", authenticity: "isolated-installed-runtime"))
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("fixture-manifest.json"))
        self.module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("fixture-manifest.json")))
    }

    var processRecordURL: URL { layout.phpInstancesDirectoryURL.appendingPathComponent(package.version).appendingPathComponent("process.json") }
    var socketURL: URL { layout.rootURL.appendingPathComponent("runtime/sockets/php/php-\(package.version).sock") }

    /// Always attempt the provider's identity-checked graceful stop first.
    /// Preserve the sandbox if cleanup cannot be verified so a live child is
    /// never left pointing at deleted configuration or logs.
    @discardableResult
    func cleanup(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if FileManager.default.fileExists(atPath: processRecordURL.path) {
            do { _ = try module.stop(requestedVersion: package.version) }
            catch {
                XCTFail("Isolated PHP-FPM cleanup failed: \(error)", file: file, line: line)
                return false
            }
        }
        guard !FileManager.default.fileExists(atPath: processRecordURL.path),
              !FileManager.default.fileExists(atPath: socketURL.path) else {
            XCTFail("Isolated PHP-FPM process record or socket remains; preserving its temporary root at \(root.path)", file: file, line: line)
            return false
        }
        do { try FileManager.default.removeItem(at: root) }
        catch {
            XCTFail("Could not remove isolated PHP fixture: \(error)", file: file, line: line)
            return false
        }
        return true
    }
}
