import Foundation
import Darwin
import OSLog

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
    public let responderState: DNSResponderState
    public let health: String
    public let conflict: String?

    public init(state: SystemCapabilityState, ownership: DNSOwnership, resolverPath: String = "/etc/resolver/test", resolverContent: String? = nil, address: String = "127.0.0.1", port: Int = 53535, pid: Int32? = nil, responderState: DNSResponderState = .stopped, health: String, conflict: String? = nil) {
        self.state = state; self.ownership = ownership; self.resolverPath = resolverPath; self.resolverContent = resolverContent; self.address = address; self.port = port; self.pid = pid; self.responderState = responderState; self.health = health; self.conflict = conflict
    }
}

public struct ResolverInspection: Codable, Equatable, Sendable {
    public let exists: Bool
    public let content: String?
    public let ownership: DNSOwnership
    public let snapshot: ResolverFileSnapshot?
    public init(exists: Bool, content: String?, ownership: DNSOwnership, snapshot: ResolverFileSnapshot? = nil) { self.exists = exists; self.content = content; self.ownership = ownership; self.snapshot = snapshot }
}

public struct ResolverFileSnapshot: Codable, Equatable, Sendable {
    public let exists: Bool
    public let bytes: Data?
    public let owner: UInt32?
    public let group: UInt32?
    public let mode: UInt16?
    public let device: UInt64?
    public let inode: UInt64?
    public let fileType: UInt16?

    public init(exists: Bool, bytes: Data?, owner: UInt32?, group: UInt32?, mode: UInt16?, device: UInt64?, inode: UInt64?, fileType: UInt16?) {
        self.exists = exists; self.bytes = bytes; self.owner = owner; self.group = group; self.mode = mode; self.device = device; self.inode = inode; self.fileType = fileType
    }

    public static func read(_ path: String) throws -> ResolverFileSnapshot {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return ResolverFileSnapshot(exists: false, bytes: nil, owner: nil, group: nil, mode: nil, device: nil, inode: nil, fileType: nil) }
            throw DNSCapabilityError.processFailed("Unable to inspect resolver path: \(String(cString: strerror(errno)) )")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw DNSCapabilityError.resolverConflict("Resolver path is not a regular file") }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DNSCapabilityError.resolverConflict("Resolver path changed or cannot be opened without following links") }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            close(descriptor)
            throw DNSCapabilityError.resolverConflict("Resolver path changed during inspection")
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).readToEnd() ?? Data()
        return ResolverFileSnapshot(exists: true, bytes: data, owner: opened.st_uid, group: opened.st_gid, mode: UInt16(opened.st_mode & 0o7777), device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino), fileType: UInt16(opened.st_mode & S_IFMT))
    }
}

public struct DNSResolverOwnershipRecord: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, owned, restoring, resolverRestored, uncertain }
    public let phase: Phase
    public let previous: ResolverFileSnapshot
    public let intendedBytes: Data
    public let written: ResolverFileSnapshot?
    public let responder: DNSResponderIdentity?
    public init(phase: Phase, previous: ResolverFileSnapshot, intendedBytes: Data, written: ResolverFileSnapshot?, responder: DNSResponderIdentity? = nil) { self.phase = phase; self.previous = previous; self.intendedBytes = intendedBytes; self.written = written; self.responder = responder }
}

public protocol PrivilegedDNSHelper: Sendable {
    func inspectTestResolver() async throws -> ResolverInspection
    func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot
    func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws
}

public struct UnavailablePrivilegedDNSHelper: PrivilegedDNSHelper {
    public init() {}
    public func inspectTestResolver() async throws -> ResolverInspection {
        let snapshot = try ResolverFileSnapshot.read("/etc/resolver/test")
        return ResolverInspection(exists: snapshot.exists, content: snapshot.bytes.map { String(decoding: $0, as: UTF8.self) }, ownership: snapshot.exists ? .unknown : .none, snapshot: snapshot)
    }
    public func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot { throw DNSCapabilityError.privilegeUnavailable }
    public func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws { throw DNSCapabilityError.privilegeUnavailable }
}

