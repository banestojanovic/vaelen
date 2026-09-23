import XCTest
import Darwin
import Foundation
@testable import VaelenCore

final class MailpitModuleTests: XCTestCase {
    func testOwnedFixtureLifecycleReleasesBothListenersAndIsReaped() throws {
        let fixture = try makeFixture(resistTermination: false)
        defer { removeTestRoot(fixture.root) }
        let initial = fixture.module.status()
        XCTAssertEqual(initial.state, .installed)
        let started = try fixture.module.start()
        XCTAssertEqual(started.state, .running)
        XCTAssertEqual(started.health, "healthy")
        let pid = try XCTUnwrap(started.pid)
        XCTAssertTrue(isProcessLive(pid))
        XCTAssertTrue(portAcceptsConnection(started.smtpPort))
        XCTAssertTrue(portAcceptsConnection(started.httpPort))

        let stopped = try fixture.module.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.health, "stopped")
        XCTAssertNil(stopped.pid)
        XCTAssertFalse(isProcessLive(pid))
        XCTAssertFalse(portAcceptsConnection(started.smtpPort))
        XCTAssertFalse(portAcceptsConnection(started.httpPort))
        XCTAssertEqual(fixture.module.status().state, .stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.module.instanceDatabasePath()))
    }

    func testAlreadyExitedOwnedChildIsReapedAndListenersUnavailable() throws {
        let fixture = try makeFixture(resistTermination: false)
        defer { removeTestRoot(fixture.root) }
        let started = try fixture.module.start()
        let pid = try XCTUnwrap(started.pid)
        XCTAssertEqual(kill(pid, SIGTERM), 0)
        XCTAssertTrue(waitUntil { !isProcessLive(pid) })
        XCTAssertFalse(portAcceptsConnection(started.smtpPort))
        XCTAssertFalse(portAcceptsConnection(started.httpPort))
        let status = fixture.module.status()
        XCTAssertEqual(status.state, .stopped)
        XCTAssertEqual(status.health, "stopped")
        XCTAssertNil(status.pid)
        let stopped = try fixture.module.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(portAcceptsConnection(started.smtpPort))
        XCTAssertFalse(portAcceptsConnection(started.httpPort))
        XCTAssertFalse(isProcessLive(pid))
    }

    func testPersistedPIDOrMismatchedRecordCannotSignalUnrelatedProcess() throws {
        let fixture = try makeFixture(resistTermination: false)
        defer { removeTestRoot(fixture.root) }
        let processFile = fixture.processFile
        let unrelated = try launchUnrelatedListener()
        defer { unrelated.terminate(); unrelated.waitUntilExit() }
        let record = MailpitFixtureRecord(pid: unrelated.processIdentifier, user: NSUserName(), version: "1.31.1", executable: "/tmp/not-the-fixture", arguments: ["--smtp", "127.0.0.1:\(fixture.configuration.smtpPort)"], database: fixture.module.instanceDatabasePath(), log: "", smtpPort: fixture.configuration.smtpPort, httpPort: fixture.configuration.httpPort, startedAt: processStartIdentity(unrelated.processIdentifier))
        try JSONEncoder().encode(record).write(to: processFile)
        let status = fixture.module.status()
        XCTAssertEqual(status.state, .unhealthy)
        XCTAssertEqual(status.health, "identity-unverified")
        XCTAssertThrowsError(try fixture.module.stop()) { XCTAssertEqual($0 as? MailpitModuleError, .processIdentityMismatch) }
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertTrue(isProcessLive(unrelated.processIdentifier))
        XCTAssertFalse(portAcceptsConnection(fixture.configuration.smtpPort))
        XCTAssertFalse(portAcceptsConnection(fixture.configuration.httpPort))
    }

    func testExitedChildWithReoccupiedListenerRetainsRecordUntilRelease() throws {
        let fixture = try makeFixture(resistTermination: false)
        defer { removeTestRoot(fixture.root) }
        let started = try fixture.module.start()
        let pid = try XCTUnwrap(started.pid)
        XCTAssertEqual(kill(pid, SIGTERM), 0)
        XCTAssertTrue(waitUntil { !isProcessLive(pid) })
        let external = try launchListener(on: started.smtpPort)
        defer { external.terminate(); external.waitUntilExit() }
        XCTAssertTrue(portAcceptsConnection(started.smtpPort))
        XCTAssertFalse(portAcceptsConnection(started.httpPort))
        let status = fixture.module.status()
        XCTAssertEqual(status.state, .unhealthy)
        XCTAssertEqual(status.health, "listener-release-incomplete")
        XCTAssertNil(status.pid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.processFile.path))
        XCTAssertThrowsError(try fixture.module.stop()) { error in
            guard let moduleError = error as? MailpitModuleError, case .unhealthy = moduleError else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertTrue(external.isRunning, "provider must not signal the unrelated endpoint listener")
        external.terminate(); external.waitUntilExit()
        XCTAssertTrue(waitUntil { !portAcceptsConnection(started.smtpPort) })
        let stopped = try fixture.module.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.processFile.path))
    }

    func testGracefulStopTimeoutRetainsEvidenceAndRetrySucceeds() throws {
        let fixture = try makeFixture(resistTermination: true)
        defer { removeTestRoot(fixture.root) }
        let started = try fixture.module.start()
        let pid = try XCTUnwrap(started.pid)
        XCTAssertTrue(portAcceptsConnection(started.smtpPort))
        XCTAssertTrue(portAcceptsConnection(started.httpPort))
        XCTAssertThrowsError(try fixture.module.stop()) { error in
            guard let moduleError = error as? MailpitModuleError, case .unhealthy = moduleError else { return XCTFail("unexpected error: \(error)") }
        }
        let partial = fixture.module.status()
        XCTAssertEqual(partial.state, .running)
        XCTAssertEqual(partial.health, "healthy")
        XCTAssertEqual(partial.pid, pid)
        XCTAssertTrue(isProcessLive(pid))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.processFile.path))
        XCTAssertTrue(portAcceptsConnection(started.smtpPort))
        XCTAssertTrue(portAcceptsConnection(started.httpPort))

        try FileManager.default.removeItem(at: fixture.resistFile)
        let stopped = try fixture.module.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(isProcessLive(pid))
        XCTAssertFalse(portAcceptsConnection(started.smtpPort))
        XCTAssertFalse(portAcceptsConnection(started.httpPort))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.processFile.path))
    }

    func testLifecycleHealthSMTPAndPersistentMessages() async throws {
        let package = try testPackage()
        let root = URL(fileURLWithPath: "/tmp/vaelen-mailpit-\(UUID().uuidString)", isDirectory: true)
        defer { removeTestRoot(root) }
        let configuration = try testConfiguration()
        let layout = VaelenFilesystemLayout(rootURL: root)
        try copy(package: package, into: layout)
        let module = MailpitModule(layout: layout, configuration: configuration)

        XCTAssertEqual(module.status().state, .installed)
        let started = try module.start()
        XCTAssertEqual(started.state, .running)
        XCTAssertEqual(started.health, "healthy")
        XCTAssertEqual(started.smtpPort, configuration.smtpPort)
        XCTAssertEqual(started.httpPort, configuration.httpPort)
        try sendSMTP(port: configuration.smtpPort)
        let messages = try await fetchMessages(port: configuration.httpPort)
        XCTAssertTrue(messages.contains("mailpit-test-subject"), messages)

        let stopped = try module.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: module.instanceDatabasePath()))

        let restarted = try module.start()
        XCTAssertEqual(restarted.state, .running)
        let persistedMessages = try await fetchMessages(port: configuration.httpPort)
        XCTAssertTrue(persistedMessages.contains("mailpit-test-subject"), persistedMessages)
        _ = try module.stop()
    }

    func testExternalPortConflictDoesNotStartOrSignalAnything() throws {
        let package = try testPackage()
        let root = URL(fileURLWithPath: "/tmp/vaelen-mailpit-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { removeTestRoot(root) }
        let configuration = try testConfiguration()
        let layout = VaelenFilesystemLayout(rootURL: root)
        try copy(package: package, into: layout)
        let module = MailpitModule(layout: layout, configuration: configuration)
        let listener = try listen(on: configuration.smtpPort)
        defer { close(listener) }

        XCTAssertEqual(module.status().state, .conflict)
        XCTAssertThrowsError(try module.start()) { error in
            XCTAssertEqual(error as? MailpitModuleError, .portConflict(configuration.smtpPort))
        }
        XCTAssertEqual(fcntl(listener, F_GETFD), 0)
        XCTAssertNil(module.status().pid)
    }

    private func testPackage() throws -> MailpitPackage {
        guard let package = MailpitModule().installedVersions().first else { throw XCTSkip("Mailpit package prerequisite unavailable") }
        return package
    }

    private struct Fixture {
        let root: URL
        let module: MailpitModule
        let configuration: MailpitRuntimeConfiguration
        let resistFile: URL
        let processFile: URL
    }

    private struct MailpitFixtureRecord: Codable {
        let pid: Int32; let user: String; let version: String; let executable: String; let arguments: [String]; let database: String; let log: String; let smtpPort: Int; let httpPort: Int; let startedAt: String
    }

    private func makeFixture(resistTermination: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-mailpit-owned-\(UUID().uuidString)", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        let packageDirectory = layout.mailpitPackagesDirectoryURL.appendingPathComponent(MailpitModule.defaultVersion, isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let executable = packageDirectory.appendingPathComponent("mailpit")
        let script = #"""
#!/usr/bin/python3
import os, signal, socket, sys, select, time
args=sys.argv[1:]
smtp=args[args.index('--smtp')+1]; http=args[args.index('--listen')+1]
def endpoint(value):
    host, port=value.rsplit(':',1); return host,int(port)
listeners=[]
for value in (smtp,http):
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(endpoint(value)); s.listen(8); s.setblocking(False); listeners.append(s)
database=args[args.index('--database')+1]
open(database,'a').close()
resist=os.path.join(os.path.dirname(database),'resist-term')
def onterm(sig,frame):
    if not os.path.exists(resist): raise SystemExit(0)
signal.signal(signal.SIGTERM,onterm)
while True:
    ready,_,_=select.select(listeners,[],[],.1)
    for listener in ready:
        client,_=listener.accept(); client.settimeout(.3)
        try:
            if listener is listeners[0]:
                client.sendall(b'220 fixture Mailpit\r\n')
            else:
                client.recv(4096); client.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
        except Exception: pass
        client.close()
"""#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let package = MailpitPackage(version: MailpitModule.defaultVersion, architecture: "arm64", packagePath: packageDirectory.path, executablePath: executable.path, source: "fixture", artifactSHA256: MailpitManifest.official1_31_1.artifactSHA256, license: "MIT", installedAt: Date())
        try JSONEncoder().encode(package).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
        let configuration = MailpitRuntimeConfiguration(smtpPort: try ephemeralPort(), httpPort: try ephemeralPort())
        let module = MailpitModule(layout: layout, configuration: configuration)
        let resist = layout.mailpitInstancesDirectoryURL.appendingPathComponent("default/resist-term")
        try FileManager.default.createDirectory(at: resist.deletingLastPathComponent(), withIntermediateDirectories: true)
        if resistTermination { try Data("resist".utf8).write(to: resist) }
        return Fixture(root: root, module: module, configuration: configuration, resistFile: resist, processFile: layout.mailpitInstancesDirectoryURL.appendingPathComponent("default/process.json"))
    }

    private func ephemeralPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw MailpitModuleError.processFailed("socket") }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw MailpitModuleError.processFailed("bind") }
        var result = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &result) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard queried == 0 else { throw MailpitModuleError.processFailed("getsockname") }
        return Int(UInt16(bigEndian: result.sin_port))
    }

    private func portAcceptsConnection(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }

    private func isProcessLive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func waitUntil(_ predicate: () -> Bool) -> Bool { for _ in 0..<100 { if predicate() { return true }; usleep(20_000) }; return predicate() }
    private func processStartIdentity(_ pid: Int32) -> String { let p = Process(); let pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-p", "\(pid)", "-o", "lstart="]; p.standardOutput = pipe; guard (try? p.run()) != nil else { return "" }; let value = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func launchUnrelatedListener() throws -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-c", "import socket,time;s=socket.socket();s.bind(('127.0.0.1',0));s.listen();time.sleep(30)"]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try p.run(); return p
    }

    private func launchListener(on port: Int) throws -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',\(port)));s.listen();time.sleep(30)"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try p.run()
        XCTAssertTrue(waitUntil { portAcceptsConnection(port) })
        return p
    }

    private func testConfiguration() throws -> MailpitRuntimeConfiguration {
        let ports = try CaddyTestSupport.configuration()
        return MailpitRuntimeConfiguration(smtpPort: ports.httpPort, httpPort: ports.httpsPort)
    }

    private func copy(package: MailpitPackage, into layout: VaelenFilesystemLayout) throws {
        let final = layout.mailpitPackagesDirectoryURL.appendingPathComponent(package.version, isDirectory: true)
        try FileManager.default.createDirectory(at: layout.mailpitPackagesDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: package.packagePath), to: final)
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod"); chmod.arguments = ["-R", "u+w", final.path]; try chmod.run(); chmod.waitUntilExit()
        let copied = MailpitPackage(version: package.version, architecture: package.architecture, packagePath: final.path, executablePath: final.appendingPathComponent("mailpit").path, source: package.source, artifactSHA256: package.artifactSHA256, license: package.license, installedAt: package.installedAt)
        try JSONEncoder().encode(copied).write(to: final.appendingPathComponent(".vaelen-package.json"), options: .atomic)
    }

    private func removeTestRoot(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod"); process.arguments = ["-R", "u+w", root.path]; try? process.run(); process.waitUntilExit(); try? FileManager.default.removeItem(at: root)
    }

    private func listen(on port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MailpitModuleError.processFailed("socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, Darwin.listen(descriptor, 1) == 0 else { close(descriptor); throw MailpitModuleError.processFailed("bind") }
        return descriptor
    }

    private func sendSMTP(port: Int) throws {
        let descriptor = try connect(port: port); defer { close(descriptor) }
        _ = try receive(descriptor)
        try send(descriptor, "EHLO localhost\r\n")
        _ = try receive(descriptor)
        try send(descriptor, "MAIL FROM:<sender@example.test>\r\nRCPT TO:<recipient@example.test>\r\nDATA\r\nFrom: sender@example.test\r\nTo: recipient@example.test\r\nSubject: mailpit-test-subject\r\n\r\nMailpit test body\r\n.\r\nQUIT\r\n")
        _ = try receive(descriptor)
    }

    private func connect(port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0); guard descriptor >= 0 else { throw MailpitModuleError.processFailed("socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { close(descriptor); throw MailpitModuleError.processFailed("connect") }; return descriptor
    }

    private func send(_ descriptor: Int32, _ value: String) throws { let data = Data(value.utf8); try data.withUnsafeBytes { buffer in guard Darwin.send(descriptor, buffer.baseAddress!, buffer.count, 0) == buffer.count else { throw MailpitModuleError.processFailed("send") } } }
    private func receive(_ descriptor: Int32) throws -> String { var buffer = [UInt8](repeating: 0, count: 4096); let count = recv(descriptor, &buffer, buffer.count, 0); guard count > 0 else { throw MailpitModuleError.processFailed("receive") }; return String(decoding: buffer.prefix(count), as: UTF8.self) }
    private func fetchMessages(port: Int) async throws -> String { let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/v1/messages")!); return String(decoding: data, as: UTF8.self) }
}
