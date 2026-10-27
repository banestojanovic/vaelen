import Foundation
import Darwin
import Dispatch
import XCTest
@testable import VaelenCore
import VaelenIPC
import VaelenDaemonSupport

private struct ProjectRouteFixtureDNSHelper: PrivilegedDNSHelper {
    private let state: ProjectRouteDNSState
    init(state: ProjectRouteDNSState) { self.state = state }
    func inspectTestResolver() async throws -> ResolverInspection { await state.inspection() }
    func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot { await state.install(port: port) }
    func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws { await state.restore(restore) }
}

private actor ProjectRouteDNSState {
    private var snapshot = ResolverFileSnapshot(exists: false, bytes: nil, owner: nil, group: nil, mode: nil, device: nil, inode: nil, fileType: nil)
    func inspection() -> ResolverInspection { ResolverInspection(exists: snapshot.exists, content: snapshot.bytes.map { String(decoding: $0, as: UTF8.self) }, ownership: snapshot.exists ? .vaelen : .none, snapshot: snapshot) }
    func install(port: Int) -> ResolverFileSnapshot {
        snapshot = ResolverFileSnapshot(exists: true, bytes: Data("nameserver 127.0.0.1\nport \(port)\n".utf8), owner: 501, group: 20, mode: 0o644, device: 1, inode: 1, fileType: 0o100000)
        return snapshot
    }
    func restore(_ value: ResolverFileSnapshot) { snapshot = value }
}

private actor ProjectRouteDNSResponder: DNSResponderControlling {
    private var identity: DNSResponderIdentity?
    func status() -> DNSResponderStatus {
        guard let identity else { return DNSResponderStatus(state: .stopped) }
        return DNSResponderStatus(state: .ownedRunning, pid: identity.pid, listenerResponding: true, listenerPresent: true, identity: identity)
    }
    func start() -> DNSResponderIdentity {
        let value = DNSResponderIdentity(pid: 42424, executablePath: "/fixture/vaelendns", arguments: ["--port", "53535"], startedAt: "fixture")
        identity = value
        return value
    }
    func stop(expected: DNSResponderIdentity, timeout: TimeInterval) -> DNSResponderStatus { identity = nil; return DNSResponderStatus(state: .exited, pid: expected.pid, identity: expected) }
}

private final class ProjectRoutePortsState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    func setActive() { lock.lock(); active = true; lock.unlock() }
    func isActive() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
}

