import Foundation
import CryptoKit
import Darwin
import os

public struct PHPVersion: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              !parts[2].isEmpty else { return nil }
        let patchPart = parts[2].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let patch = Int(patchPart[0]), patch >= 0,
              major >= 0, minor >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = patchPart.count == 2 && !patchPart[1].isEmpty ? String(patchPart[1]) : nil
    }

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    public var isStable: Bool { prerelease == nil }
    public var family: String { "\(major).\(minor)" }
    public var description: String { "\(major).\(minor).\(patch)\(prerelease.map { "-\($0)" } ?? "")" }

    public static func < (lhs: PHPVersion, rhs: PHPVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return left < right
        }
    }
}

public struct PHPFamily: Hashable, Codable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]), major >= 0, minor >= 0 else { return nil }
        self.major = major; self.minor = minor
    }

    public var description: String { "\(major).\(minor)" }
}

public enum PHPVersionResolver {
    public static func resolve(_ requested: String, versions: [PHPVersion]) -> PHPVersion? {
        let stable = versions.filter(\.isStable)
        if requested == "latest" { return stable.max() }
        if let exact = PHPVersion(requested), exact.isStable { return stable.first(where: { $0 == exact }) }
        guard let family = PHPFamily(requested) else { return nil }
        return stable.filter { $0.major == family.major && $0.minor == family.minor }.max()
    }

    public static func resolve(_ requested: String, versionStrings: [String]) -> String? {
        guard let version = resolve(requested, versions: versionStrings.compactMap(PHPVersion.init)) else { return nil }
        return version.description
    }
}

public enum PHPPackageEligibility: String, Codable, Sendable {
    case eligible
    case invalid
    case ambiguous
}

public struct PHPInstalledPackageObservation: Codable, Equatable, Sendable {
    public let package: PHPPackage?
    public let version: String?
    public let eligibility: PHPPackageEligibility
    public let reason: String?

    public init(package: PHPPackage?, version: String?, eligibility: PHPPackageEligibility, reason: String? = nil) {
        self.package = package; self.version = version; self.eligibility = eligibility; self.reason = reason
    }
}

public struct PHPArtifact: Codable, Equatable, Sendable {
    public let file: String
    public let url: String
    public let sha256: String

    public init(file: String, url: String, sha256: String) {
        self.file = file
        self.url = url
        self.sha256 = sha256
    }
}

public struct PHPReleaseReference: Codable, Equatable, Sendable {
    public let tag: String
    public let url: String
    public init(tag: String, url: String) { self.tag = tag; self.url = url }
}

public struct PHPManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let module: String
    public let phpVersion: String
    public let platform: String
    public let architecture: String
    public let build: PHPBuildConfiguration?
    public let artifacts: [String: PHPArtifact]
    public let verification: PHPVerification
    public let catalogURL: String?
    public let release: PHPReleaseReference?
    /// Exact archive sizes in bytes, per SAPI, when Vaelen knows them from a
    /// completed download. Used only to size a determinate progress bar; a
    /// missing or wrong value degrades to per-archive progress rather than an
    /// invented percentage.
    public let verifiedArtifactSizes: [String: Int64]?

    public init(schemaVersion: Int, module: String, phpVersion: String, platform: String, architecture: String, build: PHPBuildConfiguration? = nil, artifacts: [String: PHPArtifact], verification: PHPVerification, catalogURL: String? = nil, release: PHPReleaseReference? = nil, verifiedArtifactSizes: [String: Int64]? = nil) {
        self.schemaVersion = schemaVersion
        self.module = module
        self.phpVersion = phpVersion
        self.platform = platform
        self.architecture = architecture
        self.build = build
        self.artifacts = artifacts
        self.verification = verification
        self.catalogURL = catalogURL
        self.release = release
        self.verifiedArtifactSizes = verifiedArtifactSizes
    }

    /// A copy of this manifest describing a different version, used when a
    /// provider check discovers a newer patch of an already-supported line.
    func replacingVersion(_ version: String, artifacts: [String: PHPArtifact], verification: PHPVerification, verifiedArtifactSizes: [String: Int64]? = nil) -> PHPManifest {
        PHPManifest(schemaVersion: schemaVersion, module: module, phpVersion: version, platform: platform, architecture: architecture, build: build, artifacts: artifacts, verification: verification, catalogURL: catalogURL, release: release, verifiedArtifactSizes: verifiedArtifactSizes)
    }
}

public struct PHPBuildConfiguration: Codable, Equatable, Sendable {
    public let requiredExtensions: [String]
    public let optionalExtensions: [String]
    public let minimumMacOS: String?
    public let notices: [String]?
    public let generation: String?
    public let channel: String?

    public init(requiredExtensions: [String] = [], optionalExtensions: [String] = [], minimumMacOS: String? = nil, notices: [String]? = nil, generation: String? = nil, channel: String? = nil) {
        self.requiredExtensions = requiredExtensions
        self.optionalExtensions = optionalExtensions
        self.minimumMacOS = minimumMacOS
        self.notices = notices
        self.generation = generation
        self.channel = channel
    }
}

public struct PHPVerification: Codable, Equatable, Sendable {
    public let algorithm: String
    public let authenticity: String
    /// Whether the artifact digest was pinned by review before download, rather
    /// than recorded from the bytes a provider check caused Vaelen to fetch.
    ///
    /// `true` (the default when absent) means Vaelen knows the expected digest
    /// and refuses anything else. `false` means the version was discovered at
    /// runtime: Vaelen downloads it over the provider's verified HTTPS origin
    /// and records the digest it receives as a local integrity record. That is
    /// not independent provider authentication — the provider publishes no
    /// signed checksum metadata — so Vaelen labels these versions distinctly
    /// and re-verifies every reuse against the recorded digest.
    public let digestPinnedByReview: Bool?

    public init(algorithm: String, authenticity: String, digestPinnedByReview: Bool? = nil) {
        self.algorithm = algorithm
        self.authenticity = authenticity
        self.digestPinnedByReview = digestPinnedByReview
    }

    public var isPinnedByReview: Bool { digestPinnedByReview ?? true }
}

public protocol PHPManifestLocation: Sendable {
    func manifest() throws -> PHPManifest
    func artifactBaseURL() -> URL?
    func manifests() throws -> [PHPManifest]
    func refreshCatalogIfNeeded() throws
    func checkCatalogNow() throws
    func catalogCheckStatus() -> (Date?, String?)
}

public extension PHPManifestLocation {
    func manifests() throws -> [PHPManifest] { [try manifest()] }
    func refreshCatalogIfNeeded() throws {}
    func checkCatalogNow() throws { try refreshCatalogIfNeeded() }
    func catalogCheckStatus() -> (Date?, String?) { (nil, nil) }
}

public struct PHPManifestCatalog: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let module: String
    public let manifests: [PHPManifest]
    public init(manifests: [PHPManifest], schemaVersion: Int = 1, module: String = "php") { self.schemaVersion = schemaVersion; self.module = module; self.manifests = manifests }
    private enum CodingKeys: String, CodingKey { case schemaVersion, module, manifests }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        module = try values.decode(String.self, forKey: .module)
        manifests = try values.decode([PHPManifest].self, forKey: .manifests)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(module, forKey: .module)
        try values.encode(manifests, forKey: .manifests)
    }
}

/// The provider of prepared macOS PHP packages Vaelen installs.
///
/// Vaelen does not compile PHP. It installs provider-published CLI/FPM packages
/// and verifies every byte against a SHA-256 digest pinned in Vaelen's catalog.
/// The provider publishes no checksums of its own, so the digest pin is Vaelen's
/// trust anchor and every catalog refresh re-validates the provider's bytes.
/// The single authoritative description of Vaelen's PHP package source.
///
/// These values are generated from `Distribution/PHP/provider.json`, which is the
/// only place provider configuration is written by hand. The refresh script and
/// Core must not diverge, so Core reads the same file rather than repeating
/// literals.
    /// How much is known about the offered versions right now.
///
/// A successful check means the offered versions reflect the provider's current
/// listing. A failure never clears what was last usable; it downgrades the claim
/// to cached. This distinction is what stops Vaelen from presenting "up to date"
/// merely because pinned files still appear in a listing.
public enum PHPCatalogAvailability: String, Codable, Sendable {
    /// The last check succeeded, so the offered versions are current.
    case current
    /// The last check failed; these versions came from the last usable check.
    case cached
    /// Nothing has been confirmed yet in this installation.
    case unconfirmed
}

public enum PHPPackageProvider: Sendable {
    /// Provider identity, as published by the provider's own build metadata.
    public static let id = "static-php-cli"
    public static let generation = "v3"
    public static let channel = "bulk"
    public static let baseURL = "https://dl.static-php.dev/v3/php-bin/bulk"
    public static let feedURL = "https://dl.static-php.dev/v3/php-bin/bulk/?format=json"
    public static let licenseBaseURL = "https://dl.static-php.dev/v3/php-bin/bulk/license"
    public static let authenticity = "static-php-cli-prepared-packages"
    public static let minimumMacOS = "12.0"
    /// The published packages redirect to object storage; both hosts are the
    /// provider's own infrastructure.
    public static let artifactHosts: Set<String> = [
        "dl.static-php.dev",
        "static-php-cli.fra1.digitaloceanspaces.com",
    ]
    /// Extensions the product validates after installing a package. A version is
    /// only offered when the provider's binaries actually carry all of these.
    /// This contract is deliberately not weakened to accommodate a smaller
    /// provider channel.
    public static let requiredExtensions = [
        "bcmath", "ctype", "curl", "dom", "fileinfo", "filter", "gd", "iconv", "intl",
        "mbstring", "mysqli", "mysqlnd", "openssl", "pcntl", "pdo", "pdo_mysql", "phar",
        "session", "simplexml", "sodium", "tokenizer", "xml", "xmlreader", "xmlwriter", "zip",
    ]
    /// Optional extensions are reported honestly when absent rather than
    /// required.
    public static let optionalExtensions = ["imagick"]
    public static let legacyFamilies = ["7.4", "8.0", "8.1", "8.2"]
    public static let legacyGeneration = "archive-v2"
    public static let legacyChannel = "bulk"
    public static let legacyBaseURL = "https://dl.static-php.dev/static-php-cli/bulk"
    public static let legacyFeedURL = "https://dl.static-php.dev/static-php-cli/bulk/?format=json"
    public static let legacyLicenseBaseURL = "https://dl.static-php.dev/static-php-cli/bulk/license"
    public static let legacyLicenseNotices = ["src_php-src_0.txt"]
    public static let legacyVersions = ["8.0.30", "8.1.34"]
    public static let legacyMinimumMacOS = ["8.0.30": "14.0", "8.1.34": "12.0"]
    /// Display metadata kept in sync with Distribution/PHP/provider.json.
    public static let seriesLabels: [String: String] = [
        "7.4": "Legacy · End of life", "8.0": "Legacy · End of life",
        "8.1": "Legacy · End of life", "8.2": "Security support · New projects should use 8.3 or newer",
    ]

    public static func isLegacyManifest(_ manifest: PHPManifest) -> Bool {
        manifest.release?.url == legacyBaseURL && manifest.release?.tag == legacyChannel
    }
    /// The family Vaelen bundles so a first activation needs no download.
    public static let bundledFamily = "8.5"

    /// How Vaelen establishes package integrity.
    ///
    /// The provider publishes no signed checksum metadata, so Vaelen cannot
    /// authenticate a digest against a provider signature. Vaelen instead trusts
    /// the provider's HTTPS origin (restricted to a host allowlist, including the
    /// object-storage host the provider redirects to) and records the SHA-256 of
    /// the bytes it received. That digest is a local integrity record: it proves
    /// the install matches what was downloaded and that later reuse is
    /// unmodified, but it is not independent provider authentication.
    public static let integrityTrustModel = "https-origin"

    public static func artifactFile(version: String, kind: String) -> String {
        "php-\(version)-\(kind)-macos-aarch64.tar.gz"
    }
    public static func artifactURL(version: String, kind: String) -> String {
        "\(baseURL)/\(artifactFile(version: version, kind: kind))"
    }
    /// The provider publishes per-component notices, including PHP's own license.
    public static func licenseURL(component: String) -> String {
        "\(licenseBaseURL)/\(component)_LICENSE.txt"
    }
    /// PHP itself is redistributed under its own license, not the build tool's.
    public static let phpLicenseComponent = "php-src"
}

public struct FilePHPManifestLocation: PHPManifestLocation {
    public static let defaultCatalogURL = URL(string: "https://github.com/banestojanovic/vaelen/releases/download/php-catalog/php-catalog.json")!
    private static let refreshGate = PHPCatalogRefreshGate()
    public let manifestURL: URL
    public let baseURL: URL?
    public let catalogURL: URL?
    private let now: @Sendable () -> Date
    public init(manifestURL: URL, baseURL: URL? = nil, catalogURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) { self.manifestURL = manifestURL; self.baseURL = baseURL; self.catalogURL = catalogURL; self.now = now }
    public func manifest() throws -> PHPManifest {
        try JSONDecoder().decode(PHPManifest.self, from: Data(contentsOf: manifestURL))
    }
    public func artifactBaseURL() -> URL? { baseURL ?? manifestURL.deletingLastPathComponent() }
    public func refreshCatalogIfNeeded() throws {
        try refreshCatalog(force: false)
    }
    public func checkCatalogNow() throws { try refreshCatalog(force: true) }
    private func refreshCatalog(force: Bool) throws {
        guard let catalogURL else {
            let directory = manifestURL.deletingLastPathComponent()
            let stateURL = directory.appendingPathComponent("php-catalog-check.json")
            Self.refreshGate.lock.lock()
            let previous = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: stateURL))
            let lastAttempt = [previous?.lastAttemptAt, Self.refreshGate.lastAttemptByStateFile[stateURL.path]].compactMap { $0 }.max()
            if !force, let lastAttempt, now().timeIntervalSince(lastAttempt) < 12 * 60 * 60 {
                Self.refreshGate.lock.unlock()
                return
            }
            let attempt = now()
            Self.refreshGate.lastAttemptByStateFile[stateURL.path] = attempt
            let message = "No PHP update catalog is configured for this Vaelen distribution."
            try? JSONEncoder().encode(PHPCatalogCheckState(lastAttemptAt: attempt, lastSuccessfulAt: previous?.lastSuccessfulAt, error: message)).write(to: stateURL, options: .atomic)
            Self.refreshGate.lock.unlock()
            if force { throw PHPModuleError.catalogUnavailable(message) }
            return
        }
        let directory = manifestURL.deletingLastPathComponent()
        let cacheURL = directory.appendingPathComponent("php-catalog.json")
        let stateURL = directory.appendingPathComponent("php-catalog-check.json")
        Self.refreshGate.lock.lock()
        let prior = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: stateURL))
        let previousAttempt = [prior?.lastAttemptAt, Self.refreshGate.lastAttemptByStateFile[stateURL.path]].compactMap { $0 }.max()
        let staleMissingFeedError = prior?.error?.contains("no update-feed URL") == true
        if !force, !staleMissingFeedError, let previousAttempt, now().timeIntervalSince(previousAttempt) < 12 * 60 * 60 { Self.refreshGate.lock.unlock(); return }
        guard !Self.refreshGate.inFlightStateFiles.contains(stateURL.path) else {
            Self.refreshGate.lock.unlock()
            if force { throw PHPModuleError.operationInProgress("a PHP catalog check is already in progress") }
            return
        }
        Self.refreshGate.inFlightStateFiles.insert(stateURL.path)
        let attemptDate = now()
        Self.refreshGate.lastAttemptByStateFile[stateURL.path] = attemptDate
        do {
            try JSONEncoder().encode(PHPCatalogCheckState(lastAttemptAt: attemptDate, lastSuccessfulAt: prior?.lastSuccessfulAt, error: nil)).write(to: stateURL, options: .atomic)
        } catch {
            Self.refreshGate.inFlightStateFiles.remove(stateURL.path)
            Self.refreshGate.lock.unlock()
            throw error
        }
        Self.refreshGate.lock.unlock()
        defer {
            Self.refreshGate.lock.lock()
            Self.refreshGate.inFlightStateFiles.remove(stateURL.path)
            Self.refreshGate.lock.unlock()
        }
        let scheme = catalogURL.scheme?.lowercased()
        let host = catalogURL.host?.lowercased()
        let isLocalTestEndpoint = scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host ?? "")
        guard scheme == "https" || isLocalTestEndpoint else {
            let message = "The PHP update catalog must use HTTPS."
            try? JSONEncoder().encode(PHPCatalogCheckState(lastAttemptAt: attemptDate, lastSuccessfulAt: prior?.lastSuccessfulAt, error: message)).write(to: stateURL, options: .atomic)
            throw PHPModuleError.catalogUnavailable(message)
        }
        var request = URLRequest(url: catalogURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let semaphore = DispatchSemaphore(value: 0)
        let result = PHPRemoteResultBox()
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            if let data { result.set(.success((data, response as? HTTPURLResponse))) }
            else { result.set(.failure(error ?? PHPModuleError.catalogUnavailable("The PHP update catalog could not be reached."))) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()
        let data: Data
        do {
            let (responseData, response): (Data, HTTPURLResponse?)
            do { (responseData, response) = try result.get()!.get() }
            catch {
                let cause = error as NSError
                throw PHPModuleError.catalogUnavailable("The PHP update catalog could not be reached (network error \(cause.code)).")
            }
            data = responseData
            // URLSession returns bodies for 404/500 too. Never accept a stale
            // or error document as a successful catalog response.
            guard let response, (200..<300).contains(response.statusCode) else {
                throw PHPModuleError.catalogUnavailable(response.map { "The PHP update catalog returned HTTP \($0.statusCode)." } ?? "The PHP update catalog returned no HTTP response.")
            }
            let catalog: PHPManifestCatalog
            do { catalog = try JSONDecoder().decode(PHPManifestCatalog.self, from: data) }
            catch { throw PHPModuleError.catalogUnavailable("The PHP update catalog response is not valid JSON.") }
            guard Self.isValidRemoteCatalog(catalog) else { throw PHPModuleError.catalogUnavailable("The PHP update catalog contains no valid, checksum-verified Vaelen PHP releases.") }
            try data.write(to: cacheURL, options: .atomic)
            try JSONEncoder().encode(PHPCatalogCheckState(lastAttemptAt: attemptDate, lastSuccessfulAt: attemptDate, error: nil)).write(to: stateURL, options: .atomic)
        } catch {
            let message: String
            if case PHPModuleError.catalogUnavailable(let cause) = error { message = cause }
            else { message = String(describing: error) }
            try? JSONEncoder().encode(PHPCatalogCheckState(lastAttemptAt: attemptDate, lastSuccessfulAt: prior?.lastSuccessfulAt, error: message)).write(to: stateURL, options: .atomic)
            throw error
        }
    }

    private static func isValidRemoteCatalog(_ catalog: PHPManifestCatalog) -> Bool {
        catalog.schemaVersion == 1 && catalog.module == "php" && !catalog.manifests.isEmpty && catalog.manifests.allSatisfy { manifest in
            Self.isProviderBackedManifest(manifest)
        }
    }

    /// A catalog is trusted only when every entry names the provider Vaelen
    /// installs from, on the provider's own hosts, with a pinned digest.
    static func isProviderBackedManifest(_ manifest: PHPManifest) -> Bool {
        guard manifest.module == "php", manifest.schemaVersion == 1,
              manifest.platform == "macos", manifest.architecture == "arm64",
              manifest.verification.algorithm.lowercased() == "sha256",
              manifest.verification.authenticity == PHPPackageProvider.authenticity,
              PHPVersion(manifest.phpVersion)?.isStable == true,
              let version = PHPVersion(manifest.phpVersion)?.description,
              let release = manifest.release,
              let cli = manifest.artifacts["cli"], let fpm = manifest.artifacts["fpm"] else { return false }
        return [("cli", cli), ("fpm", fpm)].allSatisfy { kind, artifact in
            let modernSource = release.url == PHPPackageProvider.baseURL && release.tag == PHPPackageProvider.channel
            let legacySource = release.url == PHPPackageProvider.legacyBaseURL && release.tag == PHPPackageProvider.legacyChannel && PHPPackageProvider.legacyVersions.contains(version)
            let expectedFile = legacySource ? "archive-v2-\(version)-\(kind)-macos-aarch64.tar.gz" : PHPPackageProvider.artifactFile(version: version, kind: kind)
            let expectedURL = "\(release.url)/php-\(version)-\(kind)-macos-aarch64.tar.gz"
            guard modernSource || legacySource,
                  artifact.file == expectedFile,
                  artifact.url == expectedURL,
                  let url = URL(string: artifact.url),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  PHPPackageProvider.artifactHosts.contains(host),
                  host == "dl.static-php.dev",
                  url.path.hasSuffix("/php-\(version)-\(kind)-macos-aarch64.tar.gz"),
                  artifact.sha256.count == 64,
                  artifact.sha256.allSatisfy({ $0.isHexDigit }),
                  !artifact.file.isEmpty
            else { return false }
            if legacySource {
                guard manifest.build?.generation == PHPPackageProvider.legacyGeneration,
                      manifest.build?.channel == PHPPackageProvider.legacyChannel,
                      manifest.build?.minimumMacOS == PHPPackageProvider.legacyMinimumMacOS[version],
                      manifest.build?.notices?.contains("src_php-src_0.txt") == true
                else { return false }
            }
            // A catalog entry must not pin a build that drops an extension the
            // product or its projects rely on.
            guard let build = manifest.build else { return true }
            return !build.requiredExtensions.isEmpty
        }
    }
    public func manifests() throws -> [PHPManifest] {
        let catalogURL = manifestURL.deletingLastPathComponent().appendingPathComponent("php-catalog.json")
        guard let data = try? Data(contentsOf: catalogURL) else { return [try manifest()] }
        return try JSONDecoder().decode(PHPManifestCatalog.self, from: data).manifests
    }
    public func catalogCheckStatus() -> (Date?, String?) {
        let url = manifestURL.deletingLastPathComponent().appendingPathComponent("php-catalog-check.json")
        guard let state = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: url)) else { return (nil, nil) }
        return (state.lastSuccessfulAt, state.error)
    }
}

