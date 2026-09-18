import Foundation
import Darwin

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

    public init(schemaVersion: Int, module: String, phpVersion: String, platform: String, architecture: String, build: PHPBuildConfiguration? = nil, artifacts: [String: PHPArtifact], verification: PHPVerification) {
        self.schemaVersion = schemaVersion
        self.module = module
        self.phpVersion = phpVersion
        self.platform = platform
        self.architecture = architecture
        self.build = build
        self.artifacts = artifacts
        self.verification = verification
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
}

public struct FilePHPManifestLocation: PHPManifestLocation {
    public let manifestURL: URL
    public let baseURL: URL?
    public init(manifestURL: URL, baseURL: URL? = nil) { self.manifestURL = manifestURL; self.baseURL = baseURL }
    public func manifest() throws -> PHPManifest {
        try JSONDecoder().decode(PHPManifest.self, from: Data(contentsOf: manifestURL))
    }
    public func artifactBaseURL() -> URL? { baseURL ?? manifestURL.deletingLastPathComponent() }
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

private struct PHPProcessRecord: Codable, Sendable {
    let pid: Int32
    let version: String
    let executable: String
    let arguments: [String]
    let configPath: String
    let socketPath: String
}

private struct PHPDevelopmentConfiguration: Codable, Sendable {
    let manifestPath: String
    let artifactBasePath: String
}

public final class PHPModule: @unchecked Sendable {
    private let layout: VaelenFilesystemLayout
    private let location: any PHPManifestLocation
    private let manager = FileManager.default
    private let lock = NSLock()

    public init(layout: VaelenFilesystemLayout, location: any PHPManifestLocation) {
        self.layout = layout; self.location = location
    }

