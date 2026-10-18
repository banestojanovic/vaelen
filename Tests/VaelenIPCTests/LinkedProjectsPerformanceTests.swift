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
    func testSubprocessTimeoutTerminatesOwnedChildWithoutPreservingRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lb-timeout-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.sh")
        try "#!/bin/sh\nexec sleep 30\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let unrelated = try Self.startUnrelatedChild()
        defer { _ = kill(unrelated, SIGKILL); _ = waitpid(unrelated, nil, 0) }
        XCTAssertEqual(kill(unrelated, 0), 0, "unrelated child must be running before owned-child timeout")
        XCTAssertThrowsError(try Self.capture(fixture.path, arguments: [], timeout: .milliseconds(100), terminationGrace: .milliseconds(100))) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
            XCTAssertTrue(error.localizedDescription.contains("owned child was terminated"))
        }
        XCTAssertEqual(kill(unrelated, 0), 0, "timeout handling must not terminate an unrelated child")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "the root remains available until test cleanup")
    }

    func testSubprocessUnconfirmedExitPreservesOutputAndFixture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lb-unconfirmed-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var preserveRoot = false
        defer { if !preserveRoot { try? FileManager.default.removeItem(at: root) } }
        let fixture = root.appendingPathComponent("fixture.sh")
        try "#!/bin/sh\nexec sleep 30\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        XCTAssertThrowsError(try Self.capture(fixture.path, arguments: [], timeout: .milliseconds(50), terminationGrace: .milliseconds(50), outputDirectory: root, observeExit: { _, _ in false })) { error in
            XCTAssertTrue(error.localizedDescription.contains("exit could not be established"))
            let outputPath = error.localizedDescription.components(separatedBy: "output preserved at ").last!
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
            preserveRoot = true
        }
        XCTAssertTrue(preserveRoot)
        try FileManager.default.removeItem(at: root)
    }

    func testHumanLinksEndToEndSixMinimalNoPHPProjects() async throws {
        let outcome = try await runScenario(includePHPSelection: false)
        XCTAssertTrue(outcome.samples.count == 5)
        XCTAssertEqual(outcome.projectNames.count, 6)
        XCTAssertNil(outcome.phpVersion)
        XCTAssertEqual(outcome.providerStatusObservations, 6, "only the route observation request probes router status across six invocations")
        XCTAssertEqual(outcome.providerRouteObservations, 0, "PHP selections do not probe router routes")
    }

    func testHumanLinksEndToEndSixProjectsWithSyntheticPHPSelection() async throws {
        let outcome = try await runScenario(includePHPSelection: true)
        XCTAssertEqual(outcome.projectNames.count, 6)
        XCTAssertNotNil(outcome.phpVersion)
        XCTAssertEqual(outcome.providerStatusObservations, 6, "only the route observation request probes router status across six invocations")
        XCTAssertEqual(outcome.providerRouteObservations, 0, "PHP selections do not probe router routes")
    }

    func testHumanLinksDetectsMissingExpectedProject() async throws {
        do {
            _ = try await runScenario(includePHPSelection: false, missingExpectedProjectName: "deliberately-absent-project")
            XCTFail("the links output checker accepted a project that was not present in the output")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("deliberately-absent-project"), message)
            XCTAssertTrue(message.contains("CLI exit=0"), message)
            XCTAssertTrue(message.contains("CLI output:"), message)
            print("[LinksBenchmark] expected-checker-rejection \(message)")
        }
    }

    private struct ScenarioOutcome {
        let projectNames: [String]
        let samples: [Double]
        let phpVersion: String?
        let providerStatusObservations: Int
        let providerRouteObservations: Int
    }

    private func runScenario(includePHPSelection: Bool, missingExpectedProjectName: String? = nil) async throws -> ScenarioOutcome {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lb-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
                        let shutdownError = error
                        guard await Self.serverTaskFinished(serverTask, within: .seconds(2)) else {
                            preserveRoot = true
                            throw NSError(domain: "LinkedProjectsPerformanceTests", code: 12, userInfo: [NSLocalizedDescriptionKey: "server did not finish within bounded cleanup window after shutdown connection failure: \(shutdownError)"])
                        }
                        _ = try? await serverTask.value
                        serverStopped = true
                        throw shutdownError
                    }
                }
                guard await Self.serverTaskFinished(serverTask, within: .seconds(2)) else {
                    preserveRoot = true
                    throw NSError(domain: "LinkedProjectsPerformanceTests", code: 13, userInfo: [NSLocalizedDescriptionKey: "server did not finish within bounded cleanup window after private shutdown"])
                }
                _ = try? await serverTask.value
                serverStopped = true
            }
            if !preserveRoot, fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
            print("[LinksBenchmark] cleanup serverStopped=\(serverStopped) socketExists=\(fm.fileExists(atPath: paths.socketPath)) rootExists=\(fm.fileExists(atPath: root.path)) rootRemoved=\(!fm.fileExists(atPath: root.path))")
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
                phpProvenance = "generated package metadata and default; no package archive or PHP-FPM bytes; local executable \(phpBinary) used only for -v package validation; no PHP-FPM service started"
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

            let doctor = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "links-benchmark-doctor", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
            try await doctor.connect()
            let coreStatus = try await doctor.status()
            await doctor.disconnect()
            XCTAssertEqual(coreStatus.core.pid, Int32(getpid()), "isolated Core should report this test process as its expected PID")

            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let executable = source.appendingPathComponent(".build/debug/val")
            guard fm.isExecutableFile(atPath: executable.path) else { throw NSError(domain: "LinkedProjectsPerformanceTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "assigned-worktree CLI missing at \(executable.path)"]) }
            print("[LinksBenchmark] preflight handshake=validated coreVersion=\(coreStatus.core.version) protocol=\(coreStatus.protocolVersion) corePID=\(coreStatus.core.pid) expectedPID=\(getpid()) socket=\(paths.socketPath) testRoot=\(supportRoot.path) source=\(source.path) executable=\(executable.path) cliIdentity=val/\(VaelenBuildInfo.version)")
            func runLinks() throws -> (String, Double, Int32) {
                let process = Process()
                let outputURL = root.appendingPathComponent("cli-output-\(UUID().uuidString)")
                guard fm.createFile(atPath: outputURL.path, contents: nil) else {
                    throw NSError(domain: "LinkedProjectsPerformanceTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "could not create isolated CLI output file"])
                }
                let output = try FileHandle(forWritingTo: outputURL)
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
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                do {
                    try process.run()
                } catch {
                    try? output.close()
                    try? fm.removeItem(at: outputURL)
                    throw error
                }
                var didExit = exited.wait(timeout: .now() + 30) == .success
                if !didExit {
                    process.terminate()
                    didExit = exited.wait(timeout: .now() + 2) == .success
                }
                if !didExit {
                    _ = kill(process.processIdentifier, SIGKILL)
                    didExit = exited.wait(timeout: .now() + 2) == .success
                }
                guard didExit else {
                    preserveRoot = true
                    try? output.close()
                    throw NSError(domain: "LinkedProjectsPerformanceTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "timed val links child did not terminate within bounded termination window; preserving its output file and fixture root because it may still be running"])
                }
                process.waitUntilExit()
                try output.close()
                let data = try Data(contentsOf: outputURL)
                try fm.removeItem(at: outputURL)
                let duration = start.duration(to: .now)
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                guard !process.isRunning else { throw NSError(domain: "LinkedProjectsPerformanceTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "timed val links child exit was signaled but Process still reports it running"]) }
                print("[LinksBenchmark] child-exit pid=\(process.processIdentifier) confirmed=true status=\(process.terminationStatus)")
                return (String(decoding: data, as: UTF8.self), seconds, process.terminationStatus)
            }

            let warmup = try runLinks()
            print("[LinksBenchmark] warmup transcript exit=\(warmup.2):\n\(warmup.0)")
            let requiredNames = expectedNames + (missingExpectedProjectName.map { [$0] } ?? [])
            let missingNames = requiredNames.filter { !warmup.0.contains($0) }
            guard warmup.2 == 0, missingNames.isEmpty, !includePHPSelection || (phpVersion.map(warmup.0.contains) ?? false) else {
                throw NSError(domain: "LinkedProjectsPerformanceTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "warm-up failed or omitted expected project/PHP output. Missing=\(missingNames); CLI exit=\(warmup.2); CLI output:\n\(warmup.0)"])
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
            let phpAccounting = includePHPSelection ? "PHP effectivePHPByProject: 0 extra PHP connections/handshakes, +1 project.php.selections request per invocation (Core-authoritative batch); expected effective PHP=\(phpVersion ?? "unknown"); provider/package provenance=\(phpProvenance)" : "no PHP module/package/default; PHP effective selection/runtime resolution unavailable because Core has no PHP module; PHP effectivePHPByProject uses +1 project.php.selections request per invocation with 0 extra PHP connections"
            print("[LinksBenchmark] scenario=\(includePHPSelection ? "six projects with synthetic PHP selection" : "six minimal/no-PHP directories (no index.php)") warmup=\(warmup.1)s endToEndCLIWarmRepeats=\(samples) median=\(median)s range=\(sorted.first!)...\(sorted.last!)s; output=all six project names validated; inferred from CLI call path per invocation: CLI client=1 connection+1 handshake, linkedProjects=1 request, routeList=1 request, routeObservedList=1 request, project.php.selections=1 request; \(phpAccounting); measured simulated-router provider calls across warmup+timed runs(status=\(cliObservationCounts.status),observedRoutes=\(cliObservationCounts.routes)); no installed slowdown reproduced")
            return ScenarioOutcome(projectNames: expectedNames, samples: samples, phpVersion: phpVersion, providerStatusObservations: cliObservationCounts.status, providerRouteObservations: cliObservationCounts.routes)
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

    private static func startUnrelatedChild() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process.processIdentifier
    }

    private static func serverTaskFinished(_ task: Task<Void, Error>, within duration: Duration) async -> Bool {
        let completed = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await task.value
            completed.signal()
        }
        return Self.wait(completed, duration: duration)
    }

    private static func wait(_ semaphore: DispatchSemaphore, duration: Duration) -> Bool {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return semaphore.wait(timeout: .now() + seconds) == .success
    }

    private static func capture(_ executable: String, arguments: [String], timeout: Duration = .seconds(10), terminationGrace: Duration = .seconds(1), outputDirectory: URL = FileManager.default.temporaryDirectory, observeExit: (DispatchSemaphore, TimeInterval) -> Bool = { semaphore, seconds in semaphore.wait(timeout: .now() + seconds) == .success }) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let outputURL = outputDirectory.appendingPathComponent("lb-capture-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else { throw NSError(domain: "LinkedProjectsPerformanceTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "could not create subprocess output file"]) }
        let file = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = file; process.standardError = file
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        var didExit = observeExit(exited, seconds)
        let timedOut = !didExit
        if !didExit {
            process.terminate()
            let grace = Double(terminationGrace.components.seconds) + Double(terminationGrace.components.attoseconds) / 1e18
            didExit = observeExit(exited, grace)
        }
        if !didExit { _ = kill(process.processIdentifier, SIGKILL); didExit = observeExit(exited, 1) }
        guard didExit else {
            try? file.close()
            throw NSError(domain: "LinkedProjectsPerformanceTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "subprocess timed out and its exit could not be established; output preserved at \(outputURL.path)"])
        }
        process.waitUntilExit()
        try file.close()
        let data = try Data(contentsOf: outputURL)
        try FileManager.default.removeItem(at: outputURL)
        guard !timedOut else { throw NSError(domain: "LinkedProjectsPerformanceTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "subprocess timed out and its owned child was terminated"]) }
        guard process.terminationStatus == 0 else { throw NSError(domain: "LinkedProjectsPerformanceTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "local PHP version probe failed"]) }
        return String(decoding: data, as: UTF8.self)
    }
}
