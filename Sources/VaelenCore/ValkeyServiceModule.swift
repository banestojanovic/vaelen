import Foundation
import Darwin

public enum ValkeyServiceError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedPackage
    case invalidPackage(String)
    case missingInstance
    case existingInstanceMismatch
    case nonemptyDataDirectory
    case portConflict(Int)
    case processIdentityMismatch
    case processFailure(String)
    case runningOrClaimed

    public var errorDescription: String? {
        switch self {
        case .unsupportedPackage: "Valkey package valkey-9.1.2 is unavailable."
        case .invalidPackage(let reason): "Valkey package validation failed: \(reason)"
        case .missingInstance: "The named Valkey instance does not exist."
        case .existingInstanceMismatch: "The named Valkey instance already exists with different settings."
        case .nonemptyDataDirectory: "The Valkey data directory is not empty; existing files were preserved."
        case .portConflict(let port): "Loopback port \(port) is already in use."
        case .processIdentityMismatch: "The Valkey process identity could not be verified; it was left untouched."
        case .processFailure(let reason): reason
        case .runningOrClaimed: "The Valkey instance must be stopped and unclaimed before removal."
        }
    }
}

public struct ValkeyServiceStatus: Equatable, Sendable {
    public let record: ServiceInstanceRecord?
    public let health: String
    public let pid: Int32?
    public let queryOutput: String?
}

public final class ValkeyServiceModule: @unchecked Sendable {
    public static let packageIdentifier = "valkey-9.1.2"
    private let layout: VaelenFilesystemLayout
    private let repository: ServiceInstanceRepository
    private let packageSource: URL
    private let shutdownTimeout: TimeInterval
    private let manager = FileManager.default
    private let lock = NSRecursiveLock()
    private var ownedProcesses: [String: Process] = [:]

    public init(layout: VaelenFilesystemLayout, repository: ServiceInstanceRepository, packageRoot: URL? = nil, shutdownTimeout: TimeInterval = 10) {
        self.layout = layout
        self.repository = repository
        self.packageSource = (packageRoot ?? layout.valkeyPackagesDirectoryURL.appendingPathComponent(Self.packageIdentifier, isDirectory: true)).resolvingSymlinksInPath().standardizedFileURL
        self.shutdownTimeout = shutdownTimeout
    }

    public static func availableLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ValkeyServiceError.processFailure("Could not allocate a loopback socket.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw ValkeyServiceError.processFailure("Could not reserve a loopback port.") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard read == 0 else { throw ValkeyServiceError.processFailure("Could not read the reserved loopback port.") }
        return Int(UInt16(bigEndian: actual.sin_port))
    }

    public func create(id: ServiceInstanceID, port: Int) throws -> ServiceInstanceRecord {
        lock.lock(); defer { lock.unlock() }
        guard id.kind == .valkey, (1...65535).contains(port) else { throw SQLiteStateError.invalidRecord }
        _ = try validatedPackage()
        let paths = instancePaths(id)
        let record = try ServiceInstanceRecord(id: id, packageIdentifier: Self.packageIdentifier, endpoint: .valkey(port: port), dataDirectory: paths.data.path)
        if let existing = try repository.instance(id) {
            guard existing == record else { throw ValkeyServiceError.existingInstanceMismatch }
            try repository.saveManuallyClaimedInstance(existing)
            return existing
        }
        try manager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if manager.fileExists(atPath: paths.data.path) {
            let contents = try manager.contentsOfDirectory(atPath: paths.data.path)
            guard contents.isEmpty else { throw ValkeyServiceError.nonemptyDataDirectory }
        } else {
            try manager.createDirectory(at: paths.data, withIntermediateDirectories: true)
        }
        try repository.saveManuallyClaimedInstance(record)
        return record
    }

