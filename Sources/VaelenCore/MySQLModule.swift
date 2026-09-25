import Foundation
import Darwin

public struct MySQLManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let version: String
    public let platform: String
    public let architecture: String
    public let artifactFile: String
    public let artifactURL: URL
    public let artifactSHA256: String
    public let signatureURL: URL
    public let license: String

    public static let official8_4_11 = MySQLManifest(
        version: "8.4.11",
        platform: "macos",
        architecture: "arm64",
        artifactFile: "mysql-8.4.11-macos15-arm64.tar.gz",
        artifactURL: URL(string: "https://dev.mysql.com/get/Downloads/MySQL-8.4/mysql-8.4.11-macos15-arm64.tar.gz")!,
        artifactSHA256: "b96e00493bc3499b9ffd7f08d65c5d64933af0383a8287d9873b64f94c2d6009",
        signatureURL: URL(string: "https://dev.mysql.com/downloads/gpg/?file=mysql-8.4.11-macos15-arm64.tar.gz&p=23")!,
        license: "GPL-2.0"
    )

    public init(schemaVersion: Int = 1, version: String, platform: String, architecture: String, artifactFile: String, artifactURL: URL, artifactSHA256: String, signatureURL: URL, license: String) {
        self.schemaVersion = schemaVersion; self.version = version; self.platform = platform; self.architecture = architecture; self.artifactFile = artifactFile; self.artifactURL = artifactURL; self.artifactSHA256 = artifactSHA256; self.signatureURL = signatureURL; self.license = license
    }
}

public struct MySQLPackage: Codable, Equatable, Sendable {
    public let version: String
    public let architecture: String
    public let packagePath: String
    public let serverPath: String
    public let clientPath: String
    public let adminPath: String
    public let source: String
    public let artifactSHA256: String
    public let signatureURL: String
    public let license: String
    public let installedAt: Date
}

public enum MySQLState: String, Codable, Sendable { case notInstalled, installed, stopped, starting, running, unhealthy, conflict }

public struct MySQLStatus: Codable, Equatable, Sendable {
    public let state: MySQLState
    public let health: String
    public let installedVersion: String?
    public let selectedVersion: String?
    public let pid: Int32?
    public let port: Int
    public let socket: String
    public let datadir: String
    public let executablePath: String
    public let uptime: Int?
    public let memoryBytes: UInt64?
    public let cpuPercent: Double?
    /// Non-system databases observed through Vaelen's private local socket.
    /// Nil means the catalog could not be observed; an empty array is an
    /// authoritative observation that no project databases exist.
    public let databases: [String]?

    public init(state: MySQLState, health: String, installedVersion: String?, selectedVersion: String?, pid: Int32?, port: Int, socket: String, datadir: String, executablePath: String, uptime: Int? = nil, memoryBytes: UInt64? = nil, cpuPercent: Double? = nil, databases: [String]? = nil) {
        self.state = state; self.health = health; self.installedVersion = installedVersion; self.selectedVersion = selectedVersion; self.pid = pid; self.port = port; self.socket = socket; self.datadir = datadir; self.executablePath = executablePath; self.uptime = uptime; self.memoryBytes = memoryBytes; self.cpuPercent = cpuPercent; self.databases = databases
    }
}

public enum MySQLModuleError: Error, Equatable, Sendable {
    case unsupportedVersion(String)
    case unsupportedArchitecture(String)
    case verificationFailed(String)
    case validationFailed(String)
    case packageMissing(String)
    case instanceVersionMismatch(expected: String, actual: String)
    case notInitialized
    case alreadyInitialized
    case partialInitialization
    case portConflict(Int)
    case processIdentityMismatch
    case processFailed(String)
    case credentialsUnavailable
}

public protocol MySQLArtifactDownloader: Sendable { func download(_ source: URL, to destination: URL) throws }

public struct SystemMySQLArtifactDownloader: MySQLArtifactDownloader {
    public init() {}
    public func download(_ source: URL, to destination: URL) throws {
        if source.isFileURL { try FileManager.default.copyItem(at: source, to: destination); return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-fL", "-o", destination.path, source.absoluteString]
        let error = Pipe(); process.standardError = error; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MySQLModuleError.validationFailed(String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "download failed") }
    }
}

public final class MySQLModule: @unchecked Sendable {
    public static let defaultVersion = MySQLManifest.official8_4_11.version
    public static let defaultPort = 3306
    private let layout: VaelenFilesystemLayout
    private let manifest: MySQLManifest
    private let downloader: any MySQLArtifactDownloader
    private let port: Int
    private let instanceName: String
    private let tcpEnabled: Bool
    private let packageOverride: MySQLPackage?
    private let clientCommandTimeout: TimeInterval
    var shutdownTimeout: TimeInterval
    private let manager = FileManager.default
    private let lock = NSLock()
    private var ownedServer: OwnedChildProcess?

    public convenience init(layout: VaelenFilesystemLayout, manifest: MySQLManifest = .official8_4_11, downloader: any MySQLArtifactDownloader = SystemMySQLArtifactDownloader(), port: Int = MySQLModule.defaultPort) {
        self.init(layout: layout, manifest: manifest, downloader: downloader, port: port, instanceName: "default", tcpEnabled: true, packageOverride: nil, clientCommandTimeout: 10, shutdownTimeout: 5)
    }

