import Foundation
import VaelenCore

/// Vaelen's verified provider package cache, shared by every test target.
///
/// It resolves the same artifact files `Scripts/refresh-php-catalog-from-provider.sh`
/// produced and verified, so tests install real provider bytes from disk instead
/// of re-downloading. `stagedExecutables` returns the extracted `php`/`php-fpm`
/// pair for seeding an already-installed package.
public final class ProviderArtifactCache: @unchecked Sendable {
    public static let shared = ProviderArtifactCache()
    private let lock = NSLock()
    private let root: URL

    private init() {
        // Tests/…/file.swift -> repository root
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // Mirrors the refresh script's generation/channel-scoped cache layout so
        // tests and the shipped catalog can never read another generation's bytes.
        let generation = (try? JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("Distribution/PHP/provider.json"))) as? [String: Any])
            .flatMap { ($0?["provider"] as? [String: Any])?["generation"] as? String } ?? "legacy"
        let channel = (try? JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("Distribution/PHP/provider.json"))) as? [String: Any])
            .flatMap { ($0?["provider"] as? [String: Any])?["channel"] as? String } ?? "bulk"
        root = repository.appendingPathComponent(".build/php-provider/\(generation)/\(channel)", isDirectory: true)
    }

    /// Directory holding a version's verified packages, or the shared root when
    /// `version` is nil.
    public func directory(for version: String?) -> URL {
        lock.lock()
        defer { lock.unlock() }
        let directory = version.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Real SHA-256 digests of a version's verified packages.
    public func artifacts(version: String) throws -> [String: String] {
        let directory = directory(for: version)
        var digests: [String: String] = [:]
        for kind in ["cli", "fpm"] {
            let file = PHPPackageProvider.artifactFile(version: version, kind: kind)
            let path = directory.appendingPathComponent(file).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw CacheError.missingPackage(version: version, kind: kind)
            }
            digests[kind] = try sha256(path)
        }
        return digests
    }

    /// Extract a version's verified packages and return the directory holding the
    /// real `php` and `php-fpm` binaries.
    public func stagedExecutables(version: String) throws -> URL {
        // Resolve the directory before taking the lock: the lock is not
        // recursive, so calling `directory(for:)` while holding it would
        // deadlock.
        let versionDirectory = directory(for: version)
        let staged = versionDirectory.appendingPathComponent("staged", isDirectory: true)
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: staged.appendingPathComponent("php-fpm").path) { return staged }
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        for kind in ["cli", "fpm"] {
            let archive = versionDirectory.appendingPathComponent(PHPPackageProvider.artifactFile(version: version, kind: kind))
            guard FileManager.default.fileExists(atPath: archive.path) else {
                throw CacheError.missingPackage(version: version, kind: kind)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", staged.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CacheError.extractionFailed(version: version) }
        }
        return staged
    }

    /// A single flat directory holding every cached version's verified archives, so
    /// one artifact base can resolve artifacts for several versions.
    public func flatDirectory() throws -> URL {
        let flat = directory(for: nil).appendingPathComponent("flat", isDirectory: true)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        for version in try publishedVersions() {
            for kind in ["cli", "fpm"] {
                let name = PHPPackageProvider.artifactFile(version: version, kind: kind)
                let source = directory(for: version).appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = flat.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            }
        }
        return flat
    }

    /// Build a provider manifest for a version using its real verified digests.
    /// Every version the provider's cached feed lists, newest last.
    public func publishedVersions() throws -> [String] {
        let cachedFeed = directory(for: nil).appendingPathComponent("feed.json")
        guard FileManager.default.fileExists(atPath: cachedFeed.path) else {
            throw CacheError.missingFeed
        }
        return try BundledPHPManifestLocation.publishedVersions(from: Data(contentsOf: cachedFeed)).allVersions.sorted()
    }

    public func manifest(version: String) throws -> PHPManifest {
        let digests = try artifacts(version: version)
        guard let cli = digests["cli"], let fpm = digests["fpm"] else {
            throw CacheError.missingPackage(version: version, kind: "digest")
        }
        return PHPManifest(
            schemaVersion: 1, module: "php", phpVersion: version, platform: "macos", architecture: "arm64",
            build: .init(requiredExtensions: [], optionalExtensions: []),
            artifacts: [
                "cli": PHPArtifact(file: PHPPackageProvider.artifactFile(version: version, kind: "cli"), url: PHPPackageProvider.artifactURL(version: version, kind: "cli"), sha256: cli),
                "fpm": PHPArtifact(file: PHPPackageProvider.artifactFile(version: version, kind: "fpm"), url: PHPPackageProvider.artifactURL(version: version, kind: "fpm"), sha256: fpm),
            ],
            verification: .init(algorithm: "sha256", authenticity: PHPPackageProvider.authenticity, digestPinnedByReview: true),
            release: .init(tag: PHPPackageProvider.channel, url: PHPPackageProvider.baseURL)
        )
    }

    private func sha256(_ path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0, let digest = output.split(separator: " ").first else {
            throw CacheError.digestFailed(path: path)
        }
        return String(digest)
    }

    public enum CacheError: Error, CustomStringConvertible {
        case missingPackage(version: String, kind: String)
        case extractionFailed(version: String)
        case digestFailed(path: String)
        case missingFeed

        public var description: String {
            switch self {
            case .missingPackage(let version, let kind):
                return "The verified provider cache has no \(kind) package for PHP \(version). Run ./Scripts/refresh-php-catalog-from-provider.sh first."
            case .extractionFailed(let version):
                return "Could not extract the cached provider packages for PHP \(version)."
            case .digestFailed(let path):
                return "Could not compute a digest for \(path)."
            case .missingFeed:
                return "The provider feed is not cached. Run ./Scripts/refresh-php-catalog-from-provider.sh first."
            }
        }
    }
}

/// A catalog whose artifacts resolve from the verified provider cache, so tests
/// install real provider bytes from disk with no network access. The catalog is
/// held in a reference so a test can model an in-process catalog correction.
public struct PHPProviderManifestLocation: PHPManifestLocation {
    public final class CatalogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PHPManifestCatalog
        public init(_ value: PHPManifestCatalog) { self.value = value }
        public var catalog: PHPManifestCatalog {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    public let box: CatalogBox
    public let stateDirectory: URL
    public let artifactBase: URL?

    public init(box: CatalogBox, stateDirectory: URL, artifactBase: URL?) {
        self.box = box
        self.stateDirectory = stateDirectory
        self.artifactBase = artifactBase
    }

    public func manifests() throws -> [PHPManifest] {
        guard !box.catalog.manifests.isEmpty else { throw PHPModuleError.manifestUnavailable }
        return box.catalog.manifests
    }

    public func manifest() throws -> PHPManifest {
        guard let first = box.catalog.manifests.max(by: {
            (PHPVersion($0.phpVersion) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1.phpVersion) ?? .init(major: 0, minor: 0, patch: 0))
        }) else { throw PHPModuleError.manifestUnavailable }
        return first
    }

    public func artifactBaseURL() -> URL? { artifactBase }
}
