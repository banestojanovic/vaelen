import XCTest
import CryptoKit
@testable import VaelenCore

final class CaddyModuleTests: XCTestCase {
    func testInstallVerifiesAndAtomicallyRecordsProvenanceWithoutStartingProcess() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vaelen-caddy-\(UUID().uuidString)")
        let fixture = try makeFixture(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try fixture.module.install()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: package.executablePath))
        XCTAssertEqual(package.expectedSHA512, fixture.manifest.artifactSHA512)
        XCTAssertEqual(fixture.module.installedVersions().first?.expectedSHA512, fixture.manifest.artifactSHA512)
        XCTAssertEqual(try fixture.module.resolveInstalled(requestedVersion: "2.11.4"), package)
        XCTAssertEqual(package.source, fixture.manifest.artifactURL.absoluteString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: package.packagePath).appendingPathComponent(".vaelen-package.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.caddyInstancesDirectoryURL.path))
    }

    func testTamperedChecksumFailsBeforePackagePlacement() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vaelen-caddy-\(UUID().uuidString)")
        let fixture = try makeFixture(root: root, advertisedChecksum: String(repeating: "0", count: 128))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try fixture.module.install()) { error in XCTAssertEqual(error as? CaddyModuleError, .checksumMismatch) }
        XCTAssertTrue(fixture.module.installedVersions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.caddyPackagesDirectoryURL.appendingPathComponent(fixture.manifest.version).path), "checksum rejection must precede package placement")
    }

    /// Official artifact integration is separate from deterministic package
    /// tests. Set VAELEN_COSIGN_PATH to the development cosign executable and
    /// provide network access to Caddy's signed GitHub release assets.
    func testOfficialDistributionWithDevelopmentCosign() throws {
        guard ProcessInfo.processInfo.environment["VAELEN_COSIGN_PATH"] != nil else {
            throw XCTSkip("official-artifact integration requires VAELEN_COSIGN_PATH and network access; deterministic fixture tests cover local install behavior")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vaelen-caddy-official-\(UUID().uuidString)")
        let module = CaddyModule(layout: VaelenFilesystemLayout(rootURL: root))
        defer { try? FileManager.default.removeItem(at: root) }

        let package: CaddyPackage
        do {
            package = try module.install()
        } catch CaddyModuleError.validationFailed(let message) where message.contains("403") {
            throw XCTSkip("Caddy distribution unavailable: GitHub returned HTTP 403")
        }
        XCTAssertEqual(package.version, "2.11.4")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: package.executablePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaelenFilesystemLayout(rootURL: root).caddyInstancesDirectoryURL.path))
    }

    private struct Fixture {
        let layout: VaelenFilesystemLayout
        let manifest: CaddyManifest
        let module: CaddyModule
    }

    private func makeFixture(root: URL, advertisedChecksum: String? = nil) throws -> Fixture {
        let fixtureRoot = root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let source = fixtureRoot.appendingPathComponent("caddy.c")
        let executable = fixtureRoot.appendingPathComponent("caddy")
        try "#include <stdio.h>\n#include <string.h>\nint main(int argc, char **argv) { if (argc > 1 && strcmp(argv[1], \"version\") == 0) { puts(\"v2.11.4\"); return 0; } return 0; }\n".write(to: source, atomically: true, encoding: .utf8)

        let compile = Process()
        let compileOutput = Pipe()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["--sdk", "macosx", "clang", "-arch", "arm64", "-mmacosx-version-min=14.0", "-o", executable.path, source.path]
        compile.standardOutput = compileOutput
        compile.standardError = compileOutput
        try compile.run()
        let compileData = compileOutput.fileHandleForReading.readDataToEndOfFile()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            throw NSError(domain: "CaddyModuleTests.fixture", code: Int(compile.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: compileData, as: UTF8.self)])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let artifactFile = "caddy_2.11.4_mac_arm64.tar.gz"
        let archive = fixtureRoot.appendingPathComponent(artifactFile)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", fixtureRoot.path, "caddy"]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw NSError(domain: "CaddyModuleTests.fixture", code: Int(tar.terminationStatus)) }

        let actualChecksum = SHA512.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        let expectedChecksum = advertisedChecksum ?? actualChecksum
        let checksum = fixtureRoot.appendingPathComponent("checksums.txt")
        try "\(expectedChecksum)  \(artifactFile)\n".write(to: checksum, atomically: true, encoding: .utf8)
        let manifest = CaddyManifest(version: "2.11.4", platform: "macos", architecture: "arm64", artifactFile: artifactFile, artifactURL: archive, artifactSHA512: expectedChecksum, checksumURL: checksum, signatureURL: checksum, certificateURL: checksum, verificationMechanism: "test verifier", certificateIdentity: "test", certificateOIDCIssuer: "test", license: "Apache-2.0")
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true))
        let module = CaddyModule(layout: layout, manifest: manifest, downloader: CopyDownloader(), verifier: AcceptingVerifier())
        return Fixture(layout: layout, manifest: manifest, module: module)
    }
}

private struct AcceptingVerifier: CaddyArtifactVerifier {
    func verify(checksum: URL, signature: URL, certificate: URL, identity: String, issuer: String) throws {}
}

private struct CopyDownloader: CaddyArtifactDownloader {
    func download(_ url: URL, to destination: URL) throws { try FileManager.default.copyItem(at: url, to: destination) }
}