    init(layout: VaelenFilesystemLayout, manifest: MySQLManifest = .official8_4_11, downloader: any MySQLArtifactDownloader = SystemMySQLArtifactDownloader(), port: Int = MySQLModule.defaultPort, instanceName: String, tcpEnabled: Bool, packageOverride: MySQLPackage? = nil, clientCommandTimeout: TimeInterval = 10, shutdownTimeout: TimeInterval = 8) {
        self.layout = layout; self.manifest = manifest; self.downloader = downloader; self.port = port; self.instanceName = instanceName; self.tcpEnabled = tcpEnabled; self.packageOverride = packageOverride; self.clientCommandTimeout = clientCommandTimeout; self.shutdownTimeout = shutdownTimeout
    }

    public func availableVersions() -> [String] { [manifest.version] }

    public func installedVersions() -> [MySQLPackage] {
        if let packageOverride {
            return packageOverride.version == manifest.version && packageOverride.architecture == manifest.architecture && packageOverride.artifactSHA256 == manifest.artifactSHA256 && manager.isExecutableFile(atPath: packageOverride.serverPath) && manager.isExecutableFile(atPath: packageOverride.clientPath) && manager.isExecutableFile(atPath: packageOverride.adminPath) ? [packageOverride] : []
        }
        guard let entries = try? manager.contentsOfDirectory(at: layout.mysqlPackagesDirectoryURL, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { url in
            guard let package = try? JSONDecoder().decode(MySQLPackage.self, from: Data(contentsOf: url.appendingPathComponent(".vaelen-package.json"))), isValid(package) else { return nil }
            return package
        }.sorted { $0.version < $1.version }
    }

    public func install(requestedVersion: String) throws -> MySQLPackage {
        lock.lock(); defer { lock.unlock() }
        guard requestedVersion == manifest.version else { throw MySQLModuleError.unsupportedVersion(requestedVersion) }
        guard manifest.platform == "macos", manifest.architecture == "arm64", manifest.artifactSHA256.count == 64 else { throw MySQLModuleError.validationFailed("invalid MySQL manifest") }
        if let existing = installedVersions().first(where: { $0.version == manifest.version }) { return existing }
        let operation = UUID().uuidString
        let staging = layout.stagingDirectoryURL.appendingPathComponent("mysql-\(manifest.version)-\(operation)", isDirectory: true)
        let download = layout.downloadsDirectoryURL.appendingPathComponent("mysql-\(manifest.version)-\(operation)", isDirectory: true)
        try makeDirectories([layout.stagingDirectoryURL, layout.downloadsDirectoryURL, layout.mysqlPackagesDirectoryURL, staging, download])
        defer { try? manager.removeItem(at: staging); try? manager.removeItem(at: download) }
        let archive = download.appendingPathComponent(manifest.artifactFile)
        try downloader.download(manifest.artifactURL, to: archive)
        guard sha256(archive) == manifest.artifactSHA256.lowercased() else { throw MySQLModuleError.verificationFailed("SHA-256 mismatch") }
        try extract(archive, to: staging)
        let extracted = staging.appendingPathComponent("mysql-\(manifest.version)-macos15-arm64", isDirectory: true)
        let server = extracted.appendingPathComponent("bin/mysqld")
        let client = extracted.appendingPathComponent("bin/mysql")
        let admin = extracted.appendingPathComponent("bin/mysqladmin")
        try validateExecutable(server, expected: manifest.version)
        try validateExecutable(client, expected: manifest.version)
        try validateExecutable(admin, expected: manifest.version)
        guard try !command("/usr/bin/otool", ["-L", server.path]).contains("/opt/homebrew/") else { throw MySQLModuleError.validationFailed("unexpected Homebrew dependency") }
        _ = try? command("/usr/bin/codesign", ["--verify", "--deep", "--strict", server.path])
        let final = layout.mysqlPackagesDirectoryURL.appendingPathComponent(manifest.version, isDirectory: true)
        guard !manager.fileExists(atPath: final.path) else { throw MySQLModuleError.validationFailed("package directory already exists") }
        try manager.moveItem(at: extracted, to: final)
        let package = MySQLPackage(version: manifest.version, architecture: manifest.architecture, packagePath: final.path, serverPath: final.appendingPathComponent("bin/mysqld").path, clientPath: final.appendingPathComponent("bin/mysql").path, adminPath: final.appendingPathComponent("bin/mysqladmin").path, source: manifest.artifactURL.absoluteString, artifactSHA256: manifest.artifactSHA256, signatureURL: manifest.signatureURL.absoluteString, license: manifest.license, installedAt: Date())
        try atomicWrite(package, to: final.appendingPathComponent(".vaelen-package.json"))
        try setImmutable(final)
        return package
    }

    public func use(_ version: String) throws -> MySQLPackage {
        guard let package = installedVersions().first(where: { $0.version == version }) else { throw MySQLModuleError.packageMissing(version) }
        if let metadata = instanceMetadata(), metadata.initialized, metadata.initializedVersion != package.version { throw MySQLModuleError.instanceVersionMismatch(expected: metadata.initializedVersion, actual: package.version) }
        try makeDirectories([layout.configurationDirectoryURL]); try atomicWrite(package.version, to: layout.configurationDirectoryURL.appendingPathComponent("mysql-default.json")); return package
    }

    public func selectedVersion() -> String? { try? String(contentsOf: layout.configurationDirectoryURL.appendingPathComponent("mysql-default.json"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }

    public func initialize() throws {
        guard let package = selectedPackage() else { throw MySQLModuleError.packageMissing(manifest.version) }
        if let metadata = instanceMetadata(), metadata.initialized { throw MySQLModuleError.alreadyInitialized }
        let paths = instancePaths(package: package); try makeDirectories([paths.instance, paths.data, layout.mysqlLogsDirectoryURL, layout.rootURL.appendingPathComponent("runtime/sockets/mysql", isDirectory: true), layout.rootURL.appendingPathComponent("runtime/pids/mysql", isDirectory: true)])
        let contents = (try? manager.contentsOfDirectory(atPath: paths.data.path)) ?? []
        guard contents.isEmpty else { throw MySQLModuleError.partialInitialization }
        let log = paths.log; manager.createFile(atPath: log.path, contents: nil)
        let process = Process(); process.executableURL = URL(fileURLWithPath: package.serverPath); process.arguments = ["--no-defaults", "--initialize-insecure", "--basedir=\(package.packagePath)", "--datadir=\(paths.data.path)", "--log-error=\(log.path)"]; try process.run()
        let initializationDeadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < initializationDeadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline { usleep(20_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw MySQLModuleError.processFailed("MySQL initialization timed out; existing data files were left intact for inspection")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MySQLModuleError.processFailed(logText(paths.log)) }
        try writeConfig(package: package, paths: paths)
        let metadata = MySQLInstanceMetadata(version: package.version, initializedVersion: package.version, initialized: true, port: port, socket: paths.socket.path, datadir: paths.data.path, rootPasswordMode: "empty")
        try atomicWrite(metadata, to: paths.metadata)
        try writeCredentials(paths: paths, password: "")
        try start(package: package, paths: paths, allowExpiredPassword: false)
        _ = try stop()
    }

    public func status() -> MySQLStatus {
        let package = selectedPackage(); let paths = instancePaths(package: package); let record = processRecord(paths)
        let base = (package?.version, selectedVersion(), paths.socket.path, paths.data.path, package?.serverPath ?? "")
         guard let record else { return MySQLStatus(state: package == nil ? .notInstalled : (instanceMetadata()?.initialized == true ? .stopped : .installed), health: package == nil ? "not-installed" : (instanceMetadata()?.initialized == true ? "stopped" : "not-initialized"), installedVersion: base.0, selectedVersion: base.1, pid: nil, port: instanceMetadata()?.port ?? port, socket: base.2, datadir: base.3, executablePath: base.4) }
        if let child = ownedServer, child.processIdentifier == record.pid, !child.isRunningAndReapedIfExited() {
            guard record.executable == child.executablePath, record.arguments == child.arguments, record.datadir == paths.data.path, record.socket == paths.socket.path else {
                return MySQLStatus(state: .unhealthy, health: "identity-unverified", installedVersion: base.0, selectedVersion: base.1, pid: record.pid, port: record.port, socket: record.socket, datadir: record.datadir, executablePath: record.executable)
            }
            if child.hasLiveOwnedDescendants {
                return MySQLStatus(state: .unhealthy, health: "server-exited-children-running", installedVersion: base.0, selectedVersion: base.1, pid: record.pid, port: record.port, socket: record.socket, datadir: record.datadir, executablePath: record.executable)
            }
            clearExitedRecord(record, paths: paths)
            ownedServer = nil
            return MySQLStatus(state: .stopped, health: "stopped", installedVersion: base.0, selectedVersion: base.1, pid: nil, port: record.port, socket: record.socket, datadir: record.datadir, executablePath: record.executable)
        }
        guard processExists(record.pid) else { clearExitedRecord(record, paths: paths); return MySQLStatus(state: .stopped, health: "stopped", installedVersion: base.0, selectedVersion: base.1, pid: nil, port: record.port, socket: record.socket, datadir: record.datadir, executablePath: record.executable) }
        guard processMatches(record) else { return MySQLStatus(state: .unhealthy, health: "identity-unverified", installedVersion: base.0, selectedVersion: base.1, pid: record.pid, port: record.port, socket: record.socket, datadir: record.datadir, executablePath: record.executable) }
        guard isPortOwnedByRecord(record) else { return MySQLStatus(state: .conflict, health: "port-conflict", installedVersion: base.0, selectedVersion: base.1, pid: record.pid, port: record.port, socket: record.socket, datadir: record.datadir, executablePath: record.executable) }
        let healthy = (try? ping(paths: paths)) == true
        let databases = healthy ? (try? databaseNames(package: package, paths: paths)) : nil
        return MySQLStatus(state: healthy ? .running : .unhealthy, health: healthy ? "healthy" : "not-ready", installedVersion: base.0, selectedVersion: base.1, pid: record.pid, port: record.port, socket: record.socket, datadir: record.datadir, executablePath: record.executable, uptime: processUptime(record.pid), memoryBytes: processMemory(record.pid), cpuPercent: processCPU(record.pid), databases: databases)
    }

    public func start() throws -> MySQLStatus {
        guard let package = selectedPackage() else { throw MySQLModuleError.packageMissing(manifest.version) }; guard instanceMetadata()?.initialized == true else { throw MySQLModuleError.notInitialized }
        let paths = instancePaths(package: package); let current = status(); if current.state == .running { return current }; if current.state == .unhealthy || current.state == .conflict { if let record = processRecord(paths), processExists(record.pid) { throw MySQLModuleError.processIdentityMismatch }; try? manager.removeItem(at: paths.process) }
        if tcpEnabled, !isPortAvailable(port) { throw MySQLModuleError.portConflict(port) }
        if processRecord(paths) == nil { try reconcileExitedRuntimeArtifacts(paths: paths, package: package) }
        try writeConfig(package: package, paths: paths)
        try start(package: package, paths: paths, allowExpiredPassword: false)
        if let metadata = instanceMetadata(), metadata.rootPasswordMode != "empty" {
            try normalizeLegacyRootPassword(package: package, paths: paths, metadata: metadata)
        } else if let metadata = instanceMetadata(), metadata.port != (tcpEnabled ? port : 0) {
            try saveMetadata(metadata, paths: paths, port: tcpEnabled ? port : 0, rootPasswordMode: "empty")
        }
        return status()
    }

    public func stop() throws -> MySQLStatus {
        let paths = instancePaths(package: selectedPackage())
        let observed = status()
        guard let record = processRecord(paths) else { return observed }
        let child = ownedServer
        guard processExists(record.pid), processMatches(record), socketMatches(record), isPortOwnedByRecord(record) else {
            // Never discard the only ownership evidence while a process with
            // this PID is still alive. A later Core cannot safely adopt or
            // stop it without a matching identity, but removing this record
            // would make the live instance untraceable and block recovery.
            if processExists(record.pid) {
                throw MySQLModuleError.processIdentityMismatch
            }
            removeOwnedFiles(record)
            try? manager.removeItem(at: paths.process)
            ownedServer = nil
            return MySQLStatus(state: .stopped, health: "stopped", installedVersion: observed.installedVersion, selectedVersion: observed.selectedVersion, pid: nil, port: record.port, socket: record.socket, datadir: record.datadir, executablePath: record.executable)
        }
        guard let package = selectedPackage(), FileManager.default.fileExists(atPath: paths.credentials.path) else { throw MySQLModuleError.credentialsUnavailable }
        // mysqladmin contacts only the recorded, inode-verified Unix socket;
        // no TCP port is used for a shutdown request.
        try runClient(package.adminPath, paths: paths, arguments: ["--defaults-extra-file=\(paths.credentials.path)", "shutdown"], timeout: min(clientCommandTimeout, 3))
        let deadline = Date().addingTimeInterval(shutdownTimeout)
        while Date() < deadline {
            let masterRunning = processMatches(record)
            if let child, child.processIdentifier == record.pid, !child.isRunningAndReapedIfExited() {
                guard !child.hasLiveOwnedDescendants else { usleep(50_000); continue }
            }
            if !masterRunning {
                removeOwnedFiles(record)
                guard !socketMatches(record), !pidFileMatches(record, paths: paths) else { throw MySQLModuleError.processFailed("MySQL PID \(record.pid) exited but its owned socket or PID file remains; process record retained") }
                ownedServer = nil
                try manager.removeItem(at: paths.process)
                return status()
            }
            usleep(50_000)
        }
        throw MySQLModuleError.processFailed("MySQL PID \(record.pid) did not stop within the graceful shutdown timeout; process record retained")
    }

    private struct MySQLInstanceMetadata: Codable {
        let version: String
        let initializedVersion: String
        let initialized: Bool
        let port: Int
        let socket: String
        let datadir: String
        var rootPasswordMode: String?

        init(version: String, initializedVersion: String, initialized: Bool, port: Int, socket: String, datadir: String, rootPasswordMode: String? = nil) {
            self.version = version
            self.initializedVersion = initializedVersion
            self.initialized = initialized
            self.port = port
            self.socket = socket
            self.datadir = datadir
            self.rootPasswordMode = rootPasswordMode
        }
    }
    private struct MySQLProcessRecord: Codable { let pid: Int32; let version: String; let executable: String; let arguments: [String]; let port: Int; let socket: String; let datadir: String; let startedAt: String; let socketDevice: Int64?; let socketInode: Int64?; let pidFile: String?; let pidFileDevice: Int64?; let pidFileInode: Int64?; let tcpEnabled: Bool? }
    private struct InstancePaths { let instance: URL; let data: URL; let config: URL; let metadata: URL; let credentials: URL; let process: URL; let socket: URL; let log: URL }

    private func selectedPackage() -> MySQLPackage? { let version = selectedVersion() ?? manifest.version; return installedVersions().first { $0.version == version } }
    private func instancePaths(package: MySQLPackage?) -> InstancePaths { let instance = layout.mysqlInstancesDirectoryURL.appendingPathComponent(instanceName, isDirectory: true); let runtime = layout.rootURL.appendingPathComponent("runtime", isDirectory: true); let preferredSocket = runtime.appendingPathComponent("sockets/mysql/\(instanceName).sock"); let socket = preferredSocket.path.utf8.count < 103 ? preferredSocket : URL(fileURLWithPath: "/tmp/vaelen-mysql-\(stableSocketSuffix())-\(instanceName).sock"); return .init(instance: instance, data: instance.appendingPathComponent("data", isDirectory: true), config: instance.appendingPathComponent("my.cnf"), metadata: instance.appendingPathComponent("metadata.json"), credentials: instance.appendingPathComponent("client.cnf"), process: instance.appendingPathComponent("process.json"), socket: socket, log: layout.mysqlLogsDirectoryURL.appendingPathComponent("\(instanceName).log")) }
    private func instanceMetadata() -> MySQLInstanceMetadata? {
        let url = instancePaths(package: selectedPackage()).metadata
        guard manager.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MySQLInstanceMetadata.self, from: data)
    }
       private func writeConfig(package: MySQLPackage, paths: InstancePaths) throws { var directories = [paths.instance, paths.config.deletingLastPathComponent(), layout.mysqlLogsDirectoryURL, paths.process.deletingLastPathComponent(), paths.instance.appendingPathComponent("tmp")]; let socketParent = paths.socket.deletingLastPathComponent(); if socketParent.path != "/tmp" { directories.append(socketParent) }; try makeDirectories(directories); let tcp = tcpEnabled ? "bind-address=127.0.0.1\nport=\(port)\n" : "skip-networking\n"; let content = "[mysqld]\nbasedir=\(package.packagePath)\ndatadir=\(paths.data.path)\nsocket=\(paths.socket.path)\npid-file=\(paths.instance.appendingPathComponent("mysqld.pid").path)\nlog-error=\(paths.log.path)\n\(tcp)tmpdir=\(paths.instance.appendingPathComponent("tmp").path)\nmysqlx=OFF\n"; try atomicWrite(content, to: paths.config) }
       private func start(package: MySQLPackage, paths: InstancePaths, allowExpiredPassword: Bool) throws {
          var directories = [paths.instance, layout.mysqlLogsDirectoryURL]
          if paths.socket.deletingLastPathComponent().path != "/tmp" { directories.append(paths.socket.deletingLastPathComponent()) }
          try makeDirectories(directories)
          guard !manager.fileExists(atPath: paths.socket.path), !manager.fileExists(atPath: paths.instance.appendingPathComponent("mysqld.pid").path) else { throw MySQLModuleError.processFailed("MySQL socket or PID path already exists; refusing to replace it") }
          let logHandle = FileHandle(forWritingAtPath: paths.log.path) ?? { manager.createFile(atPath: paths.log.path, contents: nil); return try! FileHandle(forWritingTo: paths.log) }()
          let process = Process(); process.executableURL = URL(fileURLWithPath: package.serverPath); process.arguments = ["--defaults-file=\(paths.config.path)"] + (tcpEnabled ? [] : ["--skip-networking"]); process.currentDirectoryURL = layout.rootURL; process.standardOutput = logHandle; process.standardError = logHandle
          try process.run()
          let child = OwnedChildProcess(process: process, label: "MySQL \(package.version) \(instanceName)")
          ownedServer = child
          var record = MySQLProcessRecord(pid: process.processIdentifier, version: package.version, executable: package.serverPath, arguments: process.arguments ?? [], port: tcpEnabled ? port : 0, socket: paths.socket.path, datadir: paths.data.path, startedAt: processStartIdentity(process.processIdentifier), socketDevice: nil, socketInode: nil, pidFile: paths.instance.appendingPathComponent("mysqld.pid").path, pidFileDevice: nil, pidFileInode: nil, tcpEnabled: tcpEnabled)
          try atomicWrite(record, to: paths.process)
           let readinessDeadline = Date().addingTimeInterval(8)
           while Date() < readinessDeadline {
               let remaining = readinessDeadline.timeIntervalSinceNow
               if (try? ping(paths: paths, allowExpiredPassword: allowExpiredPassword, timeout: min(0.5, max(0.05, remaining)))) == true {
                   record = recordWithFileIdentities(record, paths: paths)
                   try atomicWrite(record, to: paths.process)
                   return
              }
              if !child.isRunningAndReapedIfExited() { break }
              usleep(50_000)
          }
          guard child.terminateAndWait(timeout: 8, signal: SIGTERM, waitForDescendants: true) else {
              throw MySQLModuleError.processFailed("MySQL PID \(record.pid) failed readiness and remains live; process record retained")
          }
          ownedServer = nil
          try? manager.removeItem(at: paths.process)
          removeOwnedFiles(record)
          throw MySQLModuleError.processFailed(logText(paths.log))
      }
    private func writeCredentials(paths: InstancePaths, password: String) throws { try atomicWrite("[client]\nuser=root\npassword=\(password)\nprotocol=socket\nsocket=\(paths.socket.path)\n", to: paths.credentials); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.credentials.path) }
     @discardableResult private func runClient(_ executable: String, paths: InstancePaths, arguments: [String], timeout: TimeInterval = 10) throws -> String {
         let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
         var clientArguments = arguments
         let defaultsFile = clientArguments.first(where: { $0.hasPrefix("--defaults-extra-file=") })
         clientArguments.removeAll(where: { $0.hasPrefix("--defaults-extra-file=") })
         process.arguments = (defaultsFile.map { [$0] } ?? []) + ["--protocol=socket", "--socket=\(paths.socket.path)"] + clientArguments
          let output = Pipe(); let error = Pipe(); process.standardOutput = output; process.standardError = error
         try process.run()
         let deadline = Date().addingTimeInterval(timeout)
         while process.isRunning && Date() < deadline { usleep(20_000) }
         if process.isRunning {
             process.terminate()
             let terminateDeadline = Date().addingTimeInterval(1)
             while process.isRunning && Date() < terminateDeadline { usleep(20_000) }
             if !process.isRunning { process.waitUntilExit() }
             throw MySQLModuleError.processFailed("MySQL client command timed out")
         }
          let data = output.fileHandleForReading.readDataToEndOfFile()
          let errorData = error.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          let text = String(data: data, encoding: .utf8) ?? ""
          let errorText = String(data: errorData, encoding: .utf8) ?? ""
          guard process.terminationStatus == 0 else { throw MySQLModuleError.processFailed(errorText.isEmpty ? (text.isEmpty ? "MySQL client failed" : text) : errorText) }
          return text
      }
     private func databaseNames(package: MySQLPackage?, paths: InstancePaths) throws -> [String] {
         guard let package else { throw MySQLModuleError.packageMissing(manifest.version) }
         let output = try runClient(package.clientPath, paths: paths, arguments: [
             "--defaults-extra-file=\(paths.credentials.path)", "--batch", "--skip-column-names", "-e",
             "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys') ORDER BY SCHEMA_NAME"
         ], timeout: min(clientCommandTimeout, 2))
         return output.split(whereSeparator: \.isNewline).map(String.init)
     }
     private func ping(paths: InstancePaths, allowExpiredPassword: Bool = false, timeout: TimeInterval = 0.5) throws -> Bool {
         if allowExpiredPassword { return manager.fileExists(atPath: paths.socket.path) }
         guard let package = selectedPackage() else { return false }
         let standardArguments = ["--defaults-extra-file=\(paths.credentials.path)", "--protocol=socket", "ping", "--socket=\(paths.socket.path)"]
         if try runAdminProbe(package.adminPath, arguments: standardArguments, timeout: timeout) { return true }
         guard instanceMetadata()?.rootPasswordMode == "normalizingEmpty" else { return false }
         return try runAdminProbe(package.adminPath, arguments: ["--no-defaults", "--protocol=socket", "-uroot", "--password=", "ping", "--socket=\(paths.socket.path)"], timeout: timeout)
     }
     private func runAdminProbe(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> Bool {
         let process = Process()
         process.executableURL = URL(fileURLWithPath: executable)
         process.arguments = arguments
         process.standardOutput = FileHandle.nullDevice
         process.standardError = FileHandle.nullDevice
         try process.run()
         let deadline = Date().addingTimeInterval(max(0.05, timeout))
         while process.isRunning && Date() < deadline { usleep(20_000) }
         guard !process.isRunning else {
             process.terminate()
             let terminationDeadline = Date().addingTimeInterval(0.25)
             while process.isRunning && Date() < terminationDeadline { usleep(20_000) }
             if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
             process.waitUntilExit()
             return false
         }
         process.waitUntilExit()
         return process.terminationStatus == 0
     }

     private func normalizeLegacyRootPassword(package: MySQLPackage, paths: InstancePaths, metadata: MySQLInstanceMetadata) throws {
         let transitioning = MySQLInstanceMetadata(version: metadata.version, initializedVersion: metadata.initializedVersion, initialized: metadata.initialized, port: metadata.port, socket: metadata.socket, datadir: metadata.datadir, rootPasswordMode: "normalizingEmpty")
         try atomicWrite(transitioning, to: paths.metadata)

         // Recover safely if the previous attempt changed authentication but
         // stopped before updating Vaelen's client credentials/metadata.
         let emptyCredentialWorks = (try? runClient(package.clientPath, paths: paths, arguments: ["--defaults-extra-file=\(paths.credentials.path)", "--password=", "-e", "SELECT CURRENT_USER()"])) != nil
         if !emptyCredentialWorks {
             try runClient(package.clientPath, paths: paths, arguments: ["--defaults-extra-file=\(paths.credentials.path)", "-e", "ALTER USER 'root'@'localhost' IDENTIFIED BY ''; "])
         }
         try writeCredentials(paths: paths, password: "")
         try saveMetadata(metadata, paths: paths, port: tcpEnabled ? port : 0, rootPasswordMode: "empty")
     }

     private func saveMetadata(_ metadata: MySQLInstanceMetadata, paths: InstancePaths, port: Int, rootPasswordMode: String?) throws {
         try atomicWrite(MySQLInstanceMetadata(version: metadata.version, initializedVersion: metadata.initializedVersion, initialized: metadata.initialized, port: port, socket: metadata.socket, datadir: metadata.datadir, rootPasswordMode: rootPasswordMode), to: paths.metadata)
     }
      private func processRecord(_ paths: InstancePaths) -> MySQLProcessRecord? {
          guard manager.fileExists(atPath: paths.process.path), let data = try? Data(contentsOf: paths.process) else { return nil }
          return try? JSONDecoder().decode(MySQLProcessRecord.self, from: data)
      }
     private func reconcileExitedRuntimeArtifacts(paths: InstancePaths, package: MySQLPackage) throws {
         let pidPath = paths.instance.appendingPathComponent("mysqld.pid")
         let hasPID = manager.fileExists(atPath: pidPath.path)
         let hasSocket = manager.fileExists(atPath: paths.socket.path)
         guard hasPID || hasSocket else { return }
         guard hasPID, hasSocket,
               let pidText = try? String(contentsOf: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidText), pid > 1, !processExists(pid),
               let config = try? String(contentsOf: paths.config, encoding: .utf8),
               config.contains("basedir=\(package.packagePath)\n"),
               config.contains("datadir=\(paths.data.path)\n"),
               config.contains("socket=\(paths.socket.path)\n"),
               config.contains("pid-file=\(pidPath.path)\n"),
               isOwnedSocketFile(paths.socket.path),
               isUnopenedByAnyProcess(paths.socket.path),
               !tcpEnabled || isPortAvailable(port)
         else { throw MySQLModuleError.processFailed("MySQL has stale runtime paths that could not be proven safe to reconcile; no files were removed") }
         // Only these two runtime artifacts are eligible. The data directory,
         // credentials, and instance metadata are never touched here.
         try manager.removeItem(at: paths.socket)
         try manager.removeItem(at: pidPath)
     }
     private func isOwnedSocketFile(_ path: String) -> Bool {
         var info = stat()
         return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid()
     }
     private func isUnopenedByAnyProcess(_ path: String) -> Bool {
         let process = Process(), output = Pipe()
         process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
         process.arguments = ["-t", "--", path]
         process.standardOutput = output
         process.standardError = FileHandle.nullDevice
         guard (try? process.run()) != nil else { return false }
         let data = output.fileHandleForReading.readDataToEndOfFile()
         process.waitUntilExit()
         return process.terminationStatus != 0 && data.isEmpty
     }
     private func recordWithFileIdentities(_ record: MySQLProcessRecord, paths: InstancePaths) -> MySQLProcessRecord {
         var socketInfo = stat(), pidInfo = stat()
         let socketIdentity = lstat(record.socket, &socketInfo) == 0 && (socketInfo.st_mode & S_IFMT) == S_IFSOCK ? (Int64(socketInfo.st_dev), Int64(socketInfo.st_ino)) : (nil, nil)
         let pidPath = paths.instance.appendingPathComponent("mysqld.pid").path
         let pidIdentity = lstat(pidPath, &pidInfo) == 0 && (pidInfo.st_mode & S_IFMT) == S_IFREG ? (Int64(pidInfo.st_dev), Int64(pidInfo.st_ino)) : (nil, nil)
         return MySQLProcessRecord(pid: record.pid, version: record.version, executable: record.executable, arguments: record.arguments, port: record.port, socket: record.socket, datadir: record.datadir, startedAt: record.startedAt, socketDevice: socketIdentity.0, socketInode: socketIdentity.1, pidFile: pidPath, pidFileDevice: pidIdentity.0, pidFileInode: pidIdentity.1, tcpEnabled: record.tcpEnabled)
     }
     private func socketMatches(_ record: MySQLProcessRecord) -> Bool {
         guard record.socket == instancePaths(package: selectedPackage()).socket.path, let device = record.socketDevice, let inode = record.socketInode else { return false }
         var info = stat()
         return lstat(record.socket, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid() && Int64(info.st_dev) == device && Int64(info.st_ino) == inode
     }
     private func pidFileMatches(_ record: MySQLProcessRecord, paths: InstancePaths) -> Bool {
         guard let path = record.pidFile, path == paths.instance.appendingPathComponent("mysqld.pid").path, let device = record.pidFileDevice, let inode = record.pidFileInode else { return false }
         var info = stat()
         return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && Int64(info.st_dev) == device && Int64(info.st_ino) == inode
     }
     private func removeOwnedFiles(_ record: MySQLProcessRecord) {
         if socketMatches(record) { try? manager.removeItem(atPath: record.socket) }
         if let path = record.pidFile, let paths = Optional(instancePaths(package: selectedPackage())), pidFileMatches(record, paths: paths) { try? manager.removeItem(atPath: path) }
     }
     private func clearExitedRecord(_ record: MySQLProcessRecord, paths: InstancePaths) {
         removeOwnedFiles(record)
         try? manager.removeItem(at: paths.process)
     }
    private func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func processMatches(_ record: MySQLProcessRecord) -> Bool {
        if let child = ownedServer, child.processIdentifier == record.pid {
            return child.isRunningAndReapedIfExited()
                && child.executablePath == URL(fileURLWithPath: record.executable).standardizedFileURL.path
                && child.arguments == record.arguments
                && processStartIdentity(record.pid) == record.startedAt
        }
        guard processExists(record.pid) else { return false }
        let commandLine = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "command="])) ?? ""
        return commandLine.contains(record.executable) && record.arguments.allSatisfy { commandLine.contains($0) } && processStartIdentity(record.pid) == record.startedAt
    }
    private func processStartIdentity(_ pid: Int32) -> String { (try? command("/bin/ps", ["-p", "\(pid)", "-o", "lstart="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private func isPortOwnedByRecord(_ record: MySQLProcessRecord) -> Bool { record.tcpEnabled == false || isPortAvailable(record.port) == false }
     private func isPortAvailable(_ port: Int) -> Bool {
         var address = sockaddr_in()
         address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
         address.sin_family = sa_family_t(AF_INET)
         address.sin_port = in_port_t(UInt16(port).bigEndian)
         address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
         let probe = socket(AF_INET, SOCK_STREAM, 0)
         if probe >= 0 {
             let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
             close(probe)
             if connected { return false }
         }
         let descriptor = socket(AF_INET, SOCK_STREAM, 0)
         guard descriptor >= 0 else { return false }
         defer { close(descriptor) }
         var reuse: Int32 = 1
         _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
         return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
     }
    private func waitForPortRelease(_ port: Int) { for _ in 0..<40 { if isPortAvailable(port) { return }; usleep(50_000) } }
    private func processUptime(_ pid: Int32) -> Int? { guard let start = try? command("/bin/ps", ["-p", "\(pid)", "-o", "etime="]) else { return nil }; return start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : 0 }
    private func processMemory(_ pid: Int32) -> UInt64? { guard let value = try? command("/bin/ps", ["-p", "\(pid)", "-o", "rss="]).trimmingCharacters(in: .whitespacesAndNewlines), let kb = UInt64(value) else { return nil }; return kb * 1024 }
    private func processCPU(_ pid: Int32) -> Double? { guard let value = try? command("/bin/ps", ["-p", "\(pid)", "-o", "%cpu="]).trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }; return Double(value) }
    private func stableSocketSuffix() -> String { String(layout.rootURL.path.utf8.reduce(0) { ($0 &* 31) &+ UInt64($1) }, radix: 16) }
    private func logText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    private func validateExecutable(_ path: URL, expected: String) throws { guard manager.isExecutableFile(atPath: path.path), try command("/usr/bin/file", [path.path]).contains("Mach-O 64-bit executable arm64"), try command(path.path, ["--version"]).contains(expected) else { throw MySQLModuleError.validationFailed("unexpected MySQL executable") } }
    private func extract(_ archive: URL, to directory: URL) throws { let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); process.arguments = ["-xzf", archive.path, "-C", directory.path]; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw MySQLModuleError.validationFailed("archive extraction failed") } }
    private func command(_ path: String, _ arguments: [String]) throws -> String { let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe; try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw MySQLModuleError.validationFailed(String(data: data, encoding: .utf8) ?? path) }; return String(data: data, encoding: .utf8) ?? "" }
    private func sha256(_ url: URL) -> String? { try? command("/usr/bin/shasum", ["-a", "256", url.path]).split(separator: " ").first.map(String.init) }
    private func makeDirectories(_ urls: [URL]) throws { for url in urls { try manager.createDirectory(at: url, withIntermediateDirectories: true); try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) } }
    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws { try atomicWrite(try JSONEncoder().encode(value), to: url) }
    private func atomicWrite(_ value: String, to url: URL) throws { try atomicWrite(Data(value.utf8), to: url) }
    private func atomicWrite(_ data: Data, to url: URL) throws { let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp"); try data.write(to: temp, options: .atomic); if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temp) } else { try manager.moveItem(at: temp, to: url) } }
     private func setImmutable(_ url: URL) throws { let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]); while let item = enumerator?.nextObject() as? URL { let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true; let executable = item.path.hasSuffix("/bin/mysqld") || item.path.hasSuffix("/bin/mysql") || item.path.hasSuffix("/bin/mysqladmin"); try manager.setAttributes([.posixPermissions: isDirectory || executable ? 0o555 : 0o444], ofItemAtPath: item.path) }; try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path) }
    private func isValid(_ package: MySQLPackage) -> Bool { package.version == manifest.version && package.architecture == "arm64" && package.artifactSHA256 == manifest.artifactSHA256 && manager.isExecutableFile(atPath: package.serverPath) && manager.isExecutableFile(atPath: package.clientPath) && manager.isExecutableFile(atPath: package.adminPath) && package.packagePath == layout.mysqlPackagesDirectoryURL.appendingPathComponent(package.version).path }
}
