import XCTest
import Darwin
@testable import VaelenCore

final class CaddyRuntimeTests: XCTestCase {
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

    private func listen(on port: Int) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CaddyRuntimeError.processFailed("socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, Darwin.listen(descriptor, 1) == 0 else { close(descriptor); throw CaddyRuntimeError.processFailed("bind") }
        return descriptor
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
}
