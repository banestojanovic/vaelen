import Foundation
import Darwin
import XCTest
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

private actor LinksBenchmarkRouter: Router {
    private var statusObservations = 0
    private var routeObservations = 0
    func start() async throws {}
    func stop() async throws {}
    func status() async -> RouterStatus {
        statusObservations += 1
        return .init(provider: "links-benchmark", state: .stopped, health: .unknown, routeCount: 0)
    }
    func health() async -> RouterHealth { .unhealthy }
    func reconcile(routes: [Route]) async throws {}
    func addRoute(_ route: Route) async throws {}
    func updateRoute(_ route: Route) async throws {}
    func removeRoute(id: RouteID) async throws {}
    func observedRoutes() async throws -> [Route] { routeObservations += 1; return [] }
    func counts() -> (status: Int, routes: Int) { (statusObservations, routeObservations) }
}

private struct LinksBenchmarkDNSResponder: DNSResponderControlling {
    func status() async -> DNSResponderStatus { .init(state: .stopped) }
    func start() async throws -> DNSResponderIdentity { throw DNSCapabilityError.processFailed("benchmark responder is disabled") }
    func stop(expected: DNSResponderIdentity, timeout: TimeInterval) async throws -> DNSResponderStatus { .init(state: .stopped) }
}

private struct LinksBenchmarkTLSTrust: TLSTrustBoundary {
    func observe(certificateData: Data) throws -> LocalCATrustService.Observation {
        .init(trusted: false, canonical: "links-benchmark", fingerprint: nil)
    }
    func trust(certificateData: Data) throws {}
    func removeTrust(certificateData: Data) throws {}
}

final class LinkedProjectsPerformanceTests: XCTestCase {
    func testHumanLinksEndToEndSixMinimalNoPHPProjects() async throws {
        let outcome = try await runScenario(includePHPSelection: false)
        XCTAssertTrue(outcome.samples.count == 5)
        XCTAssertEqual(outcome.projectNames.count, 6)
        XCTAssertNil(outcome.phpVersion)
    }

    func testHumanLinksEndToEndSixProjectsWithSyntheticPHPSelection() async throws {
        let outcome = try await runScenario(includePHPSelection: true)
        XCTAssertEqual(outcome.projectNames.count, 6)
        XCTAssertNotNil(outcome.phpVersion)
    }

    private struct ScenarioOutcome {
        let projectNames: [String]
        let samples: [Double]
        let phpVersion: String?
    }