/// Serves the PHP catalog that ships inside the signed Vaelen application.
///
/// The shipped catalog is the trust anchor: it pins the SHA-256 of every
/// provider package Vaelen will install, so PHP is available on first launch
/// without any distribution configuration. Periodic and manual checks confirm
/// the provider still publishes those prepared packages.
public struct BundledPHPManifestLocation: PHPManifestLocation {
    private static let refreshGate = PHPCatalogRefreshGate()
    private static let checkInterval: TimeInterval = 12 * 60 * 60
    public let catalog: PHPManifestCatalog
    public let stateDirectory: URL
    private let now: @Sendable () -> Date
    private let fetchFeed: @Sendable () throws -> Data
    private let fetchLegacyFeed: @Sendable () throws -> Data

    public init(
        catalog: PHPManifestCatalog,
        stateDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        fetchFeed: (@Sendable () throws -> Data)? = nil,
        fetchLegacyFeed: (@Sendable () throws -> Data)? = nil
    ) {
        self.catalog = catalog
        self.stateDirectory = stateDirectory
        self.now = now
        self.fetchFeed = fetchFeed ?? { try BundledPHPManifestLocation.fetchProviderFeed() }
        self.fetchLegacyFeed = fetchLegacyFeed ?? { try BundledPHPManifestLocation.fetchProviderFeed(url: PHPPackageProvider.legacyFeedURL) }
    }

    public static func bundledCatalog() throws -> PHPManifestCatalog {
        guard let url = Bundle.module.url(forResource: "php-catalog", withExtension: "json") else {
            throw PHPModuleError.manifestUnavailable
        }
        return try JSONDecoder().decode(PHPManifestCatalog.self, from: Data(contentsOf: url))
    }

    public func manifests() throws -> [PHPManifest] {
        guard !catalog.manifests.isEmpty else { throw PHPModuleError.manifestUnavailable }
        return catalog.manifests.sorted {
            (PHPVersion($0.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1.phpVersion) ?? .init(major: 0, minor: 0, patch: 0))
        }
    }

    /// The latest stable PHP Vaelen includes, which the user may activate.
    public func manifest() throws -> PHPManifest {
        let all = try manifests()
        guard let newest = all.compactMap({ PHPVersion($0.phpVersion) }).max(),
              let manifest = all.first(where: { $0.phpVersion == newest.description })
        else { throw PHPModuleError.manifestUnavailable }
        return manifest
    }

    public func artifactBaseURL() -> URL? { URL(string: PHPPackageProvider.baseURL) }

    public func refreshCatalogIfNeeded() throws { try check(force: false) }
    public func checkCatalogNow() throws { try check(force: true) }

    public func catalogCheckStatus() -> (Date?, String?) {
        guard let state = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: stateFileURL)) else { return (nil, nil) }
        return (state.lastSuccessfulAt, state.error)
    }

    /// How much is known about the offered versions right now.
    public func catalogAvailability() -> PHPCatalogAvailability {
        guard let state = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: stateFileURL)) else { return .unconfirmed }
        if state.error != nil { return state.lastSuccessfulAt == nil ? .unconfirmed : .cached }
        return state.lastSuccessfulAt == nil ? .unconfirmed : .current
    }

    /// Versions the provider currently advertises that Vaelen has no installable
    /// package metadata for. Reported separately so they are never presented as
    /// installable.
    public func advertisedUnverifiedVersions() -> [String] {
        guard let state = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: stateFileURL)),
              state.error == nil,
              let feed = try? fetchFeed(),
              let published = try? Self.publishedVersions(from: feed)
        else { return [] }
        let known = Set((try? knownManifests().map(\.phpVersion)) ?? [])
        return published.newestByFamily.values.filter { !known.contains($0) }.sorted()
    }

    /// Record the digests of a version this check discovered, so subsequent
    /// installs verify the same bytes.
    func recordDiscoveredDigests(version: String, cli: String, fpm: String, sizes: [String: Int64]) {
        guard let state = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: stateFileURL)),
              var manifests = state.discovered,
              let index = manifests.firstIndex(where: { $0.phpVersion == version })
        else { return }
        let current = manifests[index]
        let currentSizes = current.verifiedArtifactSizes ?? [:]
        var merged = currentSizes
        for (kind, size) in sizes where size > 0 { merged[kind] = size }
        manifests[index] = current.replacingVersion(version, artifacts: [
            "cli": PHPArtifact(file: current.artifacts["cli"]?.file ?? PHPPackageProvider.artifactFile(version: version, kind: "cli"), url: current.artifacts["cli"]?.url ?? PHPPackageProvider.artifactURL(version: version, kind: "cli"), sha256: cli),
            "fpm": PHPArtifact(file: current.artifacts["fpm"]?.file ?? PHPPackageProvider.artifactFile(version: version, kind: "fpm"), url: current.artifacts["fpm"]?.url ?? PHPPackageProvider.artifactURL(version: version, kind: "fpm"), sha256: fpm),
        ], verification: current.verification, verifiedArtifactSizes: merged.isEmpty ? nil : merged)
        try? JSONEncoder().encode(PHPCatalogCheckState(lastAttemptAt: state.lastAttemptAt, lastSuccessfulAt: state.lastSuccessfulAt, error: state.error, discoveredVersions: manifests.map(\.phpVersion), discovered: manifests)).write(to: stateFileURL, options: .atomic)
    }

    private var stateFileURL: URL { stateDirectory.appendingPathComponent("php-catalog-check.json") }

    private func check(force: Bool) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        Self.refreshGate.lock.lock()
        let prior = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: stateFileURL))
        let previousAttempt = [prior?.lastAttemptAt, Self.refreshGate.lastAttemptByStateFile[stateFileURL.path]].compactMap { $0 }.max()
        if !force, let previousAttempt, now().timeIntervalSince(previousAttempt) < Self.checkInterval {
            Self.refreshGate.lock.unlock()
            return
        }
        guard !Self.refreshGate.inFlightStateFiles.contains(stateFileURL.path) else {
            Self.refreshGate.lock.unlock()
            if force { throw PHPModuleError.operationInProgress("a PHP catalog check is already in progress") }
            return
        }
        Self.refreshGate.inFlightStateFiles.insert(stateFileURL.path)
        let attemptDate = now()
        Self.refreshGate.lastAttemptByStateFile[stateFileURL.path] = attemptDate
        do {
            // Mark the attempt without discarding what is already known: a check
            // in progress must never make the last usable catalog disappear.
            try JSONEncoder().encode(PHPCatalogCheckState(lastAttemptAt: attemptDate, lastSuccessfulAt: prior?.lastSuccessfulAt, error: nil, discoveredVersions: prior?.discoveredVersions ?? [], discovered: prior?.discovered)).write(to: stateFileURL, options: .atomic)
        } catch {
            Self.refreshGate.inFlightStateFiles.remove(stateFileURL.path)
            Self.refreshGate.lock.unlock()
            throw error
        }
        Self.refreshGate.lock.unlock()
        defer {
            Self.refreshGate.lock.lock()
            Self.refreshGate.inFlightStateFiles.remove(stateFileURL.path)
            Self.refreshGate.lock.unlock()
        }

        do {
            let published = try Self.publishedVersions(from: try fetchFeed())
            // A provider that stopped publishing a package Vaelen already pinned
            // has changed underneath us. That is reported as a provider problem
            // rather than silently reporting the shipped catalog as current.
            let modernPinned = try pinnedVersions(source: .modern)
            let missing = modernPinned.filter { !published.allVersions.contains($0) }
            if !missing.isEmpty {
                throw PHPModuleError.catalogUnavailable("The PHP provider no longer publishes \(missing.joined(separator: ", ")).")
            }
            // Legacy releases come from the provider's archived v2 channel. A
            // successful modern feed check must not pretend to check that source;
            // verify its exact pinned packages independently and preserve the
            // usable shipped catalog if that source is unavailable.
            let legacyPinned = try pinnedVersions(source: .legacy)
            if !legacyPinned.isEmpty {
                let legacyFeed = try Self.publishedVersions(from: try fetchLegacyFeed())
                let missingLegacy = legacyPinned.filter { !legacyFeed.allVersions.contains($0) }
                if !missingLegacy.isEmpty {
                    throw PHPModuleError.catalogUnavailable("The archived PHP package source no longer publishes \(missingLegacy.joined(separator: ", ")).")
                }
            }
            // A successful check establishes what the provider currently offers.
            // Newly published compatible patches are recorded so they can be
            // offered without a new Vaelen release.
            // Newly discovered versions are added to what was already recorded; previously
            // discovered versions that are no longer the newest are dropped so
            // the offered set reflects the current listing.
            let previouslyDiscovered = prior?.discovered ?? []
            let discovered = try Self.discoverNewVersions(published: published, known: try knownManifests())
            let merged = Self.mergeDiscovered(previously: previouslyDiscovered, current: discovered)
            let state = PHPCatalogCheckState(
                lastAttemptAt: attemptDate,
                lastSuccessfulAt: attemptDate,
                error: nil,
                discoveredVersions: merged.map(\.phpVersion),
                discovered: merged
            )
            try JSONEncoder().encode(state).write(to: stateFileURL, options: .atomic)
        } catch {
            let message: String
            if case PHPModuleError.catalogUnavailable(let cause) = error { message = cause }
            else { message = String(describing: error) }
            // A failed check keeps whatever was last usable. Availability is not
            // erased, but it is no longer presented as freshly confirmed.
            let preserved = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: stateFileURL))
            try? JSONEncoder().encode(PHPCatalogCheckState(lastAttemptAt: attemptDate, lastSuccessfulAt: preserved?.lastSuccessfulAt ?? prior?.lastSuccessfulAt, error: message, discoveredVersions: preserved?.discoveredVersions ?? [], discovered: preserved?.discovered ?? [])).write(to: stateFileURL, options: .atomic)
            throw error
        }
    }

    private enum ProviderSource { case modern, legacy }
    private func pinnedVersions(source: ProviderSource) throws -> [String] {
        try manifests().filter { manifest in
            guard let release = manifest.release else { return false }
            switch source {
            case .modern: return release.url == PHPPackageProvider.baseURL
            case .legacy: return release.url == PHPPackageProvider.legacyBaseURL
            }
        }.map(\.phpVersion)
    }

    /// Combine previously recorded discoveries with the ones this check made.
    ///
    /// A version that was already discovered keeps any digests recorded by an
    /// earlier install. A version the provider no longer lists as newest is
    /// dropped, so availability always reflects the latest successful check.
    static func mergeDiscovered(previously: [PHPManifest], current: [PHPManifest]) -> [PHPManifest] {
        let currentVersions = Set(current.map(\.phpVersion))
        var byVersion = Dictionary(previously.map { ($0.phpVersion, $0) }, uniquingKeysWith: { _, newer in newer })
        for manifest in current {
            if let existing = byVersion[manifest.phpVersion],
               let existingSHA = existing.artifacts["cli"]?.sha256, !existingSHA.isEmpty {
                // Preserve recorded digests rather than discarding them.
                byVersion[manifest.phpVersion] = existing
            } else {
                byVersion[manifest.phpVersion] = manifest
            }
        }
        return byVersion.filter { currentVersions.contains($0.key) }.values.sorted {
            (PHPVersion($0.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1.phpVersion) ?? .init(major: 0, minor: 0, patch: 0))
        }
    }

    /// Everything Vaelen currently knows how to install: the shipped catalog
    /// plus versions discovered by a successful provider check.
    func knownManifests() throws -> [PHPManifest] {
        var byVersion = Dictionary(uniqueKeysWithValues: try manifests().map { ($0.phpVersion, $0) })
        for manifest in discoveredManifests() { byVersion[manifest.phpVersion] = manifest }
        return byVersion.values.sorted { (PHPVersion($0.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) }
    }

    /// Versions a successful check added beyond the shipped catalog. Each has a
    /// provider URL and a locally recorded digest; see
    /// `PHPPackageProvider.integrityTrustModel` for what that digest proves.
    func discoveredManifests() -> [PHPManifest] {
        guard let state = try? JSONDecoder().decode(PHPCatalogCheckState.self, from: Data(contentsOf: stateFileURL)) else { return [] }
        return state.discovered ?? []
    }


    /// Record newly published patches so they can be installed without a new
    /// Vaelen release. A version is only recorded when it is a genuine patch
    /// successor of something Vaelen already offers and both packages exist.
    static func discoverNewVersions(published: PublishedPackages, known: [PHPManifest]) throws -> [PHPManifest] {
        let knownByVersion = Dictionary(uniqueKeysWithValues: known.map { ($0.phpVersion, $0) })
        var discovered: [PHPManifest] = []
        for (family, newest) in published.newestByFamily {
            guard let parsed = PHPVersion(newest), parsed.isStable else { continue }
            // Only advance a line Vaelen already supports. This keeps the offered
            // set to the intended supported families instead of every historical
            // patch the provider happens to retain.
            let baseline = known.compactMap { PHPVersion($0.phpVersion) }.filter { $0.family == family }.max()
            guard let baseline, parsed > baseline, let reference = knownByVersion[baseline.description] else { continue }
            let manifest = reference.replacingVersion(newest, artifacts: [
                "cli": PHPArtifact(file: PHPPackageProvider.artifactFile(version: newest, kind: "cli"), url: PHPPackageProvider.artifactURL(version: newest, kind: "cli"), sha256: ""),
                "fpm": PHPArtifact(file: PHPPackageProvider.artifactFile(version: newest, kind: "fpm"), url: PHPPackageProvider.artifactURL(version: newest, kind: "fpm"), sha256: ""),
            // Discovered digests are not review-pinned. Vaelen records them from
            // the bytes it receives over the provider's HTTPS origin; see
            // `PHPPackageProvider.integrityTrustModel`.
            ], verification: PHPVerification(algorithm: "sha256", authenticity: PHPPackageProvider.authenticity, digestPinnedByReview: false))
            discovered.append(manifest)
        }
        return discovered
    }

    /// Every version the provider publishes with BOTH a CLI and an FPM archive,
    /// plus the newest patch of each minor family.
    public struct PublishedPackages: Equatable, Sendable {
        public var allVersions: Set<String>
        public var newestByFamily: [String: String]
        /// Exact byte sizes when the provider reported them for both SAPIs.
        /// The listing rounds sizes ("15.1M"), so sizes are only ever used as
        /// hints; exact totals come from the download response itself.
        var sizesHint: [String: Int64] = [:]
    }

    public static func publishedVersions(from feed: Data) throws -> PublishedPackages {
        guard let entries = try? JSONSerialization.jsonObject(with: feed) as? [[String: Any]] else {
            throw PHPModuleError.catalogUnavailable("The PHP provider feed is not valid JSON.")
        }
        var kindsByVersion: [String: Set<String>] = [:]
        let pattern = try NSRegularExpression(pattern: #"^php-([0-9]+\.[0-9]+\.[0-9]+)-(cli|fpm)-macos-aarch64\.tar\.gz$"#)
        for entry in entries {
            guard let name = entry["name"] as? String,
                  let isDirectory = entry["is_dir"] as? Bool, !isDirectory
            else { continue }
            let whole = NSRange(name.startIndex..., in: name)
            guard let match = pattern.firstMatch(in: name, range: whole),
                  let versionRange = Range(match.range(at: 1), in: name),
                  let kindRange = Range(match.range(at: 2), in: name)
            else { continue }
            kindsByVersion[String(name[versionRange]), default: []].insert(String(name[kindRange]))
        }
        let complete = kindsByVersion.filter { $0.value == ["cli", "fpm"] }.keys
        guard !complete.isEmpty else { throw PHPModuleError.catalogUnavailable("The PHP provider feed publishes no prepared CLI/FPM packages.") }
        var newest: [String: String] = [:]
        for version in complete {
            guard let parsed = PHPVersion(version) else { continue }
            if let existing = newest[parsed.family].flatMap(PHPVersion.init), existing >= parsed { continue }
            newest[parsed.family] = version
        }
        return PublishedPackages(allVersions: Set(complete), newestByFamily: newest)
    }

    static func fetchProviderFeed() throws -> Data { try fetchProviderFeed(url: PHPPackageProvider.feedURL) }

    static func fetchProviderFeed(url feedURL: String) throws -> Data {
        guard let url = URL(string: feedURL), url.scheme == "https",
              ["dl.static-php.dev"].contains(url.host?.lowercased() ?? "") else { throw PHPModuleError.catalogUnavailable("The PHP provider feed URL is invalid.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let session = URLSession(configuration: .ephemeral)
        let box = PHPRemoteResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            if let data { box.set(.success((data, response as? HTTPURLResponse))) }
            else { box.set(.failure(error ?? PHPModuleError.catalogUnavailable("The PHP provider feed could not be reached."))) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        session.finishTasksAndInvalidate()
        let (data, response): (Data, HTTPURLResponse?)
        do { (data, response) = try box.get()!.get() }
        catch {
            let cause = error as NSError
            throw PHPModuleError.catalogUnavailable("The PHP provider feed could not be reached (network error \(cause.code)).")
        }
        // A provider error page must never be recorded as a successful check.
        guard let response, (200..<300).contains(response.statusCode) else {
            throw PHPModuleError.catalogUnavailable(response.map { "The PHP provider feed returned HTTP \($0.statusCode)." } ?? "The PHP provider feed returned no HTTP response.")
        }
        return data
    }
}

/// Persisted outcome of the provider check, including any newly published
/// versions the check made installable.
struct PHPCatalogCheckState: Codable {
    let lastAttemptAt: Date
    let lastSuccessfulAt: Date?
    let error: String?
    /// Versions a successful check discovered beyond the shipped catalog.
    var discoveredVersions: [String] = []
    var discovered: [PHPManifest]?
    private enum CodingKeys: String, CodingKey { case lastAttemptAt, lastSuccessfulAt, checkedAt, error, discoveredVersions, discovered }
    init(lastAttemptAt: Date, lastSuccessfulAt: Date?, error: String?, discoveredVersions: [String] = [], discovered: [PHPManifest]? = nil) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.error = error
        self.discoveredVersions = discoveredVersions
        self.discovered = discovered
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let old = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt) ?? old ?? .distantPast
        lastSuccessfulAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulAt) ?? (try container.decodeIfPresent(String.self, forKey: .error) == nil ? old : nil)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        discoveredVersions = try container.decodeIfPresent([String].self, forKey: .discoveredVersions) ?? []
        discovered = try container.decodeIfPresent([PHPManifest].self, forKey: .discovered)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lastAttemptAt, forKey: .lastAttemptAt)
        try container.encodeIfPresent(lastSuccessfulAt, forKey: .lastSuccessfulAt)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(discoveredVersions, forKey: .discoveredVersions)
        try container.encodeIfPresent(discovered, forKey: .discovered)
    }
}
final class PHPCatalogRefreshGate: @unchecked Sendable {
    let lock = NSLock()
    var lastAttemptByStateFile: [String: Date] = [:]
    var inFlightStateFiles = Set<String>()
}