    public func status(id: ServiceInstanceID) throws -> ValkeyServiceStatus {
        lock.lock(); defer { lock.unlock() }
        guard let record = try repository.instance(id) else { return ValkeyServiceStatus(record: nil, health: "not-created", pid: nil, queryOutput: nil) }
        guard let evidence = readEvidence(id) else {
            return ValkeyServiceStatus(record: record, health: portIsFree(record.endpoint.portNumbers.first) ? "stopped" : "identity-unverified", pid: nil, queryOutput: nil)
        }
        guard processExists(evidence.pid) else {
            try? manager.removeItem(at: instancePaths(id).evidence)
            return ValkeyServiceStatus(record: record, health: "stopped", pid: nil, queryOutput: nil)
        }
        guard processMatches(evidence, record: record) else { return ValkeyServiceStatus(record: record, health: "identity-unverified", pid: evidence.pid, queryOutput: nil) }
        guard let package = try? validatedPackage(), package.appendingPathComponent("bin/valkey-cli").path == evidence.cliPath else {
            return ValkeyServiceStatus(record: record, health: "identity-unverified", pid: evidence.pid, queryOutput: nil)
        }
        let cli = package.appendingPathComponent("bin/valkey-cli")
        let args = ["-h", "127.0.0.1", "-p", "\(record.endpoint.portNumbers.first)", "--raw"]
        let info = try? run(cli, args + ["INFO", "server"], timeout: 8)
        let directory = try? run(cli, args + ["CONFIG", "GET", "dir"], timeout: 8)
        let output = info?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let values = directory?.output.split(whereSeparator: \.isNewline).map(String.init) ?? []
        let infoLines = output.split(whereSeparator: \.isNewline).map(String.init)
        let version = infoLines.first(where: { $0.hasPrefix("valkey_version:") }).map { $0.dropFirst("valkey_version:".count) }
        let expectedPort = record.endpoint.portNumbers.first
        guard info?.status == 0, directory?.status == 0, version == "9.1.2", infoLines.contains("tcp_port:\(expectedPort)"), infoLines.contains(where: { $0.contains("bind=127.0.0.1,port=\(expectedPort)") }), infoLines.contains("process_id:\(evidence.pid)"), values.count >= 2, values[0] == "dir",
              URL(fileURLWithPath: values[1]).standardizedFileURL.path == URL(fileURLWithPath: record.dataDirectory).standardizedFileURL.path else {
            return ValkeyServiceStatus(record: record, health: "unhealthy", pid: evidence.pid, queryOutput: output)
        }
        return ValkeyServiceStatus(record: record, health: "healthy", pid: evidence.pid, queryOutput: output)
    }

    public func start(id: ServiceInstanceID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = try repository.instance(id) else { throw ValkeyServiceError.missingInstance }
        if let status = try? self.status(id: id), status.health == "healthy" { return }
        if let evidence = readEvidence(id), processExists(evidence.pid) { throw ValkeyServiceError.processIdentityMismatch }
        let package = try validatedPackage()
        let port = record.endpoint.portNumbers.first
        guard portIsFree(port) else { throw ValkeyServiceError.portConflict(port) }
        let paths = instancePaths(id)
        try manager.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        try manager.createDirectory(at: paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: paths.log.path) { manager.createFile(atPath: paths.log.path, contents: nil) }
        let log = try FileHandle(forWritingTo: paths.log)
        try log.seekToEnd()
        let server = Process(); server.executableURL = package.appendingPathComponent("bin/valkey-server")
        server.arguments = ["--dir", paths.data.path, "--bind", "127.0.0.1", "--port", "\(port)", "--save", "900", "1", "--appendonly", "yes", "--appendfilename", "appendonly.aof", "--dbfilename", "dump.rdb", "--daemonize", "no"]
        server.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": layout.rootURL.path, "LC_ALL": "C", "TZ": "UTC"]
        server.standardOutput = log; server.standardError = log
        try server.run()
        let pid = server.processIdentifier
        let identityDeadline = Date().addingTimeInterval(5)
        var identity: (startedAt: String, executable: String, command: String)?
        while Date() < identityDeadline {
            identity = processIdentity(pid)
            if identity != nil { break }
            usleep(20_000)
        }
        guard let identity, canonicalPath(identity.executable) == canonicalPath(package.appendingPathComponent("bin/valkey-server").path) else {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            let logText = (try? String(contentsOf: paths.log, encoding: .utf8)) ?? ""
            throw ValkeyServiceError.processFailure("Valkey process identity did not match after start. pid=\(pid) observed=\(String(describing: identity)) expected=\(package.appendingPathComponent("bin/valkey-server").path) log=\(logText)")
        }
        let evidence = ProcessEvidence(pid: pid, startedAt: identity.startedAt, executable: identity.executable, command: identity.command, dataDirectory: paths.data.path, port: port, cliPath: package.appendingPathComponent("bin/valkey-cli").path)
        do {
            try JSONEncoder().encode(evidence).write(to: paths.evidence, options: .atomic)
        } catch {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            throw ValkeyServiceError.processFailure("Could not publish Valkey process evidence; the directly launched child was stopped.")
        }
        ownedProcesses[id.name.value] = server
        let deadline = Date().addingTimeInterval(15)
        var lastStatus: ValkeyServiceStatus?
        while Date() < deadline {
            lastStatus = try status(id: id)
            if lastStatus?.health == "healthy" { return }
            usleep(100_000)
        }
        throw ValkeyServiceError.processFailure("Valkey started but did not pass its exact data-directory and version health check (\(lastStatus?.health ?? "no status")): \(lastStatus?.queryOutput ?? "no query output"); process evidence was retained.")
    }

