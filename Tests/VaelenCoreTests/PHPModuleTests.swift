import XCTest
@testable import VaelenCore

final class PHPModuleTests: XCTestCase {
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