public enum PHPModuleError: Error, Equatable, Sendable {
    case manifestUnavailable
    case catalogUnavailable(String)
    case invalidManifest(String)
    case unsupportedVersion(String)
    case unsupportedArchitecture(String)
    case verificationFailed(String)
    case validationFailed(String)
    case packageMissing(String)
    case alreadyRunning(String)
    case processIdentityMismatch
    case processFailed(String)
    case invalidWorkingDirectory(String)
    case operationInProgress(String)
    case cannotRemoveActiveRuntime(String)
    case cannotRemoveDefaultRuntime(String)
    /// An explicitly named runtime to replace cannot serve as the update source.
    /// The reason is specific so the product never silently updates a different
    /// runtime than the one the user selected.
    case invalidUpdateSource(String)
}

public struct PHPPackage: Codable, Equatable, Sendable {
    public let version: String
    public let architecture: String
    public let packagePath: String
    public let cliPath: String
    public let fpmPath: String
    public let source: String
    public let cliSHA256: String
    public let fpmSHA256: String
    public let installedAt: Date
}

public enum PHPFPMState: String, Codable, Sendable { case stopped, running, degraded }

public struct PHPStatus: Codable, Equatable, Sendable {
    public let version: String
    public let package: PHPPackage?
    public let state: PHPFPMState
    public let pid: Int32?
    public let socket: String
    public let health: String
    public let isDefault: Bool
}

public struct PHPSelectionSnapshot: Sendable {
    public let packages: [PHPPackage]
    public let invalidVersions: [String]
    public let statuses: [PHPStatus]
    public let defaultVersion: String?
}

public struct PHPManagedSettings: Codable, Equatable, Sendable {
    public let uploadLimitMB: Int
    public let memoryLimitMB: Int
    public let maxExecutionTimeSeconds: Int
    public let maxInputVariables: Int
    public let postLimitMB: Int
    public init(uploadLimitMB: Int, memoryLimitMB: Int, maxExecutionTimeSeconds: Int, maxInputVariables: Int, postLimitMB: Int) {
        self.uploadLimitMB = uploadLimitMB; self.memoryLimitMB = memoryLimitMB; self.maxExecutionTimeSeconds = maxExecutionTimeSeconds; self.maxInputVariables = maxInputVariables; self.postLimitMB = postLimitMB
    }
}
public struct PHPManagedVersionConfiguration: Codable, Equatable, Sendable {
    public let version: String
    public let settings: PHPManagedSettings
    public let inheritsDefault: Bool
    public let cliIniPath: String
    public let fpmIniPath: String
    public let fpmConfigurationPath: String
    public let fpmRunning: Bool
    public init(version: String, settings: PHPManagedSettings, inheritsDefault: Bool, cliIniPath: String, fpmIniPath: String, fpmConfigurationPath: String, fpmRunning: Bool) {
        self.version = version; self.settings = settings; self.inheritsDefault = inheritsDefault; self.cliIniPath = cliIniPath; self.fpmIniPath = fpmIniPath; self.fpmConfigurationPath = fpmConfigurationPath; self.fpmRunning = fpmRunning
    }
}
public struct PHPConfigurationSnapshot: Codable, Equatable, Sendable {
    public let defaultSettings: PHPManagedSettings
    public let versions: [PHPManagedVersionConfiguration]
    public let directory: String
    public let affectedVersions: [String]
    public init(defaultSettings: PHPManagedSettings, versions: [PHPManagedVersionConfiguration], directory: String, affectedVersions: [String] = []) {
        self.defaultSettings = defaultSettings; self.versions = versions; self.directory = directory; self.affectedVersions = affectedVersions
    }
}

/// Core-authoritative, read-only PHP inventory. Installation, default
/// selection, and process state are deliberately represented independently.
public struct PHPUpdateObservation: Codable, Equatable, Sendable {
    public let installedVersion: String
    public let latestVersion: String?

    public init(installedVersion: String, latestVersion: String? = nil) {
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
    }

    public var updateAvailable: Bool? {
        guard let latestVersion,
              let installed = PHPVersion(installedVersion),
              let latest = PHPVersion(latestVersion) else { return nil }
        guard installed.isStable, latest.isStable, installed.family == latest.family else { return false }
        return latest > installed
    }
}

public struct PHPRuntimeVersion: Codable, Equatable, Sendable {
    public let version: String
    public let series: String?
    public let running: Bool?
    public let isDefault: Bool
    public let updateAvailable: Bool?
    public let latestVersion: String?
    public let usedByProjectCount: Int
    public let explicitProjectCount: Int
    public let inheritedProjectCount: Int

    public init(version: String, series: String? = nil, running: Bool? = nil, isDefault: Bool = false, updateAvailable: Bool? = nil, latestVersion: String? = nil, usedByProjectCount: Int = 0, explicitProjectCount: Int = 0, inheritedProjectCount: Int = 0) {
        self.version = version
        self.series = series ?? PHPVersion(version)?.family
        self.running = running
        self.isDefault = isDefault
        self.updateAvailable = updateAvailable
        self.latestVersion = latestVersion
        self.usedByProjectCount = usedByProjectCount
        self.explicitProjectCount = explicitProjectCount
        self.inheritedProjectCount = inheritedProjectCount
    }
}

/// The result of updating a runtime, including what converged and what did not.
///
/// Callers that own routing and service intents use this to report the real
/// outcome rather than assuming an update finished everything.
public struct PHPUpdateOutcome: Codable, Equatable, Sendable {
    public let version: String
    /// The runtime this replaced. It is removed once the replacement is
    /// verified; while the update is incomplete it stays installed for recovery.
    public let replacedVersion: String?
    public let wasDefault: Bool
    public let wasRunning: Bool
    public let isDefault: Bool
    public let isRunning: Bool
    /// True when the replacement could not take over the default role.
    public let previousDefaultRetained: Bool
    /// Which follow-up steps completed, e.g. "running", "default".
    public let convergence: [String]

    public init(version: String, replacedVersion: String?, wasDefault: Bool, wasRunning: Bool, isDefault: Bool, isRunning: Bool, previousDefaultRetained: Bool, convergence: [String]) {
        self.version = version
        self.replacedVersion = replacedVersion
        self.wasDefault = wasDefault
        self.wasRunning = wasRunning
        self.isDefault = isDefault
        self.isRunning = isRunning
        self.previousDefaultRetained = previousDefaultRetained
        self.convergence = convergence
    }
}

/// A PHP CLI/FPM pair shipped inside the signed application bundle.
///
/// The bundled pair is verified and installed through the same managed package
/// path as a downloaded package, so ownership, configuration, licensing and
/// removal behave identically. Presence of the bundle is not presence of an
/// installed runtime: nothing is started, no default changes, and no project is
/// touched until the user activates PHP.
public struct PHPBundledRuntime: Codable, Equatable, Sendable {
    public struct Binary: Codable, Equatable, Sendable {
        public let file: String
        public let sha256: String
    }
    public let phpVersion: String
    public let verification: PHPVerification
    public let binaries: [String: Binary]
    /// Resource subdirectory holding the provider's per-component notices.
    public let notices: String?
    public let manifest: PHPManifest

    /// Locate and verify the bundled runtime inside this process's resources.
    ///
    /// The binaries are checked against the digests recorded when the bundle was
    /// built, so a truncated or modified bundle fails closed instead of being
    /// installed.
    /// The version this application bundles, read without verifying or hashing the
    /// binaries. Cheap enough for an install fast-path check.
    public static var bundledVersion: String? {
        guard let url = Bundle.module.url(forResource: "bundled-runtime", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["phpVersion"] as? String
    }

    public static func bundled() throws -> PHPBundledRuntime {
        guard let descriptorURL = Bundle.module.url(forResource: "bundled-runtime", withExtension: "json") else {
            throw PHPModuleError.manifestUnavailable
        }
        let runtime = try JSONDecoder().decode(PHPBundledRuntime.self, from: Data(contentsOf: descriptorURL))
        guard runtime.verification.algorithm.lowercased() == "sha256" else {
            throw PHPModuleError.invalidManifest("The bundled PHP runtime must be verified with SHA-256.")
        }
        let root = descriptorURL.deletingLastPathComponent()
        for kind in ["cli", "fpm"] {
            guard let binary = runtime.binaries[kind] else {
                throw PHPModuleError.invalidManifest("The bundled PHP runtime is missing its \(kind.uppercased()) binary.")
            }
            let path = root.appendingPathComponent(binary.file)
            guard FileManager.default.isReadableFile(atPath: path.path) else {
                throw PHPModuleError.validationFailed("The bundled PHP \(kind.uppercased()) binary is missing from the application.")
            }
            let digest = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
            guard digest == binary.sha256.lowercased() else {
                throw PHPModuleError.verificationFailed("The bundled PHP \(kind.uppercased()) binary does not match its recorded digest.")
            }
        }
        return runtime
    }

    /// The bundled runtime's notices, when present.
    ///
    /// The resource bundle flattens the notices directory, so they are read from
    /// the bundle root rather than from a nested subdirectory.
    public func licenseNotices() -> [(name: String, text: String)] {
        guard let notices else { return [] }
        guard let root = Bundle.module.url(forResource: "bundled-runtime", withExtension: "json")?.deletingLastPathComponent() else { return [] }
        let directory = root.appendingPathComponent(notices, isDirectory: true)
        let contents = FileManager.default.fileExists(atPath: directory.path) ? directory : root
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: contents.path) else { return [] }
        return names.sorted().compactMap { name in
            guard name.hasSuffix("_LICENSE.txt") || name == "SUMMARY.json" else { return nil }
            guard let text = try? String(contentsOf: contents.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return (name, text)
        }
    }
}

public struct PHPRuntimeCatalog: Codable, Equatable, Sendable {

    public let availableVersions: [String]
    public let installedVersions: [PHPRuntimeVersion]
    public let defaultVersion: String?
    public let runningVersions: [String]
    public let availableVersionsKnown: Bool
    public let catalogCheckedAt: Date?
    public let catalogCheckError: String?
    /// Whether the offered versions were confirmed current, are cached from an
    /// earlier successful check, or have never been confirmed.
    public let catalogAvailability: PHPCatalogAvailability?
    /// Versions the provider advertises that Vaelen has not yet recorded a
    /// verified package for, so they are not installable.
    public let advertisedUnverifiedVersions: [String]
    public var updateReports: [PHPUpdateReport]?

