import XCTest
import Darwin
@testable import VaelenCore

final class CaddyRuntimeTests: XCTestCase {
    func testStopRefusesLiveOwnedHandleWhenStoredIdentityDoesNotMatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-caddy-mismatch-\(UUID().uuidString)")
        defer { CaddyTestSupport.removeIfPresent(root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.caddyInstancesDirectoryURL, withIntermediateDirectories: true)
        let process = try OwnedChildProcess.launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], label: "Caddy mismatch fixture")
        defer { _ = process.terminateAndWait(timeout: 2) }
        let supervisor = CaddyProcessSupervisor(layout: layout)
        await supervisor.retainOwnedChild(process)
        let record = CaddyProcessRecord(pid: process.processIdentifier, version: "fixture", executablePath: "/not/the/owned/executable", arguments: ["not-the-launched-arguments"], configPath: "/fixture/config", adminEndpoint: "unix//fixture", httpPort: 0, httpsPort: 0, startedAt: "not-the-start-time")
        try JSONEncoder().encode(record).write(to: layout.caddyInstancesDirectoryURL.appendingPathComponent("process.json"))

        do {
            _ = try await supervisor.stop()
            XCTFail("a live PID with mismatched identity must retain its record")
        } catch let error as CaddyRuntimeError {
            XCTAssertEqual(error, .processIdentityMismatch)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.caddyInstancesDirectoryURL.appendingPathComponent("process.json").path))
        XCTAssertTrue(process.isRunningAndReapedIfExited(), "mismatched live process must remain untouched")
    }

    func testOfficialCaddyLifecycleIsOwnedAndIdempotent() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-caddy-\(UUID().uuidString)", isDirectory: true)
        defer { CaddyTestSupport.removeIfPresent(root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let package = try resolveCaddyPackage()
        let configuration = try CaddyTestSupport.configuration()
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        await supervisor.installPackage(package)

        let started = try await supervisor.start()
        XCTAssertEqual(started.state, .running)
        XCTAssertEqual(started.health, .healthy)
        XCTAssertNoThrow(try CaddyAdminClient(endpoint: started.adminEndpoint).getConfig())
        let repeated = try await supervisor.start()
        XCTAssertEqual(repeated.pid, started.pid)
        let runningStatus = await supervisor.status()
        XCTAssertEqual(runningStatus.pid, started.pid)

        let stopped = try await supervisor.stop()
        XCTAssertEqual(stopped.state, .stopped)
        let stoppedStatus = await supervisor.status()
        XCTAssertNil(stoppedStatus.pid)
    }

    func testNewCoreCanStopPreciselyRecordedCaddyProcess() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-caddy-core-restart-\(UUID().uuidString)", isDirectory: true)
        defer { CaddyTestSupport.removeIfPresent(root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let package = try resolveCaddyPackage()
        let configuration = try CaddyTestSupport.configuration()
        let originalCore = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        await originalCore.installPackage(package)
        let started = try await originalCore.start()
        let pid = try XCTUnwrap(started.pid)

        let relaunchedCore = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        let stopped = try await relaunchedCore.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(processIsLive(pid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.caddyInstancesDirectoryURL.appendingPathComponent("process.json").path))
    }

    func testExternalCrashIsObservedAndPortCollisionDoesNotKillListener() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-caddy-failure-\(UUID().uuidString)", isDirectory: true)
        defer { CaddyTestSupport.removeIfPresent(root) }
        let package = try resolveCaddyPackage()
        let configuration = try CaddyTestSupport.configuration()

        let collisionSocket = try listen(on: configuration.httpPort)
        let collisionLayout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("collision"))
        let collisionSupervisor = CaddyProcessSupervisor(layout: collisionLayout, configuration: configuration)
        await collisionSupervisor.installPackage(package)
        do {
            _ = try await collisionSupervisor.start()
            XCTFail("expected port collision")
        } catch let error as CaddyRuntimeError {
            XCTAssertEqual(error, .portConflict(configuration.httpPort))
        }
        let diagnostic = try String(contentsOf: collisionLayout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log"), encoding: .utf8)
        XCTAssertTrue(diagnostic.contains("timestamp:"))
        XCTAssertTrue(diagnostic.contains("Core PID:"))
        XCTAssertTrue(diagnostic.contains("127.0.0.1:\(configuration.httpPort)"))
        XCTAssertTrue(diagnostic.contains("preflight: state=stopped health=unknown"))
        XCTAssertTrue(diagnostic.contains("bind error: bind: Address already in use"))
        XCTAssertTrue(diagnostic.contains("listener:"))
        XCTAssertTrue(diagnostic.contains("pid=\(getpid())"), "listener PID should be observable for the fixture listener")
        XCTAssertTrue(diagnostic.contains("Vaelen Caddy record: unavailable"))
        XCTAssertTrue(diagnostic.contains("elapsed="))
        XCTAssertTrue(diagnostic.contains("attemptStartedAt="))
        XCTAssertTrue(diagnostic.contains("before this start attempt launched"))
        close(collisionSocket)

        let crashLayout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("crash"))
        let crashSupervisor = CaddyProcessSupervisor(layout: crashLayout, configuration: configuration)
        await crashSupervisor.installPackage(package)
        let started = try await crashSupervisor.start()
        guard let pid = started.pid else { return XCTFail("missing Caddy PID") }
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        for _ in 0..<20 {
            if (await crashSupervisor.status()).state == .stopped { return }
            usleep(50_000)
        }
        XCTFail("crashed Caddy process remained reported as running")
    }

    func testRecordedCaddyWithUnreadyAdminNeverGetsSecondLaunchOrSelfConflict() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-caddy-unready-admin-\(UUID().uuidString)", isDirectory: true)
        defer { CaddyTestSupport.removeIfPresent(root) }
        let package = try resolveCaddyPackage()
        let configuration = try CaddyTestSupport.configuration()
        let layout = VaelenFilesystemLayout(rootURL: root)
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        await supervisor.installPackage(package)
        let started = try await supervisor.start()
        let pid = try XCTUnwrap(started.pid)
        let adminSocket = URL(fileURLWithPath: started.adminEndpoint.replacingOccurrences(of: "unix//", with: ""))
        try FileManager.default.removeItem(at: adminSocket)

        do {
            _ = try await supervisor.start()
            XCTFail("expected precise readiness failure")
        } catch let error as CaddyRuntimeError {
            guard case .processFailed(let message) = error else { return XCTFail("expected readiness failure, got \(error)") }
            XCTAssertTrue(message.contains("Recorded Caddy PID \(pid)"))
            XCTAssertTrue(message.contains("admin endpoint is not ready"))
            XCTAssertFalse(message.contains("port conflict"))
        }
        let stillRecorded = await supervisor.status()
        XCTAssertEqual(stillRecorded.pid, pid)
        XCTAssertTrue(processIsLive(pid), "readiness failure must not launch/terminate a second process")
        _ = try await supervisor.stop()
    }

    func testAcceptingButSilentAdminSocketFailsWithinDeadlineAndRetainsCaddyRecord() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-caddy-silent-admin-\(UUID().uuidString)", isDirectory: true)
        defer { CaddyTestSupport.removeIfPresent(root) }
        let package = try resolveCaddyPackage()
        let configuration = try CaddyTestSupport.configuration()
        let layout = VaelenFilesystemLayout(rootURL: root)
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: configuration)
        await supervisor.installPackage(package)
        let started = try await supervisor.start()
        let pid = try XCTUnwrap(started.pid)
        let adminSocket = URL(fileURLWithPath: started.adminEndpoint.replacingOccurrences(of: "unix//", with: ""))
        try FileManager.default.removeItem(at: adminSocket)
        let stalledServer = try StalledUnixSocket(path: adminSocket.path)
        defer { stalledServer.stop() }

        let start = Date()
        do {
            _ = try await supervisor.start()
            XCTFail("expected bounded admin readiness failure")
        } catch let error as CaddyRuntimeError {
            guard case .processFailed(let message) = error else { return XCTFail("expected readiness failure, got \(error)") }
            XCTAssertEqual(message, "Recorded Caddy PID \(pid) is still running but its admin endpoint is not ready; refusing to launch another Caddy process")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0, "silent admin socket must not defeat the readiness deadline (elapsed \(elapsed)s)")
        XCTAssertTrue(stalledServer.waitForAccept(timeout: 1), "readiness probe should reach the accepting fixture socket")
        let stillRecorded = await supervisor.status()
        XCTAssertEqual(stillRecorded.pid, pid)
        XCTAssertTrue(processIsLive(pid), "a readiness failure must retain the recorded Caddy process")
        _ = try await supervisor.stop()
    }

    func testTimedOutDiagnosticChildIsKilledAndReaped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-caddy-diagnostic-timeout-\(UUID().uuidString)")
        defer { CaddyTestSupport.removeIfPresent(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("child.pid")
        let supervisor = CaddyProcessSupervisor(layout: VaelenFilesystemLayout(rootURL: root))
        do {
            _ = try await supervisor.diagnosticCommandForTesting("/usr/bin/python3", ["-c", "import os,signal,sys,time; open(sys.argv[1],'w').write(str(os.getpid())); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)", pidFile.path], timeout: 0.1)
            XCTFail("expected diagnostic timeout")
        } catch let error as CaddyRuntimeError {
            guard case .processFailed(let message) = error else { return XCTFail("expected timeout, got \(error)") }
            XCTAssertTrue(message.contains("exceeded 0.1s timeout"))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertFalse(processIsLive(pid), "timed-out diagnostic child must not remain running")
    }

    func testStopRetainsLivePIDRecordWhenIdentityLookupFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-caddy-identity-unavailable-\(UUID().uuidString)")
        defer { CaddyTestSupport.removeIfPresent(root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.caddyInstancesDirectoryURL, withIntermediateDirectories: true)
        let child = try OwnedChildProcess.launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], label: "Caddy identity fixture")
        defer { _ = child.terminateAndWait(timeout: 2) }
        let record = CaddyProcessRecord(pid: child.processIdentifier, version: "fixture", executablePath: "/not/confirmed/caddy", arguments: ["fixture"], configPath: "/fixture/config", adminEndpoint: "unix//fixture", httpPort: 0, httpsPort: 0, startedAt: "unknown")
        let recordURL = layout.caddyInstancesDirectoryURL.appendingPathComponent("process.json")
        try JSONEncoder().encode(record).write(to: recordURL)
        let supervisor = CaddyProcessSupervisor(layout: layout)
        await supervisor.failIdentityCommandForTesting()

        do {
            _ = try await supervisor.stop()
            XCTFail("stop must refuse to discard ownership metadata when a live PID cannot be verified")
        } catch let error as CaddyRuntimeError {
            guard case .processFailed(let message) = error else { return XCTFail("expected identity-verification failure, got \(error)") }
            XCTAssertTrue(message.contains("Cannot verify the identity of live Caddy PID \(child.processIdentifier)"))
            XCTAssertTrue(message.contains("preserving its process record"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))
        XCTAssertTrue(processIsLive(child.processIdentifier), "identity uncertainty must not signal the live process")
    }

    func testListenerDiagnosticCanRepresentUnavailableIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-caddy-unavailable-\(UUID().uuidString)")
        defer { CaddyTestSupport.removeIfPresent(root) }
        let supervisor = CaddyProcessSupervisor(layout: VaelenFilesystemLayout(rootURL: root))
        let identity = await supervisor.listenerIdentityForTesting(port: 8743, command: { _, _ in throw CocoaError(.fileReadUnknown) })
        XCTAssertEqual(identity, "unavailable (lsof could not inspect listeners without elevation)")
    }

    private func listen(on port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CaddyRuntimeError.processFailed("socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, Darwin.listen(descriptor, 1) == 0 else { close(descriptor); throw CaddyRuntimeError.processFailed("bind") }
        return descriptor
    }

    private func processIsLive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private final class StalledUnixSocket: @unchecked Sendable {
        private let listener: Int32
        private let accepted = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var peer: Int32 = -1

        init(path: String) throws {
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw CaddyRuntimeError.processFailed("fixture socket") }
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8) + [0]
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(listener); throw CaddyRuntimeError.processFailed("fixture socket path too long") }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                pathBytes.withUnsafeBytes { buffer.copyBytes(from: $0) }
            }
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0, Darwin.listen(listener, 1) == 0 else { close(listener); throw CaddyRuntimeError.processFailed("fixture socket bind/listen") }
            DispatchQueue.global().async { [self] in
                let connection = Darwin.accept(listener, nil, nil)
                lock.lock(); peer = connection; lock.unlock()
                accepted.signal()
                release.wait()
                if connection >= 0 { close(connection) }
                close(listener)
            }
        }

        func waitForAccept(timeout: TimeInterval) -> Bool { accepted.wait(timeout: .now() + timeout) == .success }

        func stop() {
            release.signal()
            lock.lock(); let connection = peer; lock.unlock()
            if connection >= 0 { shutdown(connection, SHUT_RDWR) }
        }
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
}
