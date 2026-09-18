import Foundation
import Darwin

public enum SystemCapabilityState: String, Codable, Sendable { case unavailable, notInstalled, installing, installed, unhealthy, removing, conflict }
public enum DNSOwnership: String, Codable, Sendable { case none, vaelen, external, unknown }

public struct DNSStatus: Codable, Equatable, Sendable {
    public let state: SystemCapabilityState
    public let ownership: DNSOwnership
    public let resolverPath: String
    public let resolverContent: String?
    public let address: String
    public let port: Int
    public let pid: Int32?
    public let health: String
    public let conflict: String?

    public init(state: SystemCapabilityState, ownership: DNSOwnership, resolverPath: String = "/etc/resolver/test", resolverContent: String? = nil, address: String = "127.0.0.1", port: Int = 53535, pid: Int32? = nil, health: String, conflict: String? = nil) {
        self.state = state; self.ownership = ownership; self.resolverPath = resolverPath; self.resolverContent = resolverContent; self.address = address; self.port = port; self.pid = pid; self.health = health; self.conflict = conflict
    }
}

public struct ResolverInspection: Codable, Equatable, Sendable {
    public let exists: Bool
    public let content: String?
    public let ownership: DNSOwnership
    public init(exists: Bool, content: String?, ownership: DNSOwnership) { self.exists = exists; self.content = content; self.ownership = ownership }
}

public protocol PrivilegedDNSHelper: Sendable {
    func inspectTestResolver() async throws -> ResolverInspection
    func installTestResolver(port: Int, replacing: ResolverInspection?) async throws
    func removeTestResolver(expectedContent: String, restoreContent: String?) async throws
}

public struct UnavailablePrivilegedDNSHelper: PrivilegedDNSHelper {
    public init() {}
    public func inspectTestResolver() async throws -> ResolverInspection {
        let url = URL(fileURLWithPath: "/etc/resolver/test")
        guard FileManager.default.fileExists(atPath: url.path) else { return ResolverInspection(exists: false, content: nil, ownership: .none) }
        return ResolverInspection(exists: true, content: try String(contentsOf: url, encoding: .utf8), ownership: .unknown)
    }
    public func installTestResolver(port: Int, replacing: ResolverInspection?) async throws { throw DNSCapabilityError.privilegeUnavailable }
    public func removeTestResolver(expectedContent: String, restoreContent: String?) async throws { throw DNSCapabilityError.privilegeUnavailable }
}

/// Development-only bridge. Authorization remains external: the developer must pre-authorize sudo.
public struct DevelopmentPrivilegedDNSHelper: PrivilegedDNSHelper {
    public init() {}
    public func inspectTestResolver() async throws -> ResolverInspection {
        let url = URL(fileURLWithPath: "/etc/resolver/test")
        guard FileManager.default.fileExists(atPath: url.path) else { return ResolverInspection(exists: false, content: nil, ownership: .none) }
        return ResolverInspection(exists: true, content: try String(contentsOf: url, encoding: .utf8), ownership: .unknown)
    }
    public func installTestResolver(port: Int, replacing: ResolverInspection?) async throws {
        guard (1024...65535).contains(port) else { throw DNSCapabilityError.invalidPort(port) }
        // A non-nil replacement is the explicit, user-authorized takeover path.
        try runSudo(arguments: ["/usr/bin/tee", "/etc/resolver/test"], input: "nameserver 127.0.0.1\nport \(port)\n")
    }
    public func removeTestResolver(expectedContent: String, restoreContent: String?) async throws {
        guard try await inspectTestResolver().content == expectedContent else { throw DNSCapabilityError.ownershipMismatch }
        if let restoreContent { try runSudo(arguments: ["/usr/bin/tee", "/etc/resolver/test"], input: restoreContent) }
        else { try runSudo(arguments: ["/bin/rm", "/etc/resolver/test"]) }
    }
    private func runSudo(arguments: [String], input: String? = nil) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo"); process.arguments = ["-n"] + arguments
        let error = Pipe(); process.standardError = error
        if let input { let pipe = Pipe(); process.standardInput = pipe; try process.run(); pipe.fileHandleForWriting.write(Data(input.utf8)); pipe.fileHandleForWriting.closeFile() } else { try process.run() }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DNSCapabilityError.authorizationRequired(String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sudo failed") }
    }
}

public enum DNSCapabilityError: Error, Equatable, Sendable { case invalidPort(Int), externalConflict, ownershipMismatch, privilegeUnavailable, authorizationRequired(String), processFailed(String) }

public protocol DNSResponderControlling: Sendable {
    func status() async -> (pid: Int32?, running: Bool)
    func start() async throws -> Int32
    func stop() async
}