    private func runScenario(includePHPSelection: Bool) async throws -> ScenarioOutcome {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/var/folders/9b/1f1sf2v51_36ys9ngvlqzc8c0000gn/T/lb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let supportRoot = root.appendingPathComponent("s", isDirectory: true)
        let projectsRoot = root.appendingPathComponent("p", isDirectory: true)
        let socketRoot = supportRoot.appendingPathComponent("runtime", isDirectory: true)
        let paths = CoreEndpointPaths(root: socketRoot)
        var serverTask: Task<Void, Error>?
        var serverStopped = false
        var preserveRoot = false
        func cleanup() async throws {
            if let serverTask, !serverStopped {
                if fm.fileExists(atPath: paths.socketPath) {
                    let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "links-benchmark-cleanup", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
                    do {
                        try await client.connect()
                        _ = try await client.shutdown()
                        await client.disconnect()
                    } catch {
                        await client.disconnect()
                        _ = try? await serverTask.value
                        throw error
                    }
                }
                _ = try await serverTask.value
                serverStopped = true
            }
            if !preserveRoot, fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        }
        do {
            try fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
            let store = try SQLiteStateStore(databaseURL: supportRoot.appendingPathComponent("state/vaelen.sqlite"))
            let registry = ProjectRegistry(store: store)
            var expectedNames = [String]()
            for index in 0..<6 {
                let name = "bench-project-\(index)"
                let project = projectsRoot.appendingPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: project, withIntermediateDirectories: true)
                _ = try await registry.link(path: project, name: name)
                expectedNames.append(name)
            }

            let router = LinksBenchmarkRouter()
            let layout = VaelenFilesystemLayout(rootURL: supportRoot)
            var phpModule: PHPModule?
            var phpVersion: String?
            var phpProvenance = "none"
            if includePHPSelection {
                guard let phpBinary = Self.findExecutable(named: "php") else {
                    throw XCTSkip("No local PHP CLI executable is available for the explicitly simulated selection fixture.")
                }
                let versionOutput = try Self.capture(phpBinary, arguments: ["-v"])
                guard let detected = versionOutput.split(whereSeparator: \.isWhitespace).dropFirst().first,
                      detected.split(separator: ".").count == 3 else {
                    throw NSError(domain: "LinkedProjectsPerformanceTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not derive a stable PHP version from local CLI output: \(versionOutput)"])
                }
                let version = String(detected)
                let packageDirectory = layout.phpPackagesDirectoryURL.appendingPathComponent(version, isDirectory: true)
                try fm.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
                let package = PHPPackage(version: version, architecture: "arm64", packagePath: packageDirectory.path,
                    cliPath: phpBinary, fpmPath: phpBinary, source: "synthetic links benchmark metadata; local PHP CLI reused for observation only",
                    cliSHA256: "synthetic", fpmSHA256: "synthetic", installedAt: Date())
                try JSONEncoder().encode(package).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
                try fm.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
                try Data(version.utf8).write(to: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"))
                phpModule = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: supportRoot.appendingPathComponent("synthetic-php-manifest.json")))
                phpVersion = version
                phpProvenance = "generated package metadata and default; no package archive or PHP-FPM bytes; local executable \(phpBinary) used for package observation only, not started"
            }
            let dns = DNSCapability(layout: layout, helper: UnavailablePrivilegedDNSHelper(), responder: LinksBenchmarkDNSResponder())
            let tls = TLSCapability(layout: layout, store: store, keychain: LocalCAKeychain(tag: "dev.vaelen.links-benchmark"), trustBoundary: LinksBenchmarkTLSTrust())
            let portsPaths = StandardPortsPaths(anchorPath: root.appendingPathComponent("pf/anchor").path, pfConfPath: root.appendingPathComponent("pf/pf.conf").path)
            let ports = StandardPortsCapability(privileged: UnavailableStandardPortsPrivileged(paths: portsPaths), paths: portsPaths, portOccupied: { _ in false }, backendHealthy: { false })
            let intents = ServiceIntentStore(url: supportRoot.appendingPathComponent("state/service-intents.json"))
            let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: registry, php: phpModule, router: router, routeRepository: RouteIntentRepository(store: store), dns: dns, tls: tls, ports: ports, serviceIntents: intents)
            try paths.prepareDirectories()
            try paths.validateSocketPathLength()
            let server = DaemonServer(paths: paths, dispatcher: dispatcher)
            serverTask = Task.detached { try server.run() }
            for _ in 0..<200 where !fm.fileExists(atPath: paths.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
            guard fm.fileExists(atPath: paths.socketPath) else { throw NSError(domain: "LinkedProjectsPerformanceTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "isolated Core socket did not appear"]) }

            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let executable = source.appendingPathComponent(".build/debug/val")
            guard fm.isExecutableFile(atPath: executable.path) else { throw NSError(domain: "LinkedProjectsPerformanceTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "assigned-worktree CLI missing at \(executable.path)"]) }
            func runLinks() throws -> (String, Double, Int32) {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = ["links"]
                process.currentDirectoryURL = source
                var environment = ProcessInfo.processInfo.environment
                environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
                environment["VAELEN_TEST_SUPPORT_ROOT"] = supportRoot.path
                process.environment = environment
                process.standardOutput = output
                process.standardError = output
                let start = ContinuousClock.now
                try process.run()
                let deadline = Date().addingTimeInterval(30)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let duration = start.duration(to: .now)
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                guard !process.isRunning else { throw NSError(domain: "LinkedProjectsPerformanceTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "timed val links child did not terminate"]) }
                return (String(decoding: data, as: UTF8.self), seconds, process.terminationStatus)
            }

            let warmup = try runLinks()
            guard warmup.2 == 0, expectedNames.allSatisfy(warmup.0.contains), !includePHPSelection || (phpVersion.map(warmup.0.contains) ?? false) else {
                throw NSError(domain: "LinkedProjectsPerformanceTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "warm-up failed or omitted expected project/PHP output. Exit=\(warmup.2), output=\(warmup.0)"])
            }
            var samples = [Double]()
            for _ in 0..<5 {
                let sample = try runLinks()
                guard sample.2 == 0, expectedNames.allSatisfy(sample.0.contains), !includePHPSelection || (phpVersion.map(sample.0.contains) ?? false) else {
                    throw NSError(domain: "LinkedProjectsPerformanceTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "timed run failed or omitted expected project/PHP output. Exit=\(sample.2), output=\(sample.0)"])
                }
                samples.append(sample.1)
            }
            let cliObservationCounts = await router.counts()
            let sorted = samples.sorted()
            let median = sorted[sorted.count / 2]
            try await cleanup()
            let phpAccounting = includePHPSelection ? "PHP effectivePHPByProject: +6 fresh connections, +6 handshakes, +6 projectPHP selection requests per invocation; expected effective PHP=\(phpVersion ?? "unknown"); provider/package provenance=\(phpProvenance)" : "no PHP module/package/default; no PHP selection connections or requests"
            print("[LinksBenchmark] scenario=\(includePHPSelection ? "six projects with synthetic PHP selection" : "six minimal/no-PHP directories (no index.php)") warmup=\(warmup.1)s endToEndCLIWarmRepeats=\(samples) median=\(median)s range=\(sorted.first!)...\(sorted.last!)s; output=all six project names validated; per invocation CLI client=1 connection+1 handshake, linkedProjects=1 request, routeList=1 request, routeObservedList=1 request; \(phpAccounting); measured simulated-router provider calls across warmup+timed runs(status=\(cliObservationCounts.status),observedRoutes=\(cliObservationCounts.routes)); no installed slowdown reproduced")
            return ScenarioOutcome(projectNames: expectedNames, samples: samples, phpVersion: phpVersion)
        } catch {
            do { try await cleanup() }
            catch {
                preserveRoot = true
                XCTFail("Owned fixture cleanup failed; preserving root at \(root.path): \(error)")
            }
            throw error
        }
    }

    private static func findExecutable(named name: String) -> String? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func capture(_ executable: String, arguments: [String]) throws -> String {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw NSError(domain: "LinkedProjectsPerformanceTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "local PHP version probe failed"]) }
        return String(decoding: data, as: UTF8.self)
    }
}