/// Development-only bridge. Authorization remains external: the developer must pre-authorize sudo.
public struct DevelopmentPrivilegedDNSHelper: PrivilegedDNSHelper {
    public init() {}
    public func inspectTestResolver() async throws -> ResolverInspection {
        let snapshot = try ResolverFileSnapshot.read("/etc/resolver/test")
        return ResolverInspection(exists: snapshot.exists, content: snapshot.bytes.map { String(decoding: $0, as: UTF8.self) }, ownership: snapshot.exists ? .unknown : .none, snapshot: snapshot)
    }
    public func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot {
        guard (1024...65535).contains(port) else { throw DNSCapabilityError.invalidPort(port) }
        let path = "/etc/resolver/test"
        let before = try ResolverFileSnapshot.read(path)
        guard before == replacing else { throw DNSCapabilityError.ownershipMismatch }
        // Keep the existing authorization mechanism for the privileged write.
        try runSudo(arguments: ["/usr/bin/tee", "/etc/resolver/test"], input: Data("nameserver 127.0.0.1\nport \(port)\n".utf8))
        let after = try ResolverFileSnapshot.read(path)
        guard after.bytes == Data("nameserver 127.0.0.1\nport \(port)\n".utf8) else { throw DNSCapabilityError.ownershipUncertain("Resolver write did not produce the expected bytes") }
        return after
    }
    public func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws {
        let path = "/etc/resolver/test"
        guard try ResolverFileSnapshot.read(path) == expected else { throw DNSCapabilityError.ownershipMismatch }
        if restore.exists, let bytes = restore.bytes {
            try runSudo(arguments: ["/usr/bin/tee", path], input: bytes)
            try runSudo(arguments: ["/usr/sbin/chown", "\(restore.owner ?? 0):\(restore.group ?? 0)", path])
            try runSudo(arguments: ["/bin/chmod", String(restore.mode ?? 0o644, radix: 8), path])
        } else {
            try runSudo(arguments: ["/bin/rm", path])
        }
        let restored = try ResolverFileSnapshot.read(path)
        guard restored.exists == restore.exists, restored.bytes == restore.bytes, (!restore.exists || (restored.owner == restore.owner && restored.group == restore.group && restored.mode == restore.mode)) else {
            throw DNSCapabilityError.ownershipUncertain("Resolver restoration could not be verified")
        }
    }
    private func runSudo(arguments: [String], input: Data? = nil) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo"); process.arguments = ["-n"] + arguments
        let error = Pipe(); process.standardError = error
        if let input { let pipe = Pipe(); process.standardInput = pipe; try process.run(); pipe.fileHandleForWriting.write(input); pipe.fileHandleForWriting.closeFile() } else { try process.run() }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DNSCapabilityError.authorizationRequired(String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sudo failed") }
    }
}

public enum DNSCapabilityError: Error, Equatable, Sendable { case invalidPort(Int), externalConflict, ownershipMismatch, ownershipUncertain(String), resolverConflict(String), responderUnverified(String), responderShutdownFailed(String), privilegeUnavailable, authorizationRequired(String), processFailed(String) }

public enum DNSResponderState: String, Codable, Sendable { case stopped, ownedRunning, exited, unverified }
public struct DNSResponderIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let arguments: [String]
    public let startedAt: String
    public init(pid: Int32, executablePath: String, arguments: [String], startedAt: String) { self.pid = pid; self.executablePath = executablePath; self.arguments = arguments; self.startedAt = startedAt }
}
public struct DNSResponderStatus: Equatable, Sendable {
    public let state: DNSResponderState
    public let pid: Int32?
    public let listenerResponding: Bool
    public let listenerPresent: Bool
    public let identity: DNSResponderIdentity?
    public init(state: DNSResponderState, pid: Int32? = nil, listenerResponding: Bool = false, listenerPresent: Bool = false, identity: DNSResponderIdentity? = nil) { self.state = state; self.pid = pid; self.listenerResponding = listenerResponding; self.listenerPresent = listenerPresent; self.identity = identity }
}
public protocol DNSResponderControlling: Sendable {
    func validateExecutable() async throws
    func status() async -> DNSResponderStatus
    func start() async throws -> DNSResponderIdentity
    func stop(expected: DNSResponderIdentity, timeout: TimeInterval) async throws -> DNSResponderStatus
}

public extension DNSResponderControlling {
    func validateExecutable() async throws {}
}