    public func stop(id: ServiceInstanceID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = try repository.instance(id) else { throw ValkeyServiceError.missingInstance }
        guard let evidence = readEvidence(id) else {
            guard portIsFree(record.endpoint.portNumbers.first) else { throw ValkeyServiceError.processIdentityMismatch }
            return
        }
        guard processExists(evidence.pid) else {
            try? manager.removeItem(at: instancePaths(id).evidence)
            ownedProcesses.removeValue(forKey: id.name.value)
            return
        }
        guard processMatches(evidence, record: record), try status(id: id).health == "healthy" else { throw ValkeyServiceError.processIdentityMismatch }
        guard kill(evidence.pid, SIGTERM) == 0 || errno == ESRCH else { throw ValkeyServiceError.processFailure("Valkey graceful shutdown signal failed; process evidence and data were retained.") }
        let deadline = Date().addingTimeInterval(shutdownTimeout)
        while Date() < deadline && processExists(evidence.pid) { usleep(50_000) }
        guard !processExists(evidence.pid) else { throw ValkeyServiceError.processFailure("Valkey did not stop before the deadline; process evidence and data were retained.") }
        ownedProcesses.removeValue(forKey: id.name.value)
        try? manager.removeItem(at: instancePaths(id).evidence)
    }

    public func remove(id: ServiceInstanceID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = try repository.instance(id) else { throw ValkeyServiceError.missingInstance }
        guard try status(id: id).health == "stopped", portIsFree(record.endpoint.portNumbers.first) else { throw ValkeyServiceError.runningOrClaimed }
        do { try repository.removeStoppedInstance(id) }
        catch { throw ValkeyServiceError.runningOrClaimed }
        _ = record
    }

    private struct ProcessEvidence: Codable {
        let pid: Int32
        let startedAt: String
        let executable: String
        let command: String
        let dataDirectory: String
        let port: Int
        let cliPath: String
    }
    private struct Paths {
        let root: URL; let data: URL; let runtime: URL; let log: URL; let evidence: URL
    }
    private func instancePaths(_ id: ServiceInstanceID) -> Paths {
        let root = layout.valkeyInstancesDirectoryURL.appendingPathComponent(id.name.value, isDirectory: true)
        let runtime = layout.rootURL.appendingPathComponent("runtime/valkey/\(id.name.value)", isDirectory: true)
        return Paths(root: root, data: root.appendingPathComponent("data", isDirectory: true), runtime: runtime, log: layout.logsDirectoryURL.appendingPathComponent("valkey/\(id.name.value).log"), evidence: runtime.appendingPathComponent("process.json"))
    }
    private func validatedPackage() throws -> URL {
        if isExecutable(packageSource.appendingPathComponent("bin/valkey-server")), isExecutable(packageSource.appendingPathComponent("bin/valkey-cli")) {
            guard packageSource.lastPathComponent == Self.packageIdentifier,
                  (try? packageSource.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw ValkeyServiceError.invalidPackage("package root must be the exact valkey-9.1.2 directory") }
            let version = try? run(packageSource.appendingPathComponent("bin/valkey-server"), ["--version"], timeout: 3)
            guard version?.status == 0, version?.output.contains("9.1.2") == true else { throw ValkeyServiceError.invalidPackage("unexpected Valkey executable version") }
            return packageSource
        }
        throw ValkeyServiceError.unsupportedPackage
    }

