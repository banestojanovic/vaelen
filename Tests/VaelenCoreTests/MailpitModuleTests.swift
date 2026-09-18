import XCTest
import Darwin
import Foundation
@testable import VaelenCore

final class MailpitModuleTests: XCTestCase {
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
