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

private struct CaddyProcessRecord: Codable, Sendable {
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
        guard processExists(record.pid) else {
            try? manager.removeItem(at: processRecordURL())
            return CaddyProcessStatus(state: .stopped, health: .unknown, version: version, pid: nil, executablePath: executable, httpPort: configuration.httpPort, adminEndpoint: admin)
        }
        guard processMatches(record) else { return CaddyProcessStatus(state: .degraded, health: .unhealthy, version: record.version, pid: record.pid, executablePath: record.executablePath, httpPort: record.httpPort, adminEndpoint: record.adminEndpoint) }
        let healthy = manager.fileExists(atPath: record.adminEndpoint.replacingOccurrences(of: "unix//", with: ""))
        return CaddyProcessStatus(state: .running, health: healthy ? .healthy : .unknown, version: record.version, pid: record.pid, executablePath: record.executablePath, httpPort: record.httpPort, adminEndpoint: record.adminEndpoint)
    }

    public func start() throws -> CaddyProcessStatus {
        let package = self.package ?? installedPackage()
        guard let package else { throw CaddyRuntimeError.packageUnavailable }
        let current = status()
        if current.state == .running, current.health == .healthy { return current }
        if current.state == .degraded { throw CaddyRuntimeError.processIdentityMismatch }
        guard isPortAvailable(configuration.httpPort) else { throw CaddyRuntimeError.portConflict(configuration.httpPort) }
        guard isPortAvailable(configuration.httpsPort) else { throw CaddyRuntimeError.portConflict(configuration.httpsPort) }

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
        let record = CaddyProcessRecord(pid: process.processIdentifier, version: package.version, executablePath: package.executablePath, arguments: arguments, configPath: configURL.path, adminEndpoint: admin, httpPort: configuration.httpPort, httpsPort: configuration.httpsPort, startedAt: processStartIdentity(process.processIdentifier))
        try atomicWrite(record, to: processRecordURL())

        for _ in 0..<60 {
            let result = status()
            if result.state == .running, result.health == .healthy, (try? CaddyAdminClient(endpoint: admin).getConfig()) != nil { return result }
            usleep(50_000)
        }
        if processMatches(record) { _ = kill(record.pid, SIGTERM) }
        try? manager.removeItem(at: processRecordURL())
        let output = (try? String(contentsOf: logURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw CaddyRuntimeError.processFailed(output.isEmpty ? "Caddy did not become ready" : output)
    }

    public func stop() throws -> CaddyProcessStatus {
        guard let record = processRecord() else { return status() }
        guard processMatches(record) else { throw CaddyRuntimeError.processIdentityMismatch }
        _ = kill(record.pid, SIGTERM)
        for _ in 0..<60 {
            if !processExists(record.pid) {
                try? manager.removeItem(at: processRecordURL())
                return status()
            }
            usleep(50_000)
        }
        _ = kill(record.pid, SIGKILL)
        try? manager.removeItem(at: processRecordURL())
        return status()
    }

    public func adminEndpoint() -> String { "unix//\(layout.routingRuntimeDirectoryURL.appendingPathComponent("admin.sock").path)" }

    private func installedPackage() -> CaddyPackage? { CaddyModule(layout: layout, verifier: nil).installedVersions().last }
    private func processRecordURL() -> URL { layout.caddyInstancesDirectoryURL.appendingPathComponent("process.json") }
    private func processRecord() -> CaddyProcessRecord? { try? JSONDecoder().decode(CaddyProcessRecord.self, from: Data(contentsOf: processRecordURL())) }
    private func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func processMatches(_ record: CaddyProcessRecord) -> Bool {
        guard processExists(record.pid) else { return false }
        let commandOutput = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "command="])) ?? ""
        let start = (try? command("/bin/ps", ["-p", "\(record.pid)", "-o", "lstart="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return commandOutput.contains(record.executablePath) && record.arguments.allSatisfy { commandOutput.contains($0) } && start == record.startedAt
    }
    private func processStartIdentity(_ pid: Int32) -> String { (try? command("/bin/ps", ["-p", "\(pid)", "-o", "lstart="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private func command(_ executable: String, _ arguments: [String]) throws -> String { let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = pipe; try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return String(data: data, encoding: .utf8) ?? "" }
    private func makeDirectories(_ urls: [URL]) throws { for url in urls { try manager.createDirectory(at: url, withIntermediateDirectories: true); try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) } }
    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws { let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp"); try JSONEncoder().encode(value).write(to: temporary, options: .atomic); if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: temporary) } else { try manager.moveItem(at: temporary, to: url) } }
    private func writeInitialConfiguration(to url: URL, admin: String, dataDirectory: URL) throws {
        let config: [String: Any] = ["admin": ["listen": admin], "storage": ["module": "file_system", "root": dataDirectory.path], "apps": ["http": ["servers": ["vaelen-http": ["listen": ["127.0.0.1:\(configuration.httpPort)"], "automatic_https": ["disable": true], "protocols": ["h1", "h2"], "routes": []]]]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted]); try data.write(to: url, options: .atomic)
    }
    private func isPortAvailable(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0); guard descriptor >= 0 else { return false }; defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")); return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
}
