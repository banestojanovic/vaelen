import Darwin
import Foundation
import XCTest
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

private actor ComposerFixtureRouter: Router {
    func start() async throws {}
    func stop() async throws {}
    func status() async -> RouterStatus { .init(provider: "composer-fixture", state: .stopped, health: .unknown, routeCount: 0) }
    func health() async -> RouterHealth { .unhealthy }
    func reconcile(routes: [Route]) async throws {}
    func addRoute(_ route: Route) async throws {}
    func updateRoute(_ route: Route) async throws {}
    func removeRoute(id: RouteID) async throws {}
    func observedRoutes() async throws -> [Route] { [] }
}

private struct ComposerFixtureDNS: DNSResponderControlling {
    func status() async -> DNSResponderStatus { .init(state: .stopped) }
    func start() async throws -> DNSResponderIdentity { throw DNSCapabilityError.processFailed("composer fixture responder is disabled") }
    func stop(expected: DNSResponderIdentity, timeout: TimeInterval) async throws -> DNSResponderStatus { .init(state: .stopped) }
}

private struct ComposerFixtureTrust: TLSTrustBoundary {
    func observe(certificateData: Data) throws -> LocalCATrustService.Observation { .init(trusted: false, canonical: "composer-fixture", fingerprint: nil) }
    func trust(certificateData: Data) throws {}
    func removeTrust(certificateData: Data) throws {}
}

final class ComposerEndToEndTests: XCTestCase {
    private struct ChildResult {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    func testComposerUsesCoreEffectivePHPAndPreservesProcessContract() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ce-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        var socketPaths: CoreEndpointPaths?
        var serverTask: Task<Void, Error>?
        var serverStopped = false
        var preserveRoot = false

