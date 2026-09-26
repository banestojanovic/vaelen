import Foundation
import Darwin

public struct CaddyRuntimeConfiguration: Codable, Equatable, Sendable {
    public let httpPort: Int
    public let httpsPort: Int

    public init(httpPort: Int = VaelenNetworkPorts.httpBackend, httpsPort: Int = VaelenNetworkPorts.httpsBackend) { self.httpPort = httpPort; self.httpsPort = httpsPort }
}

public enum CaddyProcessState: String, Codable, Sendable { case stopped, starting, running, degraded, stopping }

public struct CaddyProcessStatus: Codable, Equatable, Sendable {
    public let state: CaddyProcessState
    public let health: RouterHealth
    public let version: String
    public let pid: Int32?
    public let executablePath: String
    public let httpPort: Int
    public let adminEndpoint: String

    public init(state: CaddyProcessState, health: RouterHealth, version: String, pid: Int32?, executablePath: String, httpPort: Int, adminEndpoint: String) {
        self.state = state; self.health = health; self.version = version; self.pid = pid; self.executablePath = executablePath; self.httpPort = httpPort; self.adminEndpoint = adminEndpoint
    }
}

public enum CaddyRuntimeError: Error, Equatable, Sendable {
    case packageUnavailable
    case portConflict(Int)
    case processIdentityMismatch
    case processFailed(String)
    case invalidConfiguration(String)
}

struct CaddyProcessRecord: Codable, Sendable {
    let pid: Int32
    let version: String
    let executablePath: String
    let arguments: [String]
    let configPath: String
    let adminEndpoint: String
    let httpPort: Int
    let httpsPort: Int
    let startedAt: String

    private enum CodingKeys: String, CodingKey { case pid, version, executablePath, arguments, configPath, adminEndpoint, httpPort, httpsPort, startedAt }

    init(pid: Int32, version: String, executablePath: String, arguments: [String], configPath: String, adminEndpoint: String, httpPort: Int, httpsPort: Int, startedAt: String) {
        self.pid = pid; self.version = version; self.executablePath = executablePath; self.arguments = arguments; self.configPath = configPath; self.adminEndpoint = adminEndpoint; self.httpPort = httpPort; self.httpsPort = httpsPort; self.startedAt = startedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        version = try container.decode(String.self, forKey: .version)
        executablePath = try container.decode(String.self, forKey: .executablePath)
        arguments = try container.decode([String].self, forKey: .arguments)
        configPath = try container.decode(String.self, forKey: .configPath)
        adminEndpoint = try container.decode(String.self, forKey: .adminEndpoint)
        httpPort = try container.decode(Int.self, forKey: .httpPort)
        httpsPort = try container.decodeIfPresent(Int.self, forKey: .httpsPort) ?? VaelenNetworkPorts.httpsBackend
        startedAt = try container.decode(String.self, forKey: .startedAt)
    }
}

