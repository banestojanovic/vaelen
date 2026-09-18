import Foundation
import Darwin

public struct CaddyManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let platform: String
    public let architecture: String
    public let artifactFile: String
    public let artifactURL: URL
    public let artifactSHA512: String
    public let checksumURL: URL
    public let signatureURL: URL
    public let certificateURL: URL
    public let verificationMechanism: String
    public let certificateIdentity: String
    public let certificateOIDCIssuer: String
    public let license: String

    public init(schemaVersion: Int = 1, version: String, platform: String, architecture: String, artifactFile: String, artifactURL: URL, artifactSHA512: String, checksumURL: URL, signatureURL: URL, certificateURL: URL, verificationMechanism: String, certificateIdentity: String, certificateOIDCIssuer: String, license: String) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.platform = platform
        self.architecture = architecture
        self.artifactFile = artifactFile
        self.artifactURL = artifactURL
        self.artifactSHA512 = artifactSHA512
        self.checksumURL = checksumURL
        self.signatureURL = signatureURL
        self.certificateURL = certificateURL
        self.verificationMechanism = verificationMechanism
        self.certificateIdentity = certificateIdentity
        self.certificateOIDCIssuer = certificateOIDCIssuer
        self.license = license
    }

    public static let officialV2_11_4 = CaddyManifest(
        version: "2.11.4",
        platform: "macos",
        architecture: "arm64",
        artifactFile: "caddy_2.11.4_mac_arm64.tar.gz",
        artifactURL: URL(string: "https://api.github.com/repos/caddyserver/caddy/releases/assets/436912311")!,
        artifactSHA512: "3190ae0df98b59ab4b6021556fa35adc3c526a4f3e138776b0eaec8a037cc26121cbbb1ad53453f565551b47d37d5ba4755e2c2c3652256737fe2ce9e53c8ec0",
        checksumURL: URL(string: "https://api.github.com/repos/caddyserver/caddy/releases/assets/436912404")!,
        signatureURL: URL(string: "https://api.github.com/repos/caddyserver/caddy/releases/assets/436912565")!,
        certificateURL: URL(string: "https://api.github.com/repos/caddyserver/caddy/releases/assets/436912567")!,
        verificationMechanism: "Sigstore cosign verify-blob with signed checksum artifact",
        certificateIdentity: "https://github.com/caddyserver/caddy/.github/workflows/release.yml@refs/tags/v2.11.4",
        certificateOIDCIssuer: "https://token.actions.githubusercontent.com",
        license: "Apache-2.0"
    )
}

public struct CaddyPackage: Codable, Equatable, Sendable {
    public let version: String
    public let architecture: String
    public let packagePath: String
    public let executablePath: String
    public let source: String
    public let expectedSHA512: String
    public let verificationMechanism: String
    public let license: String
    public let installedAt: Date
}

public enum CaddyModuleError: Error, Equatable, Sendable {
    case invalidManifest(String)
    case unsupportedPlatform(String)
    case unsupportedArchitecture(String)
    case verificationUnavailable
    case verificationFailed(String)
    case checksumMismatch
    case validationFailed(String)
    case packageMissing(String)
}

public protocol CaddyArtifactDownloader: Sendable {
    func download(_ url: URL, to destination: URL) throws
}

public struct SystemCaddyArtifactDownloader: CaddyArtifactDownloader {
    public init() {}

    public func download(_ url: URL, to destination: URL) throws {
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: destination)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-fL", "-H", "Accept: application/octet-stream", "-o", destination.path, url.absoluteString]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "curl failed"
            throw CaddyModuleError.validationFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public protocol CaddyArtifactVerifier: Sendable {
    func verify(checksum: URL, signature: URL, certificate: URL, identity: String, issuer: String) throws
}

/// Development-only adapter. Public distribution must replace this with an owned verifier.
public struct DevelopmentCosignVerifier: CaddyArtifactVerifier {
    public let executableURL: URL

    public init(executableURL: URL) { self.executableURL = executableURL }

    public static func fromDevelopmentEnvironment() -> DevelopmentCosignVerifier? {
        guard let path = ProcessInfo.processInfo.environment["VAELEN_COSIGN_PATH"] else { return nil }
        return DevelopmentCosignVerifier(executableURL: URL(fileURLWithPath: path))
    }

