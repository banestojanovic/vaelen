import XCTest
import CryptoKit
@testable import VaelenCore

private struct TestCatalogCheckState: Codable { let checkedAt: Date; let error: String? }

private final class ArtifactProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [(Int64, Int64?)]()
    func append(_ bytes: Int64, _ total: Int64?) { lock.lock(); values.append((bytes, total)); lock.unlock() }
    func snapshot() -> [(Int64, Int64?)] { lock.lock(); defer { lock.unlock() }; return values }
}

final class PHPModuleTests: XCTestCase {
    func testSuccessfulValidationCacheInvalidatesExecutableAndMetadataChanges() throws {
        let fixture = try isolatedFixture()
        defer { fixture.cleanup() }
        let directory = URL(fileURLWithPath: fixture.package.packagePath)
        let cli = directory.appendingPathComponent("php-copy")
        try FileManager.default.copyItem(atPath: fixture.package.cliPath, toPath: cli.path)
        let package = PHPPackage(version: fixture.package.version, architecture: fixture.package.architecture, packagePath: directory.path, cliPath: cli.path, fpmPath: fixture.package.fpmPath, source: fixture.package.source, cliSHA256: fixture.package.cliSHA256, fpmSHA256: fixture.package.fpmSHA256, installedAt: fixture.package.installedAt)
        let metadata = directory.appendingPathComponent(".vaelen-package.json")
        let data = try JSONEncoder().encode(package)
        try data.write(to: metadata)
        XCTAssertEqual(fixture.module.packageObservations().first?.eligibility, .eligible)
        XCTAssertEqual(fixture.module.packageObservations().first?.eligibility, .eligible)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cli.path)
        XCTAssertEqual(fixture.module.packageObservations().first?.eligibility, .invalid)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        XCTAssertEqual(fixture.module.packageObservations().first?.eligibility, .eligible)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        XCTAssertEqual(fixture.module.packageObservations().first?.eligibility, .invalid, "Changed executable must not inherit a prior validation")
        try FileManager.default.removeItem(at: cli)
        try FileManager.default.copyItem(atPath: fixture.package.cliPath, toPath: cli.path)
        XCTAssertEqual(fixture.module.packageObservations().first?.eligibility, .eligible)
        try Data("invalid metadata".utf8).write(to: metadata)
        XCTAssertEqual(fixture.module.packageObservations().first?.eligibility, .invalid)
        try data.write(to: metadata)
        XCTAssertEqual(fixture.module.packageObservations().first?.eligibility, .eligible)
    }
    func testRuntimeCatalogKeepsInstalledDefaultAndRunningIndependent() {
        let first = PHPPackage(version: "8.4.23", architecture: "arm64", packagePath: "/php/8.4.23", cliPath: "/php/8.4.23/php", fpmPath: "/php/8.4.23/php-fpm", source: "fixture", cliSHA256: "cli", fpmSHA256: "fpm", installedAt: Date())
        let second = PHPPackage(version: "8.3.30", architecture: "arm64", packagePath: "/php/8.3.30", cliPath: "/php/8.3.30/php", fpmPath: "/php/8.3.30/php-fpm", source: "fixture", cliSHA256: "cli", fpmSHA256: "fpm", installedAt: Date())
        let running = PHPStatus(version: "8.4.23", package: first, state: .running, pid: 42, socket: "/tmp/php.sock", health: "healthy", isDefault: true)
        let stopped = PHPStatus(version: "8.3.30", package: second, state: .stopped, pid: nil, socket: "/tmp/php-old.sock", health: "stopped", isDefault: false)

        let catalog = PHPRuntimeCatalog(availableVersions: ["8.5.0", "8.4.23", "8.4.23"], packages: [second, first, first], statuses: [stopped, running], defaultVersion: "8.4.23", updates: [PHPUpdateObservation(installedVersion: "8.4.23", latestVersion: "8.4.25")])

        XCTAssertEqual(catalog.availableVersions, ["8.5.0", "8.4.23"])
        XCTAssertEqual(catalog.installedVersions.map(\.version), ["8.4.23", "8.3.30"])
        XCTAssertEqual(catalog.defaultVersion, "8.4.23")
        XCTAssertEqual(catalog.runningVersions, ["8.4.23"])
        XCTAssertEqual(catalog.installedVersions.first { $0.version == "8.3.30" }?.running, false)
        XCTAssertEqual(catalog.installedVersions.first { $0.version == "8.4.23" }?.updateAvailable, true)
    }

    func testRuntimeCatalogOrdersVersionsNumericallyNewestFirst() {
        let versions = ["8.4.9", "8.3.29", "8.5.0", "8.4.23"]
        let catalog = PHPRuntimeCatalog(availableVersions: versions, installedVersions: versions.map { .init(version: $0) }, defaultVersion: nil, runningVersions: [])
        XCTAssertEqual(catalog.availableVersions, ["8.5.0", "8.4.23", "8.4.9", "8.3.29"])
        XCTAssertEqual(catalog.installedVersions.map(\.version), ["8.5.0", "8.4.23", "8.4.9", "8.3.29"])
    }

    func testCatalogRefreshPersistsAttemptTimeThrottlesFailureAndKeepsLastValidCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifacts = ["cli": PHPArtifact(file: "cli", url: "https://example.test/cli", sha256: String(repeating: "a", count: 64)), "fpm": PHPArtifact(file: "fpm", url: "https://example.test/fpm", sha256: String(repeating: "b", count: 64))]
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: artifacts, verification: .init(algorithm: "sha256", authenticity: "trusted-vaelen-release-manifest"))
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try JSONEncoder().encode(PHPManifestCatalog(manifests: [manifest])).write(to: root.appendingPathComponent("php-catalog.json"))
        let stateURL = root.appendingPathComponent("php-catalog-check.json")
        let oldEncoder = JSONEncoder()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try oldEncoder.encode(TestCatalogCheckState(checkedAt: now.addingTimeInterval(-13 * 60 * 60), error: nil)).write(to: stateURL)
        let location = FilePHPManifestLocation(manifestURL: manifestURL, catalogURL: URL(string: "http://127.0.0.1:1/unreachable")!, now: { now })

        XCTAssertThrowsError(try location.refreshCatalogIfNeeded())
        let firstStatus = location.catalogCheckStatus()
        XCTAssertEqual(firstStatus.0, now.addingTimeInterval(-13 * 60 * 60), "A failed attempt must not advance the last successful check date.")
        XCTAssertNotNil(firstStatus.1)
        XCTAssertEqual(try location.manifests(), [manifest])
        XCTAssertNoThrow(try location.refreshCatalogIfNeeded(), "A failed check is persisted and must not immediately retry.")
        XCTAssertEqual(location.catalogCheckStatus().0, firstStatus.0)
        XCTAssertTrue(String(describing: try XCTUnwrap(firstStatus.1)).contains("could not be reached"))
        XCTAssertThrowsError(try location.checkCatalogNow()) { error in
            guard case PHPModuleError.catalogUnavailable(let message) = error else { return XCTFail("feed failure must retain its catalog-specific cause: \(error)") }
            XCTAssertTrue(message.contains("could not be reached"))
        }
    }

    func testHTTPAndInvalidCatalogFailuresPreserveLastValidCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-catalog-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.26", platform: "macos", architecture: "arm64", artifacts: [
            "cli": PHPArtifact(file: "cli.tar.gz", url: "https://example.test/cli.tar.gz", sha256: String(repeating: "a", count: 64)),
            "fpm": PHPArtifact(file: "fpm.tar.gz", url: "https://example.test/fpm.tar.gz", sha256: String(repeating: "b", count: 64))
        ], verification: .init(algorithm: "sha256", authenticity: "trusted-vaelen-release-manifest"))
        let cacheURL = root.appendingPathComponent("php-catalog.json")
        let originalCache = try JSONEncoder().encode(PHPManifestCatalog(manifests: [manifest]))
        try originalCache.write(to: cacheURL)
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let stateURL = root.appendingPathComponent("php-catalog-check.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        for (status, responseBody, expectedCause) in [
            (503, Data("temporarily unavailable".utf8), "HTTP 503"),
            (200, Data("not-json".utf8), "not valid JSON"),
            (200, Data(#"{"manifests":[]}"#.utf8), "not valid JSON"),
            (200, Data(#"{"schemaVersion":2,"module":"other","manifests":[]}"#.utf8), "contains no valid")
        ] {
            let (server, endpoint) = try startCatalogHTTPServer(root: root, body: responseBody, status: status)
            defer {
                server.terminate()
                server.waitUntilExit()
                XCTAssertNotEqual(server.terminationStatus, 0, "test server must be explicitly terminated")
            }
            let location = FilePHPManifestLocation(manifestURL: manifestURL, catalogURL: endpoint, now: { now })
            XCTAssertThrowsError(try location.checkCatalogNow()) { error in
                guard case PHPModuleError.catalogUnavailable(let message) = error else { return XCTFail("expected catalog-specific failure: \(error)") }
                XCTAssertTrue(message.contains(expectedCause), message)
            }
            XCTAssertEqual(try Data(contentsOf: cacheURL), originalCache, "failed refresh must preserve last valid catalog bytes")
            XCTAssertEqual(try JSONDecoder().decode(PHPManifestCatalog.self, from: Data(contentsOf: cacheURL)).manifests, [manifest])
            XCTAssertEqual(location.catalogCheckStatus().0, nil, "failed refresh is not a successful catalog check")
            XCTAssertNotNil(location.catalogCheckStatus().1)
            XCTAssertNoThrow(try FileManager.default.removeItem(at: stateURL))
        }
    }

    func testSuccessfulHTTPCatalogRefreshDiscoversPublishedSameSeriesPatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-catalog-success-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func releaseManifest(_ version: String) -> PHPManifest {
            let root = "https://github.com/banestojanovic/vaelen/releases/download/php-v\(version)"
            let artifacts = ["cli": PHPArtifact(file: "php-\(version)-cli-macos-arm64.tar.gz", url: "\(root)/php-\(version)-cli-macos-arm64.tar.gz", sha256: String(repeating: "a", count: 64)), "fpm": PHPArtifact(file: "php-\(version)-fpm-macos-arm64.tar.gz", url: "\(root)/php-\(version)-fpm-macos-arm64.tar.gz", sha256: String(repeating: "b", count: 64))]
            return PHPManifest(schemaVersion: 1, module: "php", phpVersion: version, platform: "macos", architecture: "arm64", artifacts: artifacts, verification: .init(algorithm: "sha256", authenticity: "trusted-vaelen-release-manifest"), release: .init(tag: "php-v\(version)", url: root))
        }
        let current = releaseManifest("8.4.26")
        let newer = releaseManifest("8.4.27")
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(current).write(to: manifestURL)
        let body = try JSONEncoder().encode(PHPManifestCatalog(manifests: [current, newer]))
        let (server, endpoint) = try startCatalogHTTPServer(root: root, body: body, status: 200)
        defer { server.terminate(); server.waitUntilExit() }
        let now = Date(timeIntervalSince1970: 2_000_000_100)
        let location = FilePHPManifestLocation(manifestURL: manifestURL, catalogURL: endpoint, now: { now })
        try location.checkCatalogNow()
        XCTAssertEqual(try location.manifests(), [current, newer])
        XCTAssertEqual(location.catalogCheckStatus().0, now)
        XCTAssertNil(location.catalogCheckStatus().1)
        XCTAssertEqual(PHPUpdateObservation(installedVersion: "8.4.26", latestVersion: try XCTUnwrap(location.manifests().map(\.phpVersion).max())).updateAvailable, true)
    }

    func testMissingCatalogURLIsAVisibleRetryableErrorNotUpToDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: [:], verification: .init(algorithm: "sha256", authenticity: "local"))
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let location = FilePHPManifestLocation(manifestURL: manifestURL)
        XCTAssertNoThrow(try location.refreshCatalogIfNeeded())
        XCTAssertNil(location.catalogCheckStatus().0)
        XCTAssertEqual(location.catalogCheckStatus().1, "No PHP update catalog is configured for this Vaelen distribution.")
        XCTAssertThrowsError(try location.checkCatalogNow()) { error in
            guard case PHPModuleError.catalogUnavailable(let message) = error else { return XCTFail("missing feed must not be reported as invalid package metadata: \(error)") }
            XCTAssertEqual(message, "No PHP update catalog is configured for this Vaelen distribution.")
        }
        XCTAssertNil(location.catalogCheckStatus().0)
    }

    func testNonHTTPSRemoteCatalogIsRejectedBeforeNetworkAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-insecure-feed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(PHPManifestCatalog(manifests: [])).write(to: root.appendingPathComponent("php-catalog.json"))
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: [:], verification: .init(algorithm: "sha256", authenticity: "bootstrap-local-machine"))
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let location = FilePHPManifestLocation(manifestURL: manifestURL, catalogURL: URL(string: "http://example.test/php-catalog.json")!)
        XCTAssertThrowsError(try location.checkCatalogNow()) { error in
            guard case PHPModuleError.catalogUnavailable(let message) = error else { return XCTFail("HTTP catalog must be rejected as a transport policy failure: \(error)") }
            XCTAssertEqual(message, "The PHP update catalog must use HTTPS.")
        }
        XCTAssertEqual(location.catalogCheckStatus().1, "The PHP update catalog must use HTTPS.")
    }

    func testConfiguredFeedDoesNotHonorThrottleFromLegacyMissingURLError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-feed-upgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: [:], verification: .init(algorithm: "sha256", authenticity: "bootstrap-local-machine"))
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let now = Date(timeIntervalSince1970: 2_000_000_200)
        let oldState = TestCatalogCheckState(checkedAt: now.addingTimeInterval(-60), error: "This PHP distribution has no update-feed URL. Configure a trusted catalog URL in the distribution manifest.")
        try JSONEncoder().encode(oldState).write(to: root.appendingPathComponent("php-catalog-check.json"))
        let (server, endpoint) = try startCatalogHTTPServer(root: root, body: Data("not-json".utf8), status: 200)
        defer { server.terminate(); server.waitUntilExit() }
        let location = FilePHPManifestLocation(manifestURL: manifestURL, catalogURL: endpoint, now: { now })
        XCTAssertThrowsError(try location.refreshCatalogIfNeeded(), "A newly configured feed must be checked immediately instead of retaining the old missing-feed error for twelve hours.")
        XCTAssertTrue(location.catalogCheckStatus().1?.contains("not valid JSON") == true)
        XCTAssertNoThrow(try location.refreshCatalogIfNeeded(), "The actual failed request is then throttled normally.")
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

    func testBundledCatalogDoesNotAdvertiseUnpublishedPlaceholderReleases() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "php-catalog", withExtension: "json"))
        let bundled = try JSONDecoder().decode(PHPManifestCatalog.self, from: Data(contentsOf: url))
        XCTAssertTrue(bundled.manifests.isEmpty, "Only trusted catalog entries whose immutable CLI/FPM assets have been verified are advertised.")
    }

    func testCatalogFixtureCanDescribeMultipleAvailableReleasesWithoutNetwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let verification = PHPVerification(algorithm: "sha256", authenticity: "fixture")
        let artifacts = ["cli": PHPArtifact(file: "cli.tar.gz", url: "https://example.test/cli.tar.gz", sha256: String(repeating: "a", count: 64)), "fpm": PHPArtifact(file: "fpm.tar.gz", url: "https://example.test/fpm.tar.gz", sha256: String(repeating: "b", count: 64))]
        let manifests = [
            PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: artifacts, verification: verification),
            PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.25", platform: "macos", architecture: "arm64", artifacts: artifacts, verification: verification),
            PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.5.0", platform: "macos", architecture: "arm64", artifacts: artifacts, verification: verification)
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

    func testCatalogFiltersUnsupportedProductionEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = ["cli": PHPArtifact(file: "cli", url: "https://example.test/cli", sha256: String(repeating: "a", count: 64)), "fpm": PHPArtifact(file: "fpm", url: "https://example.test/fpm", sha256: String(repeating: "b", count: 64))]
        let valid = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.25", platform: "macos", architecture: "arm64", artifacts: artifact, verification: .init(algorithm: "sha256", authenticity: "trusted"))
        let unsupported = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.5.0", platform: "linux", architecture: "arm64", artifacts: artifact, verification: .init(algorithm: "sha256", authenticity: "trusted"))
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(valid).write(to: manifestURL)
        try JSONEncoder().encode(PHPManifestCatalog(manifests: [valid, unsupported])).write(to: root.appendingPathComponent("php-catalog.json"))
        let module = PHPModule(layout: VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support")), location: FilePHPManifestLocation(manifestURL: manifestURL))
        XCTAssertEqual(try module.availableVersions(), ["8.4.25"])
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

    func testActivePHPFPMRuntimeCannotBeRemovedInIsolatedState() throws {
        let fixture = try isolatedFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(try fixture.module.status(requestedVersion: fixture.package.version).state, .stopped)
        let started = try fixture.module.start(requestedVersion: fixture.package.version)
        XCTAssertEqual(started.state, .running)
        XCTAssertThrowsError(try fixture.module.remove(requestedVersion: fixture.package.version)) { error in
            XCTAssertEqual(error as? PHPModuleError, .cannotRemoveActiveRuntime(fixture.package.version))
        }
        XCTAssertEqual(try fixture.module.runtimeCatalog().installedVersions.first { $0.version == fixture.package.version }?.running, true)
    }

    func testDefaultSelectionStartsFPMAndPersistsInIsolatedState() throws {
        let fixture = try isolatedFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(try fixture.module.status(requestedVersion: fixture.package.version).state, .stopped)
        let catalog = try fixture.module.selectDefault(requestedVersion: fixture.package.version)
        XCTAssertEqual(catalog.defaultVersion, fixture.package.version)
        XCTAssertTrue(catalog.installedVersions.first { $0.version == fixture.package.version }?.running == true)
        let reloaded = PHPModule(layout: fixture.layout, location: FilePHPManifestLocation(manifestURL: fixture.root.appendingPathComponent("fixture-manifest.json")))
        XCTAssertEqual(try reloaded.runtimeCatalog().defaultVersion, fixture.package.version)
        XCTAssertTrue(try reloaded.runtimeCatalog().installedVersions.first { $0.version == fixture.package.version }?.running == true)
    }

    func testManagedConfigurationUsesPersistentIniAndVersionOverrideInheritsExplicitly() throws {
        let fixture = try isolatedFixture()
        defer { fixture.cleanup() }

        let initial = try fixture.module.configuration()
        XCTAssertEqual(initial.directory, fixture.layout.configurationDirectoryURL.appendingPathComponent("php").path)
        let runtime = try XCTUnwrap(initial.versions.first)
        XCTAssertTrue(runtime.inheritsDefault)
        XCTAssertEqual(runtime.settings.uploadLimitMB, 2)
        XCTAssertEqual(runtime.settings.postLimitMB, 8)
        XCTAssertEqual(runtime.settings.memoryLimitMB, 128)
        XCTAssertEqual(runtime.settings.maxExecutionTimeSeconds, 30)
        XCTAssertEqual(runtime.settings.maxInputVariables, 1_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.cliIniPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.fpmIniPath))

        let cli = try fixture.module.exec(requestedVersion: fixture.package.version, workingDirectory: fixture.root.path, arguments: ["-r", "echo ini_get('upload_max_filesize').'|'.ini_get('post_max_size').'|'.ini_get('memory_limit').'|'.ini_get('max_execution_time').'|'.ini_get('max_input_vars');"])
        XCTAssertEqual(cli.status, 0, cli.output)
        XCTAssertTrue(cli.output.contains("2M|8M|128M|0|1000"), cli.output)
        let iniInfo = try fixture.module.exec(requestedVersion: fixture.package.version, workingDirectory: fixture.root.path, arguments: ["--ini"])
        XCTAssertEqual(iniInfo.status, 0, iniInfo.output)
        XCTAssertTrue(iniInfo.output.contains("Loaded Configuration File:         \(runtime.cliIniPath)"), iniInfo.output)

        let override = PHPManagedSettings(uploadLimitMB: 20, memoryLimitMB: 256, maxExecutionTimeSeconds: 45, maxInputVariables: 2_000, postLimitMB: 8)
        let update = try fixture.module.updateConfiguration(version: fixture.package.version, settings: override)
        let configured = try XCTUnwrap(update.versions.first)
        XCTAssertFalse(configured.inheritsDefault)
        XCTAssertEqual(configured.settings.postLimitMB, 21, "POST limit is raised above upload size")
        let ini = try String(contentsOfFile: configured.fpmIniPath, encoding: .utf8)
        XCTAssertTrue(ini.contains("upload_max_filesize = 20M"), ini)
        XCTAssertTrue(ini.contains("post_max_size = 21M"), ini)
        XCTAssertTrue(ini.contains("max_execution_time = 45"), ini)

        let changedDefault = PHPManagedSettings(uploadLimitMB: 4, memoryLimitMB: 192, maxExecutionTimeSeconds: 60, maxInputVariables: 1_500, postLimitMB: 8)
        let defaultUpdate = try fixture.module.updateConfiguration(version: nil, settings: changedDefault)
        let inherited = try XCTUnwrap(defaultUpdate.versions.first)
        XCTAssertFalse(inherited.inheritsDefault)
        XCTAssertEqual(inherited.settings, configured.settings, "A version override must remain independent of later shared-default edits")

        let reloaded = PHPModule(layout: fixture.layout, location: FilePHPManifestLocation(manifestURL: fixture.root.appendingPathComponent("fixture-manifest.json")))
        XCTAssertEqual(try reloaded.configuration(), defaultUpdate)
    }

    func testPHPConfigurationRejectsInvalidValuesBeforePersisting() throws {
        let fixture = try isolatedFixture()
        defer { fixture.cleanup() }
        let invalid = PHPManagedSettings(uploadLimitMB: 0, memoryLimitMB: 128, maxExecutionTimeSeconds: 30, maxInputVariables: 1_000, postLimitMB: 8)
        XCTAssertThrowsError(try fixture.module.updateConfiguration(version: nil, settings: invalid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.layout.configurationDirectoryURL.appendingPathComponent("php/settings.json").path))
        XCTAssertEqual(try fixture.module.configuration().defaultSettings.uploadLimitMB, 2)
    }

    func testConfigurationSaveAndResetRestartAffectedRunningFPMOnlyInIsolatedState() throws {
        let fixture = try isolatedFixture()
        defer { fixture.cleanup() }
        _ = try fixture.module.configuration()
        let started = try fixture.module.start(requestedVersion: fixture.package.version)
        XCTAssertEqual(started.state, .running)
        let override = PHPManagedSettings(uploadLimitMB: 32, memoryLimitMB: 512, maxExecutionTimeSeconds: 60, maxInputVariables: 4000, postLimitMB: 33)
        let saved = try fixture.module.updateConfiguration(version: fixture.package.version, settings: override)
        XCTAssertEqual(saved.affectedVersions, [fixture.package.version])
        XCTAssertTrue(try XCTUnwrap(saved.versions.first).fpmRunning)
        XCTAssertFalse(try XCTUnwrap(saved.versions.first).inheritsDefault)
        XCTAssertEqual(try fixture.module.status(requestedVersion: fixture.package.version).state, .running)
        let reset = try fixture.module.updateConfiguration(version: fixture.package.version, settings: nil)
        XCTAssertEqual(reset.affectedVersions, [fixture.package.version])
        XCTAssertTrue(try XCTUnwrap(reset.versions.first).inheritsDefault)
        XCTAssertTrue(try XCTUnwrap(reset.versions.first).fpmRunning)
        XCTAssertEqual(try fixture.module.configuration().defaultSettings, reset.defaultSettings)
    }

    private func isolatedFixture() throws -> IsolatedPHPFixture {
        let layout = VaelenFilesystemLayout()
        let metadata = layout.phpPackagesDirectoryURL.appendingPathComponent("8.4.23/.vaelen-package.json")
        guard let package = try? JSONDecoder().decode(PHPPackage.self, from: Data(contentsOf: metadata)) else {
            throw XCTSkip("installed PHP 8.4.23 package metadata unavailable")
        }
        return try IsolatedPHPFixture(installedPackage: package)
    }

    func testDefaultSelectionRejectsUnavailableExactVersion() throws {
        let fixture = try isolatedFixture()
        defer { fixture.cleanup() }
        try Data(fixture.package.version.utf8).write(to: fixture.layout.configurationDirectoryURL.appendingPathComponent("php-default.json"), options: .atomic)
        XCTAssertThrowsError(try fixture.module.selectDefault(requestedVersion: "8.5.0")) { error in
            XCTAssertEqual(error as? PHPModuleError, .packageMissing("8.5.0"))
        }
        XCTAssertEqual(try fixture.module.runtimeCatalog().defaultVersion, fixture.package.version)
        XCTAssertEqual(try fixture.module.status(requestedVersion: fixture.package.version).state, .stopped)
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

    func testLocalArtifactTransferReportsIncrementalBytesAndAggregatesBothArchives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-local-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x5a, count: 900_000)
        let source = root.appendingPathComponent("source.tar.gz")
        let destination = root.appendingPathComponent("downloaded.tar.gz")
        try payload.write(to: source)
        let samples = ArtifactProgressSamples()
        try PHPModule.transferArtifact(source: source, destination: destination, progress: PHPArtifactProgressSink { samples.append($0, $1) })
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let updates = samples.snapshot()
        XCTAssertGreaterThan(updates.count, 2, "copy should report incremental chunks")
        XCTAssertEqual(updates.last?.0, Int64(payload.count))
        XCTAssertEqual(updates.last?.1, Int64(payload.count))

        let aggregate = ArtifactProgressSamples()
        let tracker = PHPArtifactProgressTracker(artifactCount: 2) { bytes, total, _, _, _ in aggregate.append(bytes, total) }
        tracker.update(name: "CLI", index: 1, bytes: 400, total: 400)
        XCTAssertNil(aggregate.snapshot().last?.1, "one complete archive must not appear as 100% of the package")
        tracker.update(name: "FPM", index: 2, bytes: 200, total: 600)
        XCTAssertEqual(aggregate.snapshot().last?.0, 600)
        XCTAssertEqual(aggregate.snapshot().last?.1, 1_000)
        tracker.update(name: "FPM", index: 2, bytes: 600, total: 600)
        XCTAssertEqual(aggregate.snapshot().last?.0, 1_000)
        XCTAssertEqual(aggregate.snapshot().last?.1, 1_000)
    }

    func testLocalInstallDownloadNeverReportsCLIAsCompletePackageAndKeepsFailedProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-two-archive-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let release = root.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        var artifacts = [String: PHPArtifact]()
        var byteCount: Int64 = 0
        for name in ["cli", "fpm"] {
            let content = release.appendingPathComponent("content-\(name)")
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            try Data("fixture \(name) payload".utf8).write(to: content.appendingPathComponent("payload.txt"))
            let archive = release.appendingPathComponent("\(name).tar.gz")
            let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.arguments = ["-czf", archive.path, "-C", content.path, "."]
            try tar.run(); tar.waitUntilExit(); XCTAssertEqual(tar.terminationStatus, 0)
            let bytes = try Data(contentsOf: archive)
            byteCount += Int64(bytes.count)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            artifacts[name] = PHPArtifact(file: archive.lastPathComponent, url: "https://example.test/\(archive.lastPathComponent)", sha256: digest)
        }
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: artifacts, verification: .init(algorithm: "sha256", authenticity: "isolated-progress-test"))
        let manifestURL = release.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"))
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: manifestURL, baseURL: release))

        XCTAssertThrowsError(try module.install(requestedVersion: "8.4.23"), "empty PHP archives should fail validation after both downloads")
        let failed = try XCTUnwrap(module.operationState())
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.bytesTransferred, byteCount)
        XCTAssertEqual(failed.totalBytes, byteCount, "denominator must include both CLI and FPM archives")
        XCTAssertEqual(failed.artifactIndex, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpPackagesDirectoryURL.appendingPathComponent("8.4.23").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.stagingDirectoryURL.path), [])
    }

    func testProductionHTTPTransferReportsKnownAndUnknownLengthsAndRejectsFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("php-http-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x31, count: 1_100_000)

        for chunked in [false, true] {
            let (server, endpoint) = try startTransferHTTPServer(root: root, payload: payload, chunked: chunked, status: 200)
            defer { server.terminate(); server.waitUntilExit() }
            let destination = root.appendingPathComponent(chunked ? "unknown.bin" : "known.bin")
            let samples = ArtifactProgressSamples()
            try PHPModule.transferArtifact(source: endpoint, destination: destination, progress: PHPArtifactProgressSink { samples.append($0, $1) })
            XCTAssertEqual(try Data(contentsOf: destination), payload)
            let updates = samples.snapshot()
            XCTAssertGreaterThan(updates.count, 2)
            XCTAssertEqual(updates.last?.0, Int64(payload.count))
            if chunked { XCTAssertTrue(updates.allSatisfy { $0.1 == nil }, "chunked responses without a length must remain unknown") }
            else { XCTAssertTrue(updates.contains { $0.0 > 0 && $0.0 < Int64(payload.count) }); XCTAssertEqual(updates.last?.1, Int64(payload.count)) }
            server.terminate(); server.waitUntilExit()
        }

        let (failingServer, failingEndpoint) = try startTransferHTTPServer(root: root, payload: payload, chunked: false, status: 503)
        defer { failingServer.terminate(); failingServer.waitUntilExit() }
        XCTAssertThrowsError(try PHPModule.transferArtifact(source: failingEndpoint, destination: root.appendingPathComponent("failed.bin"), progress: PHPArtifactProgressSink { _, _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("failed.bin").path))
    }

    private func startTransferHTTPServer(root: URL, payload: Data, chunked: Bool, status: Int) throws -> (Process, URL) {
        let portFile = root.appendingPathComponent("port-\(UUID().uuidString).txt")
        let bodyFile = root.appendingPathComponent("body-\(UUID().uuidString).bin")
        try payload.write(to: bodyFile)
        let script = #"""
import http.server, sys
body = open(sys.argv[1], 'rb').read()
chunked = sys.argv[3] == '1'
status = int(sys.argv[4])
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(status)
  if chunked:
   self.send_header('Transfer-Encoding', 'chunked')
  else:
   self.send_header('Content-Length', str(len(body)))
  self.end_headers()
  if status == 200:
   for i in range(0, len(body), 32768):
    part = body[i:i+32768]
    if chunked: self.wfile.write(('%x\r\n' % len(part)).encode() + part + b'\r\n')
    else: self.wfile.write(part)
   if chunked: self.wfile.write(b'0\r\n\r\n')
 def log_message(self, *args): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
open(sys.argv[2], 'w').write(str(server.server_port))
server.serve_forever()
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script, bodyFile.path, portFile.path, chunked ? "1" : "0", "\(status)"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<200 {
            if let raw = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(raw) { return (process, URL(string: "http://127.0.0.1:\(port)/artifact")!) }
            if !process.isRunning { throw PHPModuleError.manifestUnavailable }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.terminate(); process.waitUntilExit()
        throw PHPModuleError.manifestUnavailable
    }

    private func startCatalogHTTPServer(root: URL, body: Data, status: Int) throws -> (Process, URL) {
        let portFile = root.appendingPathComponent("catalog-port-\(UUID().uuidString).txt")
        let bodyFile = root.appendingPathComponent("catalog-body-\(UUID().uuidString).bin")
        try body.write(to: bodyFile)
        let script = #"""
import http.server, sys
body = open(sys.argv[1], 'rb').read()
status = int(sys.argv[3])
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(status)
  self.send_header('Content-Length', str(len(body)))
  self.end_headers()
  self.wfile.write(body)
 def log_message(self, *args): pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
open(sys.argv[2], 'w').write(str(server.server_port))
server.serve_forever()
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script, bodyFile.path, portFile.path, "\(status)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<200 {
            if let raw = try? String(contentsOf: portFile, encoding: .utf8), let port = Int(raw) {
                return (process, URL(string: "http://127.0.0.1:\(port)/php-catalog.json")!)
            }
            guard process.isRunning else { throw PHPModuleError.manifestUnavailable }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.terminate()
        process.waitUntilExit()
        throw PHPModuleError.manifestUnavailable
    }

    func testExecUsesCallerWorkingDirectoryAndPreservesArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workingDirectory = root.appendingPathComponent("fixture with spaces")
        let packageDirectory = root.appendingPathComponent("support/packages/php/8.4.23")
        let executable = root.appendingPathComponent("php-fixture.sh")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try Data("fixture script\n".utf8).write(to: workingDirectory.appendingPathComponent("test.php"))
        try Data("#!/bin/sh\nif [ \"$1\" = \"-c\" ]; then shift 2; fi\nprintf 'cwd=%s\\n' \"$PWD\"\nprintf 'script='\ncat \"$1\"\nshift\nfor argument in \"$@\"; do printf 'arg=<%s>\\n' \"$argument\"; done\n".utf8).write(to: executable)
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
