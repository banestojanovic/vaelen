import XCTest
import Darwin
@testable import VaelenCore

/// macOS PF loopback finding (M4 Slice 3): while a Vaelen rdr anchor is
/// active, an `rdr ... to 127.0.0.1 port P -> 127.0.0.1 port Q` rule poisons
/// DIRECT connections to the target port Q on 127.0.0.1. SYNs hang in
/// SYN_RCVD (observed) while connections arriving via the rdr translation
/// complete normally, and unrelated ports (e.g. a :8789 control) are
/// unaffected. The kernel even carries reverse-association state of the
/// form `127.0.0.1:Q -> 127.0.0.1:P`, consistent with reply traffic from Q
/// being reverse-translated to P even for non-translated connections.
///
/// Consequence: backend-dependent tests must not run while Standard Ports
/// forwarding is active on the dev machine. They skip with a reason instead
/// of hanging; CI machines without PF run everything.
private enum DirectBackendGate {
    /// True unless direct TCP to the HTTP backend hangs (PF wedge signature).
    /// A fast refusal means the port is free and tests may start their own
    /// Caddy; a fast success means a (possibly stale) owner answers.
    /// Only a timeout skips.
    static func requireDirectBackend(file: StaticString = #filePath, line: UInt = #line) throws {
        if tcpConnectHangs(port: VaelenNetworkPorts.httpBackend) || tcpConnectHangsWithTemporaryListener(port: VaelenNetworkPorts.httpBackend) {
            throw XCTSkip("Standard Ports forwarding is active; backend tests need it disabled", file: file, line: line)
        }
    }

    private static func tcpConnectHangsWithTemporaryListener(port: Int) -> Bool {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { return false }
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 1) == 0 else { return false }
        return tcpConnectHangs(port: port)
    }

    private static func tcpConnectHangs(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result == 0 { return false }
        guard errno == EINPROGRESS else { return false }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        return poll(&pollDescriptor, 1, 2000) == 0
    }
}

final class CaddyRouterTests: XCTestCase {
    func testOfficialCaddyServesMultipleStaticRoutesAndRemovesOne() async throws {
        try DirectBackendGate.requireDirectBackend()
        let root = URL(fileURLWithPath: "/tmp/vaelen-router-\(UUID().uuidString)", isDirectory: true)
        let alphaRoot = root.appendingPathComponent("alpha", isDirectory: true)
        let betaRoot = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaRoot, withIntermediateDirectories: true)
        try Data("alpha response".utf8).write(to: alphaRoot.appendingPathComponent("index.html"))
        try Data("beta response".utf8).write(to: betaRoot.appendingPathComponent("index.html"))
        
        let layout = VaelenFilesystemLayout(rootURL: root)
        let package = try resolveCaddyPackage()
        let supervisor = CaddyProcessSupervisor(layout: layout)
        await supervisor.installPackage(package)
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await router.start()

        let alpha = Route(hostname: "alpha.test", target: .staticFiles(documentRoot: alphaRoot.path), tls: .disabled)
        let beta = Route(hostname: "beta.test", target: .staticFiles(documentRoot: betaRoot.path), tls: .disabled)
        try await router.reconcile(routes: [alpha, beta])
        XCTAssertEqual(try runCurl(host: "alpha.test"), "alpha response")
        XCTAssertEqual(try runCurl(host: "beta.test"), "beta response")

