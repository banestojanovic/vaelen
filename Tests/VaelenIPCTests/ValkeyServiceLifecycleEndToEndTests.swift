import Foundation
import Darwin
import Dispatch
import XCTest
import VaelenCore
import VaelenIPC
import VaelenDaemonSupport

final class ValkeyServiceLifecycleEndToEndTests: XCTestCase {
    func testActualValChildLifecycleThroughPrivateCore() async throws {
        guard let valPath = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"],
              let packagePath = ProcessInfo.processInfo.environment["VAELEN_TEST_VALKEY_PACKAGE_ROOT"] else {
            throw XCTSkip("Run Scripts/tests/valkey-service-lifecycle-test.sh to supply val and the local pinned package fixture.")
        }
        let root = URL(fileURLWithPath: "/private/tmp/vvk-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let repository = ServiceInstanceRepository(store: store)
        let module = ValkeyServiceModule(layout: layout, repository: repository, packageRoot: URL(fileURLWithPath: packagePath, isDirectory: true))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: ProjectRegistry(store: store), valkey: module, serviceInstances: repository, logs: CoreLogCatalog(layout: layout))
        let paths = CoreEndpointPaths(layout: layout)
        let server = DaemonServer(paths: paths, dispatcher: dispatcher)
        let exited = DispatchSemaphore(value: 0)
        let serverTask = Task.detached { defer { exited.signal() }; try server.run() }
        var preserveRoot = false
        defer { if testRun?.hasSucceeded == false { preserveRoot = true }; if !preserveRoot { try? FileManager.default.removeItem(at: root) } }
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: paths.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))

        let id = ServiceInstanceID(kind: .valkey, name: try ProjectInstanceName("cache"))
        do {
        let occupiedData = layout.valkeyInstancesDirectoryURL.appendingPathComponent("occupied/data", isDirectory: true)
        try FileManager.default.createDirectory(at: occupiedData, withIntermediateDirectories: true)
        let occupiedBytes = Data("keep existing bytes".utf8)
        try occupiedBytes.write(to: occupiedData.appendingPathComponent("keep.bin"))
        let refused = try runVal(valPath, root: root, args: ["service", "valkey", "create", "occupied"])
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertEqual(try Data(contentsOf: occupiedData.appendingPathComponent("keep.bin")), occupiedBytes)
        XCTAssertNil(try repository.instance(ServiceInstanceID(kind: .valkey, name: ProjectInstanceName("occupied"))))
        let create = try runVal(valPath, root: root, args: ["service", "valkey", "create", "cache", "--json"])
        XCTAssertEqual(create.status, 0, "\(create.error)\n\(create.output)")
        let created = try JSONDecoder().decode(ServiceInstanceLifecycleResult.self, from: Data(create.output.utf8))
        let port = try XCTUnwrap(created.instance.map(endpointPort))
        let repeated = try runVal(valPath, root: root, args: ["service", "valkey", "create", "cache", "--json"])
        XCTAssertEqual(repeated.status, 0, "\(repeated.error)\n\(repeated.output)")
        let repeatedCreated = try JSONDecoder().decode(ServiceInstanceLifecycleResult.self, from: Data(repeated.output.utf8))
        XCTAssertEqual(repeatedCreated.instance.map(endpointPort), port)
        XCTAssertEqual(try repository.claims(for: id), [.manual(instance: id)])

        let start = try runVal(valPath, root: root, args: ["service", "valkey", "start", "cache", "--json"])
        XCTAssertEqual(start.status, 0, "\(start.error)\n\(start.output)")
        var status = try JSONDecoder().decode(ServiceInstanceLifecycleResult.self, from: Data(start.output.utf8))
        XCTAssertEqual(status.health, "healthy")
        XCTAssertEqual(status.instance?.packageIdentifier, "valkey-9.1.2")
        XCTAssertEqual(status.instance?.endpoint.displayEndpoints, ["valkey 127.0.0.1:\(port)"])
        let dataDirectory = try XCTUnwrap(status.instance?.dataDirectory)
        XCTAssertTrue(dataDirectory.hasPrefix(layout.valkeyInstancesDirectoryURL.appendingPathComponent("cache/data").path))
        let evidenceURL = layout.rootURL.appendingPathComponent("runtime/valkey/cache/process.json")
        let evidence = try Data(contentsOf: evidenceURL)
        var changedEvidence = try XCTUnwrap(JSONSerialization.jsonObject(with: evidence) as? [String: Any])
        let secondCreate = try runVal(valPath, root: root, args: ["service", "valkey", "create", "other", "--json"])
        XCTAssertEqual(secondCreate.status, 0, "\(secondCreate.error)\n\(secondCreate.output)")
        let secondStart = try runVal(valPath, root: root, args: ["service", "valkey", "start", "other", "--json"])
        XCTAssertEqual(secondStart.status, 0, "\(secondStart.error)\n\(secondStart.output)")
        let otherEvidenceURL = layout.rootURL.appendingPathComponent("runtime/valkey/other/process.json")
        let otherEvidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: otherEvidenceURL)) as? [String: Any])
        var wrongOwnerEvidence = changedEvidence
        for key in ["pid", "startedAt", "executable", "command"] { wrongOwnerEvidence[key] = otherEvidence[key] }
        try JSONSerialization.data(withJSONObject: wrongOwnerEvidence).write(to: evidenceURL, options: .atomic)
        XCTAssertEqual(try module.status(id: id).health, "unhealthy")
        XCTAssertThrowsError(try module.stop(id: id))
        let otherID = ServiceInstanceID(kind: .valkey, name: try ProjectInstanceName("other"))
        XCTAssertEqual(try module.status(id: otherID).health, "healthy")
        try evidence.write(to: evidenceURL, options: .atomic)
        try module.stop(id: otherID)
        changedEvidence["startedAt"] = "not-the-recorded-start"
        try JSONSerialization.data(withJSONObject: changedEvidence).write(to: evidenceURL, options: .atomic)
        XCTAssertEqual(try module.status(id: id).health, "identity-unverified")
        XCTAssertThrowsError(try module.stop(id: id))
        try evidence.write(to: evidenceURL, options: .atomic)
        let snapshotPolicy = URL(fileURLWithPath: dataDirectory).appendingPathComponent("appendonlydir/appendonly.aof.manifest")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPolicy.path))
        XCTAssertThrowsError(try module.remove(id: id))

        let cli = URL(fileURLWithPath: packagePath).appendingPathComponent("bin/valkey-cli").path
        XCTAssertEqual(try runExecutable(cli, args: ["-h", "127.0.0.1", "-p", "\(port)", "SET", "lifecycle-key", "persisted-value"]).status, 0)
        let stop = try runVal(valPath, root: root, args: ["service", "valkey", "stop", "cache", "--json"])
        XCTAssertEqual(stop.status, 0, "\(stop.error)\n\(stop.output)")
        status = try JSONDecoder().decode(ServiceInstanceLifecycleResult.self, from: Data(stop.output.utf8))
        XCTAssertEqual(status.health, "stopped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: dataDirectory).appendingPathComponent("appendonlydir/appendonly.aof.manifest").path))
        let restart = try runVal(valPath, root: root, args: ["service", "valkey", "start", "cache", "--json"])
        XCTAssertEqual(restart.status, 0, "\(restart.error)\n\(restart.output)")
        let recovered = try runExecutable(cli, args: ["-h", "127.0.0.1", "-p", "\(port)", "--raw", "GET", "lifecycle-key"])
        XCTAssertEqual(recovered.status, 0)
        XCTAssertEqual(recovered.output.trimmingCharacters(in: .whitespacesAndNewlines), "persisted-value")
        let stopAfterRestart = try runVal(valPath, root: root, args: ["service", "valkey", "stop", "cache", "--json"])
        XCTAssertEqual(stopAfterRestart.status, 0, "\(stopAfterRestart.error)\n\(stopAfterRestart.output)")
        let remove = try runVal(valPath, root: root, args: ["service", "valkey", "remove", "cache", "--json"])
        XCTAssertEqual(remove.status, 0, "\(remove.error)\n\(remove.output)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDirectory))
        XCTAssertFalse(try repository.isManuallyClaimed(id))

        let projectID = ServiceInstanceID(kind: .valkey, name: try ProjectInstanceName("project-cache"))
        try module.create(id: projectID, port: ValkeyServiceModule.availableLoopbackPort())
        try repository.setManualClaim(for: projectID, claimed: false)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let linkedProject = try await ProjectRegistry(store: store).link(path: projectDirectory, name: "valkey-project").id!
        let manifestURL = projectDirectory.appendingPathComponent("vaelen.yml")
        func writeManifest(aliases: [String]) throws {
            let declarations = aliases.map { "  \($0):\n    kind: valkey\n    instance: project-cache\n    version: valkey-9.1.2\n" }.joined()
            try Data("version: 2\nservices:\n\(declarations)".utf8).write(to: manifestURL)
        }
        func runProject(_ action: String) throws -> ProjectReconciliationExecutionResult {
            let child = try runVal(valPath, root: root, args: ["project", action, linkedProject.rawValue.uuidString, "--json"])
            XCTAssertEqual(child.status, 0, "val project \(action) failed: \(child.error)\n\(child.output)")
            return try JSONDecoder().decode(ProjectReconciliationExecutionResult.self, from: Data(child.output.utf8))
        }
        let projectRecord = try XCTUnwrap(repository.instance(projectID))
        let projectDataDirectory = projectRecord.dataDirectory
        let projectBinding = try ProjectServiceBinding(alias: ProjectBindingAlias("cache"), kind: .valkey, instance: projectID.name, version: ValkeyServiceModule.packageIdentifier)
        let secondaryBinding = try ProjectServiceBinding(alias: ProjectBindingAlias("replica"), kind: .valkey, instance: projectID.name, version: ValkeyServiceModule.packageIdentifier)
        try writeManifest(aliases: ["cache", "replica"])
        let multiAliasActivation = try runProject("up")
        XCTAssertEqual(multiAliasActivation.state, .succeeded)
        let aliasResults = multiAliasActivation.operations.filter { ["service.cache", "service.replica"].contains($0.operationID) }
        XCTAssertEqual(aliasResults.count, 2)
        XCTAssertTrue(aliasResults.allSatisfy { $0.state == .succeeded && $0.verified })
        let projectEvidenceURL = layout.rootURL.appendingPathComponent("runtime/valkey/project-cache/process.json")
        XCTAssertEqual(try module.status(id: projectID).health, "healthy")
        XCTAssertEqual(Set(try repository.projectClaims(for: linkedProject)), Set([projectBinding, secondaryBinding]))
        let sharedEvidenceURL = layout.rootURL.appendingPathComponent("runtime/valkey/project-cache/process.json")
        let sharedEvidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sharedEvidenceURL)) as? [String: Any])
        XCTAssertNotNil(sharedEvidence["pid"])
        XCTAssertNotNil(sharedEvidence["startedAt"])
        XCTAssertEqual(try runProject("up").state, .succeeded)
        XCTAssertEqual(Set(try repository.projectClaims(for: linkedProject)), Set([projectBinding, secondaryBinding]))
        let repeatedEvidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sharedEvidenceURL)) as? [String: Any])
        XCTAssertEqual(repeatedEvidence["pid"] as? Int32, sharedEvidence["pid"] as? Int32)
        XCTAssertEqual(repeatedEvidence["startedAt"] as? String, sharedEvidence["startedAt"] as? String)

        let renamedBinding = try ProjectServiceBinding(alias: ProjectBindingAlias("primary"), kind: .valkey, instance: projectID.name, version: ValkeyServiceModule.packageIdentifier)
        try writeManifest(aliases: ["primary"])
        XCTAssertEqual(try runProject("up").state, .succeeded)
        XCTAssertEqual(try repository.projectClaims(for: linkedProject), [renamedBinding])
        try repository.setManualClaim(for: projectID, claimed: true)
        XCTAssertEqual(try runProject("down").state, .succeeded)
        XCTAssertTrue(try repository.projectClaims(for: linkedProject).isEmpty)
        XCTAssertEqual(try module.status(id: projectID).health, "healthy", "down must leave a shared manual owner running")
        XCTAssertEqual(try runProject("down").state, .succeeded)

        try repository.setManualClaim(for: projectID, claimed: false)
        XCTAssertEqual(try runProject("up").state, .succeeded)
        XCTAssertEqual(try repository.claims(for: projectID), [.project(projectID: linkedProject, binding: renamedBinding)])
        XCTAssertEqual(try runProject("down").state, .succeeded)
        XCTAssertEqual(try module.status(id: projectID).health, "stopped")
        XCTAssertTrue(try FileManager.default.fileExists(atPath: projectDataDirectory))
        XCTAssertTrue(try repository.projectClaims(for: linkedProject).isEmpty)
        XCTAssertEqual(try runProject("down").state, .succeeded)

        XCTAssertEqual(try runProject("up").state, .succeeded)
        try repository.setManualClaim(for: projectID, claimed: true)
        let sharedFailureEvidence = try Data(contentsOf: projectEvidenceURL)
        var sharedFailureJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedFailureEvidence) as? [String: Any])
        sharedFailureJSON["startedAt"] = "not-the-recorded-start"
        try JSONSerialization.data(withJSONObject: sharedFailureJSON).write(to: projectEvidenceURL, options: .atomic)
        XCTAssertEqual(try runProject("down").state, .succeeded)
        XCTAssertTrue(try repository.projectClaims(for: linkedProject).isEmpty)
        XCTAssertEqual(try module.status(id: projectID).health, "identity-unverified")
        try sharedFailureEvidence.write(to: projectEvidenceURL, options: .atomic)
        try repository.setManualClaim(for: projectID, claimed: false)
        XCTAssertEqual(try runProject("up").state, .succeeded)
        let projectEvidence = try Data(contentsOf: projectEvidenceURL)
        var corruptedProjectEvidence = try XCTUnwrap(JSONSerialization.jsonObject(with: projectEvidence) as? [String: Any])
        corruptedProjectEvidence["startedAt"] = "not-the-recorded-start"
        try JSONSerialization.data(withJSONObject: corruptedProjectEvidence).write(to: projectEvidenceURL, options: .atomic)
        XCTAssertEqual(try runProject("down").state, .failed)
        XCTAssertEqual(try repository.projectClaims(for: linkedProject), [renamedBinding])
        XCTAssertEqual(try module.status(id: projectID).health, "identity-unverified")
        XCTAssertTrue(try FileManager.default.fileExists(atPath: projectDataDirectory))
        try projectEvidence.write(to: projectEvidenceURL, options: .atomic)
        XCTAssertEqual(try runProject("down").state, .succeeded)
        XCTAssertEqual(try module.status(id: projectID).health, "stopped")
        XCTAssertTrue(try FileManager.default.fileExists(atPath: projectDataDirectory))

        let staleID = ServiceInstanceID(kind: .valkey, name: try ProjectInstanceName("stale"))
        try module.create(id: staleID, port: ValkeyServiceModule.availableLoopbackPort())
        try module.start(id: staleID)
        let staleEvidenceURL = layout.rootURL.appendingPathComponent("runtime/valkey/stale/process.json")
        let staleEvidence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: staleEvidenceURL)) as? [String: Any])
        let stalePID = try XCTUnwrap(staleEvidence["pid"] as? Int32)
        XCTAssertEqual(kill(pid_t(stalePID), SIGKILL), 0)
        for _ in 0..<100 where kill(pid_t(stalePID), 0) == 0 { usleep(20_000) }
        try module.stop(id: staleID)
        XCTAssertEqual(try module.status(id: staleID).health, "stopped")
        try module.start(id: staleID)
        XCTAssertEqual(try module.status(id: staleID).health, "healthy")
        try module.stop(id: staleID)

        let failureID = ServiceInstanceID(kind: .valkey, name: try ProjectInstanceName("evidencefail"))
        try module.create(id: failureID, port: ValkeyServiceModule.availableLoopbackPort())
        let failureEvidenceURL = layout.rootURL.appendingPathComponent("runtime/valkey/evidencefail/process.json")
        try FileManager.default.createDirectory(at: failureEvidenceURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try module.start(id: failureID))
        XCTAssertEqual(try module.status(id: failureID).health, "stopped", "failed evidence publication must leave no listener")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.valkeyInstancesDirectoryURL.appendingPathComponent("evidencefail/data").path))
        let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "valkey-lifecycle-fixture", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
        try await client.connect(); _ = try await client.shutdown(); await client.disconnect()
        _ = try await serverTask.value
        XCTAssertEqual(exited.wait(timeout: .now() + 3), .success)
        } catch {
            preserveRoot = true
            if (try? repository.instance(id)) != nil { try? module.stop(id: id) }
            let cleanupClient = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "valkey-lifecycle-cleanup", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
            try? await cleanupClient.connect(); _ = try? await cleanupClient.shutdown(); await cleanupClient.disconnect()
            _ = try? await serverTask.value
            throw error
        }
    }

    private func endpointPort(_ instance: ServiceInstanceRecordWire) -> Int {
        guard case .valkey(let port) = instance.endpoint else { XCTFail("Expected a Valkey endpoint"); return 0 }
        return port
    }

    private func runExecutable(_ path: String, args: [String]) throws -> (status: Int32, output: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func runVal(_ path: String, root: URL, args: [String]) throws -> (status: Int32, output: String, error: String) {
        let out = root.appendingPathComponent("val.out"), err = root.appendingPathComponent("val.err")
        FileManager.default.createFile(atPath: out.path, contents: nil); FileManager.default.createFile(atPath: err.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(["VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1", "VAELEN_TEST_SUPPORT_ROOT": root.path, "NO_COLOR": "1"]) { _, value in value }
        process.standardOutput = stdout; process.standardError = stderr
        try process.run(); process.waitUntilExit(); try stdout.close(); try stderr.close()
        return (process.terminationStatus, String(decoding: try Data(contentsOf: out), as: UTF8.self), String(decoding: try Data(contentsOf: err), as: UTF8.self))
    }
}