private struct ProjectRoutePortsPrivileged: StandardPortsPrivileged {
    let paths: StandardPortsPaths
    let state: ProjectRoutePortsState
    func inspectForwarding() async throws -> StandardPortsInspection {
        StandardPortsInspection(anchorContent: try? String(contentsOfFile: paths.anchorPath), pfConfContent: try? String(contentsOfFile: paths.pfConfPath), pfEnabled: state.isActive(), forwardingActive: state.isActive())
    }
    func installForwarding() async throws -> StandardPortsAcquisition {
        let fm = FileManager.default
        try fm.createDirectory(at: URL(fileURLWithPath: paths.anchorPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(StandardPortsForwardingPolicy.anchorRules().utf8).write(to: URL(fileURLWithPath: paths.anchorPath))
        let reference = StandardPortsForwardingPolicy.pfConfReferenceLines(anchorPath: paths.anchorPath).joined(separator: "\n") + "\n"
        try Data(reference.utf8).write(to: URL(fileURLWithPath: paths.pfConfPath))
        state.setActive()
        return StandardPortsAcquisition(preimagePFConf: .init(exists: false, bytes: nil, owner: nil, group: nil, mode: nil), preimageAnchor: .init(exists: false, bytes: nil, owner: nil, group: nil, mode: nil), writtenPFConf: .init(exists: true, bytes: Data(reference.utf8), owner: 501, group: 20, mode: 0o644), writtenAnchor: .init(exists: true, bytes: Data(StandardPortsForwardingPolicy.anchorRules().utf8), owner: 501, group: 20, mode: 0o644), changedPFConf: true, changedAnchor: true, forwardingWasActive: true, pfToken: nil)
    }
    func removeForwarding(acquisition: StandardPortsAcquisition) async throws {}
}

private struct ProjectRouteTrust: TLSTrustBoundary {
    func observe(certificateData: Data) throws -> LocalCATrustService.Observation { .init(trusted: true, canonical: "fixture", fingerprint: "fixture-trust") }
    func trust(certificateData: Data) throws {}
    func removeTrust(certificateData: Data) throws {}
}

final class ProjectRouteLifecycleEndToEndTests: XCTestCase {
    func testAdoptedHTTPAndHTTPSRoutesServePHPThroughActualValChildren() async throws {
        guard let val = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"] else { throw XCTSkip("Run Scripts/tests/val-project-route-lifecycle-test.sh to build and provide the actual val child.") }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/vpr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: support)
        var preserve = false
        var coreStopped = false
        var router: CaddyRouter?
        var php: PHPModule?
        var phpVersion: String?
        var readOnlyPackageRoots = [URL]()
        let keyTag = "dev.vaelen.project-route-fixture.\(UUID().uuidString)"
        let keychain = LocalCAKeychain(tag: keyTag)
        let paths = CoreEndpointPaths(layout: layout)
        var serverTask: Task<Void, Error>?
        let serverExited = DispatchSemaphore(value: 0)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let liveLayout = VaelenFilesystemLayout()
            let liveCaddy: CaddyPackage
            do { liveCaddy = try CaddyModule(layout: liveLayout, verifier: nil).resolveInstalled(requestedVersion: "2.11.4") }
            catch { throw XCTSkip("Installed Caddy 2.11.4 package is unavailable. No download was attempted. \(error)") }
            let livePHPModule = PHPModule(layout: liveLayout, location: FilePHPManifestLocation(manifestURL: liveLayout.configurationDirectoryURL.appendingPathComponent("php-manifest.json")))
            let livePHP: PHPPackage
            do { livePHP = try livePHPModule.installedVersions().sorted { $0.version > $1.version }.first ?? { throw PHPModuleError.packageMissing("installed PHP") }() }
            catch { throw XCTSkip("An installed PHP-FPM package is unavailable. No download was attempted. \(error)") }
            guard fm.isExecutableFile(atPath: livePHP.fpmPath) else { throw XCTSkip("Installed PHP-FPM binary is unavailable at \(livePHP.fpmPath). No download was attempted.") }
            phpVersion = livePHP.version

            try paths.prepareDirectories(); try paths.validateSocketPathLength()
            let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
            let ledger = SystemModificationLedger(store: store)
            let dnsState = ProjectRouteDNSState()
            let dns = DNSCapability(layout: layout, helper: ProjectRouteFixtureDNSHelper(state: dnsState), responder: ProjectRouteDNSResponder(), port: 53535, ledger: ledger)
            _ = try await dns.install()
            let portPaths = StandardPortsPaths(anchorPath: root.appendingPathComponent("fixture-pf/anchor").path, pfConfPath: root.appendingPathComponent("fixture-pf/pf.conf").path)
            try fm.createDirectory(at: URL(fileURLWithPath: portPaths.anchorPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            let portState = ProjectRoutePortsState()
            let ports = StandardPortsCapability(privileged: ProjectRoutePortsPrivileged(paths: portPaths, state: portState), paths: portPaths, ledger: ledger, portOccupied: { _ in portState.isActive() }, backendHealthy: { true })
            _ = try await ports.install()
            let tls = TLSCapability(layout: layout, store: store, keychain: keychain, trustBoundary: ProjectRouteTrust())
            _ = try await tls.install()
            _ = try await tls.trustLocalCA()

            let caddyDir = layout.caddyPackagesDirectoryURL.appendingPathComponent(liveCaddy.version, isDirectory: true)
            try fm.createDirectory(at: caddyDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: liveCaddy.packagePath), to: caddyDir)
            let caddyMetadataURL = caddyDir.appendingPathComponent(".vaelen-package.json")
            var caddyMetadata = try JSONSerialization.jsonObject(with: Data(contentsOf: caddyMetadataURL)) as! [String: Any]
            caddyMetadata["packagePath"] = caddyDir.path
            caddyMetadata["executablePath"] = caddyDir.appendingPathComponent("caddy").path
            try JSONSerialization.data(withJSONObject: caddyMetadata).write(to: caddyMetadataURL)
            let caddyPackage = try JSONDecoder().decode(CaddyPackage.self, from: JSONSerialization.data(withJSONObject: caddyMetadata))
            try makeReadOnly(caddyDir)
            readOnlyPackageRoots.append(caddyDir)
            let httpPort = try availablePort(); let httpsPort = try availablePort(excluding: httpPort)
            let caddySupervisor = CaddyProcessSupervisor(layout: layout, configuration: CaddyRuntimeConfiguration(httpPort: httpPort, httpsPort: httpsPort))
            await caddySupervisor.installPackage(caddyPackage)
            let caddy = CaddyRouter(layout: layout, supervisor: caddySupervisor, tls: tls)
            router = caddy
            try await caddy.start()

            let phpDir = layout.phpPackagesDirectoryURL.appendingPathComponent(livePHP.version, isDirectory: true)
            try fm.createDirectory(at: phpDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: livePHP.packagePath), to: phpDir)
            let phpMetadataURL = phpDir.appendingPathComponent(".vaelen-package.json")
            var phpMetadata = try JSONSerialization.jsonObject(with: Data(contentsOf: phpMetadataURL)) as! [String: Any]
            phpMetadata["packagePath"] = phpDir.path
            phpMetadata["cliPath"] = phpDir.appendingPathComponent("php").path
            phpMetadata["fpmPath"] = phpDir.appendingPathComponent("php-fpm").path
            try JSONSerialization.data(withJSONObject: phpMetadata).write(to: phpMetadataURL)
            let isolatedPHP = try JSONDecoder().decode(PHPPackage.self, from: JSONSerialization.data(withJSONObject: phpMetadata))
            try JSONEncoder().encode(isolatedPHP).write(to: phpDir.appendingPathComponent(".vaelen-package.json"))
            try makeReadOnly(phpDir)
            readOnlyPackageRoots.append(phpDir)
            let phpModule = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("missing-php-manifest.json")))
            php = phpModule

            let registry = ProjectRegistry(store: store)
            let routeRepository = RouteIntentRepository(store: store)
            let serviceInstances = ServiceInstanceRepository(store: store)
            let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: registry, php: phpModule, router: caddy, routeRepository: routeRepository, dns: dns, tls: tls, ports: ports, serviceIntents: ServiceIntentStore(url: layout.rootURL.appendingPathComponent("state/service-intents.json")), serviceInstances: serviceInstances)
            let server = DaemonServer(paths: paths, dispatcher: dispatcher)
            serverTask = Task.detached { defer { serverExited.signal() }; try server.run() }
            for _ in 0..<300 where !fm.fileExists(atPath: paths.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(fm.fileExists(atPath: paths.socketPath), "private Core socket must be ready")

            let projects = [("route-http", "route-http.test", false, "HTTP PHP fixture"), ("route-https", "route-https.test", true, "HTTPS PHP fixture")]
            for (name, host, secure, body) in projects {
                let project = root.appendingPathComponent(name, isDirectory: true)
                let documentRoot = project.appendingPathComponent("public", isDirectory: true)
                try fm.createDirectory(at: documentRoot, withIntermediateDirectories: true)
                try Data("<?php echo '\(body)';".utf8).write(to: documentRoot.appendingPathComponent("index.php"))
                let envBytes = Data("DATABASE_URL=postgresql://untouched\nTOKEN=keep-this-byte-for-byte\n".utf8)
                try envBytes.write(to: project.appendingPathComponent(".env"))
                _ = try await registry.link(path: project, name: name)
                let preview = try runVal(val, root: support, cwd: project, args: ["project", "adopt", "--json"])
                XCTAssertEqual(preview.status, 0, "\(preview.error)\n\(preview.output)")
                let reviewed = try JSONDecoder().decode(ProjectAdoptionPreviewResult.self, from: Data(preview.output.utf8))
                XCTAssertEqual(reviewed.preview.identity.name, name)
                let secureFlag = secure ? "--secure" : "--insecure"
                let applied = try runVal(val, root: support, cwd: project, args: ["project", "adopt", "--apply", reviewed.confirmation.uuidString, "--php", livePHP.version, "--web-host", host, "--document-root", "public", secureFlag, "--create-route", "--json"])
                XCTAssertEqual(applied.status, 0, "\(applied.error)\n\(applied.output)")
                let manifestBytes = try Data(contentsOf: project.appendingPathComponent("vaelen.yml"))
                XCTAssertTrue(String(decoding: manifestBytes, as: UTF8.self).contains(host))
            }

            func project(_ action: String, _ selector: String) throws -> ProjectReconciliationExecutionResult {
                let result = try runVal(val, root: support, cwd: root, args: ["project", action, selector, "--json"])
                XCTAssertEqual(result.status, 0, "val project \(action) failed: \(result.error)\n\(result.output)")
                return try JSONDecoder().decode(ProjectReconciliationExecutionResult.self, from: Data(result.output.utf8))
            }
            for (name, host, secure, expected) in projects {
                let firstUp = try project("up", name)
                XCTAssertTrue(firstUp.operations.contains { $0.operationID == "route.create" && $0.state == .succeeded }, "the explicitly reviewed route must be created during the first up")
                XCTAssertEqual(try project("up", name).state, .succeeded, "the second up must observe the route created during the first up")
                let manifestData = try Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent("vaelen.yml"))
                XCTAssertTrue(String(decoding: manifestData, as: UTF8.self).contains("host: \(host)"))
                let projectPath = root.appendingPathComponent(name).resolvingSymlinksInPath().path
                let owned = try routeRepository.all().filter { $0.projectPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == projectPath }
                XCTAssertEqual(owned.count, 1)
                XCTAssertEqual(owned.first?.route.tls, secure ? .local : .disabled)
                let url = secure ? "https://\(host):\(httpsPort)/" : "http://\(host):\(httpPort)/"
                let response = try curl(host: host, url: url, insecure: secure)
                XCTAssertEqual(response, expected)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent(".env")), Data("DATABASE_URL=postgresql://untouched\nTOKEN=keep-this-byte-for-byte\n".utf8))
                XCTAssertEqual(try project("down", name).state, .succeeded)
                XCTAssertEqual(try routeRepository.all().filter { $0.projectPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == projectPath }.map(\.route.id), owned.map(\.route.id), "down releases project service claims but retains the developer-owned route")
                XCTAssertEqual(try project("up", name).state, .succeeded)
                XCTAssertEqual(try curl(host: host, url: url, insecure: secure), expected)
                XCTAssertEqual(try project("down", name).state, .succeeded)
            }
            let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "project-route-fixture", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
            try await client.connect(); _ = try await client.shutdown(); await client.disconnect()
            guard await wait(serverExited, seconds: 3) else { preserve = true; throw NSError(domain: "ProjectRouteLifecycle", code: 9, userInfo: [NSLocalizedDescriptionKey: "private Core failed to stop; root preserved at \(root.path)"]) }
            _ = try await serverTask!.value; coreStopped = true
            let fpmStopped = try await phpModule.status(requestedVersion: livePHP.version).state == .stopped
            let caddyStopped = (await caddy.status()).state == .stopped
            guard fpmStopped && caddyStopped else { preserve = true; throw NSError(domain: "ProjectRouteLifecycle", code: 10, userInfo: [NSLocalizedDescriptionKey: "owned FPM/Caddy shutdown was not verified; root preserved at \(root.path)"]) }
        } catch {
            var cleanupErrors = [String]()
            if let serverTask, !coreStopped {
                let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "project-route-fixture-cleanup", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
                do { try await client.connect(); _ = try await client.shutdown(); await client.disconnect() }
                catch { await client.disconnect(); cleanupErrors.append("Core shutdown request failed: \(error)") }
                if await wait(serverExited, seconds: 4) { _ = try? await serverTask.value; coreStopped = true }
                else { cleanupErrors.append("Core did not exit after shutdown request") }
            }
            if let php, let phpVersion {
                do {
                    let status = try await php.status(requestedVersion: phpVersion)
                    if status.state == .running { _ = try await php.stop(requestedVersion: phpVersion) }
                    if try await php.status(requestedVersion: phpVersion).state != .stopped { cleanupErrors.append("PHP-FPM shutdown was not verified") }
                } catch { cleanupErrors.append("PHP-FPM cleanup failed: \(error)") }
            }
            if let router {
                do { try await router.stop(); if (await router.status()).state != .stopped { cleanupErrors.append("Caddy shutdown was not verified") } }
                catch { cleanupErrors.append("Caddy cleanup failed: \(error)") }
            }
            do { try keychain.removeCAKey() } catch { cleanupErrors.append("Unique test CA key removal failed: \(error)") }
            if !cleanupErrors.isEmpty || !(error is XCTSkip) { preserve = true }
            if preserve { print("PROJECT_ROUTE_FIXTURE_EVIDENCE root=\(root.path) coreStopped=\(coreStopped) cleanup=\(cleanupErrors.joined(separator: " | "))") }
            if error is XCTSkip, cleanupErrors.isEmpty { try makeWritable(readOnlyPackageRoots); try? fm.removeItem(at: root); throw error }
            throw NSError(domain: "ProjectRouteLifecycleEndToEndTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture root \(root.path). Core stopped: \(coreStopped). Cleanup: \(cleanupErrors.joined(separator: " | ")). Original error: \(error)"])
        }
        if !preserve {
            do { try keychain.removeCAKey() }
            catch { preserve = true; throw NSError(domain: "ProjectRouteLifecycleEndToEndTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "Unique test CA key cleanup failed; fixture root preserved at \(root.path): \(error)"]) }
            try makeWritable(readOnlyPackageRoots)
            try fm.removeItem(at: root)
        }
    }

    private func makeReadOnly(_ directory: URL) throws {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])!
        for case let item as URL in enumerator { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: item.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    }
    private func makeWritable(_ packageRoots: [URL]) throws {
        let fm = FileManager.default
        for root in packageRoots {
            var directories = [root]
            let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])!
            for case let item as URL in enumerator where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { directories.append(item) }
            for directory in directories.reversed() { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        }
    }
    private func availablePort(excluding: Int? = nil) throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0); guard socketFD >= 0 else { throw NSError(domain: "port", code: 1) }; defer { close(socketFD) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")); address.sin_port = 0
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw NSError(domain: "port", code: 2) }
        var result = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size); _ = withUnsafeMutablePointer(to: &result, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } })
        let port = Int(UInt16(bigEndian: result.sin_port)); return port == excluding ? try availablePort(excluding: excluding) : port
    }
    private func curl(host: String, url: String, insecure: Bool) throws -> String {
        guard let components = URLComponents(string: url), let port = components.port else { throw NSError(domain: "curl", code: 1) }
        let process = Process(); let output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-fsS", "--connect-timeout", "3", "--max-time", "10"] + (insecure ? ["-k"] : []) + ["--resolve", "\(host):\(port):127.0.0.1", url]; process.standardOutput = output; process.standardError = FileHandle.nullDevice; try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw NSError(domain: "curl", code: Int(process.terminationStatus)) }; return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func runVal(_ executable: String, root: URL, cwd: URL, args: [String]) throws -> (status: Int32, output: String, error: String) {
        let outURL = root.appendingPathComponent("child.stdout"), errURL = root.appendingPathComponent("child.stderr"); FileManager.default.createFile(atPath: outURL.path, contents: nil); FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args; process.currentDirectoryURL = cwd; process.environment = ProcessInfo.processInfo.environment.merging(["VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1", "VAELEN_TEST_SUPPORT_ROOT": root.path, "NO_COLOR": "1"]) { _, value in value }; process.standardOutput = out; process.standardError = err
        let exited = DispatchSemaphore(value: 0); process.terminationHandler = { _ in exited.signal() }; try process.run()
        guard exited.wait(timeout: .now() + 45) == .success else {
            process.terminate()
            guard exited.wait(timeout: .now() + 3) == .success else { throw NSError(domain: "val", code: 3, userInfo: [NSLocalizedDescriptionKey: "val child PID \(process.processIdentifier) did not stop after its 45-second timeout; preserve fixture root \(root.path)"]) }
            process.waitUntilExit()
            throw NSError(domain: "val", code: 2, userInfo: [NSLocalizedDescriptionKey: "val child timed out after 45 seconds and was stopped; fixture root \(root.path)"])
        }
        process.waitUntilExit(); try out.close(); try err.close(); return (process.terminationStatus, String(decoding: try Data(contentsOf: outURL), as: UTF8.self), String(decoding: try Data(contentsOf: errURL), as: UTF8.self))
    }
    private func wait(_ semaphore: DispatchSemaphore, seconds: Int) async -> Bool {
        await Task.detached(priority: .utility) { Self.blockingWait(semaphore, seconds: seconds) }.value
    }
    nonisolated private static func blockingWait(_ semaphore: DispatchSemaphore, seconds: Int) -> Bool { semaphore.wait(timeout: .now() + .seconds(seconds)) == .success }
}
