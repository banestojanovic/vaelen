import Foundation
import Darwin

public struct MailpitManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let platform: String
    public let architecture: String
    public let artifactFile: String
    public let artifactURL: URL
    public let artifactSHA256: String
    public let license: String

    public static let official1_31_1 = MailpitManifest(version: "1.31.1", platform: "macos", architecture: "arm64", artifactFile: "mailpit-darwin-arm64.tar.gz", artifactURL: URL(string: "https://github.com/axllent/mailpit/releases/download/v1.31.1/mailpit-darwin-arm64.tar.gz")!, artifactSHA256: "71c10f33f36c78a2864c4df906f11736b092a80ad1371742bd4e90e65d778e1b", license: "MIT")
    public init(schemaVersion: Int = 1, version: String, platform: String, architecture: String, artifactFile: String, artifactURL: URL, artifactSHA256: String, license: String) { self.schemaVersion = schemaVersion; self.version = version; self.platform = platform; self.architecture = architecture; self.artifactFile = artifactFile; self.artifactURL = artifactURL; self.artifactSHA256 = artifactSHA256; self.license = license }
}

public struct MailpitPackage: Codable, Equatable, Sendable {
    public let version: String; public let architecture: String; public let packagePath: String; public let executablePath: String; public let source: String; public let artifactSHA256: String; public let license: String; public let installedAt: Date
}
public enum MailpitState: String, Codable, Sendable { case notInstalled, installed, stopped, starting, running, unhealthy, conflict }
public struct MailpitRuntimeConfiguration: Equatable, Sendable {
    public let smtpPort: Int
    public let httpPort: Int
    public init(smtpPort: Int = VaelenNetworkPorts.mailpitSMTP, httpPort: Int = VaelenNetworkPorts.mailpitHTTP) { self.smtpPort = smtpPort; self.httpPort = httpPort }
}
public struct MailpitStatus: Codable, Equatable, Sendable {
    public let state: MailpitState; public let health: String; public let installedVersion: String?; public let pid: Int32?; public let smtpPort: Int; public let httpPort: Int; public let database: String; public let uiEndpoint: String; public let executablePath: String; public let uptime: Int?; public let memoryBytes: UInt64?; public let cpuPercent: Double?
    public init(state: MailpitState, health: String, installedVersion: String?, pid: Int32?, smtpPort: Int, httpPort: Int, database: String, uiEndpoint: String, executablePath: String, uptime: Int? = nil, memoryBytes: UInt64? = nil, cpuPercent: Double? = nil) { self.state = state; self.health = health; self.installedVersion = installedVersion; self.pid = pid; self.smtpPort = smtpPort; self.httpPort = httpPort; self.database = database; self.uiEndpoint = uiEndpoint; self.executablePath = executablePath; self.uptime = uptime; self.memoryBytes = memoryBytes; self.cpuPercent = cpuPercent }
}
public enum MailpitModuleError: Error, Equatable, Sendable { case unsupportedVersion(String); case verificationFailed(String); case validationFailed(String); case packageMissing(String); case portConflict(Int); case processIdentityMismatch; case processFailed(String); case unhealthy(String) }
public protocol MailpitArtifactDownloader: Sendable { func download(_ source: URL, to destination: URL) throws }
public struct SystemMailpitArtifactDownloader: MailpitArtifactDownloader {
    public init() {}
    public func download(_ source: URL, to destination: URL) throws {
        if source.isFileURL { try FileManager.default.copyItem(at: source, to: destination); return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-fL", "-o", destination.path, source.absoluteString]; let error = Pipe(); process.standardError = error; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw MailpitModuleError.validationFailed(String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "download failed") }
    }
}

public final class MailpitModule: @unchecked Sendable {
    public static let defaultVersion = MailpitManifest.official1_31_1.version
    public static let smtpPort = VaelenNetworkPorts.mailpitSMTP
    public static let httpPort = VaelenNetworkPorts.mailpitHTTP
    private let layout: VaelenFilesystemLayout; private let manifest: MailpitManifest; private let downloader: any MailpitArtifactDownloader; private let configuration: MailpitRuntimeConfiguration; private let manager = FileManager.default; private let lock = NSLock()
    private var ownedChild: OwnedChildProcess?
    private var ownedRecord: MailpitProcessRecord?
    public init(layout: VaelenFilesystemLayout = .init(), manifest: MailpitManifest = .official1_31_1, downloader: any MailpitArtifactDownloader = SystemMailpitArtifactDownloader(), configuration: MailpitRuntimeConfiguration = .init()) { self.layout = layout; self.manifest = manifest; self.downloader = downloader; self.configuration = configuration }
    public func availableVersions() -> [String] { [manifest.version] }
    public func installedVersions() -> [MailpitPackage] { guard let entries = try? manager.contentsOfDirectory(at: layout.mailpitPackagesDirectoryURL, includingPropertiesForKeys: nil) else { return [] }; return entries.compactMap { url in guard let package = try? JSONDecoder().decode(MailpitPackage.self, from: Data(contentsOf: url.appendingPathComponent(".vaelen-package.json"))), isValid(package) else { return nil }; return package }.sorted { $0.version < $1.version } }