    public func verify(checksum: URL, signature: URL, certificate: URL, identity: String, issuer: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw CaddyModuleError.verificationUnavailable }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["verify-blob", "--certificate", certificate.path, "--signature", signature.path, "--certificate-identity", identity, "--certificate-oidc-issuer", issuer, checksum.path]
        let error = Pipe()
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "cosign verification failed"
            throw CaddyModuleError.verificationFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public final class CaddyModule: @unchecked Sendable {
    private let layout: VaelenFilesystemLayout
    private let manifest: CaddyManifest
    private let downloader: any CaddyArtifactDownloader
    private let verifier: (any CaddyArtifactVerifier)?
    private let manager = FileManager.default

    public init(layout: VaelenFilesystemLayout, manifest: CaddyManifest = .officialV2_11_4, downloader: any CaddyArtifactDownloader = SystemCaddyArtifactDownloader(), verifier: (any CaddyArtifactVerifier)? = DevelopmentCosignVerifier.fromDevelopmentEnvironment()) {
        self.layout = layout
        self.manifest = manifest
        self.downloader = downloader
        self.verifier = verifier
    }

    public func installedVersions() -> [CaddyPackage] {
        guard let entries = try? manager.contentsOfDirectory(at: layout.caddyPackagesDirectoryURL, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { url in
            guard let package = try? JSONDecoder().decode(CaddyPackage.self, from: Data(contentsOf: url.appendingPathComponent(".vaelen-package.json"))), isValidInstalledPackage(package) else { return nil }
            return package
        }.sorted { $0.version < $1.version }
    }

    public func resolveInstalled(requestedVersion: String = "2.11") throws -> CaddyPackage {
        try validateManifest(requestedVersion: requestedVersion)
        guard let package = installedVersions().first(where: { $0.version == manifest.version }) else {
            throw CaddyModuleError.packageMissing(manifest.version)
        }
        return package
    }

    public func install(requestedVersion: String = "2.11") throws -> CaddyPackage {
        try validateManifest(requestedVersion: requestedVersion)
        if let existing = installedVersions().first(where: { $0.version == manifest.version }) { return existing }
        guard let verifier else { throw CaddyModuleError.verificationUnavailable }

        let operation = UUID().uuidString
        let staging = layout.stagingDirectoryURL.appendingPathComponent("caddy-\(manifest.version)-\(operation)", isDirectory: true)
        let downloads = layout.downloadsDirectoryURL.appendingPathComponent("caddy-\(manifest.version)-\(operation)", isDirectory: true)
        try makeDirectories([layout.downloadsDirectoryURL, layout.stagingDirectoryURL, layout.caddyPackagesDirectoryURL, staging, downloads])
        defer { try? manager.removeItem(at: staging); try? manager.removeItem(at: downloads) }

        let archive = downloads.appendingPathComponent(manifest.artifactFile)
        let checksum = downloads.appendingPathComponent("checksums.txt")
        let signature = downloads.appendingPathComponent("checksums.txt.sig")
        let certificate = downloads.appendingPathComponent("checksums.txt.pem")
        try downloader.download(manifest.artifactURL, to: archive)
        try downloader.download(manifest.checksumURL, to: checksum)
        try downloader.download(manifest.signatureURL, to: signature)
        try downloader.download(manifest.certificateURL, to: certificate)
        try verifier.verify(checksum: checksum, signature: signature, certificate: certificate, identity: manifest.certificateIdentity, issuer: manifest.certificateOIDCIssuer)
        try validateChecksum(checksum, archive: archive)
        try extract(archive, to: staging)

        let executable = staging.appendingPathComponent("caddy")
        try validateExecutable(executable)
        let final = layout.caddyPackagesDirectoryURL.appendingPathComponent(manifest.version, isDirectory: true)
        guard !manager.fileExists(atPath: final.path) else { throw CaddyModuleError.validationFailed("package directory already exists") }
        try manager.moveItem(at: staging, to: final)
        let package = CaddyPackage(version: manifest.version, architecture: manifest.architecture, packagePath: final.path, executablePath: final.appendingPathComponent("caddy").path, source: manifest.artifactURL.absoluteString, expectedSHA512: manifest.artifactSHA512, verificationMechanism: manifest.verificationMechanism, license: manifest.license, installedAt: Date())
        try atomicWrite(package, to: final.appendingPathComponent(".vaelen-package.json"))
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: final.path)
        return package
    }

    private func validateManifest(requestedVersion: String) throws {
        guard manifest.schemaVersion == 1, manifest.version == "2.11.4", requestedVersion == manifest.version || requestedVersion == "2.11", manifest.platform == "macos" else { throw CaddyModuleError.invalidManifest("unsupported Caddy manifest") }
        guard manifest.architecture == "arm64" else { throw CaddyModuleError.unsupportedArchitecture(manifest.architecture) }
        guard manifest.artifactSHA512.count == 128 else { throw CaddyModuleError.invalidManifest("SHA-512 checksum is required") }
    }

    private func validateChecksum(_ checksum: URL, archive: URL) throws {
        let entries = try String(contentsOf: checksum, encoding: .utf8).split(whereSeparator: \.isNewline)
        guard let entry = entries.compactMap({ line -> [Substring]? in
            let parts = line.split { $0 == " " || $0 == "\t" }
            return parts.count >= 2 ? parts : nil
        }).first(where: { $0[1] == manifest.artifactFile }), String(entry[0]).lowercased() == manifest.artifactSHA512.lowercased() else { throw CaddyModuleError.checksumMismatch }
        let actual = try command("/usr/bin/shasum", ["-a", "512", archive.path]).split(separator: " ").first.map(String.init)
        guard actual?.lowercased() == manifest.artifactSHA512.lowercased() else { throw CaddyModuleError.checksumMismatch }
    }

    private func extract(_ archive: URL, to directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); process.arguments = ["-xzf", archive.path, "-C", directory.path]; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyModuleError.validationFailed("archive extraction failed") }
    }

