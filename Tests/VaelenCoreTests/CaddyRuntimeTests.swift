import XCTest
import Darwin
@testable import VaelenCore

final class CaddyRuntimeTests: XCTestCase {
    func testOfficialCaddyLifecycleIsOwnedAndIdempotent() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-caddy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let package = try resolveCaddyPackage()
        let supervisor = CaddyProcessSupervisor(layout: layout)
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
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try resolveCaddyPackage()

        let collisionSocket = try listenOnConfiguredPort()
        let collisionLayout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("collision"))
        let collisionSupervisor = CaddyProcessSupervisor(layout: collisionLayout)
        await collisionSupervisor.installPackage(package)
        do {
            _ = try await collisionSupervisor.start()
            XCTFail("expected port collision")
        } catch let error as CaddyRuntimeError {
            XCTAssertEqual(error, .portConflict(VaelenNetworkPorts.httpBackend))
        }
        close(collisionSocket)

        let crashLayout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("crash"))
        let crashSupervisor = CaddyProcessSupervisor(layout: crashLayout)
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

    private func listenOnConfiguredPort() throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CaddyRuntimeError.processFailed("socket") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(VaelenNetworkPorts.httpBackend).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, Darwin.listen(descriptor, 1) == 0 else { close(descriptor); throw CaddyRuntimeError.processFailed("bind") }
        return descriptor
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
