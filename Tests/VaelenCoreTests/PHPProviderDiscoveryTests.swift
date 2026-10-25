import CryptoKit
import Foundation
import XCTest
import VaelenTestSupport
@testable import VaelenCore

/// Coverage for the behaviour the provider integration must get right, all of it
/// deterministic and independent of provider uptime.
final class PHPProviderDiscoveryTests: XCTestCase {
    private var root: URL!
    private var layout: VaelenFilesystemLayout!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: "/private/var/tmp/vaelen-discovery-\(UUID().uuidString.prefix(8))", isDirectory: true)
        layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true), logsDirectoryURL: root.appendingPathComponent("logs", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    func testArtifactRedirectAllowsBothProviderHosts() throws {
        for host in ["dl.static-php.dev", "static-php-cli.fra1.digitaloceanspaces.com", "dl.static-php.dev:443"] {
            let destination = root.appendingPathComponent(UUID().uuidString)
            try transferThroughRedirect(to: "https://\(host)/payload", destination: destination)
            XCTAssertEqual(try Data(contentsOf: destination), PHPArtifactRedirectProtocol.payload)
        }
    }

    func testArtifactRedirectRejectsUnlistedHost() throws {
        for target in ["https://outside.invalid/payload", "https://dl.static-php.dev.outside.invalid/payload"] {
            try assertArtifactRedirectRefused(target)
        }
    }

    func testArtifactRedirectRejectsUnlistedHostAfterAllowedRedirect() throws {
        var intermediate = URLComponents(string: "https://static-php-cli.fra1.digitaloceanspaces.com/redirect")!
        intermediate.queryItems = [URLQueryItem(name: "target", value: "https://outside.invalid/payload")]
        try assertArtifactRedirectRefused(intermediate.url!.absoluteString)
        let hosts = PHPArtifactRedirectProtocol.requestedURLs.compactMap(\.host)
        XCTAssertTrue(hosts.contains("static-php-cli.fra1.digitaloceanspaces.com"), "The allowed intermediate host must be reached.")
        XCTAssertFalse(hosts.contains("outside.invalid"), "The forbidden next hop must be rejected before a request reaches it.")
    }

    func testArtifactRedirectRejectsHTTPSDowngrade() throws {
        try assertArtifactRedirectRefused("http://dl.static-php.dev/payload")
    }

    func testArtifactRedirectRejectsNonstandardPortAndCredentials() throws {
        for target in ["https://dl.static-php.dev:8443/payload", "https://user:password@dl.static-php.dev/payload", "https://user@dl.static-php.dev/payload"] {
            try assertArtifactRedirectRefused(target)
        }
    }

    func testProviderMetadataRedirectAcceptsProviderFeedResponse() throws {
        let body = try fetchMetadata(from: "https://dl.static-php.dev/feed", allowedHosts: ["dl.static-php.dev"])
        XCTAssertEqual(body, PHPArtifactRedirectProtocol.payload)
    }

    func testProviderMetadataRedirectRejectsFeedRedirectToUnlistedHost() {
        assertMetadataRedirectRefused("https://dl.static-php.dev/redirect?target=https%3A%2F%2Foutside.invalid%2Fbody", allowedHosts: ["dl.static-php.dev"], forbiddenHost: "outside.invalid")
    }

    func testProviderMetadataRedirectRejectsFeedHTTPSDowngrade() {
        PHPArtifactRedirectProtocol.resetRequests()
        XCTAssertThrowsError(try fetchMetadata(from: "https://dl.static-php.dev/redirect?target=http%3A%2F%2Fdl.static-php.dev%2Fbody", allowedHosts: ["dl.static-php.dev"]))
        XCTAssertFalse(PHPArtifactRedirectProtocol.requestedURLs.contains { $0.scheme == "http" }, "The downgraded destination must never receive a request.")
    }

    func testProviderMetadataRedirectRejectsInvalidInitialOrigin() {
        XCTAssertThrowsError(try fetchMetadata(from: "https://user@dl.static-php.dev/feed", allowedHosts: ["dl.static-php.dev"]))
        XCTAssertThrowsError(try fetchMetadata(from: "https://dl.static-php.dev:8443/feed", allowedHosts: ["dl.static-php.dev"]))
    }

    func testProviderMetadataRedirectAllowsLicenseRedirectToListedObjectStorage() throws {
        let body = try fetchMetadata(from: "https://dl.static-php.dev/redirect?target=%2Fdown", allowedHosts: PHPPackageProvider.artifactHosts)
        XCTAssertEqual(body, PHPArtifactRedirectProtocol.payload)
    }

    func testProviderMetadataRedirectRejectsLicenseRedirectOutsideAllowlist() {
        assertMetadataRedirectRefused("https://dl.static-php.dev/redirect?target=https%3A%2F%2Foutside.invalid%2Fbody", allowedHosts: PHPPackageProvider.artifactHosts, forbiddenHost: "outside.invalid", expectedIntermediateHost: "dl.static-php.dev")
    }

    func testProviderMetadataRedirectRejectsOutsideHostAfterAllowedObjectStorageHop() {
        var secondHop = URLComponents(string: "https://static-php-cli.fra1.digitaloceanspaces.com/redirect")!
        secondHop.queryItems = [URLQueryItem(name: "target", value: "https://outside.invalid/body")]
        var firstHop = URLComponents(string: "https://dl.static-php.dev/redirect")!
        firstHop.queryItems = [URLQueryItem(name: "target", value: secondHop.url!.absoluteString)]
        assertMetadataRedirectRefused(firstHop.url!.absoluteString, allowedHosts: PHPPackageProvider.artifactHosts, forbiddenHost: "outside.invalid", expectedIntermediateHost: "static-php-cli.fra1.digitaloceanspaces.com")
    }

    private func assertMetadataRedirectRefused(_ url: String, allowedHosts: Set<String>, forbiddenHost: String, expectedIntermediateHost: String? = nil) {
        PHPArtifactRedirectProtocol.resetRequests()
        XCTAssertThrowsError(try fetchMetadata(from: url, allowedHosts: allowedHosts))
        let hosts = PHPArtifactRedirectProtocol.requestedURLs.compactMap(\.host)
        if let expectedIntermediateHost { XCTAssertTrue(hosts.contains(expectedIntermediateHost), "The allowed redirect origin must be reached.") }
        XCTAssertFalse(hosts.contains(forbiddenHost), "The forbidden redirect destination must never receive a request.")
    }

    private func fetchMetadata(from url: String, allowedHosts: Set<String>) throws -> Data {
        try PHPMetadataRequest.fetch(url: URL(string: url)!, allowedHosts: allowedHosts, configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PHPArtifactRedirectProtocol.self]
            return configuration
        }())
    }

    private func assertArtifactRedirectRefused(_ target: String) throws {
        PHPArtifactRedirectProtocol.resetRequests()
        let destination = root.appendingPathComponent(UUID().uuidString)
        let samples = ProgressSamples()
        XCTAssertThrowsError(try transferThroughRedirect(to: target, destination: destination, samples: samples))
        XCTAssertTrue(samples.snapshot().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let targetHost = URL(string: target)?.host
        if let targetHost, !PHPPackageProvider.artifactHosts.contains(targetHost) {
            XCTAssertFalse(PHPArtifactRedirectProtocol.requestedURLs.contains { $0.host == targetHost }, "The disallowed host must never receive a request.")
        }
    }

    private func transferThroughRedirect(to target: String, destination: URL, samples: ProgressSamples? = nil) throws {
        var source = URLComponents(string: "https://dl.static-php.dev/redirect")!
        source.queryItems = [URLQueryItem(name: "target", value: target)]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PHPArtifactRedirectProtocol.self]
        try PHPModule.transferArtifact(source: source.url!, destination: destination, progress: PHPArtifactProgressSink { bytes, total in samples?.append(bytes, total) }, configuration: configuration)
    }

    // MARK: - Discovery

    /// A provider check must find a patch published after the app was built, and
    /// make it installable without a new Vaelen release.
    func testCheckDiscoversNewerPatchPublishedAfterTheBuild() throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: "a", fpmSHA: "b")
        let feed = Self.feed(published: ["8.4.23-cli", "8.4.23-fpm", "8.4.24-cli", "8.4.24-fpm"])
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: { feed })
        try location.checkCatalogNow()

        let discovered = location.discoveredManifests()
        XCTAssertEqual(discovered.map(\.phpVersion), ["8.4.24"], "A newer patch must be discovered, not merely noticed in the listing.")
        let manifest = try XCTUnwrap(discovered.first)
        XCTAssertEqual(manifest.artifacts["cli"]?.url, PHPPackageProvider.artifactURL(version: "8.4.24", kind: "cli"))
        XCTAssertEqual(manifest.artifacts["fpm"]?.url, PHPPackageProvider.artifactURL(version: "8.4.24", kind: "fpm"))
        // Discovered digests are recorded from received bytes, never invented.
        XCTAssertEqual(manifest.artifacts["cli"]?.sha256, "")
        XCTAssertFalse(manifest.verification.isPinnedByReview)
        XCTAssertEqual(manifest.verification.authenticity, PHPPackageProvider.authenticity)
        // The new version is offered through the normal catalog.
        XCTAssertTrue(try location.knownManifests().map(\.phpVersion).contains("8.4.24"))
    }

    func testSecurityReleaseWithoutPreparedPackagesIsNotOffered() throws {
        let shipped = try manifestFixture(version: "8.4.24", cliSHA: String(repeating: "a", count: 64), fpmSHA: String(repeating: "b", count: 64))
        for additionalPackages in [[], ["8.4.27-cli"], ["8.4.27-fpm"]] {
            let state = layout.stateDirectoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let feed = Self.feed(published: ["8.4.23-cli", "8.4.23-fpm", "8.4.24-cli", "8.4.24-fpm"] + additionalPackages)
            let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: state, now: { Self.now }, fetchFeed: { feed })
            let module = PHPModule(layout: layout, location: location, includesBundledCatalog: false)

            try module.checkCatalogNow()

            let catalog = try module.runtimeCatalog()
            XCTAssertEqual(catalog.availableVersions, ["8.4.24"], "An upstream release requires both prepared macOS packages before it can be offered.")
            XCTAssertEqual(catalog.catalogAvailability, .current)
            XCTAssertFalse(catalog.availableVersions.contains("8.4.27"))
        }
    }

    func testSecurityReleaseIsOfferedOnceBothPreparedPackagesArePublished() throws {
        let shipped = try manifestFixture(version: "8.4.24", cliSHA: String(repeating: "a", count: 64), fpmSHA: String(repeating: "b", count: 64))
        let feed = Self.feed(published: ["8.4.24-cli", "8.4.24-fpm", "8.4.27-cli", "8.4.27-fpm"])
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: { feed })
        let module = PHPModule(layout: layout, location: location, includesBundledCatalog: false)

        try module.checkCatalogNow()

        let catalog = try module.runtimeCatalog()
        XCTAssertEqual(catalog.availableVersions, ["8.4.27", "8.4.24"])
        XCTAssertEqual(catalog.catalogAvailability, .current)
        XCTAssertEqual(PHPUpdateObservation(installedVersion: "8.4.24", latestVersion: try XCTUnwrap(catalog.availableVersions.first)).updateAvailable, true)
        let discovered = try XCTUnwrap(location.discoveredManifests().first)
        XCTAssertFalse(discovered.verification.isPinnedByReview)
        XCTAssertEqual(discovered.artifacts["cli"]?.sha256, "")
        XCTAssertEqual(discovered.artifacts["fpm"]?.sha256, "")
    }

    func testModernAndArchivedCatalogFeedsAreCheckedIndependently() throws {
        let modern = try manifestFixture(version: "8.4.24", cliSHA: String(repeating: "a", count: 64), fpmSHA: String(repeating: "b", count: 64))
        let legacy = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.0.30", platform: "macos", architecture: "arm64",
            build: .init(requiredExtensions: ["bcmath"], minimumMacOS: "14.0", notices: PHPPackageProvider.legacyLicenseNotices, generation: PHPPackageProvider.legacyGeneration, channel: PHPPackageProvider.legacyChannel),
            artifacts: ["cli": PHPArtifact(file: "archive-v2-8.0.30-cli-macos-aarch64.tar.gz", url: "\(PHPPackageProvider.legacyBaseURL)/php-8.0.30-cli-macos-aarch64.tar.gz", sha256: String(repeating: "c", count: 64)),
                        "fpm": PHPArtifact(file: "archive-v2-8.0.30-fpm-macos-aarch64.tar.gz", url: "\(PHPPackageProvider.legacyBaseURL)/php-8.0.30-fpm-macos-aarch64.tar.gz", sha256: String(repeating: "d", count: 64))],
            verification: .init(algorithm: "sha256", authenticity: PHPPackageProvider.authenticity),
            release: .init(tag: PHPPackageProvider.legacyChannel, url: PHPPackageProvider.legacyBaseURL))
        XCTAssertTrue(FilePHPManifestLocation.isProviderBackedManifest(legacy))
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [modern, legacy]), stateDirectory: layout.stateDirectoryURL, now: { Self.now },
            fetchFeed: { Self.feed(published: ["8.4.24-cli", "8.4.24-fpm"]) },
            fetchLegacyFeed: { Self.feed(published: ["8.0.30-cli", "8.0.30-fpm"]) })
        XCTAssertNoThrow(try location.checkCatalogNow(), "A legacy family omitted from modern v3 must not invalidate the modern check.")
        XCTAssertEqual(location.catalogAvailability(), .current)
        XCTAssertTrue(try location.knownManifests().map(\.phpVersion).contains("8.0.30"))
    }

    func testLegacyFeedFailureKeepsShippedOptionsAndReportsCachedOrUnconfirmed() throws {
        let legacy = try manifestFixture(version: "8.0.30", cliSHA: String(repeating: "c", count: 64), fpmSHA: String(repeating: "d", count: 64))
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [legacy]), stateDirectory: layout.stateDirectoryURL, now: { Self.now },
            fetchFeed: { Self.feed(published: ["8.4.24-cli", "8.4.24-fpm"]) },
            fetchLegacyFeed: { throw PHPModuleError.catalogUnavailable("archive source unavailable") })
        XCTAssertThrowsError(try location.checkCatalogNow())
        XCTAssertTrue(try location.knownManifests().contains { $0.phpVersion == "8.0.30" }, "The shipped legacy package remains usable after a source-check failure.")
        XCTAssertNotNil(location.catalogCheckStatus().1)
        XCTAssertEqual(location.catalogAvailability(), .unconfirmed)
    }

    func testSupportLabelsMatchTheProviderCatalogMetadata() {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let providerURL = repository.appendingPathComponent("Distribution/PHP/provider.json")
        let data = try! Data(contentsOf: providerURL)
        let config = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(config["legacyFamilies"] as? [String: String], PHPPackageProvider.seriesLabels,
                       "Core and Settings labels must stay aligned with provider package metadata.")
        let legacyProvider = try! XCTUnwrap(config["legacyProvider"] as? [String: Any])
        XCTAssertEqual(legacyProvider["generation"] as? String, PHPPackageProvider.legacyGeneration)
        XCTAssertEqual(legacyProvider["channel"] as? String, PHPPackageProvider.legacyChannel)
    }

    /// Discovery must not invent versions for unsupported lines or regress.
    func testDiscoveryOnlyAdvancesSupportedLinesAndNeverRegresses() throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: "a", fpmSHA: "b")
        // 8.4 is behind, 8.6 is an unsupported new line, 8.5 is known nowhere.
        let feed = Self.feed(published: ["8.4.23-cli", "8.4.23-fpm", "8.4.22-cli", "8.4.22-fpm", "8.6.0-cli", "8.6.0-fpm"])
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: { feed })
        try location.checkCatalogNow()
        XCTAssertEqual(location.discoveredManifests().map(\.phpVersion), [], "An older patch and an unsupported new line must not be offered.")
    }

    /// A version the provider publishes but Vaelen has not recorded must be
    /// advertised as unverified, never as installable.
    func testAdvertisedButUnverifiedIsSeparateFromInstallable() throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: "a", fpmSHA: "b")
        let feed = Self.feed(published: ["8.4.23-cli", "8.4.23-fpm", "8.4.24-cli", "8.4.24-fpm"])
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: { feed })
        // Before any check, nothing is discovered.
        XCTAssertEqual(location.discoveredManifests().map(\.phpVersion), [])
        try location.checkCatalogNow()
        XCTAssertTrue(try location.knownManifests().map(\.phpVersion).contains("8.4.24"))
        // A version with no recorded digest is not installable.
        let manifest = try XCTUnwrap(location.knownManifests().first { $0.phpVersion == "8.4.24" })
        XCTAssertFalse(FilePHPManifestLocation.isProviderBackedManifest(manifest), "A version with no verified digest is not a pinned catalog entry.")
    }

    // MARK: - Persistence, cadence, failure and recovery

    func testDiscoveryIsPersistedAcrossLocations() throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: "a", fpmSHA: "b")
        let feed = Self.feed(published: ["8.4.23-cli", "8.4.23-fpm", "8.4.24-cli", "8.4.24-fpm"])
        let first = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: { feed })
        try first.checkCatalogNow()
        // A new location sharing the state directory keeps the discovery, which is
        // what makes it survive an app restart.
        let second = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: { feed })
        XCTAssertEqual(second.discoveredManifests().map(\.phpVersion), ["8.4.24"])
        XCTAssertEqual(second.catalogAvailability(), .current)
    }

    func testCheckIsThrottledToTwelveHoursAndForceBypassesIt() throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: "a", fpmSHA: "b")
        let calls = Counter()
        let feedProvider: @Sendable () throws -> Data = { calls.increment(); return Self.feed(published: ["8.4.23-cli", "8.4.23-fpm"]) }
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: feedProvider)
        try location.checkCatalogNow()
        XCTAssertEqual(calls.value, 1)
        // Within the interval an automatic check does not re-request.
        try location.refreshCatalogIfNeeded()
        XCTAssertEqual(calls.value, 1, "Automatic checks are throttled to roughly twice daily.")
        // A manual check always performs the request.
        try location.checkCatalogNow()
        XCTAssertEqual(calls.value, 2, "A manual check must actually check.")
    }

    func testOverdueCheckRunsAfterTwelveHours() throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: "a", fpmSHA: "b")
        let calls = Counter()
        let clock = ClockBox(Self.now)
        let feedProvider: @Sendable () throws -> Data = { calls.increment(); return Self.feed(published: ["8.4.23-cli", "8.4.23-fpm"]) }
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { clock.now }, fetchFeed: feedProvider)
        try location.checkCatalogNow()
        clock.advance(13 * 60 * 60)
        try location.refreshCatalogIfNeeded()
        XCTAssertEqual(calls.value, 2, "An elapsed interval must make the next automatic check run.")
    }

    func testFailureKeepsLastUsableCatalogAndDowngradesAvailability() throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: "a", fpmSHA: "b")
        let good = Self.feed(published: ["8.4.23-cli", "8.4.23-fpm", "8.4.24-cli", "8.4.24-fpm"])
        let failing = Toggle()
        let clock = ClockBox(Self.now)
        let provider: @Sendable () throws -> Data = { if failing.isOn { throw PHPModuleError.catalogUnavailable("The PHP provider feed could not be reached (network error -1009).") } ; return good }
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { clock.now }, fetchFeed: provider)
        try location.checkCatalogNow()
        XCTAssertEqual(location.catalogAvailability(), .current)
        XCTAssertEqual(location.discoveredManifests().map(\.phpVersion), ["8.4.24"])

        failing.set(true)
        clock.advance(13 * 60 * 60)
        XCTAssertThrowsError(try location.checkCatalogNow())
        // Availability is retained, but no longer claimed as current.
        XCTAssertEqual(location.discoveredManifests().map(\.phpVersion), ["8.4.24"], "A network failure must not erase what was last usable.")
        XCTAssertEqual(location.catalogAvailability(), .cached)
        XCTAssertNotNil(location.catalogCheckStatus().1)

        // Recovery needs no restart.
        failing.set(false)
        clock.advance(13 * 60 * 60)
        try location.checkCatalogNow()
        XCTAssertEqual(location.catalogAvailability(), .current)
        XCTAssertNil(location.catalogCheckStatus().1)
    }

    func testUnconfirmedAvailabilityBeforeAnySuccessfulCheck() throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: "a", fpmSHA: "b")
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: { Self.feed(published: ["8.4.23-cli", "8.4.23-fpm"]) })
        XCTAssertEqual(location.catalogAvailability(), .unconfirmed)
        XCTAssertNil(location.catalogCheckStatus().0)
        let failing = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: { throw PHPModuleError.catalogUnavailable("unreachable") })
        XCTAssertThrowsError(try failing.checkCatalogNow())
        XCTAssertEqual(failing.catalogAvailability(), .unconfirmed, "A failed first check leaves availability unconfirmed, not current.")
    }

    func testConcurrentChecksAreDeduplicated() async throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: "a", fpmSHA: "b")
        let counter = Counter()
        let gate = Gate()
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { Self.now }, fetchFeed: {
            counter.increment()
            gate.waitUntilOpen()
            return Self.feed(published: ["8.4.23-cli", "8.4.23-fpm"])
        })
        async let first: Void = try Task.detached { try location.checkCatalogNow() }.value
        // Give the first check time to register as in flight.
        while counter.value == 0 { await Task.yield() }
        // A second manual check while the first is in flight is refused rather
        // than starting a duplicate request.
        do { try location.checkCatalogNow(); XCTFail("A concurrent forced check must not start a duplicate request.") }
        catch { XCTAssertTrue("\(error)".contains("already in progress"), "Unexpected error: \(error)") }
        gate.open()
        try await first
        XCTAssertEqual(counter.value, 1, "Concurrent checks must be deduplicated into a single provider request.")
    }

    // MARK: - Runtime catalog truthfulness

    /// Failed discovery must not look like a confirmed empty catalog, and a
    /// successful one must be reported as current.
    func testRuntimeCatalogDistinguishesCurrentCachedAndUnconfirmed() throws {
        let shipped = try manifestFixture(version: "8.4.23", cliSHA: String(repeating: "a", count: 64), fpmSHA: String(repeating: "b", count: 64))
        let feed = Self.feed(published: ["8.4.23-cli", "8.4.23-fpm", "8.4.24-cli", "8.4.24-fpm"])
        let failing = Toggle()
        let clock = ClockBox(Self.now)
        let location = BundledPHPManifestLocation(catalog: PHPManifestCatalog(manifests: [shipped]), stateDirectory: layout.stateDirectoryURL, now: { clock.now }, fetchFeed: {
            if failing.isOn { throw PHPModuleError.catalogUnavailable("unreachable") }
            return feed
        })
        let module = PHPModule(layout: layout, location: location, includesBundledCatalog: false)

        XCTAssertEqual(try module.runtimeCatalog().catalogAvailability, .unconfirmed)
        try location.checkCatalogNow()
        let current = try module.runtimeCatalog()
        XCTAssertEqual(current.catalogAvailability, .current)
        XCTAssertEqual(current.availableVersionsKnown, true)
        // The discovered version is offered newest first.
        XCTAssertEqual(current.availableVersions.first, "8.4.24")

        failing.set(true)
        clock.advance(13 * 60 * 60)
        _ = try? location.checkCatalogNow()
        let cached = try module.runtimeCatalog()
        XCTAssertEqual(cached.catalogAvailability, .cached)
        XCTAssertEqual(cached.availableVersions.first, "8.4.24", "Cached availability must be retained, not erased.")
        XCTAssertNotNil(cached.catalogCheckError)
    }

    // MARK: - Bundled offline activation

    /// First activation must work with no network at all.
    func testBundledRuntimeInstallsWithoutAnyDownload() throws {
        guard let bundled = try? PHPBundledRuntime.bundled() else {
            throw XCTSkip("No bundled PHP runtime in this build.")
        }
        let module = PHPModule(layout: layout, location: StaticCatalogLocation(catalog: PHPManifestCatalog(manifests: [bundled.manifest])), includesBundledCatalog: false)
        let package = try module.install(requestedVersion: bundled.phpVersion)
        XCTAssertEqual(package.version, bundled.phpVersion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.cliPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.fpmPath))
        // It is a real runtime.
        let executed = try module.exec(requestedVersion: bundled.phpVersion, workingDirectory: root.path, arguments: ["-r", "echo PHP_VERSION;"])
        XCTAssertEqual(executed.output.trimmingCharacters(in: .whitespacesAndNewlines), bundled.phpVersion)
        // Bundling alone must not start anything or set a default.
        XCTAssertNil(module.defaultVersion())
        XCTAssertEqual(try module.status(requestedVersion: bundled.phpVersion).state, PHPFPMState.stopped)
        // Notices travel with the package.
        let notices = package.packagePath + "/license"
        XCTAssertTrue(FileManager.default.fileExists(atPath: notices + "/" + PHPPackageProvider.phpLicenseComponent + "_LICENSE.txt"), "PHP's own license must be retained with the installed package.")
        // Settings are usable immediately, before any start.
        let configuration = try module.configuration()
        XCTAssertTrue(configuration.versions.contains { $0.version == bundled.phpVersion })
    }

    func testBundledRuntimeRejectsTamperedBinaries() throws {
        guard let bundled = try? PHPBundledRuntime.bundled() else { throw XCTSkip("No bundled PHP runtime in this build.") }
        XCTAssertEqual(bundled.verification.algorithm, "sha256")
        for kind in ["cli", "fpm"] {
            let binary = try XCTUnwrap(bundled.binaries[kind])
            XCTAssertEqual(binary.sha256.count, 64)
        }
        XCTAssertFalse(bundled.licenseNotices().isEmpty, "The bundle must carry license notices.")
        let phpLicense = bundled.licenseNotices().first { $0.name == "php-src_LICENSE.txt" }
        XCTAssertNotNil(phpLicense, "The build tool's license does not cover PHP; PHP's own notice is required.")
        XCTAssertTrue(phpLicense?.text.contains("PHP License") == true)
    }

    // MARK: - Progress measurement

    /// Two archives must contribute to one monotonic total: the byte count and
    /// percentage never reset when the second archive begins.
    func testTwoArchiveProgressIsMonotonicAndDeterminate() throws {
        let samples = ProgressSamples()
        let tracker = PHPArtifactProgressTracker(artifactCount: 2) { bytes, total, name, index, count in
            samples.append(bytes, total)
        }
        tracker.declareSize(index: 1, bytes: 1_000)
        // One total is not yet an aggregate total.
        XCTAssertNil(samples.snapshot().last?.1, "A partial total must not be presented as the aggregate total.")
        tracker.declareSize(index: 2, bytes: 1_000)
        // Both sizes are known before transfer, so the bar is determinate at once.
        XCTAssertEqual(samples.snapshot().last?.1, 2_000)
        XCTAssertEqual(samples.snapshot().last?.0, 0, "A determinate bar starts at zero, not at an invented fraction.")
        tracker.update(name: "CLI", index: 1, bytes: 400, total: 1_000)
        let first = try XCTUnwrap(samples.snapshot().last)
        XCTAssertEqual(first.0, 400)
        XCTAssertEqual(first.1, 2_000)
        // The first archive completes; the second begins at its own zero. The
        // aggregate must continue from where it was, not reset.
        tracker.update(name: "CLI", index: 1, bytes: 1_000, total: 1_000)
        tracker.update(name: "FPM", index: 2, bytes: 250, total: 1_000)
        let second = try XCTUnwrap(samples.snapshot().last)
        XCTAssertEqual(second.0, 1_250, "Aggregate transferred bytes must include the completed archive.")
        XCTAssertEqual(second.1, 2_000)
        // Monotonic across the whole run.
        let reported = samples.snapshot().map(\.0)
        XCTAssertEqual(reported, reported.sorted(), "Reported transfer must never move backwards.")
        // A later, smaller report for the same archive cannot pull the total back.
        tracker.update(name: "FPM", index: 2, bytes: 10, total: 1_000)
        XCTAssertEqual(try XCTUnwrap(samples.snapshot().last?.0), 1_250, "A later smaller report must not pull the visible total backwards.")
    }

    /// When a total genuinely cannot be known, no percentage is invented.
    func testUnknownTotalReportsNoPercentage() throws {
        let samples = ProgressSamples()
        let tracker = PHPArtifactProgressTracker(artifactCount: 2) { bytes, total, _, _, _ in samples.append(bytes, total) }
        tracker.update(name: "CLI", index: 1, bytes: 400, total: nil)
        let sample = try XCTUnwrap(samples.snapshot().last)
        XCTAssertEqual(sample.0, 400)
        XCTAssertNil(sample.1, "An unknown total must stay unknown rather than be invented.")
    }

    /// Mixed cache and download must be reflected honestly.
    func testCachedArtifactIsReportedWhileTheOtherDownloads() throws {
        let samples = ProgressSamples()
        let tracker = PHPArtifactProgressTracker(artifactCount: 2) { bytes, total, _, _, _ in samples.append(bytes, total) }
        tracker.declareSize(index: 1, bytes: 800)
        tracker.declareSize(index: 2, bytes: 800)
        // The CLI is reused from verified cache; it contributes its full size.
        tracker.update(name: "CLI", index: 1, bytes: 800, total: 800)
        tracker.update(name: "FPM", index: 2, bytes: 100, total: 800)
        let sample = try XCTUnwrap(samples.snapshot().last)
        XCTAssertEqual(sample.0, 900, "A cached archive still counts toward the aggregate.")
        XCTAssertEqual(sample.1, 1_600)
    }

    // MARK: - Update source identity

    /// An explicitly named runtime must be validated, never silently replaced by a
    /// different one. Each rejection names the actual problem.
    func testExplicitUpdateSourceIsValidatedRatherThanSubstituted() throws {
        guard ProcessInfo.processInfo.environment["VAELEN_PHP_PROVIDER_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set VAELEN_PHP_PROVIDER_ACCEPTANCE=1 to run this provider-cache-backed source validation test.")
        }
        let cache = ProviderArtifactCache.shared
        let older = try cache.manifest(version: "8.4.23")
        let newer = try cache.manifest(version: "8.4.24")
        let otherFamily = try cache.manifest(version: "8.3.33")
        let location = PHPProviderManifestLocation(
            box: .init(PHPManifestCatalog(manifests: [older, newer, otherFamily])),
            stateDirectory: layout.stateDirectoryURL,
            artifactBase: try cache.flatDirectory()
        )
        let module = PHPModule(layout: layout, location: location, includesBundledCatalog: false)
        try seedInstalledPackage(module: module, manifest: older)
        try seedInstalledPackage(module: module, manifest: newer)
        try seedInstalledPackage(module: module, manifest: otherFamily)
        let installedBefore = Set(module.installedVersions().map(\.version))

        // Not installed at all.
        assertInvalidSource(module, version: newer.phpVersion, source: "8.9.9", containing: "not installed", installedBefore: installedBefore)
        // Wrong family.
        assertInvalidSource(module, version: newer.phpVersion, source: otherFamily.phpVersion, containing: "not an earlier patch", installedBefore: installedBefore)
        // The target itself: nothing to update.
        assertInvalidSource(module, version: newer.phpVersion, source: newer.phpVersion, containing: "already the requested version", installedBefore: installedBefore)
        // A newer patch is not an update source for an older target.
        assertInvalidSource(module, version: older.phpVersion, source: newer.phpVersion, containing: "not older than", installedBefore: installedBefore)
    }

    private func assertInvalidSource(_ module: PHPModule, version: String, source: String, containing fragment: String, installedBefore: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try module.update(requestedVersion: version, sourceVersion: source), "an invalid source must never update another runtime", file: file, line: line) { error in
            guard case PHPModuleError.invalidUpdateSource(let reason) = error else {
                return XCTFail("Expected a specific invalid-source error, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(fragment), "Unexpected reason: \(reason)", file: file, line: line)
        }
        // No runtime was replaced and nothing was installed on the way out.
        XCTAssertEqual(Set(module.installedVersions().map(\.version)), installedBefore,
                       "A rejected update source must not change any installed runtime.", file: file, line: line)
    }

    /// Place an already-installed package from the provider cache's real binaries,
    /// so package validation succeeds exactly as it would in production.
    private func seedInstalledPackage(module: PHPModule, manifest: PHPManifest) throws {
        let staged = try ProviderArtifactCache.shared.stagedExecutables(version: manifest.phpVersion)
        let directory = module.packageDirectoryURL(forTesting: manifest.phpVersion)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["php", "php-fpm"] {
            let destination = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: staged.appendingPathComponent(name), to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
        let digests = try ProviderArtifactCache.shared.artifacts(version: manifest.phpVersion)
        let package = PHPPackage(version: manifest.phpVersion, architecture: "arm64", packagePath: directory.path,
                                 cliPath: directory.appendingPathComponent("php").path,
                                 fpmPath: directory.appendingPathComponent("php-fpm").path,
                                 source: manifest.artifacts["cli"]!.url, cliSHA256: digests["cli"]!, fpmSHA256: digests["fpm"]!, installedAt: Date())
        try JSONEncoder().encode(package).write(to: directory.appendingPathComponent(".vaelen-package.json"))
    }

    // MARK: - Progress handover

    /// Announcing the second archive must not reset the aggregate measurement the
    /// first archive already contributed.
    func testAnnouncingTheNextArchivePreservesTheAggregateMeasurement() throws {
        let samples = ProgressSamples()
        let tracker = PHPArtifactProgressTracker(artifactCount: 2) { bytes, total, _, _, _ in samples.append(bytes, total) }
        tracker.declareSize(index: 1, bytes: 1_000)
        tracker.declareSize(index: 2, bytes: 1_000)
        tracker.update(name: "CLI", index: 1, bytes: 1_000, total: 1_000)
        let completed = try XCTUnwrap(samples.snapshot().last)
        XCTAssertEqual(completed.0, 1_000)
        // Starting the second archive must not publish a bare zero.
        tracker.announce(name: "FPM", index: 2)
        let announced = try XCTUnwrap(samples.snapshot().last)
        XCTAssertEqual(announced.0, 1_000, "The first archive's completed bytes must survive the handover.")
        XCTAssertEqual(announced.1, 2_000)
        // The visible series is monotonic across the whole operation.
        let reported = samples.snapshot().map(\.0)
        XCTAssertEqual(reported, reported.sorted(), "A bare zero would make the visible transfer jump backwards.")
    }

    // MARK: - Discovered package reuse

    /// A version a provider check discovered must install on first download, then
    /// reuse its verified cache and re-verify against the recorded digest. The
    /// recorded digest is a local integrity record, not provider authentication,
    /// and is labelled as such.
    func testDiscoveredVersionReusesItsRecordedDigestOnReinstall() throws {
        // Data shape: provider-named CLI and FPM archives built from local
        // arm64 executables, mapped by artifact filename to the transfer callback.
        let version = "8.5.9"
        let baselineVersion = "8.5.8"
        let fixtureRoot = root.appendingPathComponent("provider-artifacts-\(UUID().uuidString)", isDirectory: true)
        let artifactDirectory = fixtureRoot.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let source = fixtureRoot.appendingPathComponent("fixture.c")
        let extensions = PHPPackageProvider.requiredExtensions.map { "\"\($0)\"" }.joined(separator: ", ")
        let sourceText = """
        #include <stdio.h>
        #include <string.h>
        int main(int argc, char **argv) {
            if (argc > 1 && strcmp(argv[1], "-v") == 0) { puts("PHP \(version) fixture"); return 0; }
            if (argc > 1 && strcmp(argv[1], "-m") == 0) {
                puts("[PHP Modules]");
                const char *modules[] = {\(extensions)};
                for (unsigned long i = 0; i < sizeof(modules) / sizeof(modules[0]); i++) puts(modules[i]);
                return 0;
            }
            return 0;
        }
        """
        try sourceText.write(to: source, atomically: true, encoding: .utf8)
        var fixtureArtifacts: [String: URL] = [:]
        for (kind, executable) in [("cli", "php"), ("fpm", "php-fpm")] {
            let binary = fixtureRoot.appendingPathComponent(executable)
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["clang", "-arch", "arm64", "-mmacosx-version-min=12.0", source.path, "-o", binary.path]
            try compiler.run()
            compiler.waitUntilExit()
            XCTAssertEqual(compiler.terminationStatus, 0, "The local arm64 \(kind) executable fixture must compile.")
            let archive = artifactDirectory.appendingPathComponent(PHPPackageProvider.artifactFile(version: version, kind: kind))
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-czf", archive.path, "-C", fixtureRoot.path, executable]
            try tar.run()
            tar.waitUntilExit()
            XCTAssertEqual(tar.terminationStatus, 0, "The local \(kind) archive fixture must be created.")
            fixtureArtifacts[archive.lastPathComponent] = archive
        }
        let artifacts = fixtureArtifacts
        let baseline = manifestFixture(version: baselineVersion, cliSHA: String(repeating: "a", count: 64), fpmSHA: String(repeating: "b", count: 64))
        let feed = Self.feed(published: ["8.5.8-cli", "8.5.8-fpm", "8.5.9-cli", "8.5.9-fpm"])
        let location = BundledPHPManifestLocation(
            catalog: PHPManifestCatalog(manifests: [baseline]),
            stateDirectory: fixtureRoot.appendingPathComponent("catalog-state", isDirectory: true),
            now: { Self.now },
            fetchFeed: { feed },
            fetchLegacyFeed: { Self.feed(published: []) }
        )
        try location.checkCatalogNow()
        let discovered = try XCTUnwrap(location.discoveredManifests().first { $0.phpVersion == version })
        XCTAssertFalse(discovered.verification.isPinnedByReview)
        XCTAssertEqual(discovered.artifacts["cli"]?.sha256, "")
        XCTAssertEqual(discovered.artifacts["fpm"]?.sha256, "")

        let moduleLayout = VaelenFilesystemLayout(rootURL: fixtureRoot.appendingPathComponent("support", isDirectory: true), logsDirectoryURL: fixtureRoot.appendingPathComponent("logs", isDirectory: true))
        let transferCount = Counter()
        let module = PHPModule(layout: moduleLayout, location: location, includesBundledCatalog: false, artifactTransfer: { source, destination, _ in
            guard let fixture = artifacts[source.lastPathComponent] else { throw PHPModuleError.invalidManifest("Missing local artifact fixture.") }
            transferCount.increment()
            try FileManager.default.copyItem(at: fixture, to: destination)
        })

        let cliArchive = try XCTUnwrap(artifacts[PHPPackageProvider.artifactFile(version: version, kind: "cli")])
        let fpmArchive = try XCTUnwrap(artifacts[PHPPackageProvider.artifactFile(version: version, kind: "fpm")])
        let expectedCLISHA = Self.sha256(try Data(contentsOf: cliArchive))
        let expectedFPMSHA = Self.sha256(try Data(contentsOf: fpmArchive))
        let installed = try module.install(requestedVersion: version)
        XCTAssertEqual(installed.cliSHA256, expectedCLISHA, "The package records the digest of received CLI archive bytes.")
        XCTAssertEqual(installed.fpmSHA256, expectedFPMSHA, "The package records the digest of received FPM archive bytes.")
        XCTAssertEqual(transferCount.value, 2, "The first install transfers each local archive once.")
        let persisted = try XCTUnwrap(location.discoveredManifests().first { $0.phpVersion == version })
        XCTAssertEqual(persisted.artifacts["cli"]?.sha256, expectedCLISHA)
        XCTAssertEqual(persisted.artifacts["fpm"]?.sha256, expectedFPMSHA)

        // Removal then reinstall must validate and reuse the local bytes against
        // their persisted digests without another transfer.
        try module.remove(requestedVersion: version)
        let reinstalled = try module.install(requestedVersion: version)
        XCTAssertEqual(reinstalled.cliSHA256, installed.cliSHA256, "Reinstall must match the recorded integrity record.")
        XCTAssertEqual(reinstalled.fpmSHA256, installed.fpmSHA256)
        XCTAssertEqual(module.operationState()?.usingVerifiedCachedDownloads, true, "Reinstall must reuse both verified local archive bytes.")
        XCTAssertEqual(transferCount.value, 2, "Reinstall must not transfer either archive again.")
    }

    // MARK: - Support

    static let now = Date(timeIntervalSince1970: 2_100_000_000)

    private static func feed(published: [String]) -> Data {
        let entries = published.map { ["is_dir": false, "name": "php-\($0)-macos-aarch64.tar.gz"] }
        return (try? JSONSerialization.data(withJSONObject: entries)) ?? Data()
    }

    private func manifestFixture(version: String, cliSHA: String, fpmSHA: String) -> PHPManifest {
        PHPManifest(
            schemaVersion: 1, module: "php", phpVersion: version, platform: "macos", architecture: "arm64",
            build: .init(requiredExtensions: ["pdo_mysql"], optionalExtensions: ["imagick"]),
            artifacts: [
                "cli": PHPArtifact(file: PHPPackageProvider.artifactFile(version: version, kind: "cli"), url: PHPPackageProvider.artifactURL(version: version, kind: "cli"), sha256: cliSHA),
                "fpm": PHPArtifact(file: PHPPackageProvider.artifactFile(version: version, kind: "fpm"), url: PHPPackageProvider.artifactURL(version: version, kind: "fpm"), sha256: fpmSHA),
            ],
            verification: .init(algorithm: "sha256", authenticity: PHPPackageProvider.authenticity, digestPinnedByReview: true),
            release: .init(tag: PHPPackageProvider.channel, url: PHPPackageProvider.baseURL)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A catalog that never checks the provider, for tests that supply their own.
struct StaticCatalogLocation: PHPManifestLocation {
    let catalog: PHPManifestCatalog
    func manifests() throws -> [PHPManifest] { catalog.manifests }
    func manifest() throws -> PHPManifest {
        guard let first = catalog.manifests.max(by: { (PHPVersion($0.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) }) else {
            throw PHPModuleError.manifestUnavailable
        }
        return first
    }
    func artifactBaseURL() -> URL? { nil }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class Toggle: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool = false) { self.value = value }
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

/// Blocks a provider stub until the test releases it, so an in-flight check is
/// observable deterministically.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { lock.lock(); isOpen = true; lock.unlock(); semaphore.signal() }
    func waitUntilOpen() { lock.lock(); let open = isOpen; lock.unlock(); if !open { semaphore.wait() } }
}

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

private final class ProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [(Int64, Int64?)]()
    func append(_ bytes: Int64, _ total: Int64?) { lock.lock(); values.append((bytes, total)); lock.unlock() }
    func snapshot() -> [(Int64, Int64?)] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class PHPArtifactRedirectProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data("redirected artifact body".utf8)
    private static let requestLock = NSLock()
    nonisolated(unsafe) private static var requests = [URL]()

    static var requestedURLs: [URL] { requestLock.lock(); defer { requestLock.unlock() }; return requests }
    static func resetRequests() { requestLock.lock(); requests.removeAll(); requestLock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestLock.lock(); Self.requests.append(url); Self.requestLock.unlock()
        let target = url.path == "/down"
            ? "https://static-php-cli.fra1.digitaloceanspaces.com/body"
            : URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "target" })?.value
        if (url.path == "/redirect" || url.path == "/down"),
           let target,
           let destination = URL(string: target, relativeTo: url)?.absoluteURL {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(Self.payload.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