public actor DNSResponderSupervisor: DNSResponderControlling {
    public let layout: VaelenFilesystemLayout
    public let port: Int
    private let executablePath: String
    private var ownedChild: OwnedChildProcess?
    private var ownedIdentity: DNSResponderIdentity?
    private var lastExitedPID: Int32?
    private var lastExitedIdentity: DNSResponderIdentity?
    private let launchArguments: @Sendable (Int) -> [String]
    private let startupTimeout: TimeInterval
    public init(layout: VaelenFilesystemLayout, port: Int = 53535, executablePath: String? = nil, launchArguments: (@Sendable (Int) -> [String])? = nil, startupTimeout: TimeInterval = 1) {
        self.layout = layout; self.port = port
        self.executablePath = (executablePath.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("vaelendns")).standardizedFileURL.path
        self.launchArguments = launchArguments ?? { ["--port", "\($0)"] }
        self.startupTimeout = startupTimeout
    }
    public func validateExecutable() async throws {
        try validateExecutableFile()
    }
    private func validateExecutableFile() throws {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw DNSCapabilityError.processFailed("DNS responder executable is unavailable")
        }
    }
    public func status() -> DNSResponderStatus {
        if let child = ownedChild, let identity = ownedIdentity {
            if child.isRunningAndReapedIfExited() {
                let responding = responds(), present = listenerPresent()
                return .init(state: .ownedRunning, pid: identity.pid, listenerResponding: responding, listenerPresent: present, identity: identity)
            }
            child.process.waitUntilExit()
            lastExitedPID = identity.pid; ownedChild = nil; ownedIdentity = nil
            let responding = responds(), present = listenerPresent()
            lastExitedIdentity = identity
            return .init(state: present ? .unverified : .exited, pid: present ? nil : identity.pid, listenerResponding: responding, listenerPresent: present, identity: identity)
        }
        let responding = responds(), present = listenerPresent()
        if present { return .init(state: .unverified, listenerResponding: responding, listenerPresent: true) }
        if let lastExitedPID { return .init(state: .exited, pid: lastExitedPID) }
        return .init(state: .stopped)
    }
    public func start() throws -> DNSResponderIdentity {
        if ownedChild != nil {
            let current = status()
            if current.state == .ownedRunning, let identity = current.identity { return identity }
        }
        if listenerPresent() { throw DNSCapabilityError.responderUnverified("127.0.0.1:\(port) already has a listener Vaelen cannot prove it started") }
        try validateExecutableFile()
        let arguments = launchArguments(port)
        let child = try OwnedChildProcess.launch(executable: URL(fileURLWithPath: executablePath), arguments: arguments, label: "Vaelen DNS responder")
        let identity = DNSResponderIdentity(pid: child.processIdentifier, executablePath: openedExecutablePath(child.processIdentifier) ?? executablePath, arguments: arguments, startedAt: processStartIdentity(child.processIdentifier))
        ownedChild = child; ownedIdentity = identity; lastExitedPID = nil; lastExitedIdentity = nil
        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if !child.isRunningAndReapedIfExited() { break }
            if responds() { return identity }
            usleep(20_000)
        }
        if child.isRunningAndReapedIfExited() { _ = child.terminateAndWait(timeout: 1, signal: SIGTERM, waitForDescendants: false) }
        if !child.isRunningAndReapedIfExited() { child.process.waitUntilExit(); ownedChild = nil; ownedIdentity = nil; lastExitedPID = identity.pid }
        throw DNSCapabilityError.processFailed("DNS responder could not bind 127.0.0.1:\(port)")
    }
    public func stop(expected: DNSResponderIdentity, timeout: TimeInterval) throws -> DNSResponderStatus {
        if ownedChild == nil, lastExitedIdentity == expected {
            let status = self.status()
            guard !status.listenerPresent else { throw DNSCapabilityError.responderShutdownFailed("Owned DNS responder exited, but 127.0.0.1:\(port) is still bound") }
            return status
        }
        guard let child = ownedChild, let identity = ownedIdentity, identity == expected, child.processIdentifier == expected.pid,
              child.arguments == expected.arguments else {
            // A Core restart drops Foundation's Process handle, not the
            // durable DNS identity. Reconcile it using the recorded PID,
            // executable, argv and start time before signaling.
            guard processMatches(expected) else {
                guard !listenerPresent() else { throw DNSCapabilityError.responderUnverified("A DNS listener remains, but it does not match Vaelen's recorded responder") }
                return .init(state: .stopped)
            }
            guard kill(expected.pid, SIGTERM) == 0 || errno == ESRCH else {
                throw DNSCapabilityError.responderShutdownFailed("Recorded DNS responder PID \(expected.pid) could not be asked to stop")
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, processMatches(expected) { usleep(20_000) }
            guard !processMatches(expected), !listenerPresent() else {
                throw DNSCapabilityError.responderShutdownFailed("Recorded DNS responder PID \(expected.pid) or its listener remains after shutdown")
            }
            lastExitedPID = expected.pid; lastExitedIdentity = expected
            return .init(state: .exited, pid: expected.pid, listenerResponding: false, listenerPresent: false, identity: expected)
        }
        if child.isRunningAndReapedIfExited() {
            guard processStartIdentity(expected.pid) == expected.startedAt else { throw DNSCapabilityError.responderUnverified("Owned DNS responder PID identity changed; no signal was sent") }
            guard child.terminateAndWait(timeout: timeout, signal: SIGTERM, waitForDescendants: false) else {
                throw DNSCapabilityError.responderShutdownFailed("Owned DNS responder PID \(expected.pid) did not exit before the shutdown timeout")
            }
        }
        child.process.waitUntilExit(); ownedChild = nil; ownedIdentity = nil; lastExitedPID = expected.pid; lastExitedIdentity = expected
        let status = self.status()
        guard !status.listenerPresent else { throw DNSCapabilityError.responderShutdownFailed("Owned DNS responder exited, but 127.0.0.1:\(port) is still bound") }
        return status
    }

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

    private func listenerPresent() -> Bool {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return result != 0
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

    private func processStartIdentity(_ pid: Int32) -> String { (try? command("/bin/ps", ["-p", "\(pid)", "-o", "lstart="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private func processMatches(_ identity: DNSResponderIdentity) -> Bool {
        guard identity.pid > 1, processStartIdentity(identity.pid) == identity.startedAt else { return false }
        let commandLine = (try? command("/bin/ps", ["-p", "\(identity.pid)", "-o", "command="]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard commandLine.contains(identity.executablePath), identity.arguments.allSatisfy({ commandLine.contains($0) }) else { return false }
        let executable = (try? command("/usr/sbin/lsof", ["-p", "\(identity.pid)", "-a", "-d", "txt", "-Fn"])) ?? ""
        let expectedExecutable = URL(fileURLWithPath: identity.executablePath).resolvingSymlinksInPath().path
        return executable.split(separator: "\n").contains { entry in
            guard entry.first == "n" else { return false }
            return URL(fileURLWithPath: String(entry.dropFirst())).resolvingSymlinksInPath().path == expectedExecutable
        }
    }
    private func openedExecutablePath(_ pid: Int32) -> String? {
        let output = (try? command("/usr/sbin/lsof", ["-p", "\(pid)", "-a", "-d", "txt", "-Fn"])) ?? ""
        return output.split(separator: "\n").first(where: { $0.hasPrefix("n/") }).map { String($0.dropFirst()) }
    }
    private func command(_ executable: String, _ arguments: [String]) throws -> String { let process = Process(); let output = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = output; try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return String(data: data, encoding: .utf8) ?? "" }
}

public actor DNSCapability {
    private let shutdownTimingLogger = Logger(subsystem: "dev.vaelen.daemon", category: "shutdown-timing")
    private let helper: any PrivilegedDNSHelper
    private let responder: any DNSResponderControlling
    private let port: Int
    private let ledger: SystemModificationLedger?
    private let responderShutdownTimeout: TimeInterval
    private let lifecycleGate = DNSLifecycleGate()
    private var expectedContent: String?
    private var resolverRecord: DNSResolverOwnershipRecord?
    private var ownershipLoadFailed = false
    public init(layout: VaelenFilesystemLayout = .init(), helper: any PrivilegedDNSHelper = UnavailablePrivilegedDNSHelper(), responder: (any DNSResponderControlling)? = nil, port: Int = 53535, ledger: SystemModificationLedger? = nil, responderShutdownTimeout: TimeInterval = 3) {
        self.helper = helper; self.port = port; self.ledger = ledger; self.responderShutdownTimeout = responderShutdownTimeout
        do { self.resolverRecord = try ledger?.resolverOwnershipRecord() }
        catch { self.resolverRecord = nil; self.ownershipLoadFailed = true }
        if let bytes = self.resolverRecord?.written?.bytes { self.expectedContent = String(decoding: bytes, as: UTF8.self) }
        else {
            do { let legacy = try ledger?.dnsRecord(); self.expectedContent = legacy?.active == true ? legacy?.installedContent : nil }
            catch { self.expectedContent = nil; self.ownershipLoadFailed = true }
        }
        self.responder = responder ?? DNSResponderSupervisor(layout: layout, port: port)
    }
    public func status() async -> DNSStatus {
        let process = await responder.status()
        let inspection: ResolverInspection
        do { inspection = try await helper.inspectTestResolver() }
        catch let error as DNSCapabilityError {
            if case .resolverConflict = error { return DNSStatus(state: .conflict, ownership: .external, port: port, pid: process.pid, responderState: process.state, health: "conflict", conflict: "Resolver path is a symlink or unexpected file type; it was not followed or changed.") }
            if case .privilegeUnavailable = error { return DNSStatus(state: .unavailable, ownership: .unknown, port: port, pid: process.pid, responderState: process.state, health: "privilege-unavailable", conflict: "Vaelen’s privileged helper is not registered or approved.") }
            return DNSStatus(state: .unavailable, ownership: .unknown, port: port, pid: process.pid, responderState: process.state, health: "unavailable", conflict: String(describing: error))
        } catch { return DNSStatus(state: .unavailable, ownership: .unknown, port: port, pid: process.pid, responderState: process.state, health: "unavailable", conflict: String(describing: error)) }
        if ownershipLoadFailed { return DNSStatus(state: .conflict, ownership: .unknown, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "ownership-uncertain", conflict: "Durable resolver ownership record is unreadable; no resolver change was attempted.") }
        let record = loadResolverRecord()
        if ownershipLoadFailed { return DNSStatus(state: .conflict, ownership: .unknown, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "ownership-uncertain", conflict: "Durable resolver ownership record could not be read; no resolver change was attempted.") }
        if let record, record.phase == .resolverRestored {
            switch process.state {
            case .ownedRunning: return DNSStatus(state: .unhealthy, ownership: record.previous.exists ? .external : .none, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "resolver-restored-responder-running", conflict: "Resolver state was restored, but owned vaelendns PID \(process.pid ?? 0) still needs shutdown.")
            case .unverified: return DNSStatus(state: .conflict, ownership: record.previous.exists ? .external : .none, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "resolver-restored-responder-unverified", conflict: "A DNS listener is still active; retry cleanup or inspect the live listener.")
            case .exited, .stopped: return DNSStatus(state: .notInstalled, ownership: record.previous.exists ? .external : .none, resolverContent: inspection.content, port: port, pid: nil, responderState: process.state, health: "stopped")
            }
        }
        if let record, record.phase != .owned { return DNSStatus(state: .conflict, ownership: .unknown, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "ownership-uncertain", conflict: "Resolver ownership recovery is incomplete (\(record.phase.rawValue)); preserve the record and inspect the resolver path.") }
        if let record, let written = record.written, inspection.snapshot != written { return DNSStatus(state: .conflict, ownership: .external, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "conflict", conflict: "Resolver changed independently; it was left untouched and the recovery record was retained.") }
        if process.state == .unverified { return DNSStatus(state: .conflict, ownership: record == nil ? inspection.ownership : .vaelen, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "responder-unverified", conflict: "A DNS listener responds, but Core has no retained launch handle proving Vaelen owns it.") }
        if record == nil {
            if process.state == .ownedRunning { return DNSStatus(state: .unhealthy, ownership: inspection.ownership, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "owned-responder-without-resolver-record", conflict: "Vaelen owns a responder but has no resolver ownership record.") }
            return DNSStatus(state: .notInstalled, ownership: inspection.ownership, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: process.state == .exited ? "responder-exited" : "stopped")
        }
        switch process.state {
        case .ownedRunning where process.listenerResponding:
            return DNSStatus(state: .installed, ownership: .vaelen, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "healthy")
        case .ownedRunning:
            return DNSStatus(state: .unhealthy, ownership: .vaelen, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "owned-responder-not-answering")
        case .exited:
            return DNSStatus(state: .unhealthy, ownership: .vaelen, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "responder-exited")
        case .unverified:
            return DNSStatus(state: .conflict, ownership: .vaelen, resolverContent: inspection.content, port: port, pid: process.pid, responderState: process.state, health: "responder-unverified")
        case .stopped:
            return DNSStatus(state: .unhealthy, ownership: .vaelen, resolverContent: inspection.content, port: port, pid: nil, responderState: process.state, health: "responder-stopped")
        }
    }
    public func install(takeover: Bool = false) async throws -> DNSStatus {
        try await withLifecycleGate { try await performInstall(takeover: takeover) }
    }

    private func performInstall(takeover: Bool) async throws -> DNSStatus {
        guard !ownershipLoadFailed else { throw DNSCapabilityError.ownershipUncertain("Durable resolver ownership record is unreadable; preserve the current resolver file and record") }
        guard ledger != nil else { throw DNSCapabilityError.ownershipUncertain("Resolver takeover requires durable Core state; no file change was made") }
        let inspection = try await helper.inspectTestResolver()
        let existingRecord = loadResolverRecord()
        guard !ownershipLoadFailed else { throw DNSCapabilityError.ownershipUncertain("Durable resolver ownership record could not be read; no resolver change was made") }
        let previous: ResolverFileSnapshot
        if let record = existingRecord {
            if record.phase == .owned, let written = record.written {
                guard inspection.snapshot == written else { throw DNSCapabilityError.ownershipMismatch }
                let identity = try await responder.start()
                if record.responder != identity {
                    let updated = DNSResolverOwnershipRecord(phase: .owned, previous: record.previous, intendedBytes: record.intendedBytes, written: written, responder: identity)
                    try ledger?.saveResolverOwnershipRecord(updated); resolverRecord = updated
                }
                return await status()
            }
            if (record.phase == .prepared || record.phase == .uncertain), record.written == nil,
               resolverRestored(inspection.snapshot, matches: record.previous) {
                // An unchanged exact preimage proves no resolver acquisition
                // remains. Stop only the recorded responder identity, when
                // present, then discard this pre-mutation/incomplete attempt.
                if let identity = record.responder {
                    _ = try await responder.stop(expected: identity, timeout: responderShutdownTimeout)
                } else {
                    let responderStatus = await responder.status()
                    guard responderStatus.state == .stopped || responderStatus.state == .exited else {
                        throw DNSCapabilityError.ownershipUncertain("Resolver is unchanged but an unrecorded DNS responder is still live")
                    }
                }
                try ledger?.clearResolverOwnershipRecord()
                resolverRecord = nil
                // Already inside the lifecycle gate; recurse into the
                // operation body without trying to acquire the gate twice.
                return try await performInstall(takeover: takeover)
            }
            guard record.phase == .resolverRestored else { throw DNSCapabilityError.ownershipUncertain("A prior resolver operation is incomplete; disable or inspect it before enabling DNS again") }
            // Quit restored the exact preimage but retains this ownership
            // record as the user's prior takeover authorization. Reacquire
            // only if that external file is still byte-for-byte and
            // metadata-identical to the saved preimage.
            guard let currentPreimage = inspection.snapshot,
                  resolverRestored(currentPreimage, matches: record.previous) else { throw DNSCapabilityError.ownershipMismatch }
            // Restoration uses an atomic replacement, so an otherwise exact
            // resolver preimage can legitimately have a new inode/device
            // identity after Quit. The saved record authorizes its content
            // and metadata; capture the freshly inspected identity for this
            // acquisition so the helper's stricter compare-and-write checks
            // the state actually inspected on this launch.
            previous = currentPreimage
        } else {
            if let legacy = try ledger?.dnsRecord(), legacy.active { throw DNSCapabilityError.ownershipUncertain("An older resolver record lacks exact file metadata; refusing another takeover") }
            // Existing resolver data is a temporary preimage, not ownership.
            // Preserve and displace it for this activation regardless of the
            // legacy takeover flag; the privileged helper rechecks the exact
            // snapshot immediately before writing.
            guard let snapshot = inspection.snapshot else { throw DNSCapabilityError.ownershipUncertain("Resolver inspection did not provide a safe file snapshot") }
            previous = snapshot
        }
        // The packaged responder is a prerequisite, so detect its absence
        // before creating a durable acquisition record.
        try await responder.validateExecutable()
        let content = "nameserver 127.0.0.1\nport \(port)\n"
        var record = DNSResolverOwnershipRecord(phase: .prepared, previous: previous, intendedBytes: Data(content.utf8), written: nil)
        try ledger?.saveResolverOwnershipRecord(record); resolverRecord = record
        let responderIdentity: DNSResponderIdentity
        do {
            responderIdentity = try await responder.start()
        } catch {
            let responderStatus = await responder.status()
            let resolverUnchanged = (try? await helper.inspectTestResolver()).flatMap(\.snapshot) == previous
            if (responderStatus.state == .stopped || responderStatus.state == .exited), resolverUnchanged {
                try? ledger?.clearResolverOwnershipRecord()
                resolverRecord = nil
                throw error
            }
            let uncertain = DNSResolverOwnershipRecord(phase: .uncertain, previous: previous, intendedBytes: Data(content.utf8), written: nil)
            try? ledger?.saveResolverOwnershipRecord(uncertain)
            resolverRecord = uncertain
            throw DNSCapabilityError.ownershipUncertain("DNS responder startup failed and resolver state could not be proven unchanged; recovery record retained")
        }
        record = DNSResolverOwnershipRecord(phase: .prepared, previous: previous, intendedBytes: Data(content.utf8), written: nil, responder: responderIdentity)
        resolverRecord = record
        do { try ledger?.saveResolverOwnershipRecord(record) }
        catch {
            let stopped = (try? await responder.stop(expected: responderIdentity, timeout: responderShutdownTimeout)) != nil
            let unchanged = (try? await helper.inspectTestResolver()).flatMap(\.snapshot) == previous
            if stopped && unchanged {
                try? ledger?.clearResolverOwnershipRecord()
                resolverRecord = nil
                throw DNSCapabilityError.processFailed("Could not durably record the launched DNS responder identity; no resolver change was made")
            }
            let uncertain = DNSResolverOwnershipRecord(phase: .uncertain, previous: previous, intendedBytes: Data(content.utf8), written: nil, responder: responderIdentity)
            resolverRecord = uncertain
            try? ledger?.saveResolverOwnershipRecord(uncertain)
            throw DNSCapabilityError.ownershipUncertain("Could not durably record the launched DNS responder identity; resolver state may require inspection")
        }
        do {
            let written = try await helper.installTestResolver(port: port, replacing: previous)
            record = DNSResolverOwnershipRecord(phase: .owned, previous: previous, intendedBytes: Data(content.utf8), written: written, responder: responderIdentity)
            try ledger?.saveResolverOwnershipRecord(record); resolverRecord = record
        } catch {
            // XPC may fail after the privileged write committed. Reinspect
            // and restore only a snapshot whose exact bytes are our intended
            // resolver value. Never stop vaelendns while the resolver may
            // still point at it.
            var observedWritten: ResolverFileSnapshot?
            var resolverSafeToStop = false
            if let after = try? await helper.inspectTestResolver(), let snapshot = after.snapshot {
                if snapshot.bytes == Data(content.utf8) {
                    observedWritten = snapshot
                    do {
                        try await helper.removeTestResolver(expected: snapshot, restore: previous)
                        let restored = try await helper.inspectTestResolver()
                        resolverSafeToStop = resolverRestored(restored.snapshot, matches: previous)
                    } catch { resolverSafeToStop = false }
                } else {
                    resolverSafeToStop = resolverRestored(snapshot, matches: previous)
                }
            }
            let uncertain = DNSResolverOwnershipRecord(phase: .uncertain, previous: previous, intendedBytes: Data(content.utf8), written: observedWritten, responder: responderIdentity)
            try? ledger?.saveResolverOwnershipRecord(uncertain); resolverRecord = uncertain
            if resolverSafeToStop { _ = try? await responder.stop(expected: responderIdentity, timeout: responderShutdownTimeout) }
            throw error
        }
        expectedContent = content
        try ledger?.recordDNS(installedContent: content, previousContent: inspection.content)
        return await status()
    }
    public func remove() async throws -> DNSStatus {
        try await withLifecycleGate { try await restoreResolverAndStopResponder(retainingAuthorization: false) }
    }

    /// Quit releases the responder and restores the exact resolver preimage,
    /// while retaining a `.resolverRestored` record as proof that a later
    /// launch may reacquire only that unchanged preimage.
    public func shutdownForQuit() async throws -> DNSStatus {
        try await withLifecycleGate { try await restoreResolverAndStopResponder(retainingAuthorization: true) }
    }

    private func withLifecycleGate<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        await lifecycleGate.acquire()
        do {
            let result = try await operation()
            await lifecycleGate.release()
            return result
        } catch {
            await lifecycleGate.release()
            throw error
        }
    }

    private func restoreResolverAndStopResponder(retainingAuthorization: Bool) async throws -> DNSStatus {
        guard !ownershipLoadFailed else { throw DNSCapabilityError.ownershipUncertain("Durable resolver ownership record is unreadable; automatic restore is unsafe") }
        guard let record = try ledger?.resolverOwnershipRecord() ?? resolverRecord else {
            if let legacy = try ledger?.dnsRecord(), legacy.active { throw DNSCapabilityError.ownershipUncertain("Legacy DNS record has no exact resolver snapshot; refusing automatic restoration") }
            return await status()
        }
        if record.phase == .resolverRestored {
            let inspection = try await helper.inspectTestResolver()
            if !resolverRestored(inspection.snapshot, matches: record.previous) {
                try await stopResponderForRelease(record)
                try ledger?.deactivateDNS(); try ledger?.clearResolverOwnershipRecord()
                resolverRecord = nil; expectedContent = nil
                return await status()
            }
            try await finishResponderCleanup(record, retainingAuthorization: retainingAuthorization)
            return await status()
        }
        let inspection = try await helper.inspectTestResolver()
        if (record.phase == .prepared || record.phase == .uncertain), record.written == nil {
            if resolverRestored(inspection.snapshot, matches: record.previous) {
                try await stopResponderForRelease(record)
                if retainingAuthorization {
                    let restored = DNSResolverOwnershipRecord(phase: .resolverRestored, previous: record.previous, intendedBytes: record.intendedBytes, written: nil)
                    try ledger?.saveResolverOwnershipRecord(restored); resolverRecord = restored
                } else {
                    try ledger?.clearResolverOwnershipRecord(); resolverRecord = nil
                }
                try ledger?.deactivateDNS(); expectedContent = nil
                return await status()
            }
            throw DNSCapabilityError.ownershipUncertain("Resolver state differs from the saved preimage and no exact Vaelen write was recorded; preserving it for inspection")
        }
        guard let written = record.written else { throw DNSCapabilityError.ownershipUncertain("Resolver takeover did not reach a verifiable completed state; recovery record retained") }
        if record.phase == .restoring, resolverRestored(inspection.snapshot, matches: record.previous) {
            let restored = DNSResolverOwnershipRecord(phase: .resolverRestored, previous: record.previous, intendedBytes: record.intendedBytes, written: written, responder: record.responder)
            try ledger?.saveResolverOwnershipRecord(restored); resolverRecord = restored
            try await finishResponderCleanup(restored, retainingAuthorization: retainingAuthorization)
            return await status()
        }
        guard record.phase == .owned || record.phase == .restoring || record.phase == .uncertain else { throw DNSCapabilityError.ownershipUncertain("Resolver acquisition could not be reconciled; no external resolver change was overwritten") }
        guard inspection.snapshot == written else {
            // External drift means Vaelen no longer controls the resolver.
            // Preserve it and release our responder/bookkeeping if its
            // original launch identity still proves the process is ours.
            try await stopResponderForRelease(record)
            try ledger?.deactivateDNS()
            try ledger?.clearResolverOwnershipRecord()
            resolverRecord = nil; expectedContent = nil
            return await status()
        }
        let restoring = DNSResolverOwnershipRecord(phase: .restoring, previous: record.previous, intendedBytes: record.intendedBytes, written: written, responder: record.responder)
        try ledger?.saveResolverOwnershipRecord(restoring); resolverRecord = restoring
        do {
            logShutdownTiming("resolver restore begin")
            try await helper.removeTestResolver(expected: written, restore: record.previous)
            let after = try await helper.inspectTestResolver()
            guard resolverRestored(after.snapshot, matches: record.previous) else { throw DNSCapabilityError.ownershipUncertain("Resolver restore verification did not match the saved preimage") }
            logShutdownTiming("resolver restore end")
            let restored = DNSResolverOwnershipRecord(phase: .resolverRestored, previous: record.previous, intendedBytes: record.intendedBytes, written: written, responder: record.responder)
            try ledger?.saveResolverOwnershipRecord(restored); resolverRecord = restored
            try await finishResponderCleanup(restored, retainingAuthorization: retainingAuthorization)
        } catch {
            throw error
        }
        return await status()
    }

    private func finishResponderCleanup(_ record: DNSResolverOwnershipRecord, retainingAuthorization: Bool) async throws {
        let responderStatus = await responder.status()
        if responderStatus.state == .stopped || responderStatus.state == .exited {
            guard !responderStatus.listenerResponding && !responderStatus.listenerPresent else { throw DNSCapabilityError.responderShutdownFailed("Resolver was restored, but a DNS listener still occupies 127.0.0.1:\(port)") }
            try ledger?.deactivateDNS()
            if retainingAuthorization { resolverRecord = record }
            else { try ledger?.clearResolverOwnershipRecord(); resolverRecord = nil }
            expectedContent = nil
            return
        }
        guard let identity = record.responder ?? responderStatus.identity else {
            if responderStatus.listenerPresent || responderStatus.listenerResponding {
                throw DNSCapabilityError.responderShutdownFailed("Resolver was restored, but an unowned DNS listener still occupies 127.0.0.1:\(port); no process was signaled")
            }
            throw DNSCapabilityError.responderUnverified("Resolver was restored, but Core cannot prove it owns the responding DNS process; ownership record retained")
        }
        let stopped = try await responder.stop(expected: identity, timeout: responderShutdownTimeout)
        guard !stopped.listenerResponding else { throw DNSCapabilityError.responderShutdownFailed("Resolver was restored, but a DNS listener still responds on 127.0.0.1:\(port)") }
        try ledger?.deactivateDNS()
        if retainingAuthorization { resolverRecord = record }
        else { try ledger?.clearResolverOwnershipRecord(); resolverRecord = nil }
        expectedContent = nil
    }

    private func stopResponderForRelease(_ record: DNSResolverOwnershipRecord) async throws {
        let responderStatus = await responder.status()
        guard responderStatus.state != .stopped && responderStatus.state != .exited else { return }
        guard let identity = record.responder ?? responderStatus.identity else {
            throw DNSCapabilityError.responderUnverified("Resolver changed externally; Vaelen left it untouched but cannot safely identify its responder")
        }
        _ = try await responder.stop(expected: identity, timeout: responderShutdownTimeout)
    }

    private func loadResolverRecord() -> DNSResolverOwnershipRecord? {
        do { resolverRecord = try ledger?.resolverOwnershipRecord() }
        catch { ownershipLoadFailed = true }
        return resolverRecord
    }

    private func logShutdownTiming(_ event: String) {
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        shutdownTimingLogger.notice("SHUTDOWN_TIMING \(event, privacy: .public) epoch=\(timestamp, privacy: .public)")
    }

    private func resolverRestored(_ current: ResolverFileSnapshot?, matches prior: ResolverFileSnapshot) -> Bool {
        guard let current, current.exists == prior.exists, current.bytes == prior.bytes else { return false }
        return !prior.exists || (current.owner == prior.owner && current.group == prior.group && current.mode == prior.mode && current.fileType == prior.fileType)
    }
}

/// Actor methods are reentrant across helper and responder awaits. Serialize
/// all DNS mutations/recovery over those suspension points so a saved-service
/// startup install cannot overlap a user retry or shutdown restoration.
private actor DNSLifecycleGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().resume() }
    }
}
