import Foundation
import Darwin
import Dispatch
import XCTest
import VaelenCore
import VaelenIPC
import VaelenDaemonSupport

final class PostgreSQLServiceLifecycleEndToEndTests: XCTestCase {
    func testActualValChildCreateStatusStopAndRemoveThroughPrivateCore() async throws {
        guard let valPath = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"],
              let packagePath = ProcessInfo.processInfo.environment["VAELEN_TEST_POSTGRESQL_PACKAGE_ROOT"] else {
            throw XCTSkip("Run Scripts/tests/val-service-lifecycle-test.sh to supply the built val child and verified package root.")
        }
        let root = URL(fileURLWithPath: "/private/tmp/vpg-cli-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
        let envProject = root.appendingPathComponent("fixture/project", isDirectory: true)
        try FileManager.default.createDirectory(at: envProject, withIntermediateDirectories: true)
        let envURL = envProject.appendingPathComponent(".env")
        let envBytes = Data("DATABASE_URL=postgresql://unrelated\nTOKEN=keep-me\n".utf8)
        try envBytes.write(to: envURL)
        let unrelatedPath = root.appendingPathComponent("unrelated-support/keep.bin")
        try FileManager.default.createDirectory(at: unrelatedPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelatedBytes = Data([0, 1, 2, 255])
        try unrelatedBytes.write(to: unrelatedPath)
        let unrelatedListener = try LoopbackListener(port: PostgreSQLServiceModule.availableLoopbackPort())
        defer { unrelatedListener.close() }
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let repository = ServiceInstanceRepository(store: store)
        let module = PostgreSQLServiceModule(layout: layout, repository: repository, packageRoot: URL(fileURLWithPath: packagePath, isDirectory: true))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: ProjectRegistry(store: store), postgresql: module, serviceInstances: repository, logs: CoreLogCatalog(layout: layout))
        let paths = CoreEndpointPaths(layout: layout)
        let server = DaemonServer(paths: paths, dispatcher: dispatcher)
        let serverExited = DispatchSemaphore(value: 0)
        let serverTask = Task.detached { defer { serverExited.signal() }; try server.run() }
        var preserveRoot = false
        defer { if !preserveRoot { try? FileManager.default.removeItem(at: root) } }
        do {
            for _ in 0..<300 where !FileManager.default.fileExists(atPath: paths.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))
            let port = try PostgreSQLServiceModule.availableLoopbackPort()
            let createHuman = try runVal(valPath, root: root, args: ["service", "postgresql", "create", "fixture", "--port", "\(port)"])
            XCTAssertEqual(createHuman.status, 0, "\(createHuman.error)\n\(createHuman.output)")
            XCTAssertTrue(createHuman.output.contains("PostgreSQL fixture"), createHuman.output)
            XCTAssertTrue(createHuman.output.contains("127.0.0.1:\(port)"), createHuman.output)
            let createJSON = try runVal(valPath, root: root, args: ["service", "postgresql", "status", "fixture", "--json"])
            XCTAssertEqual(createJSON.status, 0, "\(createJSON.error)\n\(createJSON.output)")
            var status = try JSONDecoder().decode(ServiceInstanceLifecycleResult.self, from: Data(createJSON.output.utf8))
            XCTAssertEqual(status.health, "stopped")
            XCTAssertEqual(status.instance?.packageIdentifier, "postgresql-18.6")
            XCTAssertEqual(status.instance?.endpoint.displayEndpoints, ["postgresql 127.0.0.1:\(port)"])
            XCTAssertTrue(try repository.isManuallyClaimed(ServiceInstanceID(kind: .postgresql, name: ProjectInstanceName("fixture"))))
            let initialClaims = try repository.claims(for: ServiceInstanceID(kind: .postgresql, name: ProjectInstanceName("fixture")))
            XCTAssertEqual(initialClaims, [try .manual(instance: ServiceInstanceID(kind: .postgresql, name: try ProjectInstanceName("fixture")))])
            let start = try runVal(valPath, root: root, args: ["service", "postgresql", "start", "fixture", "--json"])
            XCTAssertEqual(start.status, 0, "\(start.error)\n\(start.output)")
            status = try JSONDecoder().decode(ServiceInstanceLifecycleResult.self, from: Data(start.output.utf8))
            XCTAssertEqual(status.health, "healthy")
            XCTAssertNotNil(status.pid)
            let humanStatus = try runVal(valPath, root: root, args: ["service", "postgresql", "status", "fixture"])
            XCTAssertEqual(humanStatus.status, 0, "\(humanStatus.error)\n\(humanStatus.output)")
            XCTAssertTrue(humanStatus.output.contains("running"), humanStatus.output)
            let dataDirectory = try XCTUnwrap(status.instance?.dataDirectory)
            let dataSnapshot = try Data(contentsOf: URL(fileURLWithPath: dataDirectory).appendingPathComponent("PG_VERSION"))
            let stop = try runVal(valPath, root: root, args: ["service", "postgresql", "stop", "fixture", "--json"])
            XCTAssertEqual(stop.status, 0, "\(stop.error)\n\(stop.output)")
            status = try JSONDecoder().decode(ServiceInstanceLifecycleResult.self, from: Data(stop.output.utf8))
            XCTAssertEqual(status.health, "stopped")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dataDirectory).appendingPathComponent("PG_VERSION")), dataSnapshot)

            let projectID = try await ProjectRegistry(store: store).link(path: envProject, name: "lifecycle-project").id!
            try Data("version: 2\nservices:\n  database:\n    kind: postgresql\n    instance: fixture\n    version: postgresql-18.6\n".utf8).write(to: envProject.appendingPathComponent("vaelen.yml"))
            let instanceID = ServiceInstanceID(kind: .postgresql, name: try ProjectInstanceName("fixture"))
            try repository.setManualClaim(for: instanceID, claimed: false)
            let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .postgresql, instance: ProjectInstanceName("fixture"), version: PostgreSQLServiceModule.packageIdentifier)
            func runProject(_ action: String) throws -> ProjectReconciliationExecutionResult {
                let child = try runVal(valPath, root: root, args: ["project", action, projectID.rawValue.uuidString, "--json"])
                XCTAssertEqual(child.status, 0, "val project \(action) failed: \(child.error)\n\(child.output)")
                return try JSONDecoder().decode(ProjectReconciliationExecutionResult.self, from: Data(child.output.utf8))
            }
            let upResult = try runProject("up")
            XCTAssertEqual(upResult.state, .succeeded)
            XCTAssertEqual(try repository.claims(for: instanceID), [.project(projectID: projectID, binding: binding)])
            XCTAssertEqual(try module.status(id: instanceID).health, "healthy")

            let renamedBinding = try ProjectServiceBinding(alias: ProjectBindingAlias("primary"), kind: .postgresql, instance: ProjectInstanceName("fixture"), version: PostgreSQLServiceModule.packageIdentifier)
            try Data("version: 2\nservices:\n  primary:\n    kind: postgresql\n    instance: fixture\n    version: postgresql-18.6\n".utf8).write(to: envProject.appendingPathComponent("vaelen.yml"))
            let renamedResult = try runProject("up")
            XCTAssertEqual(renamedResult.state, .succeeded)
            XCTAssertEqual(try repository.claims(for: instanceID), [.project(projectID: projectID, binding: renamedBinding)])

            let evidenceURL = layout.rootURL.appendingPathComponent("runtime/postgresql/fixture/process.json")
            let evidence = try Data(contentsOf: evidenceURL)
            var corruptedEvidence = try XCTUnwrap(JSONSerialization.jsonObject(with: evidence) as? [String: Any])
            corruptedEvidence["startedAt"] = "not-the-recorded-start"
            try JSONSerialization.data(withJSONObject: corruptedEvidence).write(to: evidenceURL, options: .atomic)
            try Data("version: 2\n".utf8).write(to: envProject.appendingPathComponent("vaelen.yml"))
            let failedRetirementResult = try runProject("up")
            XCTAssertEqual(failedRetirementResult.state, .failed)
            XCTAssertEqual(try repository.claims(for: instanceID), [.project(projectID: projectID, binding: renamedBinding)])
            XCTAssertEqual(try module.status(id: instanceID).health, "identity-unverified")
            try evidence.write(to: evidenceURL, options: .atomic)

            let retiredResult = try runProject("up")
            XCTAssertEqual(retiredResult.state, .succeeded)
            XCTAssertTrue(try repository.claims(for: instanceID).isEmpty)
            XCTAssertEqual(try module.status(id: instanceID).health, "stopped")

            try Data("version: 2\nservices:\n  primary:\n    kind: postgresql\n    instance: fixture\n    version: postgresql-18.6\n".utf8).write(to: envProject.appendingPathComponent("vaelen.yml"))
            let reclaimResult = try runProject("up")
            XCTAssertEqual(reclaimResult.state, .succeeded)
            XCTAssertEqual(try repository.claims(for: instanceID), [.project(projectID: projectID, binding: renamedBinding)])

            let downResult = try runProject("down")
            XCTAssertEqual(downResult.state, .succeeded)
            XCTAssertTrue(try repository.claims(for: instanceID).isEmpty)
            XCTAssertEqual(try module.status(id: instanceID).health, "stopped")

            let upAgainResult = try runProject("up")
            XCTAssertEqual(upAgainResult.state, .succeeded)
            XCTAssertEqual(try repository.claims(for: instanceID), [.project(projectID: projectID, binding: renamedBinding)])
            XCTAssertEqual(try module.status(id: instanceID).health, "healthy")
            let finalDownResult = try runProject("down")
            XCTAssertEqual(finalDownResult.state, .succeeded)

            let remove = try runVal(valPath, root: root, args: ["service", "postgresql", "remove", "fixture", "--json"])
            XCTAssertEqual(remove.status, 0, "\(remove.error)\n\(remove.output)")
            XCTAssertTrue(try FileManager.default.fileExists(atPath: dataDirectory))
            XCTAssertFalse(try repository.isManuallyClaimed(ServiceInstanceID(kind: .postgresql, name: ProjectInstanceName("fixture"))))
            XCTAssertEqual(try Data(contentsOf: envURL), envBytes)
            XCTAssertEqual(try Data(contentsOf: unrelatedPath), unrelatedBytes)
            XCTAssertTrue(unrelatedListener.isStillListening)
            XCTAssertTrue(try repository.claims(for: ServiceInstanceID(kind: .postgresql, name: ProjectInstanceName("fixture"))).isEmpty)
            _ = try await shutdown(paths: paths)
            let exit = try await serverTask.value
            _ = exit
            XCTAssertEqual(serverExited.wait(timeout: .now() + 3), .success)
        } catch {
            preserveRoot = true
            throw NSError(domain: "PostgreSQLServiceLifecycleEndToEndTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture preserved at \(root.path): \(error)"])
        }
    }

    private func runVal(_ path: String, root: URL, args: [String]) throws -> (status: Int32, output: String, error: String) {
        let stdoutURL = root.appendingPathComponent("val.stdout")
        let stderrURL = root.appendingPathComponent("val.stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(["VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1", "VAELEN_TEST_SUPPORT_ROOT": root.path, "NO_COLOR": "1"]) { _, fresh in fresh }
        process.standardOutput = stdout; process.standardError = stderr
        let exited = DispatchSemaphore(value: 0); process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + 30) == .success else { if process.isRunning { process.terminate() }; throw NSError(domain: "val", code: 2, userInfo: [NSLocalizedDescriptionKey: "val did not exit within 30 seconds"]) }
        process.waitUntilExit(); try stdout.close(); try stderr.close()
        return (process.terminationStatus, String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self), String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self))
    }

    private func shutdown(paths: CoreEndpointPaths) async throws -> CoreShutdownResponse {
        let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "postgresql-lifecycle-fixture", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
        try await client.connect(); let response = try await client.shutdown(); await client.disconnect(); return response
    }

    private struct LoopbackListener {
        let descriptor: Int32
        init(port: Int) throws {
            descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw NSError(domain: "listener", code: 1) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian); address.sin_port = in_port_t(port).bigEndian
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, listen(descriptor, 4) == 0 else { Darwin.close(descriptor); throw NSError(domain: "listener", code: 2) }
        }
        var isStillListening: Bool {
            var address = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            return withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } } == 0
        }
        func close() { Darwin.close(descriptor) }
    }
}
