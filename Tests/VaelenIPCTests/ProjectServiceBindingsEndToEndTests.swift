import Foundation
import Darwin
import XCTest
import VaelenCore
import VaelenIPC
import VaelenDaemonSupport

final class ProjectServiceBindingsEndToEndTests: XCTestCase {
    func testMailpitProjectClaimsThroughActualValChildAndPrivateCore() async throws {
        guard let val = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"],
              let sourcePath = ProcessInfo.processInfo.environment["VAELEN_TEST_MAILPIT_PACKAGE_ROOT"] else {
            throw XCTSkip("Run Scripts/tests/val-project-service-bindings-test.sh with an installed Mailpit package.")
        }
        let fm = FileManager.default
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let sourceMetadataURL = source.appendingPathComponent(".vaelen-package.json")
        guard fm.isExecutableFile(atPath: source.appendingPathComponent("mailpit").path), fm.fileExists(atPath: sourceMetadataURL.path) else {
            throw XCTSkip("Installed Mailpit package metadata or executable is unavailable. No download was attempted.")
        }
        let sourceMetadataBytes = try Data(contentsOf: sourceMetadataURL)
        let sourceExecutableBytes = try Data(contentsOf: source.appendingPathComponent("mailpit"))
        let root = URL(fileURLWithPath: "/private/tmp/vpsb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: support)
        let paths = CoreEndpointPaths(layout: layout)
        let packageID = "mailpit-\(MailpitModule.defaultVersion)"
        let packageDestination = layout.mailpitPackagesDirectoryURL.appendingPathComponent(MailpitModule.defaultVersion, isDirectory: true)
        let serverExited = DispatchSemaphore(value: 0)
        var serverTask: Task<Void, Error>?
        var mailpit: MailpitModule?
        var preserve = false
        var coreStopped = false
        do {
            try fm.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
            let smtp = try availablePort()
            let web = try availablePort(excluding: smtp)
            try fm.createDirectory(at: packageDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: packageDestination)
            let metadataURL = packageDestination.appendingPathComponent(".vaelen-package.json")
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
            metadata["packagePath"] = packageDestination.path
            metadata["executablePath"] = packageDestination.appendingPathComponent("mailpit").path
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packageDestination.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: metadataURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: metadataURL.path)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: packageDestination.path)
            let isolated = MailpitModule(layout: layout, configuration: MailpitRuntimeConfiguration(smtpPort: smtp, httpPort: web))
            mailpit = isolated
            XCTAssertEqual(isolated.installedVersions().map(\.version), [MailpitModule.defaultVersion])
            let packageExecutableBytes = try Data(contentsOf: packageDestination.appendingPathComponent("mailpit"))
            XCTAssertEqual(packageExecutableBytes, sourceExecutableBytes)

            let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
            let repository = ServiceInstanceRepository(store: store)
            let registry = ProjectRegistry(store: store)
            let intentURL = layout.stateDirectoryURL.appendingPathComponent("service-intents.json")
            let intents = ServiceIntentStore(url: intentURL)
            let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: registry, mailpit: isolated, serviceIntents: intents, serviceInstances: repository, logs: CoreLogCatalog(layout: layout))
            let server = DaemonServer(paths: paths, dispatcher: dispatcher)
            serverTask = Task.detached { defer { serverExited.signal() }; try server.run() }
            for _ in 0..<300 where !fm.fileExists(atPath: paths.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(fm.fileExists(atPath: paths.socketPath), "private Core socket must be ready")

            let project = root.appendingPathComponent("project", isDirectory: true)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            let envURL = project.appendingPathComponent(".env")
            let envBytes = Data([0x23, 0x20, 0xff, 0x0a, 0x54, 0x4f, 0x4b, 0x45, 0x4e, 0x3d, 0x6b, 0x65, 0x65, 0x70, 0x0a])
            try envBytes.write(to: envURL)
            try Data("version: 2\nservices:\n  smtp:\n    kind: mailpit\n    instance: default\n    version: \(packageID)\n  notifications:\n    kind: mailpit\n    instance: default\n    version: \(packageID)\n".utf8).write(to: project.appendingPathComponent("vaelen.yml"))
            let linked = try await registry.link(path: project, name: "mailpit-fixture")
            let projectID = try XCTUnwrap(linked.id)
            func run(_ args: [String]) throws -> (status: Int32, output: String, error: String) {
                try runVal(val, root: support, cwd: project, args: args)
            }
            let planCall = try run(["project", "plan", "--json"])
            XCTAssertEqual(planCall.status, 0, "\(planCall.error)\n\(planCall.output)")
            let plan = try JSONDecoder().decode(ProjectReconciliationPlan.self, from: Data(planCall.output.utf8))
            XCTAssertEqual(plan.state, .actionable)
            XCTAssertTrue(try repository.claims(for: ServiceInstanceID(kind: .mailpit, name: try ProjectInstanceName("default"))).isEmpty)

            func runProject(_ action: String) throws -> ProjectReconciliationExecutionResult {
                let result = try run(["project", action, projectID.rawValue.uuidString, "--json"])
                XCTAssertEqual(result.status, 0, "val project \(action) failed: \(result.error)\n\(result.output)")
                return try JSONDecoder().decode(ProjectReconciliationExecutionResult.self, from: Data(result.output.utf8))
            }
            let firstUp = try runProject("up")
            XCTAssertEqual(firstUp.state, .succeeded)
            var status = isolated.status()
            XCTAssertEqual(status.state, .running)
            XCTAssertEqual(status.health, "healthy")
            let pid = try XCTUnwrap(status.pid)
            let id = ServiceInstanceID(kind: .mailpit, name: try ProjectInstanceName("default"))
            let claims = try repository.claims(for: id)
            XCTAssertEqual(claims.compactMap { claim -> String? in if case .project(_, let binding) = claim { return binding.alias.value }; return nil }.sorted(), ["notifications", "smtp"])
            XCTAssertEqual(try repository.instance(id)?.packageIdentifier, packageID)
            XCTAssertEqual(try repository.instances().count, 1)

            let inventoryCall = try run(["service", "instances", "--json"])
            XCTAssertEqual(inventoryCall.status, 0, "\(inventoryCall.error)\n\(inventoryCall.output)")
            let inventory = try IPCCodec.decode(ServiceInstanceInventoryResult.self, from: Data(inventoryCall.output.utf8))
            let entry = try XCTUnwrap(inventory.entries.first)
            XCTAssertEqual(inventory.entries.count, 1)
            XCTAssertEqual(entry.instance.kind, .mailpit)
            XCTAssertEqual(entry.instance.name.value, "default")
            XCTAssertEqual(entry.instance.packageIdentifier, packageID)
            XCTAssertEqual(entry.instance.endpoint.displayEndpoints, ["smtp 127.0.0.1:\(smtp)", "http 127.0.0.1:\(web)"])
            XCTAssertEqual(entry.instance.dataDirectory, layout.mailpitInstancesDirectoryURL.appendingPathComponent("default", isDirectory: true).path)
            guard case .project(_, let firstAlias, _) = try XCTUnwrap(entry.owners.first(where: { if case .project(_, let alias, _) = $0 { return alias.value == "smtp" }; return false })) else { return XCTFail("smtp claim missing") }
            XCTAssertEqual(firstAlias.value, "smtp")
            XCTAssertEqual(entry.owners.compactMap { claim -> String? in if case .project(_, let alias, _) = claim { return alias.value }; return nil }.sorted(), ["notifications", "smtp"])

            XCTAssertEqual(try runProject("down").state, .succeeded)
            XCTAssertTrue(try repository.claims(for: id).isEmpty)
            status = isolated.status()
            XCTAssertEqual(status.state, .running)
            XCTAssertEqual(status.pid, pid)
            XCTAssertFalse(try intents.enabledServices().contains("mailpit"))
            for _ in 0..<2 {
                XCTAssertEqual(try runProject("up").state, .succeeded)
                XCTAssertEqual(try runProject("down").state, .succeeded)
                XCTAssertEqual(isolated.status().pid, pid)
                XCTAssertTrue(try repository.claims(for: id).isEmpty)
            }
            XCTAssertEqual(try Data(contentsOf: envURL), envBytes)
            XCTAssertEqual(try Data(contentsOf: sourceMetadataURL), sourceMetadataBytes)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("mailpit")), sourceExecutableBytes)

            _ = try isolated.stop()
            XCTAssertEqual(isolated.status().state, .stopped)
            let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "mailpit-binding-fixture", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
            try await client.connect(); _ = try await client.shutdown(); await client.disconnect()
            guard await wait(serverExited, seconds: 4) else { preserve = true; throw NSError(domain: "ProjectServiceBindings", code: 1, userInfo: [NSLocalizedDescriptionKey: "private Core failed to stop; root preserved at \(root.path)"]) }
            _ = try await serverTask?.value
            coreStopped = true
            XCTAssertFalse(processExists(pid), "fixture Mailpit process must exit")
            print("PROJECT_SERVICE_BINDINGS_EVIDENCE package=\(packageID) pid=\(pid) smtp=\(smtp) web=\(web) claims=2 down=release-only env=unchanged source=unchanged cleanup=confirmed")
        } catch {
            var errors = [String]()
            if serverTask == nil { coreStopped = true }
            var mailpitStopped = mailpit == nil
            if let mailpit {
                do { if mailpit.status().state == .running { _ = try mailpit.stop() }; mailpitStopped = [MailpitState.stopped, .installed, .notInstalled].contains(mailpit.status().state); if !mailpitStopped { errors.append("Mailpit did not stop") } }
                catch { errors.append("Mailpit cleanup failed: \(error)") }
            }
            if let serverTask, !coreStopped {
                do {
                    let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "mailpit-binding-cleanup", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
                    try await client.connect(); _ = try await client.shutdown(); await client.disconnect()
                    if await wait(serverExited, seconds: 4) { _ = try? await serverTask.value; coreStopped = true } else { errors.append("private Core did not exit") }
                } catch { errors.append("private Core cleanup failed: \(error)") }
            }
            if !errors.isEmpty || !coreStopped { preserve = true }
            if !preserve && mailpitStopped {
                do {
                    if fm.fileExists(atPath: packageDestination.path) { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packageDestination.path) }
                    try fm.removeItem(at: root)
                } catch { errors.append("Fixture cleanup failed: \(error)"); preserve = true }
            }
            throw NSError(domain: "ProjectServiceBindingsEndToEndTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture root \(root.path). Core stopped: \(coreStopped). Cleanup: \(errors.joined(separator: " | ")). Original error: \(error)"])
        }
        if !preserve {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packageDestination.path)
            try fm.removeItem(at: root)
            XCTAssertFalse(fm.fileExists(atPath: root.path), "fixture root must be removed after Core and Mailpit stop")
        }
    }

    private func availablePort(excluding: Int? = nil) throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw NSError(domain: "port", code: 1) }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1")); address.sin_port = 0
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw NSError(domain: "port", code: 2) }
        var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size); _ = withUnsafeMutablePointer(to: &actual, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } })
        let port = Int(UInt16(bigEndian: actual.sin_port)); return port == excluding ? try availablePort(excluding: excluding) : port
    }

    private func runVal(_ executable: String, root: URL, cwd: URL, args: [String]) throws -> (status: Int32, output: String, error: String) {
        let outURL = root.appendingPathComponent("val.stdout"), errURL = root.appendingPathComponent("val.stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil); FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args; process.currentDirectoryURL = cwd
        process.environment = ProcessInfo.processInfo.environment.merging(["VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1", "VAELEN_TEST_SUPPORT_ROOT": root.path, "NO_COLOR": "1"]) { _, value in value }
        process.standardOutput = out; process.standardError = err
        let exited = DispatchSemaphore(value: 0); process.terminationHandler = { _ in exited.signal() }; try process.run()
        guard exited.wait(timeout: .now() + 30) == .success else { process.terminate(); guard exited.wait(timeout: .now() + 3) == .success else { throw NSError(domain: "val", code: 3, userInfo: [NSLocalizedDescriptionKey: "val child exit is unconfirmed; preserve \(root.path)"]) }; throw NSError(domain: "val", code: 2, userInfo: [NSLocalizedDescriptionKey: "val child timed out; preserve \(root.path)"]) }
        process.waitUntilExit(); try out.close(); try err.close()
        return (process.terminationStatus, String(decoding: try Data(contentsOf: outURL), as: UTF8.self), String(decoding: try Data(contentsOf: errURL), as: UTF8.self))
    }

    private func wait(_ semaphore: DispatchSemaphore, seconds: Int) async -> Bool { await Task.detached(priority: .utility) { Self.blockingWait(semaphore, seconds: seconds) }.value }
    nonisolated private static func blockingWait(_ semaphore: DispatchSemaphore, seconds: Int) -> Bool { semaphore.wait(timeout: .now() + .seconds(seconds)) == .success }
    private func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}