    public func install(requestedVersion: String) throws -> MailpitPackage {
        lock.lock(); defer { lock.unlock() }; guard requestedVersion == manifest.version else { throw MailpitModuleError.unsupportedVersion(requestedVersion) }; guard manifest.platform == "macos", manifest.architecture == "arm64", manifest.artifactSHA256.count == 64 else { throw MailpitModuleError.validationFailed("invalid Mailpit manifest") }; if let existing = installedVersions().first(where: { $0.version == manifest.version }) { return existing }
        let operation = UUID().uuidString; let staging = layout.stagingDirectoryURL.appendingPathComponent("mailpit-\(manifest.version)-\(operation)", isDirectory: true); let download = layout.downloadsDirectoryURL.appendingPathComponent("mailpit-\(manifest.version)-\(operation)", isDirectory: true); try makeDirectories([layout.stagingDirectoryURL, layout.downloadsDirectoryURL, layout.mailpitPackagesDirectoryURL, staging, download]); defer { try? manager.removeItem(at: staging); try? manager.removeItem(at: download) }
        let archive = download.appendingPathComponent(manifest.artifactFile); try downloader.download(manifest.artifactURL, to: archive); guard sha256(archive) == manifest.artifactSHA256.lowercased() else { throw MailpitModuleError.verificationFailed("SHA-256 mismatch") }; let entries = try command("/usr/bin/tar", ["-tzf", archive.path]).split(whereSeparator: \.isNewline).map(String.init); guard Set(entries) == Set(["LICENSE", "README.md", "mailpit"]) else { throw MailpitModuleError.validationFailed("unexpected Mailpit archive structure") }; try extract(archive, to: staging); try validateExecutable(staging.appendingPathComponent("mailpit"), expected: manifest.version)
        let final = layout.mailpitPackagesDirectoryURL.appendingPathComponent(manifest.version, isDirectory: true); guard !manager.fileExists(atPath: final.path) else { throw MailpitModuleError.validationFailed("package directory already exists") }; try manager.moveItem(at: staging, to: final); let package = MailpitPackage(version: manifest.version, architecture: manifest.architecture, packagePath: final.path, executablePath: final.appendingPathComponent("mailpit").path, source: manifest.artifactURL.absoluteString, artifactSHA256: manifest.artifactSHA256, license: manifest.license, installedAt: Date()); try atomicWrite(package, to: final.appendingPathComponent(".vaelen-package.json")); try setImmutable(final); return package
    }

