import Foundation
import Darwin
import XCTest
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

private actor LocalProxyFixtureRouter: Router {
    func start() async throws {}
    func stop() async throws {}
    func status() async -> RouterStatus { .init(provider: "local-proxy-fixture", state: .stopped, health: .unknown, routeCount: 0) }
    func health() async -> RouterHealth { .unhealthy }
    func reconcile(routes: [Route]) async throws {}
    func addRoute(_ route: Route) async throws {}
    func updateRoute(_ route: Route) async throws {}
    func removeRoute(id: RouteID) async throws {}
    func observedRoutes() async throws -> [Route] { [] }
}

final class LocalProxyEndToEndTests: XCTestCase {
    private struct CLIProcessDidNotStop: Error {}

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    func testCLIProxyLifecyclePersistsAcrossPrivateCoreRestartAndPreservesRoutes() async throws {
        let root = URL(fileURLWithPath: "/private/var/tmp/vp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let stateURL = support.appendingPathComponent("state/vaelen.sqlite")
        let proxyDB = support.appendingPathComponent("state/local-proxies.sqlite")
        let paths = CoreEndpointPaths(layout: VaelenFilesystemLayout(rootURL: support))
        let occupied = RouteIntent(route: Route(hostname: "occupied.test", target: .staticFiles(documentRoot: root.path), tls: .disabled))
        let routeID = occupied.route.id
        var serverTask: Task<Void, Error>?
        var redirectServer: OwnedChildProcess?
        var serverStopped = false
        var preserveRoot = false

        func startCore() throws -> Task<Void, Error> {
            let store = try SQLiteStateStore(databaseURL: stateURL)
            let registry = ProjectRegistry(store: store)
            let routes = RouteIntentRepository(store: store)
            if try !routes.all().contains(where: { $0.route.id == occupied.route.id }) { try routes.upsert(occupied) }
            let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: registry,
                router: LocalProxyFixtureRouter(), routeRepository: routes,
                localProxyRepository: try LocalProxyRepository(databaseURL: proxyDB),
                serviceIntents: ServiceIntentStore(url: support.appendingPathComponent("state/service-intents.json")))
            try paths.prepareDirectories()
            try paths.validateSocketPathLength()
            let server = DaemonServer(paths: paths, dispatcher: dispatcher)
            return Task.detached { try server.run() }
        }

        func waitForCore() async throws {
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: paths.socketPath) {
                    let client = makeClient(paths: paths)
                    do {
                        try await client.connect()
                        let status = try await client.status()
                        await client.disconnect()
                        XCTAssertEqual(status.core.pid, Int32(getpid()))
                        return
                    } catch { await client.disconnect() }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "LocalProxyEndToEndTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "private Core did not become ready"])
        }

        func stopCore() async throws {
            guard let serverTask else { return }
            let client = makeClient(paths: paths)
            do {
                try await client.connect()
                _ = try await client.shutdown()
                await client.disconnect()
                try await serverTask.value
                serverStopped = true
            } catch {
                await client.disconnect()
                preserveRoot = true
                throw error
            }
        }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            serverTask = try startCore()
            try await waitForCore()

            let add = try runCLI(["proxy", "add", "preview.test", "http://127.0.0.1:1"], root: root, support: support)
            XCTAssertEqual(add.status, 0, add.stderr)
            let repeated = try runCLI(["proxy", "add", "preview.test", "http://127.0.0.1:1"], root: root, support: support)
            XCTAssertEqual(repeated.status, 0, repeated.stderr)
            XCTAssertTrue(repeated.stdout.contains("already" ) || repeated.stdout.contains("preview.test"), repeated.stdout)
            let conflict = try runCLI(["proxy", "add", "preview.test", "http://127.0.0.1:2"], root: root, support: support)
            XCTAssertNotEqual(conflict.status, 0)
            let invalid = try runCLI(["proxy", "add", "remote.test", "http://192.0.2.1:80"], root: root, support: support)
            XCTAssertNotEqual(invalid.status, 0)
            let occupied = try runCLI(["proxy", "add", "occupied.test", "http://127.0.0.1:1"], root: root, support: support)
            XCTAssertNotEqual(occupied.status, 0)

            let listed = try runCLI(["proxy", "list", "--json"], root: root, support: support)
            XCTAssertEqual(listed.status, 0, listed.stderr)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [String: Any])
            let proxies = try XCTUnwrap(json["proxies"] as? [[String: Any]])
            XCTAssertEqual(proxies.count, 1)
            XCTAssertEqual(proxies.first?["hostname"] as? String, "preview.test")