    public init(availableVersions: [String], installedVersions: [PHPRuntimeVersion], defaultVersion: String?, runningVersions: [String], availableVersionsKnown: Bool = true, catalogCheckedAt: Date? = nil, catalogCheckError: String? = nil, catalogAvailability: PHPCatalogAvailability? = nil, advertisedUnverifiedVersions: [String] = [], updateReports: [PHPUpdateReport]? = nil) {
        self.availableVersions = Self.sortedUnique(availableVersions).sorted { Self.versionSort($1, $0) }
        self.installedVersions = installedVersions.reduce(into: [String: PHPRuntimeVersion]()) { result, value in
            guard result[value.version] == nil else { return }
            result[value.version] = value
        }.values.sorted { Self.versionSort($1.version, $0.version) }
        self.defaultVersion = defaultVersion
        self.runningVersions = Self.sortedUnique(runningVersions)
        self.availableVersionsKnown = availableVersionsKnown
        self.catalogCheckedAt = catalogCheckedAt
        self.catalogCheckError = catalogCheckError
        self.catalogAvailability = catalogAvailability
        self.updateReports = updateReports
        self.advertisedUnverifiedVersions = advertisedUnverifiedVersions.sorted { Self.versionSort($1, $0) }
    }

    public func withProjectUsage(_ usage: [PHPProjectUsage]) -> PHPRuntimeCatalog {
        let byVersion = Dictionary(uniqueKeysWithValues: usage.map { ($0.version, $0) })
        let updated = installedVersions.map { runtime in
            let value = byVersion[runtime.version]
            return PHPRuntimeVersion(version: runtime.version, series: runtime.series, running: runtime.running, isDefault: runtime.isDefault, updateAvailable: runtime.updateAvailable, latestVersion: runtime.latestVersion, usedByProjectCount: value?.total ?? 0, explicitProjectCount: value?.explicit ?? 0, inheritedProjectCount: value?.inherited ?? 0)
        }
        return PHPRuntimeCatalog(availableVersions: availableVersions, installedVersions: updated, defaultVersion: defaultVersion, runningVersions: runningVersions, availableVersionsKnown: availableVersionsKnown, catalogCheckedAt: catalogCheckedAt, catalogCheckError: catalogCheckError, catalogAvailability: catalogAvailability, advertisedUnverifiedVersions: advertisedUnverifiedVersions, updateReports: updateReports)
    }

    public init(availableVersions: [String], packages: [PHPPackage], statuses: [PHPStatus], defaultVersion: String?, updates: [PHPUpdateObservation] = []) {
        let statusByVersion = Dictionary(uniqueKeysWithValues: statuses.map { ($0.version, $0) })
        let updateByVersion = Dictionary(uniqueKeysWithValues: updates.map { ($0.installedVersion, $0) })
        let versions = packages.map { package in
            let status = statusByVersion[package.version]
            let update = updateByVersion[package.version]
            return PHPRuntimeVersion(version: package.version,
                                     running: status.map { $0.state == .running },
                                     isDefault: defaultVersion == package.version,
                                     updateAvailable: update?.updateAvailable,
                                     latestVersion: update?.latestVersion)
        }
        self.availableVersions = Self.sortedUnique(availableVersions).sorted { Self.versionSort($1, $0) }
        self.installedVersions = versions.reduce(into: [String: PHPRuntimeVersion]()) { result, value in
            guard result[value.version] == nil else { return }
            result[value.version] = value
        }.values.sorted { Self.versionSort($1.version, $0.version) }
        self.defaultVersion = defaultVersion
        self.runningVersions = Self.sortedUnique(statuses.filter { $0.state == .running }.map(\.version))
        self.availableVersionsKnown = true
        self.catalogCheckedAt = nil
        self.catalogCheckError = nil
        self.catalogAvailability = .unconfirmed
        self.advertisedUnverifiedVersions = []
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted(by: versionSort)
    }

    private static func versionSort(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = PHPVersion(lhs), let right = PHPVersion(rhs) else { return lhs < rhs }
        return left < right
    }
}

public struct PHPProjectUsage: Codable, Equatable, Sendable {
    public let version: String
    public let explicit: Int
    public let inherited: Int
    public var total: Int { explicit + inherited }
    public init(version: String, explicit: Int = 0, inherited: Int = 0) { self.version = version; self.explicit = explicit; self.inherited = inherited }
}

public enum PHPOperationKind: String, Codable, Sendable { case install, update, remove, defaultSelection, configurationUpdate, start, stop }
public enum PHPOperationPhase: String, Codable, Sendable {
    case starting, downloading, verifying, installing, ready, removing, removed, failed
    /// The replacement runtime is being started as part of an update. There is
    /// no meaningful percentage for this stage; the interface shows activity.
    case startingRuntime
    /// The package is installed and the dispatcher is converging follow-up work
    /// (start intents, inherited routes). The operation stays owned — never
    /// reported ready — until that work finishes or is reported as partial.
    case converging
}
public struct PHPOperationState: Codable, Equatable, Sendable {
    public let kind: PHPOperationKind
    public let targetVersion: String
    public let phase: PHPOperationPhase
    public let message: String?
    public let bytesTransferred: Int64?
    public let totalBytes: Int64?
    public let artifactName: String?
    public let artifactIndex: Int?
    public let artifactCount: Int?
    public let usingVerifiedCachedDownloads: Bool?

    public init(kind: PHPOperationKind, targetVersion: String, phase: PHPOperationPhase, message: String? = nil, bytesTransferred: Int64? = nil, totalBytes: Int64? = nil, artifactName: String? = nil, artifactIndex: Int? = nil, artifactCount: Int? = nil, usingVerifiedCachedDownloads: Bool? = nil) {
        self.kind = kind; self.targetVersion = targetVersion; self.phase = phase; self.message = message
        self.bytesTransferred = bytesTransferred; self.totalBytes = totalBytes; self.artifactName = artifactName; self.artifactIndex = artifactIndex; self.artifactCount = artifactCount
        self.usingVerifiedCachedDownloads = usingVerifiedCachedDownloads
    }
}

private struct PHPProcessRecord: Codable, Sendable {
    let pid: Int32
    let version: String
    let executable: String
    let arguments: [String]
    let configPath: String
    let socketPath: String
    let startedAt: String?
    let socketDevice: Int64?
    let socketInode: Int64?
}

private struct PHPDevelopmentConfiguration: Codable, Sendable {
    let manifestPath: String
    let artifactBasePath: String
    let catalogURL: String?
}

private struct PHPConfigurationStoreRecord: Codable {
    var defaultSettings: PHPManagedSettings
    var versionOverrides: [String: PHPManagedSettings]
}

private final class PHPRemoteResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<(Data, HTTPURLResponse?), Error>?
    func set(_ value: Result<(Data, HTTPURLResponse?), Error>) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Result<(Data, HTTPURLResponse?), Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class PHPArtifactTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: PHPArtifactProgressSink
    private let finished = DispatchSemaphore(value: 0)
    private var handle: FileHandle?
    private var transferred: Int64 = 0
    private var totalBytes: Int64?
    private var failure: Error?

    init(destination: URL, progress: PHPArtifactProgressSink) { self.destination = destination; self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), PHPPackageProvider.artifactHosts.contains(host),
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else {
            failure = URLError(.unsupportedURL)
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = URLError(.badServerResponse); completionHandler(.cancel); return
        }
        let expected = response.expectedContentLength
        totalBytes = expected > 0 ? expected : nil
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            failure = PHPModuleError.manifestUnavailable; completionHandler(.cancel); return
        }
        do { handle = try FileHandle(forWritingTo: destination); progress.report(0, totalBytes); completionHandler(.allow) }
        catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard let handle else { throw PHPModuleError.manifestUnavailable }
            try handle.write(contentsOf: data)
            transferred += Int64(data.count)
            progress.report(transferred, totalBytes)
        } catch { failure = error; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil { failure = error }
        try? handle?.close(); handle = nil
        if failure != nil { try? FileManager.default.removeItem(at: destination) }
        finished.signal()
    }

    func wait() throws {
        finished.wait()
        if let failure { throw failure }
    }
}

final class PHPArtifactProgressSink: @unchecked Sendable {
    private let callback: @Sendable (Int64, Int64?) -> Void
    init(_ callback: @escaping @Sendable (Int64, Int64?) -> Void) { self.callback = callback }
    func report(_ bytes: Int64, _ total: Int64?) { callback(bytes, total) }
}

/// Aggregates per-archive download progress into one monotonic measurement.
///
/// Both archives contribute to the same running totals, so the reported byte
/// count and percentage never reset when the second archive begins. An aggregate
/// percentage is only produced once every archive's exact size is known; the
/// provider's directory listing reports rounded sizes, so exact totals come from
/// the download response's `Content-Length` instead.
final class PHPArtifactProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let artifactCount: Int
    private let report: @Sendable (Int64, Int64?, String, Int, Int) -> Void
    private var transferred = [Int64]()
    private var totals: [Int64?]
    private var highestReported: Int64 = 0
    private var highestTotal: Int64?

    init(artifactCount: Int, report: @escaping @Sendable (Int64, Int64?, String, Int, Int) -> Void) {
        self.artifactCount = artifactCount
        self.report = report
        self.totals = Array(repeating: nil, count: artifactCount)
        self.transferred = Array(repeating: 0, count: artifactCount)
    }

    /// Report that an archive is beginning, without disturbing the aggregate.
    ///
    /// Used instead of publishing a bare zero, which would make the visible
    /// transferred bytes and percentage jump backwards when the second archive
    /// starts.
    func announce(name: String, index: Int) {
        lock.lock()
        let sumTransferred = max(highestReported, transferred.reduce(0, +))
        highestReported = sumTransferred
        let sumTotal = totals.allSatisfy { $0 != nil } ? totals.compactMap { $0 }.reduce(0, +) : nil
        lock.unlock()
        report(sumTransferred, sumTotal, name, index, artifactCount)
    }

    /// Record an archive's exact size before transferring, so a determinate
    /// percentage is available from the first byte of the first archive.
    ///
    /// Declaring sizes publishes the first measurement immediately, so a caller
    /// that knows both totals before transferring sees a determinate bar at 0%.
    func declareSize(index: Int, bytes: Int64) {
        lock.lock()
        let slot = index - 1
        guard totals.indices.contains(slot), bytes > 0 else { lock.unlock(); return }
        totals[slot] = bytes
        let allTotalsKnown = totals.allSatisfy { $0 != nil }
        let sumTotal = allTotalsKnown ? totals.compactMap { $0 }.reduce(0, +) : nil
        let sumTransferred = max(highestReported, transferred.reduce(0, +))
        highestTotal = sumTotal.map { max(highestTotal ?? 0, $0) }
        lock.unlock()
        report(sumTransferred, sumTotal.map { max($0, highestTotal ?? $0) } ?? highestTotal, "PHP package", index, artifactCount)
    }

    func update(name: String, index: Int, bytes: Int64, total: Int64?) {
        lock.lock()
        let slot = index - 1
        guard transferred.indices.contains(slot) else { lock.unlock(); return }
        // An archive that has finished contributes its full size. A report for a
        // later archive must never erase an earlier archive's contribution.
        transferred[slot] = max(transferred[slot], max(0, bytes))
        if let total, total > 0 { totals[slot] = max(totals[slot] ?? 0, total) }
        let sumTransferred = transferred.reduce(0, +)
        let allTotalsKnown = totals.allSatisfy { $0 != nil }
        let sumTotal = allTotalsKnown ? totals.compactMap { $0 }.reduce(0, +) : nil
        // Never let a later report move the visible transfer backwards.
        let monotonicTransferred = max(highestReported, sumTransferred)
        highestReported = monotonicTransferred
        if let sumTotal { highestTotal = max(highestTotal ?? 0, sumTotal) }
        let reportedTotal = sumTotal.map { max($0, highestTotal ?? $0) }
        lock.unlock()
        report(monotonicTransferred, reportedTotal, name, index, artifactCount)
    }
}

