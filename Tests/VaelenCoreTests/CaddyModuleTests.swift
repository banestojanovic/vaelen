import XCTest
@testable import VaelenCore

final class CaddyModuleTests: XCTestCase {
    func testInstallVerifiesAndAtomicallyRecordsProvenanceWithoutStartingProcess() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vaelen-caddy-\(UUID().uuidString)")
        guard let fixtureRoot = ProcessInfo.processInfo.environment["VAELEN_CADDY_TEST_FIXTURE_DIR"] else {
            throw XCTSkip("Caddy authentic-upstream fixture unavailable; set VAELEN_CADDY_TEST_FIXTURE_DIR to an explicitly prepared fixture (unit test is not an upstream-release claim).")
        }
        let source = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        let archive = source.appendingPathComponent("caddy_mac_arm64.tar.gz")
        let checksum = source.appendingPathComponent("caddy_checksums.txt")
        guard FileManager.default.isReadableFile(atPath: archive.path), FileManager.default.isReadableFile(atPath: checksum.path) else {
            throw XCTSkip("Caddy authentic-upstream fixture is incomplete; expected readable archive and checksum files under VAELEN_CADDY_TEST_FIXTURE_DIR.")
        }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let manifest = CaddyManifest(version: "2.11.4", platform: "macos", architecture: "arm64", artifactFile: "caddy_2.11.4_mac_arm64.tar.gz", artifactURL: archive, artifactSHA512: "3190ae0df98b59ab4b6021556fa35adc3c526a4f3e138776b0eaec8a037cc26121cbbb1ad53453f565551b47d37d5ba4755e2c2c3652256737fe2ce9e53c8ec0", checksumURL: checksum, signatureURL: checksum, certificateURL: checksum, verificationMechanism: "test verifier", certificateIdentity: "test", certificateOIDCIssuer: "test", license: "Apache-2.0")
        let module = CaddyModule(layout: layout, manifest: manifest, downloader: CopyDownloader(), verifier: AcceptingVerifier())
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try module.install()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: package.executablePath))
        XCTAssertEqual(module.installedVersions().first?.expectedSHA512, manifest.artifactSHA512)
        XCTAssertEqual(try module.resolveInstalled(requestedVersion: "2.11.4"), package)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.caddyInstancesDirectoryURL.path))
    }

    func testTamperedChecksumFailsBeforePackagePlacement() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vaelen-caddy-\(UUID().uuidString)")
        guard let fixtureRoot = ProcessInfo.processInfo.environment["VAELEN_CADDY_TEST_FIXTURE_DIR"] else {
            throw XCTSkip("Caddy authentic-upstream fixture unavailable; set VAELEN_CADDY_TEST_FIXTURE_DIR to an explicitly prepared fixture (unit test is not an upstream-release claim).")
        }
        let source = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        let archive = source.appendingPathComponent("caddy_mac_arm64.tar.gz")
        let checksum = source.appendingPathComponent("caddy_checksums.txt")
        guard FileManager.default.isReadableFile(atPath: archive.path), FileManager.default.isReadableFile(atPath: checksum.path) else {
            throw XCTSkip("Caddy authentic-upstream fixture is incomplete; expected readable archive and checksum files under VAELEN_CADDY_TEST_FIXTURE_DIR.")
        }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let manifest = CaddyManifest(version: "2.11.4", platform: "macos", architecture: "arm64", artifactFile: "caddy_2.11.4_mac_arm64.tar.gz", artifactURL: archive, artifactSHA512: String(repeating: "0", count: 128), checksumURL: checksum, signatureURL: checksum, certificateURL: checksum, verificationMechanism: "test verifier", certificateIdentity: "test", certificateOIDCIssuer: "test", license: "Apache-2.0")
        let module = CaddyModule(layout: layout, manifest: manifest, downloader: CopyDownloader(), verifier: AcceptingVerifier())
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try module.install()) { error in XCTAssertEqual(error as? CaddyModuleError, .checksumMismatch) }
        XCTAssertTrue(module.installedVersions().isEmpty)
    }

    func testOfficialDistributionWithDevelopmentCosign() throws {
        guard ProcessInfo.processInfo.environment["VAELEN_COSIGN_PATH"] != nil,
              ProcessInfo.processInfo.environment["VAELEN_RUN_CADDY_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("authentic Caddy release test is opt-in; set VAELEN_RUN_CADDY_NETWORK_TESTS=1 and VAELEN_COSIGN_PATH")
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
}

private struct AcceptingVerifier: CaddyArtifactVerifier {
    func verify(checksum: URL, signature: URL, certificate: URL, identity: String, issuer: String) throws {}
}

private struct CopyDownloader: CaddyArtifactDownloader {
    func download(_ url: URL, to destination: URL) throws { try FileManager.default.copyItem(at: url, to: destination) }
}