    private func isExecutable(_ url: URL) -> Bool { manager.isExecutableFile(atPath: url.path) }
    private func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, output: String) {
        try manager.createDirectory(at: layout.cacheDirectoryURL.appendingPathComponent("valkey-command-logs", isDirectory: true), withIntermediateDirectories: true)
        let logURL = layout.cacheDirectoryURL.appendingPathComponent("valkey-command-logs", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let fd = open(logURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw ValkeyServiceError.processFailure("Could not create a private command log.") }
        close(fd)
        defer { try? manager.removeItem(at: logURL) }
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ValkeyServiceError.processFailure("Could not initialize command output redirection.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        _ = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logURL.path, O_WRONLY | O_APPEND, 0o600)
        _ = posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable.path, &actions, nil, &argv, environ)
        guard spawnResult == 0 else { throw ValkeyServiceError.processFailure("Could not launch command \(executable.path): \(spawnResult)") }
        let deadline = Date().addingTimeInterval(timeout)
        var waitStatus: Int32 = 0
        while true {
            let waited = waitpid(pid, &waitStatus, WNOHANG)
            if waited == pid { break }
            if waited < 0 {
                if errno == EINTR { continue }
                throw ValkeyServiceError.processFailure("Could not observe command exit: \(executable.path)")
            }
            if Date() >= deadline {
                _ = kill(pid, SIGTERM)
                let terminationDeadline = Date().addingTimeInterval(1)
                repeat {
                    let reaped = waitpid(pid, &waitStatus, WNOHANG)
                    if reaped == pid { break }
                    if reaped < 0 && errno != EINTR { break }
                    usleep(20_000)
                } while Date() < terminationDeadline
                if waitpid(pid, &waitStatus, WNOHANG) == 0 { _ = kill(pid, SIGKILL); _ = waitpid(pid, &waitStatus, 0) }
                throw ValkeyServiceError.processFailure("Command timed out: \(executable.path)")
            }
            usleep(20_000)
        }
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let code = (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
        return (code, output)
    }
    private func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian); address.sin_port = in_port_t(port).bigEndian
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
    private func readEvidence(_ id: ServiceInstanceID) -> ProcessEvidence? { try? JSONDecoder().decode(ProcessEvidence.self, from: Data(contentsOf: instancePaths(id).evidence)) }
    private func processExists(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG)
        return waited != pid
    }
    private func processIdentity(_ pid: Int32) -> (startedAt: String, executable: String, command: String)? {
        guard let ps = try? run(URL(fileURLWithPath: "/bin/ps"), ["-p", "\(pid)", "-o", "lstart=,command="], timeout: 3), ps.status == 0,
              let executable = procPath(pid) else { return nil }
        let parts = ps.output.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 5, whereSeparator: \.isWhitespace)
        guard parts.count >= 6 else { return nil }
        return (parts.prefix(5).joined(separator: " "), canonicalPath(executable), parts.dropFirst(5).joined(separator: " "))
    }
    private func procPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return count > 0 ? String(cString: buffer) : nil
    }
    private func processMatches(_ evidence: ProcessEvidence, record: ServiceInstanceRecord) -> Bool {
        guard evidence.dataDirectory == record.dataDirectory, evidence.port == record.endpoint.portNumbers.first,
              let identity = processIdentity(evidence.pid) else { return false }
        let executable = packageSource.appendingPathComponent("bin/valkey-server").path
        return identity.startedAt == evidence.startedAt && identity.executable == evidence.executable && identity.executable == canonicalPath(executable)
    }
    private func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