    public func status() -> MailpitStatus {
        let package = installedVersions().first(where: { $0.version == manifest.version }); let paths = instancePaths()
        guard let record = processRecord(paths) ?? ownedRecord else { guard let package else { return makeStatus(state: .notInstalled, health: "not-installed", package: nil, pid: nil, paths: paths) }; let conflict = !isPortAvailable(configuration.smtpPort) ? configuration.smtpPort : !isPortAvailable(configuration.httpPort) ? configuration.httpPort : nil; let state: MailpitState = conflict == nil ? (manager.fileExists(atPath: paths.database.path) ? .stopped : .installed) : .conflict; return makeStatus(state: state, health: conflict.map { "port-conflict-\($0)" } ?? (state == .installed ? "installed" : "stopped"), package: package, pid: nil, paths: paths) }
        if let child = ownedChild, child.processIdentifier == record.pid, ownedRecord == record, !child.isRunningAndReapedIfExited() {
            guard isPortAvailable(record.smtpPort), isPortAvailable(record.httpPort) else {
                return makeStatus(state: .unhealthy, health: "listener-release-incomplete", package: package, pid: nil, paths: paths, record: record)
            }
            ownedChild = nil; ownedRecord = nil
            try? manager.removeItem(at: paths.process)
            return makeStatus(state: package == nil ? .notInstalled : .stopped, health: "stopped", package: package, pid: nil, paths: paths)
        }
        guard processExists(record.pid) else {
            if ownedChild?.processIdentifier == record.pid { _ = ownedChild?.isRunningAndReapedIfExited(); ownedChild = nil; ownedRecord = nil }
            guard isPortAvailable(record.smtpPort), isPortAvailable(record.httpPort) else {
                return makeStatus(state: .unhealthy, health: "listener-conflict-after-process-exit", package: package, pid: nil, paths: paths, record: record)
            }
            try? manager.removeItem(at: paths.process)
            return makeStatus(state: package == nil ? .notInstalled : .stopped, health: "stopped", package: package, pid: nil, paths: paths)
        }
        guard let child = ownedChild, child.processIdentifier == record.pid, ownedRecord == record,
              child.executablePath == record.executable, child.arguments == record.arguments,
              processMatches(record) else { return makeStatus(state: .unhealthy, health: "identity-unverified", package: package, pid: record.pid, paths: paths, record: record) }
        guard httpReady(port: record.httpPort), smtpReady(port: record.smtpPort) else { return makeStatus(state: .unhealthy, health: "not-ready", package: package, pid: record.pid, paths: paths) }
        return makeStatus(state: .running, health: "healthy", package: package, pid: record.pid, paths: paths, record: record)
    }

    public func start() throws -> MailpitStatus {
        guard let package = installedVersions().first(where: { $0.version == manifest.version }) else { throw MailpitModuleError.packageMissing(manifest.version) }; let current = status(); if current.state == .running { return current }; if current.state == .unhealthy, let pid = current.pid, processExists(pid) { throw MailpitModuleError.processIdentityMismatch }; guard isPortAvailable(configuration.smtpPort) else { throw MailpitModuleError.portConflict(configuration.smtpPort) }; guard isPortAvailable(configuration.httpPort) else { throw MailpitModuleError.portConflict(configuration.httpPort) }
        let paths = instancePaths(); try makeDirectories([layout.rootURL, paths.instance, layout.mailpitLogsDirectoryURL]); if !manager.fileExists(atPath: paths.log.path) { manager.createFile(atPath: paths.log.path, contents: nil) }; let arguments = ["--smtp", "127.0.0.1:\(configuration.smtpPort)", "--listen", "127.0.0.1:\(configuration.httpPort)", "--database", paths.database.path, "--log-file", paths.log.path, "--allowed-hosts", "127.0.0.1,localhost"]; let process = Process(); process.executableURL = URL(fileURLWithPath: package.executablePath); process.arguments = arguments; process.currentDirectoryURL = layout.rootURL; let logHandle = try FileHandle(forWritingTo: paths.log); process.standardOutput = logHandle; process.standardError = logHandle; try process.run(); let child = OwnedChildProcess(process: process, label: "Mailpit"); let record = MailpitProcessRecord(pid: process.processIdentifier, user: NSUserName(), version: package.version, executable: package.executablePath, arguments: arguments, database: paths.database.path, log: paths.log.path, smtpPort: configuration.smtpPort, httpPort: configuration.httpPort, startedAt: processStartIdentity(process.processIdentifier)); ownedChild = child; ownedRecord = record
        do { try atomicWrite(record, to: paths.process) } catch { throw MailpitModuleError.processFailed("Mailpit started but its process record could not be saved; retained Core ownership is available for safe stop: \(error)") }
        for _ in 0..<100 { let result = status(); if result.state == .running { return result }; if !child.isRunningAndReapedIfExited() { ownedChild = nil; ownedRecord = nil; try? manager.removeItem(at: paths.process); throw MailpitModuleError.processFailed(logText(paths.log)) }; usleep(50_000) }
        throw MailpitModuleError.unhealthy("Mailpit did not become healthy before the startup timeout; process ownership evidence was retained for retry or diagnosis")
    }

