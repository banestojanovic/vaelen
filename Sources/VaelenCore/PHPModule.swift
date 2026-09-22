import Foundation
import Darwin

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

    public init(schemaVersion: Int, module: String, phpVersion: String, platform: String, architecture: String, build: PHPBuildConfiguration? = nil, artifacts: [String: PHPArtifact], verification: PHPVerification, catalogURL: String? = nil) {
        self.schemaVersion = schemaVersion
        self.module = module
        self.phpVersion = phpVersion
        self.platform = platform
        self.architecture = architecture
        self.build = build
        self.artifacts = artifacts
        self.verification = verification
        self.catalogURL = catalogURL
    }
}

public struct PHPBuildConfiguration: Codable, Equatable, Sendable {
    public let requiredExtensions: [String]
    public let optionalExtensions: [String]

    public init(requiredExtensions: [String] = [], optionalExtensions: [String] = []) {
        self.requiredExtensions = requiredExtensions
        self.optionalExtensions = optionalExtensions
    }
}

public struct PHPVerification: Codable, Equatable, Sendable {
    public let algorithm: String
    public let authenticity: String
}

public protocol PHPManifestLocation: Sendable {
    func manifest() throws -> PHPManifest
    func artifactBaseURL() -> URL?
    func manifests() throws -> [PHPManifest]
    func refreshCatalogIfNeeded() throws
}

public extension PHPManifestLocation {
    func manifests() throws -> [PHPManifest] { [try manifest()] }
    func refreshCatalogIfNeeded() throws {}
}

public struct PHPManifestCatalog: Codable, Equatable, Sendable {
    public let manifests: [PHPManifest]
    public init(manifests: [PHPManifest]) { self.manifests = manifests }
}

public struct FilePHPManifestLocation: PHPManifestLocation {
    public let manifestURL: URL
    public let baseURL: URL?
    public let catalogURL: URL?
    public init(manifestURL: URL, baseURL: URL? = nil, catalogURL: URL? = nil) { self.manifestURL = manifestURL; self.baseURL = baseURL; self.catalogURL = catalogURL }
    public func manifest() throws -> PHPManifest {
        try JSONDecoder().decode(PHPManifest.self, from: Data(contentsOf: manifestURL))
    }
    public func artifactBaseURL() -> URL? { baseURL ?? manifestURL.deletingLastPathComponent() }
    public func refreshCatalogIfNeeded() throws {
        guard let catalogURL else { return }
        let cacheURL = manifestURL.deletingLastPathComponent().appendingPathComponent("php-catalog.json")
        if let modified = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 900 { return }
        var request = URLRequest(url: catalogURL)
        request.timeoutInterval = 10
        let semaphore = DispatchSemaphore(value: 0)
        let result = PHPRemoteResultBox()
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let data { result.set(.success(data)) }
            else { result.set(.failure(error ?? PHPModuleError.manifestUnavailable)) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        let data = try result.get()!.get()
        let catalog = try JSONDecoder().decode(PHPManifestCatalog.self, from: data)
        guard catalog.manifests.allSatisfy({ $0.verification.authenticity == "trusted-vaelen-release-manifest" }) else {
            throw PHPModuleError.invalidManifest("catalog is not a trusted Vaelen release catalog")
        }
        try data.write(to: cacheURL, options: .atomic)
    }
    public func manifests() throws -> [PHPManifest] {
        let catalogURL = manifestURL.deletingLastPathComponent().appendingPathComponent("php-catalog.json")
        guard let data = try? Data(contentsOf: catalogURL) else { return [try manifest()] }
        return try JSONDecoder().decode(PHPManifestCatalog.self, from: data).manifests
    }
}

public enum PHPModuleError: Error, Equatable, Sendable {
    case manifestUnavailable
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

public struct PHPRuntimeCatalog: Codable, Equatable, Sendable {
    public let availableVersions: [String]
    public let installedVersions: [PHPRuntimeVersion]
    public let defaultVersion: String?
    public let runningVersions: [String]
    public let availableVersionsKnown: Bool

    public init(availableVersions: [String], installedVersions: [PHPRuntimeVersion], defaultVersion: String?, runningVersions: [String], availableVersionsKnown: Bool = true) {
        self.availableVersions = Self.sortedUnique(availableVersions)
        self.installedVersions = installedVersions.reduce(into: [String: PHPRuntimeVersion]()) { result, value in
            guard result[value.version] == nil else { return }
            result[value.version] = value
        }.values.sorted { Self.versionSort($0.version, $1.version) }
        self.defaultVersion = defaultVersion
        self.runningVersions = Self.sortedUnique(runningVersions)
        self.availableVersionsKnown = availableVersionsKnown
    }

