import XCTest
@testable import VaelenCore

final class PHPModuleTests: XCTestCase {
    func testRuntimeCatalogKeepsInstalledDefaultAndRunningIndependent() {
        let first = PHPPackage(version: "8.4.23", architecture: "arm64", packagePath: "/php/8.4.23", cliPath: "/php/8.4.23/php", fpmPath: "/php/8.4.23/php-fpm", source: "fixture", cliSHA256: "cli", fpmSHA256: "fpm", installedAt: Date())
        let second = PHPPackage(version: "8.3.30", architecture: "arm64", packagePath: "/php/8.3.30", cliPath: "/php/8.3.30/php", fpmPath: "/php/8.3.30/php-fpm", source: "fixture", cliSHA256: "cli", fpmSHA256: "fpm", installedAt: Date())
        let running = PHPStatus(version: "8.4.23", package: first, state: .running, pid: 42, socket: "/tmp/php.sock", health: "healthy", isDefault: true)
        let stopped = PHPStatus(version: "8.3.30", package: second, state: .stopped, pid: nil, socket: "/tmp/php-old.sock", health: "stopped", isDefault: false)

        let catalog = PHPRuntimeCatalog(availableVersions: ["8.5.0", "8.4.23", "8.4.23"], packages: [second, first, first], statuses: [stopped, running], defaultVersion: "8.4.23", updates: [PHPUpdateObservation(installedVersion: "8.4.23", latestVersion: "8.4.25")])

        XCTAssertEqual(catalog.availableVersions, ["8.4.23", "8.5.0"])
        XCTAssertEqual(catalog.installedVersions.map(\.version), ["8.3.30", "8.4.23"])
        XCTAssertEqual(catalog.defaultVersion, "8.4.23")
        XCTAssertEqual(catalog.runningVersions, ["8.4.23"])
        XCTAssertEqual(catalog.installedVersions.first { $0.version == "8.3.30" }?.running, false)
        XCTAssertEqual(catalog.installedVersions.first { $0.version == "8.4.23" }?.updateAvailable, true)
    }

    func testPHPUpdateObservationDistinguishesSameSeriesPatchAndUnknownMetadata() {
        XCTAssertEqual(PHPUpdateObservation(installedVersion: "8.4.23", latestVersion: "8.4.25").updateAvailable, true)
        XCTAssertEqual(PHPUpdateObservation(installedVersion: "8.4.23", latestVersion: "8.5.0").updateAvailable, false)
        XCTAssertNil(PHPUpdateObservation(installedVersion: "8.4.23").updateAvailable)
    }

    func testCurrentManagedPHPIsReportedWithExactIdentityWhenAvailable() throws {
        guard let module = PHPModule.development() else { throw XCTSkip("development PHP manifest unavailable") }
        let catalog = try module.runtimeCatalog()
        XCTAssertTrue(catalog.installedVersions.contains { $0.version == "8.4.23" })
        XCTAssertEqual(catalog.installedVersions.first { $0.version == "8.4.23" }?.series, "8.4")
    }