public final class PHPModule: @unchecked Sendable {
    private static let switchLogger = Logger(subsystem: "dev.vaelen.core", category: "php-default-switch")
    private let layout: VaelenFilesystemLayout
    private let location: any PHPManifestLocation
    private let includesBundledCatalog: Bool
    private let officialReleaseStore: PHPReleaseAdvisoryStore?
    private let artifactTransfer: @Sendable (URL, URL, PHPArtifactProgressSink) throws -> Void
    private let manager = FileManager.default
    private let lock = NSLock()
    private let ownedProcessesLock = NSLock()
    private let validationLock = NSLock()
    private struct ExecutableIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let modified: timespec
        let changed: timespec
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size && lhs.mode == rhs.mode &&
            lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
            lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }
    private struct ValidatedPackage {
        let metadata: Data
        let cli: ExecutableIdentity
        let fpm: ExecutableIdentity
    }
    private var validatedPackages: [String: ValidatedPackage] = [:]
    private var switchTimings: [String: Double] = [:]
    public func defaultSwitchTimings() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }; return switchTimings
    }
    private var activeOperation: PHPOperationState?
    private var lastOperation: PHPOperationState?
    private var ownedFPMProcesses: [String: OwnedChildProcess] = [:]
    private let defaultPHPSettings = PHPManagedSettings(uploadLimitMB: 2, memoryLimitMB: 128, maxExecutionTimeSeconds: 30, maxInputVariables: 1_000, postLimitMB: 8)

    public init(layout: VaelenFilesystemLayout, location: any PHPManifestLocation, includesBundledCatalog: Bool = false) {
        self.layout = layout; self.location = location; self.includesBundledCatalog = includesBundledCatalog
        self.officialReleaseStore = nil
        self.artifactTransfer = { source, destination, progress in try Self.transferArtifact(source: source, destination: destination, progress: progress) }
    }

    init(layout: VaelenFilesystemLayout, location: any PHPManifestLocation, includesBundledCatalog: Bool = false, officialReleaseStore: PHPReleaseAdvisoryStore? = nil, artifactTransfer: (@Sendable (URL, URL, PHPArtifactProgressSink) throws -> Void)? = nil) {
        self.layout = layout; self.location = location; self.includesBundledCatalog = includesBundledCatalog
        self.officialReleaseStore = officialReleaseStore
        self.artifactTransfer = artifactTransfer ?? { source, destination, progress in try Self.transferArtifact(source: source, destination: destination, progress: progress) }
    }

    /// PHP as the installed product provides it: the catalog shipped inside the
    /// signed application, with no distribution configuration required.
    public static func bundled(layout: VaelenFilesystemLayout = .init()) -> PHPModule? {
        guard let catalog = try? BundledPHPManifestLocation.bundledCatalog() else { return nil }
        let location = BundledPHPManifestLocation(catalog: catalog, stateDirectory: layout.stateDirectoryURL)
        return PHPModule(layout: layout, location: location, includesBundledCatalog: false)
    }

    public static func development(layout: VaelenFilesystemLayout = .init()) -> PHPModule? {
        let environment = ProcessInfo.processInfo.environment
        let configurationURL = layout.configurationDirectoryURL.appendingPathComponent("php-distribution.json")
        let configuration = try? JSONDecoder().decode(PHPDevelopmentConfiguration.self, from: Data(contentsOf: configurationURL))
        guard let manifest = environment["VAELEN_PHP_MANIFEST"] ?? configuration?.manifestPath else { return nil }
        // A leftover configuration that points at a manifest which is no longer
        // present must not disable PHP. The shipped catalog takes over instead.
        guard FileManager.default.fileExists(atPath: manifest) else { return nil }
        let basePath = environment["VAELEN_PHP_ARTIFACT_BASE"] ?? configuration?.artifactBasePath
        let base = basePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let manifestMetadata = try? JSONDecoder().decode(PHPManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        // No hosted Vaelen catalog exists: the shipped catalog is the trust
        // anchor, and the provider is checked directly by the bundled location.
        let catalog = environment["VAELEN_PHP_CATALOG_URL"] ?? configuration?.catalogURL ?? manifestMetadata?.catalogURL
        return PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: URL(fileURLWithPath: manifest), baseURL: base, catalogURL: catalog.flatMap(URL.init(string:))), includesBundledCatalog: true)
    }

    public func availableVersions() throws -> [String] {
        try allManifests().filter(isInstallableManifest).map(\.phpVersion).sorted { (PHPVersion($0) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1) ?? .init(major: 0, minor: 0, patch: 0)) }
    }

    public func runtimeCatalog(updates: [PHPUpdateObservation] = []) throws -> PHPRuntimeCatalog {
        let packages = eligibleInstalledVersions()
        let statuses = packages.compactMap { try? status(requestedVersion: $0.version) }
        let availableResult = Result { try availableVersions() }
        let available = (try? availableResult.get()) ?? []
        let effectiveUpdates = updates.isEmpty ? packages.compactMap { package -> PHPUpdateObservation? in
            guard let installed = PHPVersion(package.version), let latest = available.compactMap(PHPVersion.init).filter({ $0.family == installed.family }).max(), latest > installed else { return nil }
            return PHPUpdateObservation(installedVersion: package.version, latestVersion: latest.description)
        } : updates
        let catalog = PHPRuntimeCatalog(availableVersions: available, packages: packages, statuses: statuses, defaultVersion: defaultVersion(), updates: effectiveUpdates)
        let check = location.catalogCheckStatus()
        let bundled = location as? BundledPHPManifestLocation
        let availability = bundled?.catalogAvailability() ?? .unconfirmed
        let advertised = bundled?.advertisedUnverifiedVersions() ?? []
        if case .failure = availableResult {
            return PHPRuntimeCatalog(availableVersions: catalog.availableVersions, installedVersions: catalog.installedVersions, defaultVersion: catalog.defaultVersion, runningVersions: catalog.runningVersions, availableVersionsKnown: false, catalogCheckedAt: check.0, catalogCheckError: check.1, catalogAvailability: availability, advertisedUnverifiedVersions: advertised, updateReports: PHPUpdateReport.project(installed: catalog.installedVersions, available: catalog.availableVersions, sources: officialReleases.snapshot(families: installedFamilies())))
        }
        return PHPRuntimeCatalog(availableVersions: catalog.availableVersions, installedVersions: catalog.installedVersions, defaultVersion: catalog.defaultVersion, runningVersions: catalog.runningVersions, availableVersionsKnown: true, catalogCheckedAt: check.0, catalogCheckError: check.1, catalogAvailability: availability, advertisedUnverifiedVersions: advertised, updateReports: PHPUpdateReport.project(installed: catalog.installedVersions, available: catalog.availableVersions, sources: officialReleases.snapshot(families: installedFamilies())))
    }

    private var officialReleases: PHPReleaseAdvisoryStore { officialReleaseStore ?? PHPReleaseAdvisoryStore(directory: layout.stateDirectoryURL) }
    private func installedFamilies() -> [String] { Array(Set(eligibleInstalledVersions().compactMap { PHPVersion($0.version)?.family })) }
    public func refreshCatalogIfNeeded() throws {
        try location.refreshCatalogIfNeeded()
    }
    public func checkCatalogNow() throws {
        try location.checkCatalogNow()
    }

    public func refreshOfficialReleaseAdvisories(force: Bool) {
        officialReleases.refresh(families: installedFamilies(), force: force)
    }

    public func operationState() -> PHPOperationState? {
        lock.lock(); defer { lock.unlock() }; return activeOperation ?? lastOperation
    }

    /// Vaelen's managed package directory for a version. Used by tests that need
    /// to place a real package without going through a download.
    public func packageDirectoryURL(forTesting version: String) -> URL {
        layout.phpPackagesDirectoryURL.appendingPathComponent(version, isDirectory: true)
    }

    public func installedVersions() -> [PHPPackage] {
        packageObservations().compactMap(\.package).sorted { lhs, rhs in
            guard let left = PHPVersion(lhs.version), let right = PHPVersion(rhs.version) else { return lhs.version < rhs.version }
            return left < right
        }
    }

    public func packageObservations() -> [PHPInstalledPackageObservation] {
        guard let entries = try? manager.contentsOfDirectory(at: layout.phpPackagesDirectoryURL, includingPropertiesForKeys: nil) else { return [] }
        let observations = entries.map { observePackage(at: $0) }
        let eligibleVersions = observations.compactMap { observation -> String? in
            guard observation.eligibility == .eligible, let package = observation.package else { return nil }
            return package.version
        }
        let duplicateVersions = Set(eligibleVersions.filter { version in eligibleVersions.filter { $0 == version }.count > 1 })
        return observations.map { observation in
            guard let version = observation.package?.version, duplicateVersions.contains(version), observation.eligibility == .eligible else { return observation }
            return .init(package: observation.package, version: version, eligibility: .ambiguous, reason: "Duplicate eligible package identity for PHP \(version).")
        }
    }

    public func eligibleInstalledVersions() -> [PHPPackage] {
        packageObservations().filter { $0.eligibility == .eligible }.compactMap(\.package).sorted { lhs, rhs in
            PHPVersion(lhs.version)! < PHPVersion(rhs.version)!
        }
    }

    public func resolveEligible(_ requested: String) throws -> PHPPackage {
        let packages = eligibleInstalledVersions()
        if let version = PHPVersionResolver.resolve(requested, versionStrings: packages.map(\.version)), let value = packages.first(where: { $0.version == version }) { return value }
        throw PHPModuleError.packageMissing(requested)
    }

    public func install(requestedVersion: String) throws -> PHPPackage {
        try executeOperation(kind: .install, targetVersion: requestedVersion) { try self.installUnlocked(requestedVersion: requestedVersion) }
    }

    public func update(requestedVersion: String, sourceVersion: String? = nil, holdOpenOnSuccess: Bool = false) throws -> PHPUpdateOutcome {
        try executeOperation(kind: .update, targetVersion: requestedVersion, holdOpenOnSuccess: holdOpenOnSuccess) {
            let target = try self.manifest(for: requestedVersion).phpVersion
            guard PHPVersion(target)?.isStable == true else { throw PHPModuleError.unsupportedVersion(target) }
            let previousDefault = self.defaultVersion()
            let installedBefore = eligibleInstalledVersions()
            // Identify the runtime being replaced before installing, so settings
            // come from the runtime the user actually updated rather than from
            // whichever patch of that line happens to be highest.
            // An explicitly named runtime is the user's selection, so it is
            // validated rather than silently substituted. A stale, missing, or
            // wrong-family source must fail with a specific reason instead of
            // quietly updating a different runtime.
            let source = try sourceVersion.map { try validatedUpdateSource($0, target: target, installed: installedBefore) }
                ?? defaultUpdateSource(target: target, installed: installedBefore)
            let sourceWasDefault = source.map { $0.version == previousDefault } ?? false
            let sourceWasRunning = source.flatMap { (try? status(requestedVersion: $0.version).state) == .running } ?? false

            let package = try self.installUnlocked(requestedVersion: target)

            if let source, var settings = try? self.loadPHPConfiguration(),
               settings.versionOverrides[target] == nil,
               let existingOverride = settings.versionOverrides[source.version] {
                settings.versionOverrides[target] = existingOverride
                try self.savePHPConfiguration(settings)
            }
            // Write the replacement's INI files now so its settings are effective
            // and editable without reopening Settings.
            _ = try self.writePHPIniFiles(version: target, settings: try self.effectivePHPSettings(version: target))

            var convergence: [String] = []
            // Updating the running default replaces it: the replacement must end
            // up healthy and become the default.
            if sourceWasDefault {
                _ = try self.setDefaultUnlocked(requestedVersion: target)
                // Starting has no measurable percentage; observers see activity,
                // not a frozen bar.
                self.setOperationPhase(.startingRuntime)
                let status = try self.start(requestedVersion: target)
                guard status.state == .running, status.health == "healthy" else {
                    throw PHPModuleError.processFailed("PHP \(target) installed but its runtime did not become healthy.")
                }
                convergence.append("running")
                convergence.append("default")
            }
            _ = package
            return PHPUpdateOutcome(
                version: target,
                replacedVersion: source?.version,
                wasDefault: sourceWasDefault,
                wasRunning: sourceWasRunning,
                isDefault: defaultVersion() == target,
                isRunning: (try? status(requestedVersion: target).state) == .running,
                previousDefaultRetained: sourceWasDefault && defaultVersion() != target,
                convergence: convergence
            )
        }
    }

    /// Resolve which installed runtime an update would replace, without changing
    /// anything.
    ///
    /// The update orchestrator calls this before any mutation so exact-version
    /// project pins and serving routes can be checked against the real source.
    /// Resolution is identical to `update()`'s: an explicit source is validated,
    /// otherwise the default of the target's line (or its highest installed
    /// patch) is used.
    public func updateSourceCandidate(target requestedVersion: String, sourceVersion: String?) throws -> PHPPackage? {
        let target = try self.manifest(for: requestedVersion).phpVersion
        guard PHPVersion(target)?.isStable == true else { throw PHPModuleError.unsupportedVersion(target) }
        let installed = eligibleInstalledVersions()
        return try sourceVersion.map { try validatedUpdateSource($0, target: target, installed: installed) }
            ?? defaultUpdateSource(target: target, installed: installed)
    }

    /// Remove a superseded runtime as update cleanup, inside the update's
    /// already held-open operation.
    ///
    /// Never called directly: the dispatcher owns the dependency checks (exact
    /// pins, serving routes), the default handover verification, and the
    /// operation reservation. Stops through ownership-checked lifecycle control
    /// first, then removes the managed package and its obsolete generated
    /// runtime artifacts. Saved settings (shared defaults and the version
    /// override) are deliberately kept so a reinstall restores them.
    public func removeReplacedRuntime(version: String) throws {
        guard let requested = PHPVersion(version), requested.isStable else { throw PHPModuleError.unsupportedVersion(version) }
        guard let package = self.eligibleInstalledVersions().first(where: { $0.version == requested.description }) else { return }
        // The default role is never removed as a side effect: `update()` hands it
        // to the replacement first and throws when that handover fails.
        guard defaultVersion() != package.version else { throw PHPModuleError.cannotRemoveDefaultRuntime(package.version) }
        let stopped = try self.stop(requestedVersion: package.version)
        guard stopped.state == .stopped else { throw PHPModuleError.cannotRemoveActiveRuntime(package.version) }
        let packageRoot = URL(fileURLWithPath: package.packagePath).standardizedFileURL
        let managedRoot = self.layout.phpPackagesDirectoryURL.standardizedFileURL
        guard packageRoot.path.hasPrefix(managedRoot.path + "/") else { throw PHPModuleError.validationFailed("PHP package is outside Vaelen's managed package directory") }
        // Remove generated runtime artifacts before the package itself, so a
        // failure leaves the package intact and retryable.
        let instance = layout.phpInstancesDirectoryURL.appendingPathComponent(package.version, isDirectory: true)
        if manager.fileExists(atPath: instance.path) { try manager.removeItem(at: instance) }
        setOperationPhase(.removing)
        try self.manager.removeItem(at: packageRoot)
    }

    /// Validate a runtime the user explicitly selected as the update source.
    ///
    /// Checked before any installation, so an unusable selection can never cause
    /// a different runtime to be replaced.
    private func validatedUpdateSource(_ requested: String, target: String, installed: [PHPPackage]) throws -> PHPPackage {
        guard let source = try? resolveInstalled(requested) else {
            throw PHPModuleError.invalidUpdateSource("PHP \(requested) is not installed, so it cannot be updated. Refresh and select the runtime you want to replace.")
        }
        let sourceVersion = PHPVersion(source.version)
        let targetVersion = PHPVersion(target)
        guard sourceVersion != targetVersion else {
            throw PHPModuleError.invalidUpdateSource("PHP \(requested) is already the requested version \(target); there is nothing to update.")
        }
        guard let sourceVersion, let targetVersion, sourceVersion.family == targetVersion.family else {
            throw PHPModuleError.invalidUpdateSource("PHP \(requested) is not an earlier patch of the \(targetVersion?.family ?? target) line, so it cannot be updated to \(target).")
        }
        guard sourceVersion < targetVersion else {
            throw PHPModuleError.invalidUpdateSource("PHP \(requested) is not older than \(target). An update installs a newer patch of the same line.")
        }
        guard installed.contains(where: { $0.version == source.version }) else {
            throw PHPModuleError.invalidUpdateSource("PHP \(source.version) is no longer installed. Refresh and select the runtime you want to replace.")
        }
        return source
    }

    /// The runtime an unqualified update replaces: the default when it belongs to
    /// the target's line, otherwise the highest installed patch of that line.
    private func defaultUpdateSource(target: String, installed: [PHPPackage]) -> PHPPackage? {
        guard let family = PHPVersion(target)?.family else { return nil }
        let candidates = installed.filter { PHPVersion($0.version)?.family == family && $0.version != target }
        if let preferred = defaultVersion(), PHPVersion(preferred)?.family == family, preferred != target,
           let match = candidates.first(where: { $0.version == preferred }) { return match }
        return candidates.max { (PHPVersion($0.version) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1.version) ?? .init(major: 0, minor: 0, patch: 0)) }
    }