            let redirectSourcePort = try availablePort()
            var redirectTargetPort = try availablePort()
            while redirectTargetPort == redirectSourcePort { redirectTargetPort = try availablePort() }
            let redirectMarker = root.appendingPathComponent("redirect-target-hit")
            let redirectFixture = """
            from http.server import BaseHTTPRequestHandler, HTTPServer
            from threading import Thread
            import sys
            marker, target_port = sys.argv[3], int(sys.argv[4])
            class Source(BaseHTTPRequestHandler):
                def do_HEAD(self):
                    self.send_response(302)
                    self.send_header('Location', f'http://127.0.0.1:{target_port}/redirected')
                    self.end_headers()
                def log_message(self, *args): pass
            class Target(BaseHTTPRequestHandler):
                def do_HEAD(self):
                    if self.path == '/redirected': open(marker, 'w').write('redirect followed')
                    self.send_response(200)
                    self.end_headers()
                def log_message(self, *args): pass
            Thread(target=HTTPServer(('127.0.0.1', target_port), Target).serve_forever, daemon=True).start()
            HTTPServer(('127.0.0.1', int(sys.argv[1])), Source).serve_forever()
            """
            redirectServer = try OwnedChildProcess.launch(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", redirectFixture, String(redirectSourcePort), String(redirectTargetPort), redirectMarker.path, String(redirectTargetPort)],
                label: "local proxy redirect probe fixture")
            for _ in 0..<100 where !canConnectTCP(port: redirectSourcePort) { usleep(10_000) }
            XCTAssertTrue(canConnectTCP(port: redirectSourcePort), "redirect source listener did not start")
            let redirectAdd = try runCLI(["proxy", "add", "redirect.test", "http://127.0.0.1:\(redirectSourcePort)"], root: root, support: support)
            XCTAssertEqual(redirectAdd.status, 0, redirectAdd.stderr)
            let redirectProbe = try runCLI(["proxy", "list", "--json"], root: root, support: support)
            XCTAssertEqual(redirectProbe.status, 0, redirectProbe.stderr)
            let redirectJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(redirectProbe.stdout.utf8)) as? [String: Any])
            let redirectProxies = try XCTUnwrap(redirectJSON["proxies"] as? [[String: Any]])
            let redirectProxy = try XCTUnwrap(redirectProxies.first(where: { $0["hostname"] as? String == "redirect.test" }))
            XCTAssertEqual(redirectProxy["upstreamReachability"] as? String, "reachable")
            XCTAssertFalse(FileManager.default.fileExists(atPath: redirectMarker.path), "the probe must not follow the upstream redirect")
            var directTargetRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(redirectTargetPort)/direct-check")!, timeoutInterval: 1)
            directTargetRequest.httpMethod = "HEAD"
            let (_, directTargetResponse) = try await URLSession.shared.data(for: directTargetRequest)
            XCTAssertEqual((directTargetResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertFalse(FileManager.default.fileExists(atPath: redirectMarker.path), "the redirect target remains healthy without receiving the probe")
            let redirectRemove = try runCLI(["proxy", "remove", "redirect.test"], root: root, support: support)
            XCTAssertEqual(redirectRemove.status, 0, redirectRemove.stderr)
            guard redirectServer?.terminateAndWait(timeout: 2) == true else {
                preserveRoot = true
                throw NSError(domain: "LocalProxyEndToEndTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "redirect fixture process did not stop; preserving its root"])
            }
            redirectServer = nil

            try await stopCore()
            serverTask = nil

            serverTask = try startCore()
            try await waitForCore()
            let afterRestart = try runCLI(["proxy", "list", "--json"], root: root, support: support)
            XCTAssertEqual(afterRestart.status, 0, afterRestart.stderr)
            XCTAssertTrue(afterRestart.stdout.contains("preview.test"), afterRestart.stdout)
            let remove = try runCLI(["proxy", "remove", "preview.test"], root: root, support: support)
            XCTAssertEqual(remove.status, 0, remove.stderr)
            let empty = try runCLI(["proxy", "list", "--json"], root: root, support: support)
            XCTAssertEqual(empty.status, 0, empty.stderr)
            XCTAssertTrue(empty.stdout.contains("\"proxies\":[]") || empty.stdout.contains("\"proxies\": []"), empty.stdout)
            let store = try SQLiteStateStore(databaseURL: stateURL)
            let routeRepository = RouteIntentRepository(store: store)
            XCTAssertTrue(try routeRepository.all().contains(where: { $0.route.id == routeID }), "removing a proxy must preserve the unrelated same-host route")
            try await stopCore()
            serverTask = nil
            if !preserveRoot { try FileManager.default.removeItem(at: root) }
        } catch {
            if error is CLIProcessDidNotStop { preserveRoot = true }
            if let process = redirectServer {
                if process.terminateAndWait(timeout: 2) { redirectServer = nil }
                else { preserveRoot = true }
            }
            if serverTask != nil, !serverStopped { try? await stopCore() }
            if !preserveRoot { try? FileManager.default.removeItem(at: root) }
            throw error
        }
    }

    private func makeClient(paths: CoreEndpointPaths) -> VaelenCoreClient {
        VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "local-proxy-e2e", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
    }

    private func runCLI(_ arguments: [String], root: URL, support: URL) throws -> CLIResult {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = repo.appendingPathComponent(".build/debug/val")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw NSError(domain: "LocalProxyEndToEndTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "worktree val binary is missing"])}
        var environment = ProcessInfo.processInfo.environment
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = support.path
        environment["NO_COLOR"] = "1"
        let process = Process()
        let stdoutURL = root.appendingPathComponent("cli-stdout-\(UUID().uuidString)")
        let stderrURL = root.appendingPathComponent("cli-stderr-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil),
              let stdout = FileHandle(forWritingAtPath: stdoutURL.path),
              let stderr = FileHandle(forWritingAtPath: stderrURL.path) else {
            throw NSError(domain: "LocalProxyEndToEndTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "could not create isolated CLI output files"])
        }
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let child = OwnedChildProcess(process: process, label: "local proxy acceptance CLI")
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            var stopped = child.terminateAndWait(timeout: 2)
            if !stopped { stopped = child.terminateAndWait(timeout: 2, signal: SIGKILL, waitForDescendants: false) }
            stdout.closeFile()
            stderr.closeFile()
            guard stopped else { throw CLIProcessDidNotStop() }
            throw NSError(domain: "LocalProxyEndToEndTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "CLI timed out after 30 seconds and was terminated"])
        }
        _ = child.isRunningAndReapedIfExited()
        stdout.closeFile()
        stderr.closeFile()
        return CLIResult(status: process.terminationStatus,
            stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
            stderr: try String(contentsOf: stderrURL, encoding: .utf8))
    }

    private func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: "LocalProxyEndToEndTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "could not create loopback socket"])}
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw NSError(domain: "LocalProxyEndToEndTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "could not bind an ephemeral loopback port"])}
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard result == 0 else { throw NSError(domain: "LocalProxyEndToEndTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "could not read the ephemeral loopback port"])}
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func canConnectTCP(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