    public static func development(layout: VaelenFilesystemLayout = .init()) -> PHPModule? {
        let environment = ProcessInfo.processInfo.environment
        let configurationURL = layout.configurationDirectoryURL.appendingPathComponent("php-distribution.json")
        let configuration = try? JSONDecoder().decode(PHPDevelopmentConfiguration.self, from: Data(contentsOf: configurationURL))
        guard let manifest = environment["VAELEN_PHP_MANIFEST"] ?? configuration?.manifestPath else { return nil }
        let basePath = environment["VAELEN_PHP_ARTIFACT_BASE"] ?? configuration?.artifactBasePath
        let base = basePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: URL(fileURLWithPath: manifest), baseURL: base))
    }

    public func availableVersions() throws -> [String] { [try location.manifest().phpVersion] }

    public func installedVersions() -> [PHPPackage] {
        guard let entries = try? manager.contentsOfDirectory(at: layout.phpPackagesDirectoryURL, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { try? JSONDecoder().decode(PHPPackage.self, from: Data(contentsOf: $0.appendingPathComponent(".vaelen-package.json"))) }.sorted { $0.version < $1.version }
    }

    public func install(requestedVersion: String) throws -> PHPPackage {
        lock.lock(); defer { lock.unlock() }
        let manifest = try location.manifest()
        guard manifest.module == "php", manifest.schemaVersion == 1, manifest.platform == "macos" else { throw PHPModuleError.invalidManifest("unsupported manifest") }
        guard manifest.architecture == "arm64" else { throw PHPModuleError.unsupportedArchitecture(manifest.architecture) }
        guard manifest.verification.algorithm.lowercased() == "sha256" else { throw PHPModuleError.invalidManifest("SHA-256 verification is required") }
        guard requestedVersion == manifest.phpVersion || requestedVersion == manifest.phpVersion.split(separator: ".").prefix(2).joined(separator: ".") else { throw PHPModuleError.unsupportedVersion(requestedVersion) }
        guard let cli = manifest.artifacts["cli"], let fpm = manifest.artifacts["fpm"] else { throw PHPModuleError.invalidManifest("CLI and FPM artifacts are required") }
        let version = manifest.phpVersion
        let final = layout.phpPackagesDirectoryURL.appendingPathComponent(version, isDirectory: true)
        if let existing = try? JSONDecoder().decode(PHPPackage.self, from: Data(contentsOf: final.appendingPathComponent(".vaelen-package.json"))) { return existing }
        let operation = UUID().uuidString
        let staging = layout.stagingDirectoryURL.appendingPathComponent("php-\(version)-\(operation)", isDirectory: true)
        try makeDirectories([layout.downloadsDirectoryURL, layout.stagingDirectoryURL, layout.phpPackagesDirectoryURL, staging])
        defer { try? manager.removeItem(at: staging) }
        let cliURL = try acquire(cli, base: location.artifactBaseURL())
        let fpmURL = try acquire(fpm, base: location.artifactBaseURL())
        try extract(cliURL, to: staging); try extract(fpmURL, to: staging)
        let cliPath = staging.appendingPathComponent("php").path
        let fpmPath = staging.appendingPathComponent("php-fpm").path
        try validateExecutable(cliPath, expected: version, name: "php")
        try validateExecutable(fpmPath, expected: version, name: "php-fpm")
        try makeDirectories([final.deletingLastPathComponent()])
        if manager.fileExists(atPath: final.path) { throw PHPModuleError.validationFailed("package directory already exists") }
        try manager.moveItem(at: staging, to: final)
        let package = PHPPackage(version: version, architecture: manifest.architecture, packagePath: final.path, cliPath: final.appendingPathComponent("php").path, fpmPath: final.appendingPathComponent("php-fpm").path, source: cli.url, cliSHA256: cli.sha256, fpmSHA256: fpm.sha256, installedAt: Date())
        try atomicWrite(package, to: final.appendingPathComponent(".vaelen-package.json"))
        return package
    }

    public func setDefault(requestedVersion: String) throws -> PHPPackage {
        let package = try resolveInstalled(requestedVersion)
        try makeDirectories([layout.configurationDirectoryURL])
        try atomicWrite(package.version, to: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"))
        return package
    }

    public func defaultVersion() -> String? { try? String(contentsOf: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }

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
        let healthy = manager.fileExists(atPath: socket) && isSocket(socket)
        return PHPStatus(version: version, package: package, state: healthy ? .running : .degraded, pid: record.pid, socket: socket, health: healthy ? "healthy" : "not-ready", isDefault: defaultVersion() == version)
    }

    public func start(requestedVersion: String) throws -> PHPStatus {
        let package = try resolveInstalled(requestedVersion); let current = try status(requestedVersion: package.version)
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
        let record = PHPProcessRecord(pid: process.processIdentifier, version: package.version, executable: package.fpmPath, arguments: process.arguments ?? [], configPath: config.path, socketPath: socket)
        try atomicWrite(record, to: processRecordURL(package.version));
        for _ in 0..<40 { if let result = try? status(requestedVersion: package.version), result.state == .running { return result }; usleep(50_000) }
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
        let packages = installedVersions(); if requested == "latest", let value = packages.last { return value }
        if let exact = packages.first(where: { $0.version == requested }) { return exact }
        if let minor = packages.filter({ $0.version.split(separator: ".").prefix(2).joined(separator: ".") == requested }).last { return minor }
        throw PHPModuleError.packageMissing(requested)
    }
    private func acquire(_ artifact: PHPArtifact, base: URL?) throws -> URL {
        let destination = layout.downloadsDirectoryURL.appendingPathComponent(artifact.file)
        try makeDirectories([layout.downloadsDirectoryURL])
        if manager.fileExists(atPath: destination.path) {
            if sha256(destination) == artifact.sha256.lowercased() { return destination }
            try? manager.removeItem(at: destination)
        }
        guard let base else { throw PHPModuleError.manifestUnavailable }
        let source = base.isFileURL ? base.appendingPathComponent(artifact.file) : (URL(string: artifact.url, relativeTo: base) ?? base.appendingPathComponent(artifact.file))
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
        guard sha256(destination) == artifact.sha256.lowercased() else { try? manager.removeItem(at: destination); throw PHPModuleError.verificationFailed(artifact.file) }
        return destination
    }
    private func extract(_ archive: URL, to directory: URL) throws { let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); process.arguments = ["-xzf", archive.path, "-C", directory.path]; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw PHPModuleError.validationFailed("archive extraction failed") } }
    private func validateExecutable(_ path: String, expected: String, name: String) throws {
        guard manager.isExecutableFile(atPath: path) else { throw PHPModuleError.validationFailed("missing \(name)") }
        let fileOutput = try command("/usr/bin/file", [path])
        guard fileOutput.contains("Mach-O 64-bit executable arm64") else { throw PHPModuleError.validationFailed("unexpected \(name) architecture") }
        let dependencies = try command("/usr/bin/otool", ["-L", path])
        guard !dependencies.contains("/opt/homebrew/") && !dependencies.contains("/usr/local/") && !dependencies.contains("Application Support/Herd") else { throw PHPModuleError.validationFailed("unexpected \(name) runtime dependency") }
        let output = try command(path, ["-v"])
        guard output.contains(expected) else { throw PHPModuleError.validationFailed("unexpected \(name) version") }
        if name == "php", let build = try? location.manifest().build {
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
    private func processMatches(_ record: PHPProcessRecord) -> Bool { guard processExists(record.pid) else { return false }; let output = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "command="])) ?? ""; let executableName = URL(fileURLWithPath: record.executable).lastPathComponent; return output.contains(executableName) && output.contains(record.configPath) }
    private func isSocket(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK }
    private func makeDirectories(_ urls: [URL]) throws { for url in urls { try manager.createDirectory(at: url, withIntermediateDirectories: true); try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) } }
    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws { try atomicWrite(IPCJSON.encoder.encode(value), to: url) }
    private func atomicWrite(_ value: String, to url: URL) throws { try atomicWrite(Data(value.utf8), to: url) }
    private func atomicWrite(_ data: Data, to url: URL) throws { let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp"); try data.write(to: temporary, options: .atomic); if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temporary) } else { try manager.moveItem(at: temporary, to: url) } }
}

private enum IPCJSON { static let encoder = JSONEncoder() }