public func selectDefault(requestedVersion: String) throws -> PHPRuntimeCatalog {
        try executeOperation(kind: .defaultSelection, targetVersion: requestedVersion) {
            let started = ContinuousClock.now
            let package = try self.resolveExactEligible(requestedVersion)
            let validated = ContinuousClock.now
            var status = try self.status(requestedVersion: package.version)
            if status.state != .running || status.health != "healthy" {
                status = try self.start(requestedVersion: package.version)
            }
            let startedRuntime = ContinuousClock.now
            guard status.state == .running, status.health == "healthy" else {
                throw PHPModuleError.processFailed("PHP-FPM did not become healthy for PHP \(package.version)")
            }
            _ = try self.setDefaultUnlocked(requestedVersion: package.version)
            let persisted = ContinuousClock.now
            let catalog = try self.runtimeCatalog()
            let finished = ContinuousClock.now
            self.lock.lock()
            self.switchTimings = ["validation_ms": Self.milliseconds(started.duration(to: validated)), "fpm_ms": Self.milliseconds(validated.duration(to: startedRuntime)), "persistence_ms": Self.milliseconds(startedRuntime.duration(to: persisted)), "catalog_ms": Self.milliseconds(persisted.duration(to: finished))]
            self.lock.unlock()
            Self.switchLogger.info("PHP default timing version=\(package.version, privacy: .public) validation_ms=\(Self.milliseconds(started.duration(to: validated)), privacy: .public) fpm_ms=\(Self.milliseconds(validated.duration(to: startedRuntime)), privacy: .public) persistence_ms=\(Self.milliseconds(startedRuntime.duration(to: persisted)), privacy: .public) catalog_ms=\(Self.milliseconds(persisted.duration(to: finished)), privacy: .public) total_ms=\(Self.milliseconds(started.duration(to: finished)), privacy: .public)")
            return catalog
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    public func remove(requestedVersion: String) throws {
        try executeOperation(kind: .remove, targetVersion: requestedVersion) {
            self.setOperationPhase(.removing)
            guard let requested = PHPVersion(requestedVersion), requested.isStable else { throw PHPModuleError.unsupportedVersion(requestedVersion) }
            guard let package = self.eligibleInstalledVersions().first(where: { $0.version == requested.description }) else { return }
            let status = try self.status(requestedVersion: package.version)
            if status.state != .stopped { throw PHPModuleError.cannotRemoveActiveRuntime(package.version) }
            if self.defaultVersion() == package.version { throw PHPModuleError.cannotRemoveDefaultRuntime(package.version) }
            let packageRoot = URL(fileURLWithPath: package.packagePath).standardizedFileURL
            let managedRoot = self.layout.phpPackagesDirectoryURL.standardizedFileURL
            guard packageRoot.path.hasPrefix(managedRoot.path + "/") else { throw PHPModuleError.validationFailed("PHP package is outside Vaelen's managed package directory") }
            try self.manager.removeItem(at: packageRoot)
        }
    }

    private func installUnlocked(requestedVersion: String) throws -> PHPPackage {
        let manifest = try manifest(for: requestedVersion)
        guard manifest.module == "php", manifest.schemaVersion == 1, manifest.platform == "macos" else { throw PHPModuleError.invalidManifest("unsupported manifest") }
        guard manifest.architecture == "arm64" else { throw PHPModuleError.unsupportedArchitecture(manifest.architecture) }
        guard manifest.verification.algorithm.lowercased() == "sha256" else { throw PHPModuleError.invalidManifest("SHA-256 verification is required") }
        guard requestedVersion == manifest.phpVersion || requestedVersion == manifest.phpVersion.split(separator: ".").prefix(2).joined(separator: ".") else { throw PHPModuleError.unsupportedVersion(requestedVersion) }
        guard let cli = manifest.artifacts["cli"], let fpm = manifest.artifacts["fpm"] else { throw PHPModuleError.invalidManifest("CLI and FPM artifacts are required") }
        let version = manifest.phpVersion
        let final = layout.phpPackagesDirectoryURL.appendingPathComponent(version, isDirectory: true)
        if manager.fileExists(atPath: final.path) {
            let observation = observePackage(at: final)
            guard observation.eligibility == .eligible, let existing = observation.package else {
                throw PHPModuleError.validationFailed("Existing PHP \(version) package is invalid; installation did not replace it.")
            }
            return existing
        }
        let tracker = PHPArtifactProgressTracker(artifactCount: 2) { [weak self] bytes, total, name, index, count in
            self?.setOperationDownloadProgress(bytes: bytes, total: total, artifactName: name, artifactIndex: index, artifactCount: count)
        }
        // When both archives' exact sizes are known, a determinate aggregate bar
        // is available from the first byte of the first archive.
        for (kind, size) in manifest.verifiedArtifactSizes ?? [:] {
            tracker.declareSize(index: kind == "cli" ? 1 : 2, bytes: size)
        }
        let operation = UUID().uuidString
        let staging = layout.stagingDirectoryURL.appendingPathComponent("php-\(version)-\(operation)", isDirectory: true)
        try makeDirectories([layout.downloadsDirectoryURL, layout.stagingDirectoryURL, layout.phpPackagesDirectoryURL, staging])
        defer { try? manager.removeItem(at: staging) }
        setOperationUsingVerifiedCache(
            manager.fileExists(atPath: layout.downloadsDirectoryURL.appendingPathComponent(cli.file).path) && sha256(layout.downloadsDirectoryURL.appendingPathComponent(cli.file)) == cli.sha256.lowercased() &&
            manager.fileExists(atPath: layout.downloadsDirectoryURL.appendingPathComponent(fpm.file).path) && sha256(layout.downloadsDirectoryURL.appendingPathComponent(fpm.file)) == fpm.sha256.lowercased(),
            artifactName: "CLI and FPM", index: 1)
        // A bundled runtime in the signed application is installed from disk with no
        // network request. Only that exact version is considered, so a download
        // is never delayed by inspecting the bundle.
        if PHPBundledRuntime.bundledVersion == version, try bundledRuntimeArtifactsMatch(manifest),
           let bundled = try? PHPBundledRuntime.bundled() {
            return try installFromBundledRuntime(bundled, manifest: manifest, staging: staging, final: final, progress: tracker)
        }

        // Always hand `acquire` the manifest's recorded digest when one exists.
        // For a review-pinned version that is the pinned digest. For a version a
        // provider check discovered, it is the digest recorded from the bytes a
        // previous install received — so later transfers and reinstalls verify
        // against that local integrity record instead of skipping verification.
        let cliArtifact = try acquire(cli, expectedSHA256: cli.sha256, name: "CLI", index: 1, base: location.artifactBaseURL(), progress: tracker)
        let fpmArtifact = try acquire(fpm, expectedSHA256: fpm.sha256, name: "FPM", index: 2, base: location.artifactBaseURL(), progress: tracker)
        setOperationPhase(.verifying)
        setOperationPhase(.installing)
        try extract(cliArtifact.url, to: staging); try extract(fpmArtifact.url, to: staging)
        let cliPath = staging.appendingPathComponent("php").path
        let fpmPath = staging.appendingPathComponent("php-fpm").path
        try validateExecutable(cliPath, expected: version, name: "php", build: manifest.build)
        try validateExecutable(fpmPath, expected: version, name: "php-fpm", build: manifest.build)
        try makeDirectories([final.deletingLastPathComponent()])
        if manager.fileExists(atPath: final.path) { throw PHPModuleError.validationFailed("package directory already exists") }
        try manager.moveItem(at: staging, to: final)
        // Retain the provider's license and notices with the installed package.
        try? retainLicenseNotices(manifest: manifest)
        // A discovered version's digests are recorded now, so every later reuse
        // of these bytes is verified against this record.
        if !manifest.verification.isPinnedByReview {
            recordDiscoveredDigests(version: version, cli: cliArtifact.sha256, fpm: fpmArtifact.sha256, sizes: ["cli": cliArtifact.bytes, "fpm": fpmArtifact.bytes])
        }
        let package = PHPPackage(version: version, architecture: manifest.architecture, packagePath: final.path, cliPath: final.appendingPathComponent("php").path, fpmPath: final.appendingPathComponent("php-fpm").path, source: cli.url, cliSHA256: cliArtifact.sha256, fpmSHA256: fpmArtifact.sha256, installedAt: Date())
        try atomicWrite(package, to: final.appendingPathComponent(".vaelen-package.json"))
        return package
    }

    /// Whether the requested manifest is exactly the bundled runtime's own manifest,
    /// by digest. Checked before any download so a real package request is never
    /// short-circuited by the bundle.
    private func bundledRuntimeArtifactsMatch(_ manifest: PHPManifest) throws -> Bool {
        guard let descriptorURL = Bundle.module.url(forResource: "bundled-runtime", withExtension: "json"),
              let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: descriptorURL)) as? [String: Any],
              let embedded = object["manifest"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: embedded),
              let bundledManifest = try? JSONDecoder().decode(PHPManifest.self, from: data)
        else { return false }
        return bundledManifest.phpVersion == manifest.phpVersion
            && bundledManifest.artifacts["cli"]?.sha256 == manifest.artifacts["cli"]?.sha256
            && bundledManifest.artifacts["fpm"]?.sha256 == manifest.artifacts["fpm"]?.sha256
    }

    /// Install the runtime bundled in the signed application.
    ///
    /// This is the same managed package path a download uses: the binaries are
    /// verified, validated, moved into Vaelen's own package directory, and
    /// recorded with the provider's notices. It does not start PHP-FPM, change
    /// the default, or modify any project.
    private func installFromBundledRuntime(_ bundled: PHPBundledRuntime, manifest: PHPManifest, staging: URL, final: URL, progress: PHPArtifactProgressTracker) throws -> PHPPackage {
        guard let cliBinary = bundled.binaries["cli"], let fpmBinary = bundled.binaries["fpm"] else {
            throw PHPModuleError.invalidManifest("The bundled PHP runtime is incomplete.")
        }
        let descriptor = Bundle.module.url(forResource: "bundled-runtime", withExtension: "json")?.deletingLastPathComponent()
        guard let descriptor else { throw PHPModuleError.manifestUnavailable }
        // Report the bundled copy as progress so the UI shows a real measurement
        // rather than jumping from nothing to done.
        progress.announce(name: "bundled CLI and FPM", index: 1)
        let cliSource = descriptor.appendingPathComponent(cliBinary.file)
        let fpmSource = descriptor.appendingPathComponent(fpmBinary.file)
        let cliSize = ((try? manager.attributesOfItem(atPath: cliSource.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let fpmSize = ((try? manager.attributesOfItem(atPath: fpmSource.path)[.size]) as? NSNumber)?.int64Value ?? 0
        for (kind, size) in [("cli", cliSize), ("fpm", fpmSize)] where size > 0 {
            progress.declareSize(index: kind == "cli" ? 1 : 2, bytes: size)
        }
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try manager.copyItem(at: cliSource, to: staging.appendingPathComponent("php"))
        try manager.copyItem(at: fpmSource, to: staging.appendingPathComponent("php-fpm"))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.appendingPathComponent("php").path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.appendingPathComponent("php-fpm").path)
        progress.update(name: "bundled CLI", index: 1, bytes: cliSize, total: cliSize)
        progress.update(name: "bundled FPM", index: 2, bytes: fpmSize, total: fpmSize)
        setOperationPhase(.verifying)
        setOperationPhase(.installing)
        let cliPath = staging.appendingPathComponent("php").path
        let fpmPath = staging.appendingPathComponent("php-fpm").path
        // The bundled bytes were already digest-verified against the signed
        // bundle's record; validate them exactly as a downloaded package.
        try validateExecutable(cliPath, expected: manifest.phpVersion, name: "php", build: manifest.build)
        try validateExecutable(fpmPath, expected: manifest.phpVersion, name: "php-fpm", build: manifest.build)
        try makeDirectories([final.deletingLastPathComponent()])
        if manager.fileExists(atPath: final.path) { throw PHPModuleError.validationFailed("package directory already exists") }
        try manager.moveItem(at: staging, to: final)
        let noticesDirectory = final.appendingPathComponent("license", isDirectory: true)
        try? manager.createDirectory(at: noticesDirectory, withIntermediateDirectories: true)
        for notice in bundled.licenseNotices() {
            try? notice.text.write(to: noticesDirectory.appendingPathComponent(notice.name), atomically: true, encoding: .utf8)
        }
        // Record the same digests a downloaded package records: the digests of the
        // provider archives this bundle was built from. The on-disk binaries were
        // already verified against the bundle's own record in
        // `PHPBundledRuntime.bundled()`, so package identity stays comparable no
        // matter which path installed it.
        let package = PHPPackage(
            version: manifest.phpVersion,
            architecture: manifest.architecture,
            packagePath: final.path,
            cliPath: final.appendingPathComponent("php").path,
            fpmPath: final.appendingPathComponent("php-fpm").path,
            source: manifest.artifacts["cli"]?.url ?? "bundled:\(manifest.phpVersion)",
            cliSHA256: manifest.artifacts["cli"]?.sha256 ?? cliBinary.sha256,
            fpmSHA256: manifest.artifacts["fpm"]?.sha256 ?? fpmBinary.sha256,
            installedAt: Date()
        )
        try atomicWrite(package, to: final.appendingPathComponent(".vaelen-package.json"))
        return package
    }

    /// Keep the provider's per-component notices beside the installed package.
    ///
    /// PHP and every statically linked library carry their own license, which is
    /// not covered by the build tool's. Notices are retained opportunistically:
    /// a missing notice must never fail an otherwise valid install.
    private func retainLicenseNotices(manifest: PHPManifest) throws {
        let destination = layout.phpPackagesDirectoryURL.appendingPathComponent(manifest.phpVersion).appendingPathComponent("license", isDirectory: true)
        guard !manager.fileExists(atPath: destination.path) else { return }
        try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let isLegacy = manifest.release?.url == PHPPackageProvider.legacyBaseURL
        let licenseBase = isLegacy ? PHPPackageProvider.legacyLicenseBaseURL : PHPPackageProvider.licenseBaseURL
        if let notices = manifest.build?.notices, !notices.isEmpty {
            for name in notices where !name.contains("/") && !name.contains("..") {
                guard let text = try? fetchText("\(licenseBase)/\(name)") else { continue }
                try? text.write(to: destination.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            return
        }
        guard let listing = try? fetchText("\(licenseBase)/?format=json") else { return }
        guard let entries = try? JSONSerialization.jsonObject(with: Data(listing.utf8)) as? [[String: Any]] else { return }
        for entry in entries {
            guard let name = entry["name"] as? String,
                  (entry["is_dir"] as? Bool ?? false) == false,
                  name.hasSuffix("_LICENSE.txt") || name == "SUMMARY.json"
            else { continue }
            guard let text = try? fetchText("\(PHPPackageProvider.licenseBaseURL)/\(name)") else { continue }
            try? text.write(to: destination.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func fetchText(_ urlString: String) throws -> String {
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), PHPPackageProvider.artifactHosts.contains(host)
        else { throw PHPModuleError.invalidManifest("PHP provider notice URL is not permitted.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let box = PHPRemoteResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let data { box.set(.success((data, response as? HTTPURLResponse))) }
            else { box.set(.failure(error ?? PHPModuleError.catalogUnavailable("unreachable"))) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        let (data, response): (Data, HTTPURLResponse?)
        do { (data, response) = try box.get()!.get() } catch { throw PHPModuleError.catalogUnavailable("unreachable") }
        guard let response, (200..<300).contains(response.statusCode) else { throw PHPModuleError.catalogUnavailable("notice unavailable") }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Persist the digests of a newly discovered version so later installs and
    /// cache reuse verify against what was actually downloaded.
    private func recordDiscoveredDigests(version: String, cli: String, fpm: String, sizes: [String: Int64]) {
        guard let bundled = location as? BundledPHPManifestLocation else { return }
        bundled.recordDiscoveredDigests(version: version, cli: cli, fpm: fpm, sizes: sizes)
    }

    private func resolveExactEligible(_ requestedVersion: String) throws -> PHPPackage {
        guard let version = PHPVersion(requestedVersion), version.isStable,
              let package = eligibleInstalledVersions().first(where: { $0.version == version.description }) else {
            throw PHPModuleError.packageMissing(requestedVersion)
        }
        return package
    }

    private func manifest(for requestedVersion: String) throws -> PHPManifest {
        let manifests = try allManifests()
        let installable = manifests.filter(isInstallableManifest)
        guard let exact = PHPVersion(requestedVersion), exact.isStable,
              let manifest = installable.first(where: { $0.phpVersion == exact.description }) else {
            guard let family = PHPFamily(requestedVersion), let manifest = installable.filter({ PHPVersion($0.phpVersion)?.family == family.description }).max(by: { (PHPVersion($0.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1.phpVersion) ?? .init(major: 0, minor: 0, patch: 0) ) }) else {
                throw PHPModuleError.unsupportedVersion(requestedVersion)
            }
            return manifest
        }
        return manifest
    }

    private func allManifests() throws -> [PHPManifest] {
        var byVersion = [String: PHPManifest]()
        if let bundled = bundledCatalogManifests() {
            for manifest in bundled { byVersion[manifest.phpVersion] = manifest }
        }
        for manifest in try location.manifests() { byVersion[manifest.phpVersion] = manifest }
        // Versions a successful provider check discovered are installable too.
        if let bundled = location as? BundledPHPManifestLocation {
            for manifest in bundled.discoveredManifests() { byVersion[manifest.phpVersion] = manifest }
        }
        return byVersion.values.sorted { (PHPVersion($0.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) }
    }

    private func bundledCatalogManifests() -> [PHPManifest]? {
        guard includesBundledCatalog,
              let url = Bundle.module.url(forResource: "php-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundled = try? JSONDecoder().decode(PHPManifestCatalog.self, from: data)
        else { return nil }
        return bundled.manifests
    }

    private func isInstallableManifest(_ manifest: PHPManifest) -> Bool {
        guard manifest.module == "php",
        manifest.schemaVersion == 1 &&
        manifest.platform == "macos" &&
        manifest.architecture == "arm64" &&
        manifest.verification.algorithm.lowercased() == "sha256" &&
        !manifest.verification.authenticity.isEmpty &&
        PHPVersion(manifest.phpVersion)?.isStable == true,
        let cli = manifest.artifacts["cli"],
        let fpm = manifest.artifacts["fpm"] else { return false }
        // A provider URL is required either way: bundled files and downloads
        // both resolve through it, and a discovered version with no digest yet
        // still records one on first download.
        guard [cli, fpm].allSatisfy({ artifact in
            !artifact.file.isEmpty && URL(string: artifact.url)?.scheme != nil
        }) else { return false }
        // A review-pinned version is installable only with its pinned digest.
        if manifest.verification.isPinnedByReview {
            return [cli, fpm].allSatisfy { $0.sha256.count == 64 && $0.sha256.allSatisfy { $0.isHexDigit } }
        }
        // A discovered version carries no digest until it is downloaded once.
        // It must still be a well-formed digest or explicitly empty.
        return [cli, fpm].allSatisfy { $0.sha256.isEmpty || ($0.sha256.count == 64 && $0.sha256.allSatisfy { $0.isHexDigit }) }
    }

    private func executeOperation<T>(kind: PHPOperationKind, targetVersion: String, holdOpenOnSuccess: Bool = false, body: () throws -> T) throws -> T {
        lock.lock()
        guard activeOperation == nil else {
            let current = activeOperation?.targetVersion ?? "unknown"
            lock.unlock()
            throw PHPModuleError.operationInProgress(current)
        }
        activeOperation = PHPOperationState(kind: kind, targetVersion: targetVersion, phase: .starting)
        lock.unlock()
        do {
            let result = try body()
            lock.lock()
            if holdOpenOnSuccess {
                // The caller owns follow-up work (dispatcher-level convergence)
                // and will finalize. The operation stays visibly pending so no
                // other package operation or shutdown can race it, and observers
                // never see it reported ready before the whole update finishes.
                lock.unlock()
                return result
            }
            let progress = activeOperation
            lastOperation = PHPOperationState(kind: kind, targetVersion: targetVersion, phase: kind == .remove ? .removed : .ready, bytesTransferred: progress?.bytesTransferred, totalBytes: progress?.totalBytes, artifactName: progress?.artifactName, artifactIndex: progress?.artifactIndex, artifactCount: progress?.artifactCount, usingVerifiedCachedDownloads: progress?.usingVerifiedCachedDownloads)
            activeOperation = nil
            lock.unlock()
            return result
        } catch {
            lock.lock()
            let progress = activeOperation
            lastOperation = PHPOperationState(kind: kind, targetVersion: targetVersion, phase: .failed, message: String(describing: error), bytesTransferred: progress?.bytesTransferred, totalBytes: progress?.totalBytes, artifactName: progress?.artifactName, artifactIndex: progress?.artifactIndex, artifactCount: progress?.artifactCount, usingVerifiedCachedDownloads: progress?.usingVerifiedCachedDownloads)
            activeOperation = nil
            lock.unlock()
            throw error
        }
    }

    /// Mark the held-open update operation as converging follow-up work.
    ///
    /// Called by the dispatcher inside the package-operation reservation, after
    /// `update(holdOpenOnSuccess:)` returns. If no operation is held open for
    /// this target, one is opened so convergence still owns observable pending
    /// status and still blocks racing package work and shutdown.
    public func beginPostInstallConvergence(targetVersion: String) {
        lock.lock(); defer { lock.unlock() }
        if let current = activeOperation, current.kind == .update, current.targetVersion == targetVersion {
            activeOperation = PHPOperationState(kind: current.kind, targetVersion: current.targetVersion, phase: .converging, message: current.message, bytesTransferred: current.bytesTransferred, totalBytes: current.totalBytes, artifactName: current.artifactName, artifactIndex: current.artifactIndex, artifactCount: current.artifactCount, usingVerifiedCachedDownloads: current.usingVerifiedCachedDownloads)
        } else if activeOperation == nil {
            activeOperation = PHPOperationState(kind: .update, targetVersion: targetVersion, phase: .converging)
        }
    }

    /// Finalize a held-open update operation once convergence is reported.
    ///
    /// A `nil` failure means the whole update finished; a message means the
    /// package installed but follow-up work did not converge, which is recorded
    /// as the terminal state rather than reported ready.
    public func finishPostInstallConvergence(targetVersion: String, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        let progress = activeOperation
        lastOperation = PHPOperationState(kind: .update, targetVersion: targetVersion, phase: failure == nil ? .ready : .failed, message: failure, bytesTransferred: progress?.bytesTransferred, totalBytes: progress?.totalBytes, artifactName: progress?.artifactName, artifactIndex: progress?.artifactIndex, artifactCount: progress?.artifactCount, usingVerifiedCachedDownloads: progress?.usingVerifiedCachedDownloads)
        activeOperation = nil
    }

    private func setOperationPhase(_ phase: PHPOperationPhase) {
        lock.lock(); defer { lock.unlock() }
        guard let current = activeOperation else { return }
        activeOperation = PHPOperationState(kind: current.kind, targetVersion: current.targetVersion, phase: phase, message: current.message, bytesTransferred: current.bytesTransferred, totalBytes: current.totalBytes, artifactName: current.artifactName, artifactIndex: current.artifactIndex, artifactCount: current.artifactCount, usingVerifiedCachedDownloads: current.usingVerifiedCachedDownloads)
    }

    private func setOperationUsingVerifiedCache(_ cached: Bool, artifactName: String, index: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let current = activeOperation else { return }
        activeOperation = PHPOperationState(kind: current.kind, targetVersion: current.targetVersion, phase: current.phase, message: current.message, bytesTransferred: current.bytesTransferred, totalBytes: current.totalBytes, artifactName: artifactName, artifactIndex: index, artifactCount: 2, usingVerifiedCachedDownloads: cached)
    }

    private func setOperationDownloadProgress(bytes: Int64, total: Int64?, artifactName: String, artifactIndex: Int, artifactCount: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let current = activeOperation else { return }
        activeOperation = PHPOperationState(kind: current.kind, targetVersion: current.targetVersion, phase: .downloading, message: nil, bytesTransferred: bytes, totalBytes: total, artifactName: artifactName, artifactIndex: artifactIndex, artifactCount: artifactCount, usingVerifiedCachedDownloads: false)
    }

    public func setDefault(requestedVersion: String) throws -> PHPPackage {
        try executeOperation(kind: .defaultSelection, targetVersion: requestedVersion) {
            try self.setDefaultUnlocked(requestedVersion: requestedVersion)
        }
    }

    private func setDefaultUnlocked(requestedVersion: String) throws -> PHPPackage {
        let package = try resolveEligible(requestedVersion)
        try makeDirectories([layout.configurationDirectoryURL])
        try atomicWrite(package.version, to: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"))
        return package
    }

    public func defaultVersion() -> String? {
        defaultVersion(packages: eligibleInstalledVersions())
    }

    private func defaultVersion(packages: @autoclosure () -> [PHPPackage]) -> String? {
        guard let persisted = try? String(contentsOf: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !persisted.isEmpty,
              packages().contains(where: { $0.version == persisted }) else { return nil }
        return persisted
    }

    public func selectionSnapshot() -> PHPSelectionSnapshot {
        let observations = packageObservations()
        let packages = observations.filter { $0.eligibility == .eligible }.compactMap(\.package)
        let selectedDefault = defaultVersion(packages: packages)
        return PHPSelectionSnapshot(
            packages: packages,
            invalidVersions: observations.filter { $0.eligibility != .eligible }.compactMap(\.version),
            statuses: packages.map { observeStatus(package: $0, version: $0.version, defaultVersion: selectedDefault, maintainRecords: false) },
            defaultVersion: selectedDefault
        )
    }

    public func configuration() throws -> PHPConfigurationSnapshot {
        let stored = try loadPHPConfiguration()
        if !manager.fileExists(atPath: phpSettingsFile.path) { try savePHPConfiguration(stored) }
        let installed = eligibleInstalledVersions()
        var versions = [PHPManagedVersionConfiguration]()
        for package in installed {
            let override = stored.versionOverrides[package.version]
            let settings = override ?? stored.defaultSettings
            let paths = try writePHPIniFiles(version: package.version, settings: settings)
            let fpmConfig = layout.phpInstancesDirectoryURL.appendingPathComponent(package.version).appendingPathComponent("config/php-fpm.conf").path
            let isRunning = (try? status(requestedVersion: package.version).state) == .running
            versions.append(PHPManagedVersionConfiguration(version: package.version, settings: settings, inheritsDefault: override == nil, cliIniPath: paths.cli.path, fpmIniPath: paths.fpm.path, fpmConfigurationPath: fpmConfig, fpmRunning: isRunning))
        }
        return PHPConfigurationSnapshot(defaultSettings: stored.defaultSettings, versions: versions, directory: phpConfigurationDirectory.path)
    }

    public func updateConfiguration(version requestedVersion: String?, settings requestedSettings: PHPManagedSettings?) throws -> PHPConfigurationSnapshot {
        try executeOperation(kind: .configurationUpdate, targetVersion: requestedVersion ?? "default") {
            let before = try self.loadPHPConfiguration()
            var after = before
            if let requestedVersion {
                let package = try self.resolveExactEligible(requestedVersion)
                if let requestedSettings {
                    after.versionOverrides[package.version] = try self.validatedSettings(requestedSettings)
                } else {
                    after.versionOverrides.removeValue(forKey: package.version)
                }
            } else {
                guard let requestedSettings else { throw PHPModuleError.validationFailed("Default PHP settings cannot be cleared.") }
                after.defaultSettings = try self.validatedSettings(requestedSettings)
            }

            let affected = self.eligibleInstalledVersions().filter { package in
                (before.versionOverrides[package.version] ?? before.defaultSettings) != (after.versionOverrides[package.version] ?? after.defaultSettings)
            }
            let running = affected.filter { (try? self.status(requestedVersion: $0.version).state) == .running }
            do {
                try self.savePHPConfiguration(after)
                for package in affected {
                    _ = try self.writePHPIniFiles(version: package.version, settings: after.versionOverrides[package.version] ?? after.defaultSettings)
                }
                for package in running { _ = try self.stop(requestedVersion: package.version) }
                for package in running {
                    let restarted = try self.start(requestedVersion: package.version)
                    guard restarted.state == .running, restarted.health == "healthy" else { throw PHPModuleError.processFailed("PHP-FPM \(package.version) did not become healthy after applying its configuration.") }
                }
            } catch {
                let applyFailure = String(describing: error)
                // Preferences and per-version INI files are restored before
                // restarting any runtime stopped by the failed application.
                do {
                    try self.savePHPConfiguration(before)
                    for package in affected {
                        _ = try self.writePHPIniFiles(version: package.version, settings: before.versionOverrides[package.version] ?? before.defaultSettings)
                    }
                    for package in running {
                        if (try? self.status(requestedVersion: package.version).state) == .running {
                            _ = try self.stop(requestedVersion: package.version)
                        }
                    }
                    for package in running {
                        let restored = try self.start(requestedVersion: package.version)
                        guard restored.state == .running, restored.health == "healthy" else {
                            throw PHPModuleError.processFailed("PHP-FPM \(package.version) did not return to a healthy state with its previous settings.")
                        }
                    }
                } catch {
                    throw PHPModuleError.processFailed("PHP settings could not be applied (\(applyFailure)); rollback also failed (\(error)). Review the saved settings and PHP-FPM status before retrying.")
                }
                throw PHPModuleError.processFailed("PHP settings could not be applied (\(applyFailure)). The previous settings were restored and affected PHP-FPM runtimes are healthy.")
            }
            let inventory = try self.configuration()
            return PHPConfigurationSnapshot(defaultSettings: inventory.defaultSettings, versions: inventory.versions, directory: inventory.directory, affectedVersions: running.map(\.version))
        }
    }

    private var phpConfigurationDirectory: URL { layout.configurationDirectoryURL.appendingPathComponent("php", isDirectory: true) }
    private var phpSettingsFile: URL { phpConfigurationDirectory.appendingPathComponent("settings.json") }
    private func phpVersionConfigurationDirectory(_ version: String) -> URL { phpConfigurationDirectory.appendingPathComponent("versions", isDirectory: true).appendingPathComponent(version, isDirectory: true) }
    private func loadPHPConfiguration() throws -> PHPConfigurationStoreRecord {
        guard manager.fileExists(atPath: phpSettingsFile.path) else { return PHPConfigurationStoreRecord(defaultSettings: defaultPHPSettings, versionOverrides: [:]) }
        do {
            var record = try JSONDecoder().decode(PHPConfigurationStoreRecord.self, from: Data(contentsOf: phpSettingsFile))
            record.defaultSettings = try validatedSettings(record.defaultSettings)
            for (version, settings) in record.versionOverrides {
                guard PHPVersion(version)?.isStable == true else { throw PHPModuleError.validationFailed("Invalid PHP version in the saved configuration: \(version)") }
                record.versionOverrides[version] = try validatedSettings(settings)
            }
            return record
        } catch let error as PHPModuleError { throw error }
        catch { throw PHPModuleError.validationFailed("The saved PHP settings file is unreadable: \(error.localizedDescription)") }
    }
    private func effectivePHPSettings(version: String) throws -> PHPManagedSettings {
        let stored = try loadPHPConfiguration()
        if !manager.fileExists(atPath: phpSettingsFile.path) { try savePHPConfiguration(stored) }
        return stored.versionOverrides[version] ?? stored.defaultSettings
    }
    private func savePHPConfiguration(_ record: PHPConfigurationStoreRecord) throws {
        try makeDirectories([phpConfigurationDirectory])
        try atomicWrite(record, to: phpSettingsFile)
    }
    private func validatedSettings(_ settings: PHPManagedSettings) throws -> PHPManagedSettings {
        guard (1...2048).contains(settings.uploadLimitMB) else { throw PHPModuleError.validationFailed("Maximum upload size must be between 1 and 2048 MB.") }
        guard (16...4096).contains(settings.memoryLimitMB) else { throw PHPModuleError.validationFailed("PHP memory limit must be between 16 and 4096 MB.") }
        guard (0...86_400).contains(settings.maxExecutionTimeSeconds) else { throw PHPModuleError.validationFailed("Maximum execution time must be between 0 and 86400 seconds.") }
        guard (100...1_000_000).contains(settings.maxInputVariables) else { throw PHPModuleError.validationFailed("Maximum input variables must be between 100 and 1000000.") }
        let minimumPost = settings.uploadLimitMB + 1
        let post = max(settings.postLimitMB, minimumPost)
        guard post <= 2049 else { throw PHPModuleError.validationFailed("POST size limit cannot exceed 2049 MB.") }
        return PHPManagedSettings(uploadLimitMB: settings.uploadLimitMB, memoryLimitMB: settings.memoryLimitMB, maxExecutionTimeSeconds: settings.maxExecutionTimeSeconds, maxInputVariables: settings.maxInputVariables, postLimitMB: post)
    }
    private func writePHPIniFiles(version: String, settings rawSettings: PHPManagedSettings) throws -> (cli: URL, fpm: URL) {
        let settings = try validatedSettings(rawSettings)
        let directory = phpVersionConfigurationDirectory(version)
        try makeDirectories([directory])
        let common = "upload_max_filesize = \(settings.uploadLimitMB)M\npost_max_size = \(settings.postLimitMB)M\nmemory_limit = \(settings.memoryLimitMB)M\nmax_input_vars = \(settings.maxInputVariables)\n"
        let fpm = directory.appendingPathComponent("fpm.ini")
        let cli = directory.appendingPathComponent("cli.ini")
        try atomicWrite(common + "max_execution_time = \(settings.maxExecutionTimeSeconds)\n", to: fpm)
        // The packaged CLI has historically been unlimited (0 seconds).
        // Keep that behavior unless the user invokes CLI PHP explicitly with -d.
        try atomicWrite(common + "max_execution_time = 0\n", to: cli)
        return (cli, fpm)
    }

    public func executable(requestedVersion: String? = nil) throws -> String { try resolveInstalled(requestedVersion ?? defaultVersion() ?? "latest").cliPath }

    public func exec(requestedVersion: String? = nil, workingDirectory: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let directory = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw PHPModuleError.invalidWorkingDirectory(workingDirectory) }
        let version = try resolveInstalled(requestedVersion ?? defaultVersion() ?? "latest").version
        let config = try writePHPIniFiles(version: version, settings: effectivePHPSettings(version: version))
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: try executable(requestedVersion: version)); process.arguments = ["-c", config.cli.path] + arguments; process.currentDirectoryURL = directory; process.environment = ProcessInfo.processInfo.environment.merging(["PHP_INI_SCAN_DIR": ""]) { _, managed in managed }; process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit(); return (process.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    public func status(requestedVersion: String) throws -> PHPStatus {
        let package = try? resolveInstalled(requestedVersion)
        return observeStatus(package: package, version: package?.version ?? requestedVersion, defaultVersion: defaultVersion(), maintainRecords: true)
    }

    private func observeStatus(package: PHPPackage?, version: String, defaultVersion: String?, maintainRecords: Bool) -> PHPStatus {
        let socket = socketPath(version); let record = processRecord(version)
        guard let record else { return PHPStatus(version: version, package: package, state: .stopped, pid: nil, socket: socket, health: "stopped", isDefault: defaultVersion == version) }
        if let child = ownedProcess(for: version), child.processIdentifier == record.pid, !child.isRunningAndReapedIfExited() {
            if child.hasLiveOwnedDescendants {
                return PHPStatus(version: version, package: package, state: .degraded, pid: record.pid, socket: socket, health: "master-exited-workers-running", isDefault: defaultVersion == version)
            }
            if maintainRecords {
                clearExitedFPMRecord(record, version: version)
                removeOwnedProcess(for: version)
            }
            return PHPStatus(version: version, package: package, state: .stopped, pid: nil, socket: socket, health: "stopped", isDefault: defaultVersion == version)
        }
        guard processMatches(record) else {
            if !processExists(record.pid) {
                if maintainRecords { clearExitedFPMRecord(record, version: version) }
                return PHPStatus(version: version, package: package, state: .stopped, pid: nil, socket: socket, health: "stopped", isDefault: defaultVersion == version)
            }
            return PHPStatus(version: version, package: package, state: .degraded, pid: record.pid, socket: socket, health: "identity-unverified", isDefault: defaultVersion == version)
        }
        let healthy = manager.fileExists(atPath: socket) && isSocket(socket) && isSocketReady(socket)
        if let child = ownedProcess(for: version) { _ = child.isRunningAndReapedIfExited() }
        if maintainRecords, healthy, record.socketDevice == nil || record.socketInode == nil {
            var info = stat()
            if lstat(socket, &info) == 0, var updated = processRecord(version) {
                updated = PHPProcessRecord(pid: updated.pid, version: updated.version, executable: updated.executable, arguments: updated.arguments, configPath: updated.configPath, socketPath: updated.socketPath, startedAt: updated.startedAt, socketDevice: Int64(info.st_dev), socketInode: Int64(info.st_ino))
                try? atomicWrite(updated, to: processRecordURL(version))
            }
        }
        return PHPStatus(version: version, package: package, state: healthy ? .running : .degraded, pid: record.pid, socket: socket, health: healthy ? "healthy" : "not-ready", isDefault: defaultVersion == version)
    }

    public func start(requestedVersion: String) throws -> PHPStatus {
        let package = try resolveEligible(requestedVersion); let current = try status(requestedVersion: package.version)
        if current.state == .running { return current }
        if current.state == .degraded {
            if let record = processRecord(package.version), processExists(record.pid) {
                throw PHPModuleError.processIdentityMismatch
            }
            try? manager.removeItem(at: processRecordURL(package.version))
        }
        let instance = layout.phpInstancesDirectoryURL.appendingPathComponent(package.version, isDirectory: true)
        let config = instance.appendingPathComponent("config/php-fpm.conf"); let socket = socketPath(package.version); let log = layout.phpLogsDirectoryURL.appendingPathComponent("\(package.version).log")
        try makeDirectories([config.deletingLastPathComponent(), layout.phpLogsDirectoryURL, layout.rootURL.appendingPathComponent("runtime/sockets/php", isDirectory: true)])
        try? manager.removeItem(atPath: socket)
        let ini = try writePHPIniFiles(version: package.version, settings: effectivePHPSettings(version: package.version))
        let content = "[global]\ndaemonize = no\nerror_log = \(log.path)\n\n[vaelen]\nuser = \(NSUserName())\ngroup = \(NSUserName())\nlisten = \(socket)\nlisten.mode = 0600\npm = dynamic\npm.max_children = 2\npm.start_servers = 1\npm.min_spare_servers = 1\npm.max_spare_servers = 2\n"
        try atomicWrite(content, to: config)
        if !manager.fileExists(atPath: log.path) { manager.createFile(atPath: log.path, contents: nil) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: package.fpmPath); process.arguments = ["-c", ini.fpm.path, "-y", config.path, "-F"]; process.environment = ProcessInfo.processInfo.environment.merging(["PHP_INI_SCAN_DIR": ""]) { _, managed in managed }; process.standardOutput = try FileHandle(forWritingTo: log); process.standardError = process.standardOutput
        try process.run()
        let child = OwnedChildProcess(process: process, label: "PHP-FPM \(package.version)")
        setOwnedProcess(child, for: package.version)
        let record = PHPProcessRecord(pid: process.processIdentifier, version: package.version, executable: package.fpmPath, arguments: process.arguments ?? [], configPath: config.path, socketPath: socket, startedAt: processStartIdentity(process.processIdentifier), socketDevice: nil, socketInode: nil)
        try atomicWrite(record, to: processRecordURL(package.version));
        var lastObservation: PHPStatus?
        for _ in 0..<40 {
            lastObservation = try? status(requestedVersion: package.version)
            if lastObservation?.state == .running, lastObservation?.health == "healthy" { return lastObservation! }
            if !child.process.isRunning { break }
            usleep(50_000)
        }
        guard child.terminateAndWait(timeout: 3, signal: SIGQUIT, waitForDescendants: true) else {
            throw PHPModuleError.processFailed("PHP-FPM \(package.version) PID \(record.pid) did not stop cleanly after startup timeout; process record retained")
        }
        removeOwnedProcess(for: package.version)
        try? manager.removeItem(at: processRecordURL(package.version))
        removeOwnedSocket(record)
        let detail = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw PHPModuleError.processFailed("PHP-FPM did not become ready (last health: \(lastObservation?.health ?? "unavailable"))\(detail.isEmpty ? "" : ": \(detail)")")
    }

    public func stop(requestedVersion: String) throws -> PHPStatus {
        let version = try resolveInstalled(requestedVersion).version
        let observed = try status(requestedVersion: version)
        guard let record = processRecord(version) else { return observed }
        let child = ownedProcess(for: version)
        guard processExists(record.pid), processMatches(record) else {
            // A dead PID or a live process that no longer matches this record
            // is not authority to signal anything. Drop only Vaelen's stale
            // bookkeeping; do not remove sockets that may now belong to others.
            if !processExists(record.pid) { removeOwnedSocket(record) }
            try? manager.removeItem(at: processRecordURL(version))
            removeOwnedProcess(for: version)
            return PHPStatus(version: version, package: observed.package, state: .stopped, pid: nil, socket: record.socketPath, health: "stopped", isDefault: defaultVersion() == version)
        }
        let stopped: Bool
        if let child, child.processIdentifier == record.pid {
            stopped = child.terminateAndWait(timeout: 3, signal: SIGQUIT, waitForDescendants: true)
        } else {
            // Core may have restarted while the exact recorded FPM master
            // survived. Its executable, config argv and start time are enough
            // to safely issue PHP-FPM's graceful master signal.
            stopped = kill(record.pid, SIGQUIT) == 0 && waitForRecordedProcessToExit(record, timeout: 3)
        }
        guard stopped else {
            throw PHPModuleError.processFailed("PHP-FPM \(version) PID \(record.pid) or one of its workers remains after the graceful shutdown timeout; process record retained")
        }
        removeOwnedProcess(for: version)
        removeOwnedSocket(record)
        try manager.removeItem(at: processRecordURL(version))
        let final = try status(requestedVersion: version)
        guard final.state == .stopped else { throw PHPModuleError.processFailed("PHP-FPM \(version) remains observable after shutdown; process record retained") }
        return final
    }

    private func waitForRecordedProcessToExit(_ record: PHPProcessRecord, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !processMatches(record) { return true }
            usleep(20_000)
        }
        return !processMatches(record)
    }

    private func resolveInstalled(_ requested: String) throws -> PHPPackage {
        let packages = installedVersions()
        if let version = PHPVersionResolver.resolve(requested, versionStrings: packages.map(\.version)), let value = packages.first(where: { $0.version == version }) { return value }
        throw PHPModuleError.packageMissing(requested)
    }

    private func observePackage(at directory: URL) -> PHPInstalledPackageObservation {
        let metadataURL = directory.appendingPathComponent(".vaelen-package.json")
        guard let data = try? Data(contentsOf: metadataURL), let package = try? JSONDecoder().decode(PHPPackage.self, from: data) else {
            return .init(package: nil, version: directory.lastPathComponent, eligibility: .invalid, reason: "Package metadata is missing or invalid.")
        }
        guard let version = PHPVersion(package.version) else { return .init(package: package, version: package.version, eligibility: .invalid, reason: "Package version is malformed.") }
        guard version.isStable else { return .init(package: package, version: package.version, eligibility: .invalid, reason: "Prerelease PHP packages are not eligible for project resolution.") }
        guard URL(fileURLWithPath: package.packagePath).standardizedFileURL == directory.standardizedFileURL,
              directory.lastPathComponent == package.version else { return .init(package: package, version: package.version, eligibility: .invalid, reason: "Package metadata does not match its package directory.") }
        guard package.architecture == "arm64" else { return .init(package: package, version: package.version, eligibility: .invalid, reason: "Package architecture is incompatible.") }
        // `file` and PHP's `-v` are package validation, not a runtime health
        // probe. Reuse only a successful validation of these exact unchanged
        // files; replacement, writes, chmod or metadata changes invalidate it.
        guard let cli = executableIdentity(package.cliPath), let fpm = executableIdentity(package.fpmPath) else {
            return .init(package: package, version: package.version, eligibility: .invalid, reason: "Package executables are missing.")
        }
        validationLock.lock()
        let cached = validatedPackages[directory.path]
        validationLock.unlock()
        if cached?.metadata == data, cached?.cli == cli, cached?.fpm == fpm {
            return .init(package: package, version: package.version, eligibility: .eligible)
        }
        do {
            try validateInstalledExecutable(package.cliPath, expected: package.version, name: "php")
            try validateInstalledExecutable(package.fpmPath, expected: package.version, name: "php-fpm")
        } catch {
            return .init(package: package, version: package.version, eligibility: .invalid, reason: "Package executable validation failed.")
        }
        if executableIdentity(package.cliPath) == cli, executableIdentity(package.fpmPath) == fpm {
            validationLock.lock()
            validatedPackages[directory.path] = ValidatedPackage(metadata: data, cli: cli, fpm: fpm)
            validationLock.unlock()
        }
        return .init(package: package, version: package.version, eligibility: .eligible)
    }

    private func executableIdentity(_ path: String) -> ExecutableIdentity? {
        var info = stat()
        guard stat(path, &info) == 0, manager.isExecutableFile(atPath: path) else { return nil }
        return .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size, mode: info.st_mode, modified: info.st_mtimespec, changed: info.st_ctimespec)
    }

    private func validateInstalledExecutable(_ path: String, expected: String, name: String) throws {
        guard manager.isExecutableFile(atPath: path) else { throw PHPModuleError.validationFailed("missing \(name)") }
        let fileOutput = try command("/usr/bin/file", [path])
        guard fileOutput.contains("Mach-O 64-bit executable arm64") else { throw PHPModuleError.validationFailed("unexpected \(name) architecture") }
        let output = try command(path, ["-v"])
        guard output.contains(expected) else { throw PHPModuleError.validationFailed("unexpected \(name) version") }
    }
    /// Fetches one artifact and returns its local path and measured byte count.
    ///
    /// `expectedSHA256` is the review-pinned digest. When it is empty this is a
    /// version discovered by a provider check: the bytes arrive over the
    /// provider's HTTPS origin and their digest is returned for Vaelen to
    /// record as a local integrity record.
    private func acquire(_ artifact: PHPArtifact, expectedSHA256: String, name: String, index: Int, base: URL?, progress: PHPArtifactProgressTracker) throws -> (url: URL, sha256: String, bytes: Int64) {
        let destination = layout.downloadsDirectoryURL.appendingPathComponent(artifact.file)
        try makeDirectories([layout.downloadsDirectoryURL])
        let pinned = expectedSHA256.lowercased()
        let hasPinnedDigest = pinned.count == 64
        if manager.fileExists(atPath: destination.path) {
            let existing = sha256(destination) ?? ""
            // A cached file is reused only when it matches a pinned digest, or
            // when a discovered version has already recorded this one.
            if hasPinnedDigest ? existing == pinned : (!existing.isEmpty && existing == pinned) {
                let length = ((try? manager.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
                progress.update(name: name, index: index, bytes: length, total: length)
                setOperationUsingVerifiedCache(true, artifactName: name, index: index)
                setOperationPhase(.verifying)
                return (destination, existing, length)
            }
            try? manager.removeItem(at: destination)
        }
        let source = try resolveArtifactSource(artifact, base: base)
        // Announce this archive through the aggregate tracker rather than
        // publishing a bare zero, which would erase the measurement the previous
        // archive already contributed and make the visible percentage jump back.
        progress.announce(name: name, index: index)
        let progressSink = PHPArtifactProgressSink { bytes, total in progress.update(name: name, index: index, bytes: bytes, total: total) }
        do { try artifactTransfer(source, destination, progressSink) }
        catch { try? manager.removeItem(at: destination); throw error }
        setOperationPhase(.verifying)
        let received = sha256(destination) ?? ""
        let measured = ((try? manager.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard !received.isEmpty else { try? manager.removeItem(at: destination); throw PHPModuleError.verificationFailed(artifact.file) }
        if hasPinnedDigest {
            guard received == pinned else { try? manager.removeItem(at: destination); throw PHPModuleError.verificationFailed(artifact.file) }
        }
        return (destination, received, measured)
    }

    /// Resolve where an artifact comes from, validating a remote URL's scheme and
    /// host against the provider allowlist before any request is made.
    private func resolveArtifactSource(_ artifact: PHPArtifact, base: URL?) throws -> URL {
        if let base, base.isFileURL, manager.fileExists(atPath: base.appendingPathComponent(artifact.file).path) {
            return base.appendingPathComponent(artifact.file)
        }
        guard let remote = URL(string: artifact.url), let scheme = remote.scheme?.lowercased(), let host = remote.host?.lowercased() else {
            throw PHPModuleError.invalidManifest("PHP package URL is invalid.")
        }
        if base?.isFileURL == true || remote.isFileURL {
            guard scheme == "file" || base != nil else { throw PHPModuleError.invalidManifest("PHP package URL is invalid.") }
        }
        guard scheme == "https" else {
            throw PHPModuleError.invalidManifest("PHP packages must be downloaded over HTTPS.")
        }
        guard PHPPackageProvider.artifactHosts.contains(host) else {
            throw PHPModuleError.invalidManifest("PHP package host \(host) is not the configured PHP provider.")
        }
        return remote
    }

    static func transferArtifact(source: URL, destination: URL, progress: PHPArtifactProgressSink) throws {
        try transferArtifact(source: source, destination: destination, progress: progress, configuration: .ephemeral)
    }

    static func transferArtifact(source: URL, destination: URL, progress: PHPArtifactProgressSink, configuration: URLSessionConfiguration) throws {
        if source.isFileURL {
            let sourceHandle = try FileHandle(forReadingFrom: source)
            defer { try? sourceHandle.close() }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw PHPModuleError.manifestUnavailable }
            let target = try FileHandle(forWritingTo: destination)
            defer { try? target.close() }
            let total = ((try? FileManager.default.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.int64Value
            var transferred: Int64 = 0
            progress.report(0, total)
            while let chunk = try sourceHandle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try target.write(contentsOf: chunk)
                transferred += Int64(chunk.count)
                progress.report(transferred, total)
            }
            return
        }
        let delegate = PHPArtifactTransferDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: source).resume()
        try delegate.wait()
    }
    private func extract(_ archive: URL, to directory: URL) throws {
        // Refuse archive entries that would escape the staging directory, so a
        // malformed or hostile package cannot write outside Vaelen's own space.
        let listing = Process()
        let listingPipe = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        listing.arguments = ["-tzf", archive.path]
        listing.standardOutput = listingPipe
        listing.standardError = FileHandle.nullDevice
        try listing.run()
        let names = String(data: listingPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        listing.waitUntilExit()
        guard listing.terminationStatus == 0 else { throw PHPModuleError.validationFailed("archive could not be read") }
        for line in names.split(separator: "\n") {
            let entry = String(line)
            guard !entry.isEmpty else { continue }
            guard !entry.hasPrefix("/"), !entry.contains("../"), !entry.contains("/../"), !entry.split(separator: "/").contains("..") else {
                throw PHPModuleError.validationFailed("archive contains an unsafe path")
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PHPModuleError.validationFailed("archive extraction failed") }
    }

    private func validateExecutable(_ path: String, expected: String, name: String, build: PHPBuildConfiguration? = nil) throws {
        guard manager.isExecutableFile(atPath: path) else { throw PHPModuleError.validationFailed("missing \(name)") }
        let fileOutput = try command("/usr/bin/file", [path])
        guard fileOutput.contains("Mach-O 64-bit executable arm64") else { throw PHPModuleError.validationFailed("unexpected \(name) architecture") }
        let dependencies = try command("/usr/bin/otool", ["-L", path])
        guard !dependencies.contains("/opt/homebrew/") && !dependencies.contains("/usr/local/") && !dependencies.contains("Application Support/Herd") else { throw PHPModuleError.validationFailed("unexpected \(name) runtime dependency") }
        // A package must be able to run on the macOS Vaelen supports.
        let loadCommands = try command("/usr/bin/otool", ["-l", path])
        if let range = loadCommands.range(of: #"minos (\d+)\.(\d+)"#, options: .regularExpression) {
            let version = String(loadCommands[range]).replacingOccurrences(of: "minos ", with: "")
            let minimumVersion = build?.minimumMacOS ?? PHPPackageProvider.minimumMacOS
            let minimum = minimumVersion.split(separator: ".").compactMap { Int($0) }
            let required = version.split(separator: ".").compactMap { Int($0) }
            if minimum.count == 2, required.count == 2, required[0] > minimum[0] || (required[0] == minimum[0] && required[1] > minimum[1]) {
                throw PHPModuleError.validationFailed("\(name) requires macOS \(version), but this PHP package supports macOS \(minimumVersion) or later")
            }
        }
        let output = try command(path, ["-v"])
        guard output.contains(expected) else { throw PHPModuleError.validationFailed("unexpected \(name) version") }
        if name == "php" {
            let modules = try command(path, ["-m"]).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            // The required extension contract is authoritative and is never
            // weakened to accommodate a smaller provider build.
            for extensionName in PHPPackageProvider.requiredExtensions where !modules.contains(extensionName) {
                throw PHPModuleError.validationFailed("missing required PHP extension \(extensionName)")
            }
            for extensionName in build?.requiredExtensions ?? [] where !modules.contains(extensionName.lowercased()) {
                throw PHPModuleError.validationFailed("missing PHP extension \(extensionName)")
            }
            // Optional extensions are reported, never required, so a build without them
            // is still a valid package. Their availability is described
            // separately rather than enforced here.
        }
    }
    private func command(_ path: String, _ args: [String]) throws -> String { let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw PHPModuleError.validationFailed(path) }; return String(data: output, encoding: .utf8) ?? "" }
    private func sha256(_ url: URL) -> String? { (try? command("/usr/bin/shasum", ["-a", "256", url.path]))?.split(separator: " ").first.map(String.init) }
    private func socketPath(_ version: String) -> String { layout.rootURL.appendingPathComponent("runtime/sockets/php/php-\(version).sock").path }
    private func processRecordURL(_ version: String) -> URL { layout.phpInstancesDirectoryURL.appendingPathComponent(version).appendingPathComponent("process.json") }
    private func processRecord(_ version: String) -> PHPProcessRecord? { try? JSONDecoder().decode(PHPProcessRecord.self, from: Data(contentsOf: processRecordURL(version))) }
    private func ownedProcess(for version: String) -> OwnedChildProcess? {
        ownedProcessesLock.lock(); defer { ownedProcessesLock.unlock() }
        return ownedFPMProcesses[version]
    }
    private func setOwnedProcess(_ process: OwnedChildProcess, for version: String) {
        ownedProcessesLock.lock(); defer { ownedProcessesLock.unlock() }
        ownedFPMProcesses[version] = process
    }
    private func removeOwnedProcess(for version: String) {
        ownedProcessesLock.lock(); defer { ownedProcessesLock.unlock() }
        ownedFPMProcesses.removeValue(forKey: version)
    }
    private func clearExitedFPMRecord(_ record: PHPProcessRecord, version: String) {
        try? manager.removeItem(at: processRecordURL(version))
        removeOwnedSocket(record)
    }
    private func removeOwnedSocket(_ record: PHPProcessRecord) {
        guard let device = record.socketDevice, let inode = record.socketInode else { return }
        var info = stat()
        guard lstat(record.socketPath, &info) == 0, Int64(info.st_dev) == device, Int64(info.st_ino) == inode,
              (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { return }
        try? manager.removeItem(atPath: record.socketPath)
    }
    private func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func processMatches(_ record: PHPProcessRecord) -> Bool {
        if let child = ownedProcess(for: record.version), child.processIdentifier == record.pid {
            return child.isRunningAndReapedIfExited()
                && child.executablePath == URL(fileURLWithPath: record.executable).standardizedFileURL.path
                && child.arguments == record.arguments
                && manager.fileExists(atPath: record.configPath)
        }
        guard processExists(record.pid) else { return false }
        let user = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "user="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let startedAt = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "lstart="]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let openExecutable = (try? command("/usr/sbin/lsof", ["-p", "\(record.pid)", "-a", "-d", "txt", "-Fn"])) ?? ""
        let executableMatches = openExecutable.split(separator: "\n").contains { $0 == Substring("n\(record.executable)") }
        let commandLine = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "command="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // FPM rewrites argv to "php-fpm: master process (config-path)";
        // requiring its original -F/-y tokens would reject the genuine master.
        let configArgumentMatches = commandLine.contains(record.configPath)
        let configMatches = manager.fileExists(atPath: record.configPath)
        return executableMatches && configArgumentMatches && configMatches && user == NSUserName() && (record.startedAt == nil || record.startedAt == startedAt)
    }
    private func isSocket(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid() }
    private func isSocketReady(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0); guard descriptor >= 0 else { return false }; defer { close(descriptor) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); path.withCString { pointer in withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: UnsafeRawBufferPointer(start: pointer, count: min(path.utf8.count + 1, bytes.count))) } }
        return withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 } }
    }
    private func processStartIdentity(_ pid: Int32) -> String? { try? command("/bin/ps", ["-p", "\(pid)", "-o", "lstart="]).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func makeDirectories(_ urls: [URL]) throws { for url in urls { try manager.createDirectory(at: url, withIntermediateDirectories: true); try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) } }
    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws { try atomicWrite(IPCJSON.encoder.encode(value), to: url) }
    private func atomicWrite(_ value: String, to url: URL) throws { try atomicWrite(Data(value.utf8), to: url) }
    private func atomicWrite(_ data: Data, to url: URL) throws { let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp"); try data.write(to: temporary, options: .atomic); if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temporary) } else { try manager.moveItem(at: temporary, to: url) } }
}

private enum IPCJSON { static let encoder = JSONEncoder() }