    private func validateExecutable(_ path: URL) throws {
        guard manager.isExecutableFile(atPath: path.path), try command("/usr/bin/file", [path.path]).contains("Mach-O 64-bit executable arm64") else { throw CaddyModuleError.validationFailed("unexpected Caddy architecture") }
        guard try command(path.path, ["version"]).contains("v\(manifest.version)") else { throw CaddyModuleError.validationFailed("unexpected Caddy version") }
    }

    private func isValidInstalledPackage(_ package: CaddyPackage) -> Bool {
        guard package.version == manifest.version,
              package.architecture == manifest.architecture,
              package.expectedSHA512 == manifest.artifactSHA512,
              package.verificationMechanism == manifest.verificationMechanism,
              package.license == manifest.license else { return false }
        let packagesRoot = layout.caddyPackagesDirectoryURL.standardizedFileURL.path
        let packageURL = URL(fileURLWithPath: package.packagePath).standardizedFileURL
        let executableURL = URL(fileURLWithPath: package.executablePath).standardizedFileURL
        guard packageURL.path == layout.caddyPackagesDirectoryURL.appendingPathComponent(package.version).standardizedFileURL.path,
              executableURL.path == packageURL.appendingPathComponent("caddy").path,
              packageURL.path.hasPrefix(packagesRoot + "/"),
              manager.fileExists(atPath: packageURL.appendingPathComponent(".vaelen-package.json").path),
              manager.isExecutableFile(atPath: executableURL.path),
              isOwnedByCurrentUser(packageURL.path),
              isImmutableDirectory(packageURL.path),
              isRegularFile(executableURL.path),
              executableURL.resolvingSymlinksInPath().path == executableURL.path else { return false }
        return (try? command(executableURL.path, ["version"]).contains("v\(manifest.version)")) == true
    }

    private func isOwnedByCurrentUser(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == getuid()
    }

    private func isImmutableDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && (info.st_mode & 0o7777) == 0o555
    }

    private func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private func command(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe; try process.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyModuleError.validationFailed(path) }; return String(data: output, encoding: .utf8) ?? ""
    }

    private func makeDirectories(_ urls: [URL]) throws { for url in urls { try manager.createDirectory(at: url, withIntermediateDirectories: true); try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) } }
    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws { let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp"); try JSONEncoder().encode(value).write(to: temporary, options: .atomic); try manager.moveItem(at: temporary, to: url) }
}