        try await router.removeRoute(id: alpha.id)
        XCTAssertNotEqual(try runCurl(host: "alpha.test"), "alpha response")
        XCTAssertEqual(try runCurl(host: "beta.test"), "beta response")
        try await router.stop()
    }

    func testOfficialCaddyServesControlledPHPFixtureThroughM2FPM() async throws {
        try DirectBackendGate.requireDirectBackend()
        guard let php = PHPModule.development(), let phpPackage = php.installedVersions().last else {
            throw XCTSkip("M2 PHP-FPM package is not installed")
        }
        let root = URL(fileURLWithPath: "/tmp/vaelen-fastcgi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<?php echo 'php response';".utf8).write(to: root.appendingPathComponent("index.php"))

        let layout = VaelenFilesystemLayout(rootURL: root)
        let supervisor = CaddyProcessSupervisor(layout: layout)
        let package = try resolveCaddyPackage()
        await supervisor.installPackage(package)
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            _ = try? php.stop(requestedVersion: phpPackage.version)
            try? FileManager.default.removeItem(at: root)
        }

        _ = try php.start(requestedVersion: phpPackage.version)
        try await router.start()
        let socket = try php.status(requestedVersion: phpPackage.version).socket
        let route = Route(hostname: "php.test", target: .fastCGI(socketPath: socket, documentRoot: root.path), tls: .disabled)
        try await router.reconcile(routes: [route])
        XCTAssertEqual(try runCurl(host: "php.test", path: "/index.php"), "php response")
    }

    func testOfficialCaddyReachesSyncproofLaravelFrontController() async throws {
        try DirectBackendGate.requireDirectBackend()
        guard let php = PHPModule.development(), let phpPackage = php.installedVersions().last else {
            throw XCTSkip("M2 PHP-FPM package is not installed")
        }
        let project = URL(fileURLWithPath: "/Users/banes/Code/syncproof", isDirectory: true)
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent("public/index.php").path) else {
            throw XCTSkip("syncproof project is not available")
        }
        let root = URL(fileURLWithPath: "/tmp/vaelen-syncproof-\(UUID().uuidString)", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        let supervisor = CaddyProcessSupervisor(layout: layout)
        await supervisor.installPackage(try resolveCaddyPackage())
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            _ = try? php.stop(requestedVersion: phpPackage.version)
            try? FileManager.default.removeItem(at: root)
        }

        _ = try php.start(requestedVersion: phpPackage.version)
        try await router.start()
        let route = Route(hostname: "syncproof.test", target: .fastCGI(socketPath: try php.status(requestedVersion: phpPackage.version).socket, documentRoot: project.appendingPathComponent("public").path), tls: .disabled)
        try await router.reconcile(routes: [route])

        let home = try runHTTP(host: "syncproof.test", path: "/")
        XCTAssertEqual(home.status, 302, home.body)
        XCTAssertTrue(home.headers.contains("/integrations"), home.headers)
        let login = try runHTTP(host: "syncproof.test", path: "/login")
        XCTAssertEqual(login.status, 200, login.body)
        XCTAssertTrue(login.body.contains("auth\\/login"), login.body)
    }

    func testTLSRouteRedirectsBackendHTTPToHTTPS() async throws {
        try DirectBackendGate.requireDirectBackend()
        let root = URL(fileURLWithPath: "/tmp/vaelen-redirect-\(UUID().uuidString)", isDirectory: true)
        let docRoot = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: docRoot, withIntermediateDirectories: true)
        try Data("redirect content".utf8).write(to: docRoot.appendingPathComponent("index.html"))

        let layout = VaelenFilesystemLayout(rootURL: root)
        let tls = TLSCapability(layout: layout)
        _ = try await tls.install()
        let supervisor = CaddyProcessSupervisor(layout: layout)
        await supervisor.installPackage(try resolveCaddyPackage())
        let router = CaddyRouter(layout: layout, supervisor: supervisor, tls: tls)
        addTeardownBlock {
            try? await router.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await router.start()
        try await router.reconcile(routes: [Route(hostname: "redirect.test", target: .staticFiles(documentRoot: docRoot.path), tls: .local)])

        let http = try runHTTP(host: "redirect.test", path: "/")
        XCTAssertEqual(http.status, 308, http.body)
        XCTAssertTrue(http.headers.contains("Location: https://redirect.test/"), http.headers)

        let https = try runBackendHTTPS(host: "redirect.test", path: "/")
        XCTAssertEqual(https.status, 200, https.body)
        XCTAssertTrue(https.body.contains("redirect content"), https.body)
    }

    func testRoutingDisablesHTTP3AndHoldsNoUDPListener() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-protocols-\(UUID().uuidString)", isDirectory: true)
        let docRoot = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: docRoot, withIntermediateDirectories: true)
        try Data("protocol content".utf8).write(to: docRoot.appendingPathComponent("index.html"))

        let layout = VaelenFilesystemLayout(rootURL: root)
        let supervisor = CaddyProcessSupervisor(layout: layout)
        await supervisor.installPackage(try resolveCaddyPackage())
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await router.start()
        try await router.reconcile(routes: [Route(hostname: "proto.test", target: .staticFiles(documentRoot: docRoot.path), tls: .disabled)])

        let admin = "unix//\(layout.routingRuntimeDirectoryURL.appendingPathComponent("admin.sock").path)"
        let config = try CaddyAdminClient(endpoint: admin).getConfig()
        guard let json = try JSONSerialization.jsonObject(with: config) as? [String: Any],
              let servers = ((json["apps"] as? [String: Any])?["http"] as? [String: Any])?["servers"] as? [String: Any] else {
            return XCTFail("Caddy config has no HTTP servers")
        }
        XCTAssertFalse(servers.isEmpty)
        for (name, value) in servers {
            guard let server = value as? [String: Any] else { return XCTFail("server \(name) is malformed") }
            XCTAssertEqual(server["protocols"] as? [String], ["h1", "h2"], "server \(name) must not enable HTTP/3")
            for listen in (server["listen"] as? [String] ?? []) {
                XCTAssertTrue(listen.hasPrefix("127.0.0.1:"), "server \(name) must bind loopback only: \(listen)")
            }
        }
        XCTAssertTrue(canBindUDP(port: VaelenNetworkPorts.httpBackend), "Caddy must not hold a UDP listener on the HTTP backend port")
        XCTAssertTrue(canBindUDP(port: VaelenNetworkPorts.httpsBackend), "Caddy must not hold a UDP listener on the HTTPS backend port")
    }

    private func resolveCaddyPackage() throws -> CaddyPackage {
        let module = CaddyModule(layout: VaelenFilesystemLayout())
        do {
            return try module.resolveInstalled(requestedVersion: "2.11.4")
        } catch CaddyModuleError.packageMissing {
            do {
                return try module.install(requestedVersion: "2.11.4")
            } catch {
                throw XCTSkip("Caddy distribution prerequisite unavailable: \(error)")
            }
        }
    }

    private func runCurl(host: String, path: String = "/") throws -> String {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-fsS", "-H", "Host: \(host)", "http://127.0.0.1:\(VaelenNetworkPorts.httpBackend)\(path)"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyRuntimeError.processFailed("curl failed for \(host)") }; return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runBackendHTTPS(host: String, path: String) throws -> (status: Int, headers: String, body: String) {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-k", "-sS", "-D", "-", "-o", "-", "--resolve", "\(host):\(VaelenNetworkPorts.httpsBackend):127.0.0.1", "https://\(host):\(VaelenNetworkPorts.httpsBackend)\(path)"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyRuntimeError.processFailed("curl failed for \(host)") }; let parts = output.components(separatedBy: "\r\n\r\n"); let header = parts.first ?? ""; let body = parts.dropFirst().joined(separator: "\r\n\r\n"); let status = Int(header.split(separator: "\n").first?.split(separator: " ").dropFirst().first ?? "0") ?? 0; return (status, header, body)
    }

    private func canBindUDP(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }

    private func runHTTP(host: String, path: String) throws -> (status: Int, headers: String, body: String) {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-sS", "-D", "-", "-o", "-", "-H", "Host: \(host)", "http://127.0.0.1:\(VaelenNetworkPorts.httpBackend)\(path)"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyRuntimeError.processFailed("curl failed for \(host)") }; let parts = output.components(separatedBy: "\r\n\r\n"); let header = parts.first ?? ""; let body = parts.dropFirst().joined(separator: "\r\n\r\n"); let status = Int(header.split(separator: "\n").first?.split(separator: " ").dropFirst().first ?? "0") ?? 0; return (status, header, body)
    }
}