    public func stop() throws -> MailpitStatus {
        let paths = instancePaths()
        guard let record = processRecord(paths) ?? ownedRecord else { return status() }
        if let child = ownedChild, child.processIdentifier == record.pid, ownedRecord == record,
           !child.isRunningAndReapedIfExited() {
            guard isPortAvailable(record.smtpPort), isPortAvailable(record.httpPort) else {
                throw MailpitModuleError.unhealthy("Owned Mailpit child exited, but SMTP/UI listener release is incomplete; process record retained")
            }
            ownedChild = nil; ownedRecord = nil
            if manager.fileExists(atPath: paths.process.path) { try manager.removeItem(at: paths.process) }
            return status()
        }
        guard let child = ownedChild, child.processIdentifier == record.pid, ownedRecord == record,
              child.executablePath == record.executable, child.arguments == record.arguments,
              processMatches(record) else { throw MailpitModuleError.processIdentityMismatch }
        guard child.terminateAndWait(timeout: 3) else {
            throw MailpitModuleError.unhealthy("Owned Mailpit PID \(record.pid) did not exit after graceful termination; process record retained for retry")
        }
        guard !processExists(record.pid), isPortAvailable(record.smtpPort), isPortAvailable(record.httpPort) else {
            throw MailpitModuleError.unhealthy("Mailpit exited, but SMTP/UI listener release could not be confirmed; process record retained for diagnosis and retry")
        }
        ownedChild = nil; ownedRecord = nil
        if manager.fileExists(atPath: paths.process.path) { try manager.removeItem(at: paths.process) }
        let result = status()
        guard result.state == .stopped || result.state == .installed else { throw MailpitModuleError.unhealthy("Mailpit stopped, but provider status is \(result.health)") }
        return result
    }
    public func instanceDatabasePath() -> String { instancePaths().database.path }