public actor DNSResponderSupervisor: DNSResponderControlling {
    public let layout: VaelenFilesystemLayout
    public let port: Int
    private let executablePath: String
    private var pid: Int32?
    public init(layout: VaelenFilesystemLayout, port: Int = 53535, executablePath: String? = nil) { self.layout = layout; self.port = port; self.executablePath = (executablePath.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("vaelendns")).standardizedFileURL.path }
    public func status() -> (pid: Int32?, running: Bool) {
        let candidate = pid.flatMap { isOwnedProcess($0) ? $0 : nil } ?? discoverOwnedProcess()
        guard let candidate, responds() else { pid = nil; return (nil, false) }
        pid = candidate
        return (candidate, true)
    }
    public func start() throws -> Int32 {
        if let current = pid, kill(current, 0) == 0 { return current }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { throw DNSCapabilityError.processFailed("DNS responder executable is unavailable") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executablePath); process.arguments = ["--port", "\(port)"]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
        for _ in 0..<10 {
            usleep(50_000)
            if process.isRunning && responds() { pid = process.processIdentifier; return process.processIdentifier }
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGTERM) }
        throw DNSCapabilityError.processFailed("DNS responder could not bind 127.0.0.1:\(port)")
    }
    public func stop() { if let pid { _ = kill(pid, SIGTERM); self.pid = nil } }

    private func responds() -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return false }
        let query: [UInt8] = [0x42, 0x42, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 120, 4, 116, 101, 115, 116, 0, 0, 1, 0, 1]
        let sent = query.withUnsafeBytes { send(fd, $0.baseAddress, query.count, 0) }
        guard sent == query.count else { return false }
        var buffer = [UInt8](repeating: 0, count: 512)
        return recv(fd, &buffer, buffer.count, 0) > 0
    }

    private func isOwnedProcess(_ candidate: Int32) -> Bool {
        guard kill(candidate, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(candidate, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let candidatePath = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard Self.acceptsExecutablePath(candidatePath, expected: executablePath) else { return false }
        let commandLine = processCommandLine(candidate)
        let user = (try? command("/bin/ps", ["-p", "\(candidate)", "-o", "user="]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return user == NSUserName() && commandLine.contains("--port \(port)")
    }

    private func discoverOwnedProcess() -> Int32? {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return nil }
        for candidate in pids where candidate > 0 {
            if isOwnedProcess(candidate) { return candidate }
        }
        return nil
    }

    static func acceptsExecutablePath(_ candidate: String, expected: String) -> Bool {
        if candidate == expected { return true }
        let expectedComponents = URL(fileURLWithPath: expected).standardizedFileURL.pathComponents
        let candidateComponents = URL(fileURLWithPath: candidate).standardizedFileURL.pathComponents
        guard URL(fileURLWithPath: candidate).lastPathComponent == URL(fileURLWithPath: expected).lastPathComponent,
              let expectedBuild = expectedComponents.firstIndex(of: ".build"),
              let candidateBuild = candidateComponents.firstIndex(of: ".build") else { return false }
        return expectedComponents.prefix(expectedBuild + 1).elementsEqual(candidateComponents.prefix(candidateBuild + 1))
    }

    private func processCommandLine(_ pid: Int32) -> String { (try? command("/bin/ps", ["-p", "\(pid)", "-o", "command="])) ?? "" }

    private func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); let output = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = output; try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return String(data: data, encoding: .utf8) ?? ""
    }
}

public actor DNSCapability {
    private let helper: any PrivilegedDNSHelper
    private let responder: any DNSResponderControlling
    private let port: Int
    private let ledger: SystemModificationLedger?
    private var expectedContent: String?
    public init(layout: VaelenFilesystemLayout = .init(), helper: any PrivilegedDNSHelper = UnavailablePrivilegedDNSHelper(), responder: (any DNSResponderControlling)? = nil, port: Int = 53535, ledger: SystemModificationLedger? = nil) { self.helper = helper; self.port = port; self.ledger = ledger; self.expectedContent = try? ledger?.dnsRecord()?.installedContent; self.responder = responder ?? DNSResponderSupervisor(layout: layout, port: port) }
    public func status() async -> DNSStatus {
        let inspection = try? await helper.inspectTestResolver()
        let process = await responder.status()
        guard let inspection else { return DNSStatus(state: .unavailable, ownership: .unknown, port: port, pid: process.pid, health: process.running ? "running" : "unavailable") }
        if inspection.exists && inspection.ownership == .unknown && expectedContent == nil { return DNSStatus(state: .conflict, ownership: .unknown, resolverContent: inspection.content, port: port, pid: process.pid, health: "conflict", conflict: "External /etc/resolver/test exists") }
        let installed = inspection.content == expectedContent && expectedContent != nil
        return DNSStatus(state: installed ? (process.running ? .installed : .unhealthy) : .notInstalled, ownership: installed ? .vaelen : inspection.ownership, resolverContent: inspection.content, port: port, pid: process.pid, health: process.running ? "healthy" : "stopped")
    }
    public func install(takeover: Bool = false) async throws -> DNSStatus {
        let inspection = try await helper.inspectTestResolver()
        let alreadyVaelenOwned = inspection.content == expectedContent && expectedContent != nil
        if inspection.exists && !takeover && !alreadyVaelenOwned { throw DNSCapabilityError.externalConflict }
        let content = "nameserver 127.0.0.1\nport \(port)\n"
        _ = try await responder.start()
        do {
            try await helper.installTestResolver(port: port, replacing: takeover ? ResolverInspection(exists: inspection.exists, content: inspection.content, ownership: inspection.exists ? .external : .none) : nil)
        } catch {
            await responder.stop()
            throw error
        }
        expectedContent = content
        try ledger?.recordDNS(installedContent: content, previousContent: inspection.content)
        return await status()
    }
    public func remove() async throws -> DNSStatus {
        let record = try ledger?.dnsRecord()
        let expectedContent = self.expectedContent ?? record?.installedContent
        guard let expectedContent else { return await status() }
        let recordedPrevious = record?.previousContent
        let previous = recordedPrevious == expectedContent ? nil : recordedPrevious
        try await helper.removeTestResolver(expectedContent: expectedContent, restoreContent: previous)
        try ledger?.deactivateDNS(); await responder.stop(); self.expectedContent = nil
        return await status()
    }
}