        func cleanup() async throws {
            if !serverStopped, let serverTask {
                guard let socketPaths else { throw NSError(domain: "ComposerEndToEndTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "private Core paths were not initialized before startup"])}
                let client = makeClient(paths: socketPaths)
                do {
                    try await client.connect()
                    _ = try await client.shutdown()
                    await client.disconnect()
                } catch {
                    await client.disconnect()
                    let shutdownError = error
                    guard await taskFinished(serverTask, within: .seconds(2)) else {
                        preserveRoot = true
                        throw NSError(domain: "ComposerEndToEndTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "private Core did not stop after shutdown connection failure: \(shutdownError)"])
                    }
                    _ = try? await serverTask.value
                    serverStopped = true
                    throw shutdownError
                }
                guard await taskFinished(serverTask, within: .seconds(2)) else {
                    preserveRoot = true
                    throw NSError(domain: "ComposerEndToEndTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "private Core did not stop within the cleanup window"])
                }
                _ = try? await serverTask.value
                serverStopped = true
            }
            if !preserveRoot, fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
            print("[ComposerE2E] cleanup serverStopped=\(serverStopped) rootExists=\(fm.fileExists(atPath: root.path)) rootRemoved=\(!fm.fileExists(atPath: root.path)) preserved=\(preserveRoot)")
        }

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let layout = VaelenFilesystemLayout(rootURL: support)
            let paths = CoreEndpointPaths(layout: layout)
            socketPaths = paths
            let projects = root.appendingPathComponent("project with spaces", isDirectory: true)
            let inheritedProject = root.appendingPathComponent("inherited project with spaces", isDirectory: true)
            let outside = root.appendingPathComponent("outside linked projects", isDirectory: true)
            try fm.createDirectory(at: projects, withIntermediateDirectories: true)
            try fm.createDirectory(at: inheritedProject, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)

            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let fixtureSource = repo.appendingPathComponent("Tests/Fixtures/Composer/php_stub.c")
            let overrideBinary = support.appendingPathComponent("php/8.3.99/php", isDirectory: false)
            let defaultBinary = support.appendingPathComponent("php/8.4.99/php", isDirectory: false)
            try compilePHPFixture(source: fixtureSource, output: overrideBinary, version: "8.3.99", name: "project-override")
            try compilePHPFixture(source: fixtureSource, output: defaultBinary, version: "8.4.99", name: "inherited-default")

            for (version, binary) in [("8.3.99", overrideBinary), ("8.4.99", defaultBinary)] {
                let packageDirectory = layout.phpPackagesDirectoryURL.appendingPathComponent(version, isDirectory: true)
                try fm.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
                let package = PHPPackage(version: version, architecture: "arm64", packagePath: packageDirectory.path,
                    cliPath: binary.path, fpmPath: binary.path, source: "synthetic Composer acceptance fixture",
                    cliSHA256: "synthetic", fpmSHA256: "synthetic", installedAt: Date())
                try JSONEncoder().encode(package).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
            }
            try fm.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
            let defaultURL = layout.configurationDirectoryURL.appendingPathComponent("php-default.json")
            try Data("8.4.99".utf8).write(to: defaultURL)

            let store = try SQLiteStateStore(databaseURL: support.appendingPathComponent("state/vaelen.sqlite"))
            let registry = ProjectRegistry(store: store)
            let project = try await registry.link(path: projects, name: "composer-fixture")
            let inherited = try await registry.link(path: inheritedProject, name: "composer-inherited-fixture")
            guard let projectID = project.id else { throw NSError(domain: "ComposerEndToEndTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "linked fixture project has no id"])}
            try await registry.setPHPOverride("8.3.99", for: projectID)
            guard inherited.id != nil else { throw NSError(domain: "ComposerEndToEndTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "inherited fixture project has no id"])}

            let php = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: support.appendingPathComponent("missing-php-manifest.json")))
            let router = ComposerFixtureRouter()
            let dns = DNSCapability(layout: layout, helper: UnavailablePrivilegedDNSHelper(), responder: ComposerFixtureDNS())
            let tls = TLSCapability(layout: layout, store: store, keychain: LocalCAKeychain(tag: "dev.vaelen.composer-fixture"), trustBoundary: ComposerFixtureTrust())
            let portsPaths = StandardPortsPaths(anchorPath: root.appendingPathComponent("pf/anchor").path, pfConfPath: root.appendingPathComponent("pf/pf.conf").path)
            let ports = StandardPortsCapability(privileged: UnavailableStandardPortsPrivileged(paths: portsPaths), paths: portsPaths, portOccupied: { _ in false }, backendHealthy: { false })
            let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: registry, php: php, router: router,
                routeRepository: RouteIntentRepository(store: store), dns: dns, tls: tls, ports: ports,
                serviceIntents: ServiceIntentStore(url: support.appendingPathComponent("state/service-intents.json")))
            try paths.prepareDirectories()
            try paths.validateSocketPathLength()
            let server = DaemonServer(paths: paths, dispatcher: dispatcher)
            serverTask = Task.detached { try server.run() }
            for _ in 0..<200 where !fm.fileExists(atPath: paths.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
            guard fm.fileExists(atPath: paths.socketPath) else { throw NSError(domain: "ComposerEndToEndTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "private Core socket did not appear"])}
            let doctor = makeClient(paths: paths)
            try await doctor.connect()
            let status = try await doctor.status()
            await doctor.disconnect()
            XCTAssertEqual(status.core.pid, Int32(getpid()))

            let binary = repo.appendingPathComponent(".build/debug/val")
            guard fm.isExecutableFile(atPath: binary.path) else { throw NSError(domain: "ComposerEndToEndTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "worktree CLI is missing at \(binary.path)"])}
            let composerDirectory = root.appendingPathComponent("composer tools with spaces", isDirectory: true)
            let otherDirectory = root.appendingPathComponent("second composer directory", isDirectory: true)
            let emptyDirectory = root.appendingPathComponent("empty PATH directory", isDirectory: true)
            let invalidDirectory = root.appendingPathComponent("invalid composer directory", isDirectory: true)
            for directory in [composerDirectory, otherDirectory, emptyDirectory, invalidDirectory] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let composer = composerDirectory.appendingPathComponent("composer")
            let phar = composerDirectory.appendingPathComponent("composer.phar")
            try Data("#!/usr/bin/env php\n<?php echo 'selected composer';\n".utf8).write(to: composer)
            try Data("<?php echo 'second candidate';\n".utf8).write(to: phar)
            try Data("<?php echo 'later path';\n".utf8).write(to: otherDirectory.appendingPathComponent("composer"))
            try Data("#!/bin/sh\necho unsafe\n".utf8).write(to: invalidDirectory.appendingPathComponent("composer"))

            let environment = childEnvironment(support: support, path: "\(composerDirectory.path):\(otherDirectory.path)")
            let supportBefore = try supportSnapshot(support)
            let args = ["--help", "-h", "--", "", "argument with spaces", "--exit=23"]
            let input = "composer stdin payload\n"
            let projectRun = try runCLI(binary: binary, arguments: ["composer"] + args, cwd: projects, environment: environment, stdin: input, root: root)
            XCTAssertEqual(projectRun.status, 23)
            XCTAssertEqual(projectRun.stderr, "composer-fixture-stderr\n")
            XCTAssertEqual(projectRun.stdout, expectedOutput(label: "project-override", cwd: projects, script: composer, args: args, stdin: input))
            print("[ComposerE2E] project status=\(projectRun.status) stdout=\n\(projectRun.stdout)stderr=\n\(projectRun.stderr)")

            for trailingHelp in ["--help", "-h"] {
                let helpRun = try runCLI(binary: binary, arguments: ["composer", trailingHelp], cwd: projects, environment: environment, stdin: "", root: root)
                XCTAssertEqual(helpRun.status, 0)
                XCTAssertEqual(helpRun.stdout, expectedOutput(label: "project-override", cwd: projects, script: composer, args: [trailingHelp], stdin: ""))
                XCTAssertEqual(helpRun.stderr, "composer-fixture-stderr\n")
            }

            let outsideRun = try runCLI(binary: binary, arguments: ["composer", "--version"], cwd: outside, environment: environment, stdin: "", root: root)
            XCTAssertEqual(outsideRun.status, 0)
            XCTAssertEqual(outsideRun.stderr, "composer-fixture-stderr\n")
            XCTAssertEqual(outsideRun.stdout, expectedOutput(label: "inherited-default", cwd: outside, script: composer, args: ["--version"], stdin: ""))
            print("[ComposerE2E] outside-default status=\(outsideRun.status) stdout=\n\(outsideRun.stdout)")

            let missing = try runCLI(binary: binary, arguments: ["composer"], cwd: projects, environment: childEnvironment(support: support, path: emptyDirectory.path), stdin: "", root: root)
            XCTAssertEqual(missing.status, 1)
            XCTAssertTrue(missing.stderr.contains("Composer was not found on PATH"), missing.stderr)

            let invalid = try runCLI(binary: binary, arguments: ["composer"], cwd: projects, environment: childEnvironment(support: support, path: "\(invalidDirectory.path):\(composerDirectory.path)"), stdin: "", root: root)
            XCTAssertEqual(invalid.status, 1)
            XCTAssertTrue(normalized(invalid.stderr).contains(normalized(invalidDirectory.appendingPathComponent("composer").path)), invalid.stderr)
            XCTAssertFalse(invalid.stderr.contains("composer-fixture-stderr"), invalid.stderr)

            let inheritedRun = try runCLI(binary: binary, arguments: ["composer", "--version"], cwd: inheritedProject, environment: environment, stdin: "", root: root)
            XCTAssertEqual(inheritedRun.status, 0)
            XCTAssertEqual(inheritedRun.stdout, expectedOutput(label: "inherited-default", cwd: inheritedProject, script: composer, args: ["--version"], stdin: ""))
            print("[ComposerE2E] linked-inherited-default status=\(inheritedRun.status) stdout=\n\(inheritedRun.stdout)")

            let overrideData = try Data(contentsOf: overrideBinary)
            let overridePermissions = try fm.attributesOfItem(atPath: overrideBinary.path)[.posixPermissions] as? NSNumber
            guard let overridePermissions else { throw NSError(domain: "ComposerEndToEndTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "could not read synthetic PHP permissions"])}
            try fm.removeItem(at: overrideBinary)
            let unavailablePHP = try runCLI(binary: binary, arguments: ["composer"], cwd: projects, environment: environment, stdin: "", root: root)
            XCTAssertEqual(unavailablePHP.status, 1)
            XCTAssertTrue(normalized(unavailablePHP.stderr).contains("PHP 8.3.99 is selected but its managed executable is unavailable"), unavailablePHP.stderr)
            XCTAssertFalse(unavailablePHP.stderr.contains("composer-fixture-stderr"), unavailablePHP.stderr)
            print("[ComposerE2E] selected-PHP-unavailable status=\(unavailablePHP.status) stderr=\n\(unavailablePHP.stderr)")
            try overrideData.write(to: overrideBinary)
            try fm.setAttributes([.posixPermissions: overridePermissions], ofItemAtPath: overrideBinary.path)

            let storedOverride = try await registry.phpOverride(for: projectID)
            XCTAssertEqual(storedOverride, "8.3.99")
            for version in ["8.3.99", "8.4.99"] {
                let packageMetadata = layout.phpPackagesDirectoryURL.appendingPathComponent(version, isDirectory: true).appendingPathComponent(".vaelen-package.json")
                XCTAssertTrue(fm.fileExists(atPath: packageMetadata.path))
            }

            let unavailableRoot = root.appendingPathComponent("Core unavailable", isDirectory: true)
            try fm.createDirectory(at: unavailableRoot, withIntermediateDirectories: true)
            let unavailableCore = try runCLI(binary: binary, arguments: ["composer", "--version"], cwd: projects, environment: childEnvironment(support: unavailableRoot, path: composerDirectory.path), stdin: "", root: root)
            XCTAssertEqual(unavailableCore.status, 3)
            XCTAssertTrue(unavailableCore.stderr.contains("Vaelen Core is not running"), unavailableCore.stderr)
            XCTAssertEqual(try supportSnapshot(support), supportBefore, "Composer invocations and lookup errors must leave Vaelen support files unchanged")
            print("[ComposerE2E] stateSnapshot=unchanged supportRoot=\(support.path) override=8.3.99 default=8.4.99")
            print("[ComposerE2E] scenario project-exit=\(projectRun.status) inherited-linked-exit=\(inheritedRun.status) outside-exit=\(outsideRun.status) missing-exit=\(missing.status) incompatible-exit=\(invalid.status) php-unavailable-exit=\(unavailablePHP.status) core-unavailable-exit=\(unavailableCore.status)")
            try await cleanup()
        } catch {
            let failure = error as NSError
            if failure.domain == "ComposerEndToEndTests", failure.code == 12 {
                preserveRoot = true
            }
            if serverTask != nil, !serverStopped {
                try? await cleanup()
            }
            if !preserveRoot, serverStopped || serverTask == nil { try? fm.removeItem(at: root) }
            throw error
        }
    }

    private func makeClient(paths: CoreEndpointPaths) -> VaelenCoreClient {
        VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "composer-e2e", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
    }

    private func compilePHPFixture(source: URL, output: URL, version: String, name: String) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-o", output.path, "-DPHP_VERSION=\"\(version)\"", "-DFIXTURE_NAME=\"\(name)\"", source.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "ComposerEndToEndTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "could not compile synthetic PHP fixture: \(String(decoding: diagnostics, as: UTF8.self))"])}
    }

    private func childEnvironment(support: URL, path: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = support.path
        environment["PATH"] = path
        environment["NO_COLOR"] = "1"
        return environment
    }

    private func runCLI(binary: URL, arguments: [String], cwd: URL, environment: [String: String], stdin: String, root: URL) throws -> ChildResult {
        let stdoutURL = root.appendingPathComponent("stdout-\(UUID().uuidString)")
        let stderrURL = root.appendingPathComponent("stderr-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil), FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw NSError(domain: "ComposerEndToEndTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "could not create private CLI output files"])
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        let input = Pipe()
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        guard exited.wait(timeout: .now() + 10) == .success else {
            _ = kill(process.processIdentifier, SIGKILL)
            guard exited.wait(timeout: .now() + 2) == .success else {
                try? stdout.close()
                try? stderr.close()
                throw NSError(domain: "ComposerEndToEndTests", code: 12, userInfo: [NSLocalizedDescriptionKey: "val composer exit could not be confirmed; fixture files must be preserved"])
            }
            try? stdout.close()
            try? stderr.close()
            throw NSError(domain: "ComposerEndToEndTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "val composer child did not exit within ten seconds"])
        }
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        let result = ChildResult(stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self), stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self), status: process.terminationStatus)
        try FileManager.default.removeItem(at: stdoutURL)
        try FileManager.default.removeItem(at: stderrURL)
        return result
    }

    private func expectedOutput(label: String, cwd: URL, script: URL, args: [String], stdin: String) -> String {
        let processArguments = [script.path] + args
        let renderedArguments = processArguments.enumerated().map { index, value in "ARG[\(index + 1)]=\(value.utf8.count):\(value)\n" }.joined()
        let path = cwd.path.withCString { realpath($0, nil) }
        let canonicalPath = path.map { value -> String in defer { free(value) }; return String(cString: value) } ?? cwd.path
        return "PHP_FIXTURE=\(label)\nCWD=\(canonicalPath)\n\(renderedArguments)STDIN:\(stdin)\n"
    }

    private func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func taskFinished(_ task: Task<Void, Error>, within duration: Duration) async -> Bool {
        let completed = DispatchSemaphore(value: 0)
        Task.detached { _ = try? await task.value; completed.signal() }
        return wait(completed, within: duration)
    }

    private func wait(_ semaphore: DispatchSemaphore, within duration: Duration) -> Bool {
        semaphore.wait(timeout: .now() + Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) == .success
    }

    private func supportSnapshot(_ root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            throw NSError(domain: "ComposerEndToEndTests", code: 13, userInfo: [NSLocalizedDescriptionKey: "could not enumerate private Vaelen support files"])
        }
        var result = [String: Data]()
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if relative == "runtime" || relative.hasPrefix("runtime/") { continue }
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }
}