    public func withProjectUsage(_ usage: [PHPProjectUsage]) -> PHPRuntimeCatalog {
        let byVersion = Dictionary(uniqueKeysWithValues: usage.map { ($0.version, $0) })
        let updated = installedVersions.map { runtime in
            let value = byVersion[runtime.version]
            return PHPRuntimeVersion(version: runtime.version, series: runtime.series, running: runtime.running, isDefault: runtime.isDefault, updateAvailable: runtime.updateAvailable, latestVersion: runtime.latestVersion, usedByProjectCount: value?.total ?? 0, explicitProjectCount: value?.explicit ?? 0, inheritedProjectCount: value?.inherited ?? 0)
        }
        return PHPRuntimeCatalog(availableVersions: availableVersions, installedVersions: updated, defaultVersion: defaultVersion, runningVersions: runningVersions, availableVersionsKnown: availableVersionsKnown)
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
        self.availableVersions = Self.sortedUnique(availableVersions)
        self.installedVersions = versions.reduce(into: [String: PHPRuntimeVersion]()) { result, value in
            guard result[value.version] == nil else { return }
            result[value.version] = value
        }.values.sorted { Self.versionSort($0.version, $1.version) }
        self.defaultVersion = defaultVersion
        self.runningVersions = Self.sortedUnique(statuses.filter { $0.state == .running }.map(\.version))
        self.availableVersionsKnown = true
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

public enum PHPOperationKind: String, Codable, Sendable { case install, update, remove, defaultSelection }
public enum PHPOperationPhase: String, Codable, Sendable { case starting, downloading, verifying, installing, ready, removing, removed, failed }
public struct PHPOperationState: Codable, Equatable, Sendable {
    public let kind: PHPOperationKind
    public let targetVersion: String
    public let phase: PHPOperationPhase
    public let message: String?

    public init(kind: PHPOperationKind, targetVersion: String, phase: PHPOperationPhase, message: String? = nil) {
        self.kind = kind; self.targetVersion = targetVersion; self.phase = phase; self.message = message
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
}

private struct PHPDevelopmentConfiguration: Codable, Sendable {
    let manifestPath: String
    let artifactBasePath: String
    let catalogURL: String?
}

private final class PHPRemoteResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data, Error>?
    func set(_ value: Result<Data, Error>) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

public final class PHPModule: @unchecked Sendable {
    private let layout: VaelenFilesystemLayout
    private let location: any PHPManifestLocation
    private let includesBundledCatalog: Bool
    private let manager = FileManager.default
    private let lock = NSLock()
    private var activeOperation: PHPOperationState?
    private var lastOperation: PHPOperationState?

    public init(layout: VaelenFilesystemLayout, location: any PHPManifestLocation, includesBundledCatalog: Bool = false) {
        self.layout = layout; self.location = location; self.includesBundledCatalog = includesBundledCatalog
    }

    public static func development(layout: VaelenFilesystemLayout = .init()) -> PHPModule? {
        let environment = ProcessInfo.processInfo.environment
        let configurationURL = layout.configurationDirectoryURL.appendingPathComponent("php-distribution.json")
        let configuration = try? JSONDecoder().decode(PHPDevelopmentConfiguration.self, from: Data(contentsOf: configurationURL))
        guard let manifest = environment["VAELEN_PHP_MANIFEST"] ?? configuration?.manifestPath else { return nil }
        let basePath = environment["VAELEN_PHP_ARTIFACT_BASE"] ?? configuration?.artifactBasePath
        let base = basePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let manifestMetadata = try? JSONDecoder().decode(PHPManifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
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
        if case .failure = availableResult { return PHPRuntimeCatalog(availableVersions: catalog.availableVersions, installedVersions: catalog.installedVersions, defaultVersion: catalog.defaultVersion, runningVersions: catalog.runningVersions, availableVersionsKnown: false) }
        return catalog
    }

    public func refreshCatalogIfNeeded() throws { try location.refreshCatalogIfNeeded() }

    public func operationState() -> PHPOperationState? {
        lock.lock(); defer { lock.unlock() }; return activeOperation ?? lastOperation
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

    public func update(requestedVersion: String) throws -> PHPPackage {
        try executeOperation(kind: .update, targetVersion: requestedVersion) {
            let target = try self.manifest(for: requestedVersion).phpVersion
            let currentDefault = self.defaultVersion()
            let package = try self.installUnlocked(requestedVersion: target)
            if let currentDefault, PHPVersion(currentDefault)?.family == PHPVersion(target)?.family, currentDefault != target {
                _ = try self.setDefaultUnlocked(requestedVersion: target)
            }
            return package
        }
    }

    public func selectDefault(requestedVersion: String) throws -> PHPRuntimeCatalog {
        try executeOperation(kind: .defaultSelection, targetVersion: requestedVersion) {
            let package = try self.resolveExactEligible(requestedVersion)
            var status = try self.status(requestedVersion: package.version)
            if status.state != .running || status.health != "healthy" {
                status = try self.start(requestedVersion: package.version)
            }
            guard status.state == .running, status.health == "healthy" else {
                throw PHPModuleError.processFailed("PHP-FPM did not become healthy for PHP \(package.version)")
            }
            _ = try self.setDefaultUnlocked(requestedVersion: package.version)
            return try self.runtimeCatalog()
        }
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
        if let existing = try? JSONDecoder().decode(PHPPackage.self, from: Data(contentsOf: final.appendingPathComponent(".vaelen-package.json"))) { return existing }
        setOperationPhase(.downloading)
        let operation = UUID().uuidString
        let staging = layout.stagingDirectoryURL.appendingPathComponent("php-\(version)-\(operation)", isDirectory: true)
        try makeDirectories([layout.downloadsDirectoryURL, layout.stagingDirectoryURL, layout.phpPackagesDirectoryURL, staging])
        defer { try? manager.removeItem(at: staging) }
        setOperationPhase(.verifying)
        let cliURL = try acquire(cli, base: location.artifactBaseURL())
        let fpmURL = try acquire(fpm, base: location.artifactBaseURL())
        setOperationPhase(.installing)
        try extract(cliURL, to: staging); try extract(fpmURL, to: staging)
        let cliPath = staging.appendingPathComponent("php").path
        let fpmPath = staging.appendingPathComponent("php-fpm").path
        try validateExecutable(cliPath, expected: version, name: "php", build: manifest.build)
        try validateExecutable(fpmPath, expected: version, name: "php-fpm", build: manifest.build)
        try makeDirectories([final.deletingLastPathComponent()])
        if manager.fileExists(atPath: final.path) { throw PHPModuleError.validationFailed("package directory already exists") }
        try manager.moveItem(at: staging, to: final)
        let package = PHPPackage(version: version, architecture: manifest.architecture, packagePath: final.path, cliPath: final.appendingPathComponent("php").path, fpmPath: final.appendingPathComponent("php-fpm").path, source: cli.url, cliSHA256: cli.sha256, fpmSHA256: fpm.sha256, installedAt: Date())
        try atomicWrite(package, to: final.appendingPathComponent(".vaelen-package.json"))
        return package
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
        let local = try location.manifests()
        guard includesBundledCatalog,
              let url = Bundle.module.url(forResource: "php-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundled = try? JSONDecoder().decode(PHPManifestCatalog.self, from: data) else { return local }
        var byVersion = Dictionary(uniqueKeysWithValues: bundled.manifests.map { ($0.phpVersion, $0) })
        for manifest in local { byVersion[manifest.phpVersion] = manifest }
        return byVersion.values.sorted { (PHPVersion($0.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) }
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
        return [cli, fpm].allSatisfy { artifact in
            !artifact.file.isEmpty &&
            artifact.sha256.count == 64 &&
            artifact.sha256.allSatisfy { $0.isHexDigit } &&
            URL(string: artifact.url)?.scheme != nil
        }
    }

    private func executeOperation<T>(kind: PHPOperationKind, targetVersion: String, body: () throws -> T) throws -> T {
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
            lastOperation = PHPOperationState(kind: kind, targetVersion: targetVersion, phase: kind == .remove ? .removed : .ready)
            activeOperation = nil
            lock.unlock()
            return result
        } catch {
            lock.lock()
            lastOperation = PHPOperationState(kind: kind, targetVersion: targetVersion, phase: .failed, message: String(describing: error))
            activeOperation = nil
            lock.unlock()
            throw error
        }
    }

    private func setOperationPhase(_ phase: PHPOperationPhase) {
        lock.lock(); defer { lock.unlock() }
        guard let current = activeOperation else { return }
        activeOperation = PHPOperationState(kind: current.kind, targetVersion: current.targetVersion, phase: phase, message: current.message)
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
        guard let persisted = try? String(contentsOf: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !persisted.isEmpty,
              eligibleInstalledVersions().contains(where: { $0.version == persisted }) else { return nil }
        return persisted
    }

    public func executable(requestedVersion: String? = nil) throws -> String { try resolveInstalled(requestedVersion ?? defaultVersion() ?? "latest").cliPath }

    public func exec(requestedVersion: String? = nil, workingDirectory: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let directory = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw PHPModuleError.invalidWorkingDirectory(workingDirectory) }
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: try executable(requestedVersion: requestedVersion)); process.arguments = arguments; process.currentDirectoryURL = directory; process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit(); return (process.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    public func status(requestedVersion: String) throws -> PHPStatus {
        let package = try? resolveInstalled(requestedVersion); let version = package?.version ?? requestedVersion
        let socket = socketPath(version); let record = processRecord(version)
        guard let record else { return PHPStatus(version: version, package: package, state: .stopped, pid: nil, socket: socket, health: "stopped", isDefault: defaultVersion() == version) }
        guard processMatches(record) else {
            if !processExists(record.pid) {
                try? manager.removeItem(at: processRecordURL(version))
                try? manager.removeItem(atPath: socket)
                return PHPStatus(version: version, package: package, state: .stopped, pid: nil, socket: socket, health: "stopped", isDefault: defaultVersion() == version)
            }
            return PHPStatus(version: version, package: package, state: .degraded, pid: record.pid, socket: socket, health: "identity-unverified", isDefault: defaultVersion() == version)
        }
        let healthy = manager.fileExists(atPath: socket) && isSocket(socket) && isSocketReady(socket)
        return PHPStatus(version: version, package: package, state: healthy ? .running : .degraded, pid: record.pid, socket: socket, health: healthy ? "healthy" : "not-ready", isDefault: defaultVersion() == version)
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
        let content = "[global]\ndaemonize = no\nerror_log = \(log.path)\n\n[vaelen]\nuser = \(NSUserName())\ngroup = \(NSUserName())\nlisten = \(socket)\nlisten.mode = 0600\npm = dynamic\npm.max_children = 2\npm.start_servers = 1\npm.min_spare_servers = 1\npm.max_spare_servers = 2\n"
        try atomicWrite(content, to: config)
        if !manager.fileExists(atPath: log.path) { manager.createFile(atPath: log.path, contents: nil) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: package.fpmPath); process.arguments = ["-y", config.path, "-F"]; process.standardOutput = try FileHandle(forWritingTo: log); process.standardError = process.standardOutput
        try process.run()
        let record = PHPProcessRecord(pid: process.processIdentifier, version: package.version, executable: package.fpmPath, arguments: process.arguments ?? [], configPath: config.path, socketPath: socket, startedAt: processStartIdentity(process.processIdentifier))
        try atomicWrite(record, to: processRecordURL(package.version));
        for _ in 0..<40 { if let result = try? status(requestedVersion: package.version), result.state == .running, result.health == "healthy" { return result }; usleep(50_000) }
        if processMatches(record) { _ = kill(record.pid, SIGQUIT) }
        try? manager.removeItem(at: processRecordURL(package.version))
        try? manager.removeItem(atPath: socket)
        throw PHPModuleError.processFailed("PHP-FPM did not become ready")
    }

    public func stop(requestedVersion: String) throws -> PHPStatus {
        let version = try resolveInstalled(requestedVersion).version; guard let record = processRecord(version) else { return try status(requestedVersion: version) }
        guard processMatches(record) else { throw PHPModuleError.processIdentityMismatch }
        _ = kill(record.pid, SIGQUIT)
        for _ in 0..<40 { if !processExists(record.pid) { try? manager.removeItem(at: processRecordURL(version)); try? manager.removeItem(atPath: record.socketPath); return try status(requestedVersion: version) }; usleep(50_000) }
        _ = kill(record.pid, SIGKILL); try? manager.removeItem(at: processRecordURL(version)); try? manager.removeItem(atPath: record.socketPath); return try status(requestedVersion: version)
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
        do {
            try validateInstalledExecutable(package.cliPath, expected: package.version, name: "php")
            try validateInstalledExecutable(package.fpmPath, expected: package.version, name: "php-fpm")
        } catch {
            return .init(package: package, version: package.version, eligibility: .invalid, reason: "Package executable validation failed.")
        }
        return .init(package: package, version: package.version, eligibility: .eligible)
    }

    private func validateInstalledExecutable(_ path: String, expected: String, name: String) throws {
        guard manager.isExecutableFile(atPath: path) else { throw PHPModuleError.validationFailed("missing \(name)") }
        let fileOutput = try command("/usr/bin/file", [path])
        guard fileOutput.contains("Mach-O 64-bit executable arm64") else { throw PHPModuleError.validationFailed("unexpected \(name) architecture") }
        let output = try command(path, ["-v"])
        guard output.contains(expected) else { throw PHPModuleError.validationFailed("unexpected \(name) version") }
    }
    private func acquire(_ artifact: PHPArtifact, base: URL?) throws -> URL {
        let destination = layout.downloadsDirectoryURL.appendingPathComponent(artifact.file)
        try makeDirectories([layout.downloadsDirectoryURL])
        if manager.fileExists(atPath: destination.path) {
            if sha256(destination) == artifact.sha256.lowercased() { return destination }
            try? manager.removeItem(at: destination)
        }
        let source: URL
        if let base, base.isFileURL, manager.fileExists(atPath: base.appendingPathComponent(artifact.file).path) {
            source = base.appendingPathComponent(artifact.file)
        } else if let remote = URL(string: artifact.url), remote.scheme != nil {
            source = remote
        } else if let base {
            source = base.appendingPathComponent(artifact.file)
        } else {
            throw PHPModuleError.manifestUnavailable
        }
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
        guard sha256(destination) == artifact.sha256.lowercased() else { try? manager.removeItem(at: destination); throw PHPModuleError.verificationFailed(artifact.file) }
        return destination
    }
    private func extract(_ archive: URL, to directory: URL) throws { let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); process.arguments = ["-xzf", archive.path, "-C", directory.path]; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw PHPModuleError.validationFailed("archive extraction failed") } }
    private func validateExecutable(_ path: String, expected: String, name: String, build: PHPBuildConfiguration? = nil) throws {
        guard manager.isExecutableFile(atPath: path) else { throw PHPModuleError.validationFailed("missing \(name)") }
        let fileOutput = try command("/usr/bin/file", [path])
        guard fileOutput.contains("Mach-O 64-bit executable arm64") else { throw PHPModuleError.validationFailed("unexpected \(name) architecture") }
        let dependencies = try command("/usr/bin/otool", ["-L", path])
        guard !dependencies.contains("/opt/homebrew/") && !dependencies.contains("/usr/local/") && !dependencies.contains("Application Support/Herd") else { throw PHPModuleError.validationFailed("unexpected \(name) runtime dependency") }
        let output = try command(path, ["-v"])
        guard output.contains(expected) else { throw PHPModuleError.validationFailed("unexpected \(name) version") }
        if name == "php", let build {
            let modules = try command(path, ["-m"]).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            for extensionName in build.requiredExtensions where !modules.contains(extensionName.lowercased()) { throw PHPModuleError.validationFailed("missing PHP extension \(extensionName)") }
            if build.optionalExtensions.contains("imagick") && !modules.contains("imagick") { throw PHPModuleError.validationFailed("missing PHP extension imagick") }
        }
    }
    private func command(_ path: String, _ args: [String]) throws -> String { let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw PHPModuleError.validationFailed(path) }; return String(data: output, encoding: .utf8) ?? "" }
    private func sha256(_ url: URL) -> String? { (try? command("/usr/bin/shasum", ["-a", "256", url.path]))?.split(separator: " ").first.map(String.init) }
    private func socketPath(_ version: String) -> String { layout.rootURL.appendingPathComponent("runtime/sockets/php/php-\(version).sock").path }
    private func processRecordURL(_ version: String) -> URL { layout.phpInstancesDirectoryURL.appendingPathComponent(version).appendingPathComponent("process.json") }
    private func processRecord(_ version: String) -> PHPProcessRecord? { try? JSONDecoder().decode(PHPProcessRecord.self, from: Data(contentsOf: processRecordURL(version))) }
    private func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func processMatches(_ record: PHPProcessRecord) -> Bool {
        guard processExists(record.pid) else { return false }
        let user = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "user="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let startedAt = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "lstart="]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let openExecutable = (try? command("/usr/sbin/lsof", ["-p", "\(record.pid)", "-a", "-d", "txt", "-Fn"])) ?? ""
        let executableMatches = openExecutable.split(separator: "\n").contains { $0 == Substring("n\(record.executable)") }
        let configMatches = manager.fileExists(atPath: record.configPath)
        return executableMatches && configMatches && user == NSUserName() && (record.startedAt == nil || record.startedAt == startedAt)
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