    func testCatalogFixtureCanDescribeMultipleAvailableReleasesWithoutNetwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let verification = PHPVerification(algorithm: "sha256", authenticity: "fixture")
        let manifests = [
            PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: [:], verification: verification),
            PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.25", platform: "macos", architecture: "arm64", artifacts: [:], verification: verification),
            PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.5.0", platform: "macos", architecture: "arm64", artifacts: [:], verification: verification)
        ]
        let manifestURL = root.appendingPathComponent("php-distribution.json")
        try JSONEncoder().encode(manifests[0]).write(to: manifestURL)
        try JSONEncoder().encode(PHPManifestCatalog(manifests: manifests)).write(to: root.appendingPathComponent("php-catalog.json"))
        let module = PHPModule(layout: VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support")), location: FilePHPManifestLocation(manifestURL: manifestURL))
        XCTAssertEqual(try module.availableVersions(), ["8.4.23", "8.4.25", "8.5.0"])
        XCTAssertThrowsError(try module.install(requestedVersion: "8.4.25"))
        XCTAssertEqual(module.operationState()?.phase, .failed)
        XCTAssertTrue(module.installedVersions().isEmpty)
    }

    func testUnknownPHPInstallDoesNotCreateRuntimeOrClaimInstalledState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: [:], verification: .init(algorithm: "sha256", authenticity: "fixture"))
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"))
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: manifestURL))
        XCTAssertThrowsError(try module.install(requestedVersion: "8.5.0")) { error in
            XCTAssertEqual(error as? PHPModuleError, .unsupportedVersion("8.5.0"))
        }
        XCTAssertTrue(module.installedVersions().isEmpty)
        XCTAssertEqual(module.operationState()?.phase, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpPackagesDirectoryURL.appendingPathComponent("8.5.0").path))
    }

    func testRemovalOfMissingVersionIsIdempotentInIsolatedRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: [:], verification: .init(algorithm: "sha256", authenticity: "fixture"))
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let module = PHPModule(layout: VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support")), location: FilePHPManifestLocation(manifestURL: manifestURL))
        XCTAssertNoThrow(try module.remove(requestedVersion: "8.4.23"))
        XCTAssertEqual(module.operationState()?.phase, .removed)
    }

    func testRealDefaultRunningPHPCannotBeRemoved() throws {
        guard let module = PHPModule.development() else { throw XCTSkip("development PHP manifest unavailable") }
        XCTAssertThrowsError(try module.remove(requestedVersion: "8.4.23")) { error in
            XCTAssertEqual(error as? PHPModuleError, .cannotRemoveActiveRuntime("8.4.23"))
        }
        XCTAssertEqual(try module.runtimeCatalog().installedVersions.first { $0.version == "8.4.23" }?.running, true)
    }

    func testNumericPHPVersionResolutionUsesHighestStablePatch() {
        XCTAssertEqual(PHPVersionResolver.resolve("8.4", versionStrings: ["8.4.9", "8.4.23", "8.3.99"]), "8.4.23")
        XCTAssertEqual(PHPVersionResolver.resolve("8.4.9", versionStrings: ["8.4.9", "8.4.23"]), "8.4.9")
        XCTAssertEqual(PHPVersionResolver.resolve("latest", versionStrings: ["8.4.9", "8.4.23", "8.3.30"]), "8.4.23")
        XCTAssertNil(PHPVersionResolver.resolve("8.5", versionStrings: ["8.4.23"]))
        XCTAssertNil(PHPVersionResolver.resolve("8.4", versionStrings: ["8.4.23-beta1"]))
    }

    func testInvalidInstalledPHPMetadataIsObservedButIneligible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageRoot = root.appendingPathComponent("support/packages/php/8.4.23")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let package = PHPPackage(version: "8.4.23", architecture: "arm64", packagePath: packageRoot.path, cliPath: "/missing/php", fpmPath: "/missing/php-fpm", source: "fixture", cliSHA256: String(repeating: "0", count: 64), fpmSHA256: String(repeating: "0", count: 64), installedAt: Date())
        try JSONEncoder().encode(package).write(to: packageRoot.appendingPathComponent(".vaelen-package.json"))
        let module = PHPModule(layout: VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support")), location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("manifest.json")))
        let observation = try XCTUnwrap(module.packageObservations().first)
        XCTAssertEqual(observation.version, "8.4.23")
        XCTAssertEqual(observation.eligibility, .invalid)
        XCTAssertTrue(module.eligibleInstalledVersions().isEmpty)
    }

    func testChecksumFailureDoesNotCreatePackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let release = root.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let cli = release.appendingPathComponent("cli.tar.gz")
        let fpm = release.appendingPathComponent("fpm.tar.gz")
        try Data("not an archive".utf8).write(to: cli)
        try Data("not an archive".utf8).write(to: fpm)
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: [
            "cli": PHPArtifact(file: cli.lastPathComponent, url: "https://invalid/cli.tar.gz", sha256: String(repeating: "0", count: 64)),
            "fpm": PHPArtifact(file: fpm.lastPathComponent, url: "https://invalid/fpm.tar.gz", sha256: String(repeating: "0", count: 64))
        ], verification: PHPVerification(algorithm: "sha256", authenticity: "test"))
        let manifestURL = release.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"))
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: manifestURL, baseURL: release))

        XCTAssertThrowsError(try module.install(requestedVersion: "8.4"))
        XCTAssertTrue(module.installedVersions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpPackagesDirectoryURL.appendingPathComponent("8.4.23").path))
    }

    func testExecUsesCallerWorkingDirectoryAndPreservesArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workingDirectory = root.appendingPathComponent("fixture with spaces")
        let packageDirectory = root.appendingPathComponent("support/packages/php/8.4.23")
        let executable = root.appendingPathComponent("php-fixture.sh")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data("fixture script\n".utf8).write(to: workingDirectory.appendingPathComponent("test.php"))
        try Data("#!/bin/sh\nprintf 'cwd=%s\\n' \"$PWD\"\nprintf 'script='\ncat \"$1\"\nshift\nfor argument in \"$@\"; do printf 'arg=<%s>\\n' \"$argument\"; done\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let package = PHPPackage(version: "8.4.23", architecture: "arm64", packagePath: packageDirectory.path, cliPath: executable.path, fpmPath: executable.path, source: "fixture", cliSHA256: "cli", fpmSHA256: "fpm", installedAt: Date())
        try JSONEncoder().encode(package).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"))
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("manifest.json")))

        let result = try module.exec(workingDirectory: workingDirectory.path, arguments: ["test.php", "--flag", "value with spaces"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("cwd=") && result.output.contains("/fixture with spaces\n"), result.output)
        XCTAssertTrue(result.output.contains("fixture script"))
        XCTAssertTrue(result.output.contains("arg=<--flag>"))
        XCTAssertTrue(result.output.contains("arg=<value with spaces>"))
    }

    func testExecRejectsMissingWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let packageDirectory = root.appendingPathComponent("support/packages/php/8.4.23")
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let package = PHPPackage(version: "8.4.23", architecture: "arm64", packagePath: packageDirectory.path, cliPath: "/bin/echo", fpmPath: "/bin/echo", source: "fixture", cliSHA256: "cli", fpmSHA256: "fpm", installedAt: Date())
        try JSONEncoder().encode(package).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"))
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("manifest.json")))

        XCTAssertThrowsError(try module.exec(workingDirectory: root.appendingPathComponent("missing").path, arguments: ["test.php"])) { error in
            XCTAssertEqual(error as? PHPModuleError, .invalidWorkingDirectory(root.appendingPathComponent("missing").path))
        }
    }
}