    private struct MailpitProcessRecord: Codable, Equatable { let pid: Int32; let user: String; let version: String; let executable: String; let arguments: [String]; let database: String; let log: String; let smtpPort: Int; let httpPort: Int; let startedAt: String }
    private struct InstancePaths { let instance: URL; let database: URL; let process: URL; let log: URL }
    private func instancePaths() -> InstancePaths { let instance = layout.mailpitInstancesDirectoryURL.appendingPathComponent("default", isDirectory: true); return .init(instance: instance, database: instance.appendingPathComponent("messages.db"), process: instance.appendingPathComponent("process.json"), log: layout.mailpitLogsDirectoryURL.appendingPathComponent("default.log")) }
    private func makeStatus(state: MailpitState, health: String, package: MailpitPackage?, pid: Int32?, paths: InstancePaths, record: MailpitProcessRecord? = nil) -> MailpitStatus { MailpitStatus(state: state, health: health, installedVersion: package?.version, pid: pid, smtpPort: record?.smtpPort ?? configuration.smtpPort, httpPort: record?.httpPort ?? configuration.httpPort, database: record?.database ?? paths.database.path, uiEndpoint: "http://127.0.0.1:\(record?.httpPort ?? configuration.httpPort)", executablePath: package?.executablePath ?? record?.executable ?? "", uptime: pid.flatMap(processUptime), memoryBytes: pid.flatMap(processMemory), cpuPercent: pid.flatMap(processCPU)) }
    private func processRecord(_ paths: InstancePaths) -> MailpitProcessRecord? { try? JSONDecoder().decode(MailpitProcessRecord.self, from: Data(contentsOf: paths.process)) }
    private func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func processMatches(_ record: MailpitProcessRecord) -> Bool { guard processExists(record.pid) else { return false }; let commandLine = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "command="])) ?? ""; let user = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "user="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; let start = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "lstart="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; return user == record.user && commandLine.contains(record.executable) && record.arguments.allSatisfy { commandLine.contains($0) } && start == record.startedAt }
    private func connect(port: Int) -> Int32? { let descriptor = socket(AF_INET, SOCK_STREAM, 0); guard descriptor >= 0 else { return nil }; var timeout = timeval(tv_sec: 0, tv_usec: 250_000); setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")); let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }; guard result == 0 else { close(descriptor); return nil }; return descriptor }
    private func httpReady(port: Int) -> Bool { guard let descriptor = connect(port: port) else { return false }; defer { close(descriptor) }; guard sendAll(descriptor, data: Data("GET /readyz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)) else { return false }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024); while true { let count = recv(descriptor, &buffer, buffer.count, 0); if count <= 0 { break }; data.append(buffer, count: count) }; return String(data: data, encoding: .utf8)?.contains(" 200 ") == true }
    private func smtpReady(port: Int) -> Bool { guard let descriptor = connect(port: port) else { return false }; defer { close(descriptor) }; var buffer = [UInt8](repeating: 0, count: 512); let count = recv(descriptor, &buffer, buffer.count, 0); return count > 3 && String(decoding: buffer.prefix(count), as: UTF8.self).hasPrefix("220") }
    private func sendAll(_ descriptor: Int32, data: Data) -> Bool { data.withUnsafeBytes { buffer in var offset = 0; while offset < buffer.count { let sent = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0); if sent <= 0 { return false }; offset += sent }; return true } }
    private func isPortAvailable(_ port: Int) -> Bool { guard connect(port: port) == nil else { return false }; let descriptor = socket(AF_INET, SOCK_STREAM, 0); guard descriptor >= 0 else { return false }; defer { close(descriptor) }; var reuse: Int32 = 1; setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)); var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")); return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
    private func validateExecutable(_ url: URL, expected: String) throws { guard manager.isExecutableFile(atPath: url.path), try command("/usr/bin/file", [url.path]).contains("Mach-O 64-bit executable arm64"), try command(url.path, ["version"]).contains(expected), !(try command("/usr/bin/otool", ["-L", url.path])).contains("/opt/homebrew/") else { throw MailpitModuleError.validationFailed("unexpected Mailpit executable") } }
    private func extract(_ archive: URL, to directory: URL) throws { let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); process.arguments = ["-xzf", archive.path, "-C", directory.path]; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw MailpitModuleError.validationFailed("archive extraction failed") } }
    private func setImmutable(_ url: URL) throws { let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]); while let item = enumerator?.nextObject() as? URL { let directory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true; try manager.setAttributes([.posixPermissions: directory || item.lastPathComponent == "mailpit" ? 0o555 : 0o444], ofItemAtPath: item.path) }; try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path) }
    private func isValid(_ package: MailpitPackage) -> Bool { package.version == manifest.version && package.architecture == "arm64" && package.artifactSHA256 == manifest.artifactSHA256 && manager.isExecutableFile(atPath: package.executablePath) && package.packagePath == layout.mailpitPackagesDirectoryURL.appendingPathComponent(package.version).path }
    private func sha256(_ url: URL) -> String? { try? command("/usr/bin/shasum", ["-a", "256", url.path]).split(separator: " ").first.map(String.init) }
    private func command(_ path: String, _ arguments: [String]) throws -> String { let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe; try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw MailpitModuleError.validationFailed(String(data: data, encoding: .utf8) ?? path) }; return String(data: data, encoding: .utf8) ?? "" }
    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws { try makeDirectories([url.deletingLastPathComponent()]); try JSONEncoder().encode(value).write(to: url, options: .atomic) }
    private func makeDirectories(_ urls: [URL]) throws { for url in urls { try manager.createDirectory(at: url, withIntermediateDirectories: true); try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) } }
    private func processStartIdentity(_ pid: Int32) -> String { (try? command("/bin/ps", ["-p", "\(pid)", "-o", "lstart="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private func processUptime(_ pid: Int32) -> Int? { processExists(pid) ? 0 : nil }
    private func processMemory(_ pid: Int32) -> UInt64? { guard let value = try? command("/bin/ps", ["-p", "\(pid)", "-o", "rss="]).trimmingCharacters(in: .whitespacesAndNewlines), let kb = UInt64(value) else { return nil }; return kb * 1024 }
    private func processCPU(_ pid: Int32) -> Double? { guard let value = try? command("/bin/ps", ["-p", "\(pid)", "-o", "%cpu="]).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }; return Double(value) }
    private func logText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}
