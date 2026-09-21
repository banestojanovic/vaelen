import XCTest
import Darwin
@testable import VaelenCore

final class CaddyRouterTests: XCTestCase {
    func testOfficialCaddyServesMultipleStaticRoutesAndRemovesOne() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-router-\(UUID().uuidString)", isDirectory: true)
        let alphaRoot = root.appendingPathComponent("alpha", isDirectory: true)
        let betaRoot = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaRoot, withIntermediateDirectories: true)
        try Data("alpha response".utf8).write(to: alphaRoot.appendingPathComponent("index.html"))
        try Data("beta response".utf8).write(to: betaRoot.appendingPathComponent("index.html"))
        
        let layout = VaelenFilesystemLayout(rootURL: root)
        let package = try resolveCaddyPackage()
        let configuration = try CaddyTestSupport.configuration()
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: configuration)
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
        XCTAssertEqual(try runCurl(host: "alpha.test", port: configuration.httpPort), "alpha response")
        XCTAssertEqual(try runCurl(host: "beta.test", port: configuration.httpPort), "beta response")

        try await router.removeRoute(id: alpha.id)
        XCTAssertNotEqual(try runCurl(host: "alpha.test", port: configuration.httpPort), "alpha response")
        XCTAssertEqual(try runCurl(host: "beta.test", port: configuration.httpPort), "beta response")
        try await router.stop()
    }

    func testOfficialCaddyServesControlledPHPFixtureThroughM2FPM() async throws {
        guard let php = PHPModule.development(), let phpPackage = php.installedVersions().last else {
            throw XCTSkip("M2 PHP-FPM package is not installed")
        }
        let phpWasRunning = (try? php.status(requestedVersion: phpPackage.version).state) == .running
        let root = URL(fileURLWithPath: "/tmp/vaelen-fastcgi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<?php echo 'php response';".utf8).write(to: root.appendingPathComponent("index.php"))
        try Data("asset response".utf8).write(to: root.appendingPathComponent("asset.txt"))

        let layout = VaelenFilesystemLayout(rootURL: root)
        let configuration = try CaddyTestSupport.configuration()
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        let package = try resolveCaddyPackage()
        await supervisor.installPackage(package)
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            if !phpWasRunning { _ = try? php.stop(requestedVersion: phpPackage.version) }
            try? FileManager.default.removeItem(at: root)
        }

        _ = try php.start(requestedVersion: phpPackage.version)
        try await router.start()
        let socket = try php.status(requestedVersion: phpPackage.version).socket
        let route = Route(hostname: "php.test", target: .fastCGI(socketPath: socket, documentRoot: root.path), tls: .disabled)
        try await router.reconcile(routes: [route])
        XCTAssertEqual(try runCurl(host: "php.test", port: configuration.httpPort, path: "/index.php"), "php response")
        let phpPath = try runHTTP(host: "php.test", port: configuration.httpPort, path: "/index.php")
        XCTAssertEqual(phpPath.status, 200, phpPath.body)
        XCTAssertFalse(phpPath.body.contains("<?php"), phpPath.body)
        let asset = try runHTTP(host: "php.test", port: configuration.httpPort, path: "/asset.txt")
        XCTAssertEqual(asset.status, 200, asset.body)
        XCTAssertEqual(asset.body, "asset response")
    }

    func testOfficialCaddyRoundTripsNormalizedFastCGIRoute() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-fastcgi-observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        let configuration = try CaddyTestSupport.configuration()
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        await supervisor.installPackage(try resolveCaddyPackage())
        let tls = TLSCapability(layout: layout)
        _ = try await tls.install()
        let router = CaddyRouter(layout: layout, supervisor: supervisor, tls: tls)
        addTeardownBlock {
            try? await router.stop()
            try? FileManager.default.removeItem(at: root)
        }

        try await router.start()
        let route = Route(hostname: "roundtrip.test", target: .fastCGI(socketPath: "/tmp/vaelen-roundtrip.sock", documentRoot: root.appendingPathComponent("public").path), tls: .local)
        try await router.reconcile(routes: [route])

        let observed = try await router.observedRoutes()
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed[0].hostname, route.hostname)
        XCTAssertEqual(observed[0].target, route.target)
        XCTAssertEqual(observed[0].tls, route.tls)
    }

    func testObservedRoutesRejectsMalformedProviderSemantics() throws {
        let cases: [[[String: Any]]] = [
            [["match": [["host": []]], "handle": [["handler": "file_server", "root": "/tmp"]]]],
            [["match": [["host": ["malformed.test"]]], "handle": [["handler": "vars", "root": "/tmp"], ["handler": "reverse_proxy", "transport": ["protocol": "fastcgi"], "upstreams": [["dial": "unix//"]]]]]],
            [["match": [["host": ["malformed.test"]]], "handle": [["handler": "reverse_proxy", "upstreams": [["dial": "not-a-supported-target"]]]]]]
        ]

        for routes in cases {
            let configuration: [String: Any] = [
                "apps": ["http": ["servers": ["vaelen-http": ["routes": routes]]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: configuration)
            XCTAssertThrowsError(try CaddyRouter.decodeObservedRoutes(data))
        }
    }

    func testOfficialCaddyReachesSyncproofLaravelFrontController() async throws {
        guard ProcessInfo.processInfo.environment["VAELEN_RUN_SYNCPROOF_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Syncproof integration is opt-in; set VAELEN_RUN_SYNCPROOF_INTEGRATION_TESTS=1 with an explicitly prepared external project and database.")
        }
        guard let php = PHPModule.development(), let phpPackage = php.installedVersions().last else {
            throw XCTSkip("M2 PHP-FPM package is not installed")
        }
        let phpWasRunning = (try? php.status(requestedVersion: phpPackage.version).state) == .running
        let project = URL(fileURLWithPath: "/Users/banes/Code/syncproof", isDirectory: true)
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent("public/index.php").path) else {
            throw XCTSkip("syncproof project is not available")
        }
        let database = syncproofDatabaseEndpoint(project: project)
        guard canConnectTCP(host: database.host, port: database.port) else {
            throw XCTSkip("syncproof MySQL is unavailable at \(database.host):\(database.port)")
        }
        let root = URL(fileURLWithPath: "/tmp/vaelen-syncproof-\(UUID().uuidString)", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        let configuration = try CaddyTestSupport.configuration()
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        await supervisor.installPackage(try resolveCaddyPackage())
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            if !phpWasRunning { _ = try? php.stop(requestedVersion: phpPackage.version) }
            try? FileManager.default.removeItem(at: root)
        }

        _ = try php.start(requestedVersion: phpPackage.version)
        try await router.start()
        let route = Route(hostname: "syncproof.test", target: .fastCGI(socketPath: try php.status(requestedVersion: phpPackage.version).socket, documentRoot: project.appendingPathComponent("public").path), tls: .disabled)
        try await router.reconcile(routes: [route])

        let home = try runHTTP(host: "syncproof.test", port: configuration.httpPort, path: "/")
        XCTAssertEqual(home.status, 302, home.body)
        XCTAssertTrue(home.headers.contains("/integrations"), home.headers)
        let login = try runHTTP(host: "syncproof.test", port: configuration.httpPort, path: "/login")
        XCTAssertEqual(login.status, 200, login.body)
        XCTAssertTrue(login.body.contains("auth\\/login"), login.body)
    }

    func testTLSRouteRedirectsBackendHTTPToHTTPS() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-redirect-\(UUID().uuidString)", isDirectory: true)
        let docRoot = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: docRoot, withIntermediateDirectories: true)
        try Data("redirect content".utf8).write(to: docRoot.appendingPathComponent("index.html"))

        let layout = VaelenFilesystemLayout(rootURL: root)
        let tls = TLSCapability(layout: layout)
        _ = try await tls.install()
        let configuration = try CaddyTestSupport.configuration()
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        await supervisor.installPackage(try resolveCaddyPackage())
        let router = CaddyRouter(layout: layout, supervisor: supervisor, tls: tls)
        addTeardownBlock {
            try? await router.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await router.start()
        try await router.reconcile(routes: [Route(hostname: "redirect.test", target: .staticFiles(documentRoot: docRoot.path), tls: .local)])

        let http = try runHTTP(host: "redirect.test", port: configuration.httpPort, path: "/")
        XCTAssertEqual(http.status, 308, http.body)
        XCTAssertTrue(http.headers.contains("Location: https://redirect.test/"), http.headers)

        let https = try runBackendHTTPS(host: "redirect.test", port: configuration.httpsPort, path: "/")
        XCTAssertEqual(https.status, 200, https.body)
        XCTAssertTrue(https.body.contains("redirect content"), https.body)
    }

    func testRoutingDisablesHTTP3AndHoldsNoUDPListener() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-protocols-\(UUID().uuidString)", isDirectory: true)
        let docRoot = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: docRoot, withIntermediateDirectories: true)
        try Data("protocol content".utf8).write(to: docRoot.appendingPathComponent("index.html"))

        let layout = VaelenFilesystemLayout(rootURL: root)
        let configuration = try CaddyTestSupport.configuration()
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        await supervisor.installPackage(try resolveCaddyPackage())
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await router.start()
        try await router.reconcile(routes: [Route(hostname: "proto.test", target: .staticFiles(documentRoot: docRoot.path), tls: .disabled)])

        let config = try CaddyAdminClient(endpoint: await supervisor.adminEndpoint()).getConfig()
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
        XCTAssertTrue(canBindUDP(port: configuration.httpPort), "Caddy must not hold a UDP listener on the HTTP backend port")
        XCTAssertTrue(canBindUDP(port: configuration.httpsPort), "Caddy must not hold a UDP listener on the HTTPS backend port")
    }

    private func resolveCaddyPackage() throws -> CaddyPackage {
        guard let path = ProcessInfo.processInfo.environment["VAELEN_CADDY_TEST_PACKAGE"] else {
            throw XCTSkip("Caddy runtime fixture unavailable; set VAELEN_CADDY_TEST_PACKAGE to an independently prepared authentic package (no network/live-state install in swift test).")
        }
        let metadata = URL(fileURLWithPath: path).appendingPathComponent(".vaelen-package.json")
        guard let data = try? Data(contentsOf: metadata), let package = try? JSONDecoder().decode(CaddyPackage.self, from: data) else {
            throw XCTSkip("Caddy runtime fixture is missing .vaelen-package.json provenance.")
        }
        guard FileManager.default.isExecutableFile(atPath: package.executablePath) else {
            throw XCTSkip("Caddy runtime fixture executable is absent or not executable: \(package.executablePath)")
        }
        return package
    }

    private func runCurl(host: String, port: Int, path: String = "/") throws -> String {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-fsS", "-H", "Host: \(host)", "http://127.0.0.1:\(port)\(path)"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyRuntimeError.processFailed("curl failed for \(host)") }; return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runBackendHTTPS(host: String, port: Int, path: String) throws -> (status: Int, headers: String, body: String) {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-k", "-sS", "-D", "-", "-o", "-", "--resolve", "\(host):\(port):127.0.0.1", "https://\(host):\(port)\(path)"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyRuntimeError.processFailed("curl failed for \(host)") }; let parts = output.components(separatedBy: "\r\n\r\n"); let header = parts.first ?? ""; let body = parts.dropFirst().joined(separator: "\r\n\r\n"); let status = Int(header.split(separator: "\n").first?.split(separator: " ").dropFirst().first ?? "0") ?? 0; return (status, header, body)
    }

    private func canBindUDP(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }

    private func syncproofDatabaseEndpoint(project: URL) -> (host: String, port: Int) {
        let env = (try? String(contentsOf: project.appendingPathComponent(".env"), encoding: .utf8)) ?? ""
        func value(_ key: String) -> String? {
            env.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix(key + "=") }).map({ String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) })
        }
        return (value("DB_HOST") ?? "127.0.0.1", Int(value("DB_PORT") ?? "") ?? 3306)
    }

    private func canConnectTCP(host: String, port: Int) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let address = result else { return false }
        defer { freeaddrinfo(address) }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return Darwin.connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0
    }

    private func runHTTP(host: String, port: Int, path: String) throws -> (status: Int, headers: String, body: String) {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-sS", "-D", "-", "-o", "-", "-H", "Host: \(host)", "http://127.0.0.1:\(port)\(path)"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyRuntimeError.processFailed("curl failed for \(host)") }; let parts = output.components(separatedBy: "\r\n\r\n"); let header = parts.first ?? ""; let body = parts.dropFirst().joined(separator: "\r\n\r\n"); let status = Int(header.split(separator: "\n").first?.split(separator: " ").dropFirst().first ?? "0") ?? 0; return (status, header, body)
    }
}