public actor CaddyProcessSupervisor {
    public let layout: VaelenFilesystemLayout
    public let configuration: CaddyRuntimeConfiguration
    private let manager = FileManager.default
    private var package: CaddyPackage?
    private var ownedChild: OwnedChildProcess?
    private var identityCommandFailsForTesting = false

    public init(layout: VaelenFilesystemLayout, configuration: CaddyRuntimeConfiguration = .init()) {
        self.layout = layout; self.configuration = configuration
    }

    public func installPackage(_ package: CaddyPackage) { self.package = package }

    public func status() -> CaddyProcessStatus {
        let package = self.package ?? installedPackage()
        let executable = package?.executablePath ?? ""
        let version = package?.version ?? ""
        let record = processRecord()
        let admin = adminEndpoint()
        guard let record else { return CaddyProcessStatus(state: .stopped, health: .unknown, version: version, pid: nil, executablePath: executable, httpPort: configuration.httpPort, adminEndpoint: admin) }
        if let child = ownedChild, child.processIdentifier == record.pid, !child.isRunningAndReapedIfExited() {
            try? manager.removeItem(at: processRecordURL())
            ownedChild = nil
            return CaddyProcessStatus(state: .stopped, health: .unknown, version: version, pid: nil, executablePath: executable, httpPort: configuration.httpPort, adminEndpoint: admin)
        }
        if !processHasCommand(record.pid) {
            // kill(pid, 0) can still succeed briefly for an exited zombie.
            // No command means no live process to own; dropping the stale
            // record is safe and prevents reporting the child as degraded.
            try? manager.removeItem(at: processRecordURL())
            ownedChild = nil
            return CaddyProcessStatus(state: .stopped, health: .unknown, version: version, pid: nil, executablePath: executable, httpPort: configuration.httpPort, adminEndpoint: admin)
        }
        guard processMatches(record) else { return CaddyProcessStatus(state: .degraded, health: .unhealthy, version: record.version, pid: record.pid, executablePath: record.executablePath, httpPort: record.httpPort, adminEndpoint: record.adminEndpoint) }
        let healthy = manager.fileExists(atPath: record.adminEndpoint.replacingOccurrences(of: "unix//", with: ""))
        return CaddyProcessStatus(state: .running, health: healthy ? .healthy : .unknown, version: record.version, pid: record.pid, executablePath: record.executablePath, httpPort: record.httpPort, adminEndpoint: record.adminEndpoint)
    }

    public func start() throws -> CaddyProcessStatus {
        let attemptStarted = Date()
        let package = self.package ?? installedPackage()
        guard let package else { throw CaddyRuntimeError.packageUnavailable }
        var current = status()
        if current.state == .running {
            // Leave margin for the final status projection and error delivery;
            // this is deliberately below the externally observed 3s bound.
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline {
                let observed = status()
                current = observed
                if observed.state != .running { break }
                let remaining = deadline.timeIntervalSinceNow
                if observed.health == .healthy, (try? CaddyAdminClient(endpoint: observed.adminEndpoint).getConfig(timeout: min(0.25, remaining))) != nil { return observed }
                if remaining > 0 { usleep(useconds_t(min(50_000, remaining * 1_000_000))) }
            }
            if current.state == .running {
                throw CaddyRuntimeError.processFailed("Recorded Caddy PID \(current.pid ?? -1) is still running but its admin endpoint is not ready; refusing to launch another Caddy process")
            }
        }
        if current.state == .degraded { throw CaddyRuntimeError.processIdentityMismatch }
        let httpAvailability = portAvailability(configuration.httpPort)
        guard httpAvailability.available else { throw portConflict(configuration.httpPort, preflight: current, bindError: httpAvailability.error, elapsed: Date().timeIntervalSince(attemptStarted), startedAt: attemptStarted) }
        let httpsAvailability = portAvailability(configuration.httpsPort)
        guard httpsAvailability.available else { throw portConflict(configuration.httpsPort, preflight: current, bindError: httpsAvailability.error, elapsed: Date().timeIntervalSince(attemptStarted), startedAt: attemptStarted) }

        let configURL = layout.routingConfigurationDirectoryURL.appendingPathComponent("caddy.json")
        let admin = adminEndpoint()
        let runtimeData = layout.routingRuntimeDirectoryURL.appendingPathComponent("data", isDirectory: true)
        try makeDirectories([layout.routingConfigurationDirectoryURL, layout.routingRuntimeDirectoryURL, runtimeData, layout.caddyLogsDirectoryURL, layout.caddyInstancesDirectoryURL])
        try? manager.removeItem(atPath: admin.replacingOccurrences(of: "unix//", with: ""))
        try writeInitialConfiguration(to: configURL, admin: admin, dataDirectory: runtimeData)

        let logURL = layout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log")
        if !manager.fileExists(atPath: logURL.path) { manager.createFile(atPath: logURL.path, contents: nil) }
        let arguments = ["run", "--config", configURL.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: package.executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = layout.rootURL
        process.environment = ProcessInfo.processInfo.environment.merging(["XDG_DATA_HOME": layout.routingRuntimeDirectoryURL.path, "XDG_CONFIG_HOME": layout.routingConfigurationDirectoryURL.path]) { _, value in value }
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log; process.standardError = log
        try process.run()
        let ownedChild = OwnedChildProcess(process: process, label: "Caddy")
        self.ownedChild = ownedChild
        let record = CaddyProcessRecord(pid: process.processIdentifier, version: package.version, executablePath: package.executablePath, arguments: arguments, configPath: configURL.path, adminEndpoint: admin, httpPort: configuration.httpPort, httpsPort: configuration.httpsPort, startedAt: processStartIdentity(process.processIdentifier))
        try atomicWrite(record, to: processRecordURL())

        let readinessDeadline = Date().addingTimeInterval(3)
        while Date() < readinessDeadline {
            let result = status()
            let remaining = readinessDeadline.timeIntervalSinceNow
            if result.state == .running, result.health == .healthy, (try? CaddyAdminClient(endpoint: admin).getConfig(timeout: min(0.25, remaining))) != nil { return result }
            usleep(50_000)
        }
        guard ownedChild.terminateAndWait(timeout: 3) else {
            throw CaddyRuntimeError.processFailed("Caddy PID \(record.pid) did not stop within the bounded startup cleanup interval")
        }
        self.ownedChild = nil
        try? manager.removeItem(at: processRecordURL())
        let output = (try? String(contentsOf: logURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw CaddyRuntimeError.processFailed(output.isEmpty ? "Caddy did not become ready" : output)
    }

    public func stop() throws -> CaddyProcessStatus {
        let observed = status()
        if observed.state == .stopped { return observed }
        guard let record = processRecord() else { return status() }
        let child = ownedChild
        switch verifyProcessIdentity(record) {
        case .gone:
            removeProcessRecord()
            return CaddyProcessStatus(state: .stopped, health: .unknown, version: record.version, pid: nil, executablePath: record.executablePath, httpPort: record.httpPort, adminEndpoint: record.adminEndpoint)
        case .unavailable:
            throw CaddyRuntimeError.processFailed("Cannot verify the identity of live Caddy PID \(record.pid); preserving its process record and leaving it untouched")
        case .mismatch:
            throw CaddyRuntimeError.processIdentityMismatch
        case .matches:
            break
        }
        let stopped: Bool
        if let child, child.processIdentifier == record.pid {
            stopped = child.terminateAndWait(timeout: 3)
        } else {
            // The durable process identity survives a Core restart. Signal
            // only the still-matching Caddy process; a mismatched PID is
            // handled above without signaling.
            guard kill(record.pid, SIGTERM) == 0 else { throw CaddyRuntimeError.processFailed("Caddy PID \(record.pid) could not be asked to stop") }
            let deadline = Date().addingTimeInterval(3)
            var confirmedGone = false
            while Date() < deadline {
                switch verifyProcessIdentity(record) {
                case .gone: confirmedGone = true
                case .matches: usleep(20_000)
                case .unavailable:
                    throw CaddyRuntimeError.processFailed("Cannot verify the identity of live Caddy PID \(record.pid) during shutdown; preserving its process record")
                case .mismatch:
                    throw CaddyRuntimeError.processIdentityMismatch
                }
                if confirmedGone { break }
            }
            stopped = confirmedGone || !processExists(record.pid)
        }
        guard stopped else {
            throw CaddyRuntimeError.processFailed("Caddy PID \(record.pid) is still running after the graceful shutdown timeout")
        }
        ownedChild = nil
        try? manager.removeItem(at: processRecordURL())
        removeStaleAdminSocket(record.adminEndpoint)
        let result = status()
        guard result.state == .stopped else { throw CaddyRuntimeError.processFailed("Caddy remains observable after shutdown") }
        return result
    }

    private func removeStaleAdminSocket(_ endpoint: String) {
        let path = endpoint.replacingOccurrences(of: "unix//", with: "")
        guard path == layout.routingRuntimeDirectoryURL.appendingPathComponent("admin.sock").path else { return }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else { return }
        try? manager.removeItem(atPath: path)
    }

    public func adminEndpoint() -> String { "unix//\(layout.routingRuntimeDirectoryURL.appendingPathComponent("admin.sock").path)" }

    private func installedPackage() -> CaddyPackage? { CaddyModule(layout: layout, verifier: nil).installedVersions().last }
    private func processRecordURL() -> URL { layout.caddyInstancesDirectoryURL.appendingPathComponent("process.json") }
    func retainOwnedChild(_ child: OwnedChildProcess) { ownedChild = child }
    private func processRecord() -> CaddyProcessRecord? { try? JSONDecoder().decode(CaddyProcessRecord.self, from: Data(contentsOf: processRecordURL())) }
    private func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func processHasCommand(_ pid: Int32) -> Bool {
        guard let output = try? command("/bin/ps", ["-p", "\(pid)", "-o", "command="]) else { return processExists(pid) }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || processExists(pid)
    }
    private func processMatches(_ record: CaddyProcessRecord) -> Bool {
        verifyProcessIdentity(record) == .matches
    }

    private enum ProcessIdentityVerification: Equatable { case gone, matches, mismatch, unavailable }

    private func verifyProcessIdentity(_ record: CaddyProcessRecord) -> ProcessIdentityVerification {
        if let child = ownedChild, child.processIdentifier == record.pid, !child.isRunningAndReapedIfExited() { return .gone }
        guard processExists(record.pid) else { return .gone }
        if identityCommandFailsForTesting { return processExists(record.pid) ? .unavailable : .gone }
        let commandOutput: String
        let start: String
        do {
            commandOutput = try command("/bin/ps", ["-p", "\(record.pid)", "-o", "command="])
            start = try command("/bin/ps", ["-p", "\(record.pid)", "-o", "lstart="]).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return processExists(record.pid) ? .unavailable : .gone
        }
        guard processExists(record.pid) else { return .gone }
        return commandOutput.contains(record.executablePath)
            && record.arguments.allSatisfy { commandOutput.contains($0) }
            && start == record.startedAt ? .matches : .mismatch
    }

    private func removeProcessRecord() {
        try? manager.removeItem(at: processRecordURL())
        ownedChild = nil
    }

    func failIdentityCommandForTesting() {
        identityCommandFailsForTesting = true
    }
    private func processStartIdentity(_ pid: Int32) -> String { (try? command("/bin/ps", ["-p", "\(pid)", "-o", "lstart="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private func command(_ executable: String, _ arguments: [String]) throws -> String { try boundedCommand(executable, arguments, timeout: 0.75) }
    private func boundedCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process(); let pipe = Pipe(); let finished = DispatchSemaphore(value: 0); let outputBuffer = CaddyCommandOutputBuffer()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outputBuffer.append(chunk) }
        }
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; throw error }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                finished.wait()
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            throw CaddyRuntimeError.processFailed("diagnostic process \(executable) exceeded \(timeout)s timeout")
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let output = outputBuffer.data
        guard process.terminationStatus == 0 else { throw CaddyRuntimeError.processFailed("diagnostic process \(executable) exited \(process.terminationStatus)") }
        return String(data: output, encoding: .utf8) ?? ""
    }
    func diagnosticCommandForTesting(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        try boundedCommand(executable, arguments, timeout: timeout)
    }
    private func makeDirectories(_ urls: [URL]) throws { for url in urls { try manager.createDirectory(at: url, withIntermediateDirectories: true); try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) } }
    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws { let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp"); try JSONEncoder().encode(value).write(to: temporary, options: .atomic); if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temporary) } else { try manager.moveItem(at: temporary, to: url) } }
    private func writeInitialConfiguration(to url: URL, admin: String, dataDirectory: URL) throws {
        let config: [String: Any] = ["admin": ["listen": admin], "storage": ["module": "file_system", "root": dataDirectory.path], "apps": ["http": ["servers": ["vaelen-http": ["listen": ["127.0.0.1:\(configuration.httpPort)"], "automatic_https": ["disable": true], "protocols": ["h1", "h2"], "routes": []]]]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted]); try data.write(to: url, options: .atomic)
    }
    private func portAvailability(_ port: Int) -> (available: Bool, error: String) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { let code = errno; return (false, "socket: \(String(cString: strerror(code))) (errno \(code))") }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { let code = errno; return (false, "bind: \(String(cString: strerror(code))) (errno \(code))") }
        return (true, "none")
    }

    private func portConflict(_ port: Int, preflight: CaddyProcessStatus, bindError: String, elapsed: TimeInterval, startedAt: Date) -> CaddyRuntimeError {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let listener = listenerIdentity(port: port)
        let record = processRecord()
        let lines = [
            "Caddy port conflict diagnostic",
            "timestamp: \(timestamp)",
            "Core PID: \(ProcessInfo.processInfo.processIdentifier)",
            "port: 127.0.0.1:\(port)",
            "preflight: state=\(preflight.state.rawValue) health=\(preflight.health)",
            "bind error: \(bindError)",
            "listener: \(listener)",
            "Vaelen Caddy record: \(record.map { "pid=\($0.pid) executable=\($0.executablePath) config=\($0.configPath) startedAt=\($0.startedAt) ownership=\(ownedChild?.processIdentifier == $0.pid ? "owned-child" : "durable-record-only")" } ?? "unavailable")",
            "startup timing: elapsed=\(String(format: "%.3f", elapsed))s; attemptStartedAt=\(ISO8601DateFormatter().string(from: startedAt)); conflict detected before this start attempt launched a Caddy process"
        ]
        let text = lines.joined(separator: "\n") + "\n"
        let logURL = layout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log")
        do {
            try makeDirectories([layout.caddyLogsDirectoryURL])
            if !manager.fileExists(atPath: logURL.path) { _ = manager.createFile(atPath: logURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
        } catch { /* Preserve refusal even when diagnostic persistence is unavailable. */ }
        return .portConflict(port)
    }

    private func listenerIdentity(port: Int) -> String {
        Self.listenerIdentity(port: port) { try boundedCommand($0, $1, timeout: 0.5) }
    }

    func listenerIdentityForTesting(port: Int, command: (String, [String]) throws -> String) -> String {
        Self.listenerIdentity(port: port, command: command)
    }

    private static func listenerIdentity(port: Int, command: (String, [String]) throws -> String) -> String {
        guard let output = try? command("/usr/sbin/lsof", ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]) else { return "unavailable (lsof could not inspect listeners without elevation)" }
        let pids = output.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return "unavailable (no listener PID observable)" }
        return pids.map { pid in
            let executable = (try? command("/bin/ps", ["-p", "\(pid)", "-o", "comm="]))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "pid=\(pid) executable=\(executable?.isEmpty == false ? executable! : "unavailable")"
        }.joined(separator: "; ")
    }
}

private final class CaddyCommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}
