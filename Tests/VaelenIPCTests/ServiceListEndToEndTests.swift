import Foundation
import Darwin
import XCTest
import VaelenCore
import VaelenIPC
import VaelenDaemonSupport

final class ServiceListEndToEndTests: XCTestCase {
    private struct Inventory: Decodable {
        struct Service: Decodable {
            let service: String
            let instance: String
            let state: String
            let endpoints: [String: String]
            let observationError: String?
        }

        let complete: Bool
        let services: [Service]
    }

    func testActualValChildReportsBothServicesUnavailableWhenCoreIsMissing() throws {
        guard let valPath = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"] else {
            throw XCTSkip("Set VAELEN_VAL_EXECUTABLE to the actual built val binary by running Scripts/tests/val-service-list-test.sh.")
        }

        let root = URL(fileURLWithPath: "/private/tmp/vsl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var preserveRoot = false
        defer { if !preserveRoot { try? FileManager.default.removeItem(at: root) } }

        var environment = ProcessInfo.processInfo.environment
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = root.path
        environment["NO_COLOR"] = "1"

        let stdoutURL = root.appendingPathComponent("stdout")
        let stderrURL = root.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw NSError(domain: "ServiceListEndToEndTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create private CLI output files"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: valPath)
        process.arguments = ["service", "list", "--json"]
        process.environment = environment
        let stdoutFile = try FileHandle(forWritingTo: stdoutURL)
        let stderrFile = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutFile
        process.standardError = stderrFile
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var didExit = exited.wait(timeout: .now() + 10) == .success
        if !didExit {
            if process.isRunning { process.terminate() }
            didExit = exited.wait(timeout: .now() + 1) == .success
        }
        if !didExit {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            didExit = exited.wait(timeout: .now() + 2) == .success
        }
        guard didExit else {
            preserveRoot = true
            try? stdoutFile.close()
            try? stderrFile.close()
            XCTFail("val child exit could not be confirmed; fixture preserved at \(root.path)")
            return
        }
        process.waitUntilExit()
        try stdoutFile.close()
        try stderrFile.close()

        let stdout = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 3, "stdout: \(stdout)\nstderr: \(stderr)")
        XCTAssertTrue(stderr.contains("Vaelen Core is not running"), stderr)

        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(stdout.utf8))
        XCTAssertFalse(inventory.complete)
        XCTAssertEqual(inventory.services.map(\.service), ["mysql", "mailpit"])
        XCTAssertEqual(inventory.services.map(\.state), ["unavailable", "unavailable"])
    }

    func testActualValChildListsServicesFromPrivateCoreWithoutInstalledPackages() async throws {
        guard let valPath = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"] else {
            throw XCTSkip("Set VAELEN_VAL_EXECUTABLE to the actual built val binary by running Scripts/tests/val-service-list-test.sh.")
        }
        let root = URL(fileURLWithPath: "/private/tmp/vsl-core-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let registry = ProjectRegistry(store: store)
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test", pid: getpid()),
            registry: registry,
            mysql: MySQLModule(layout: layout),
            mailpit: MailpitModule(layout: layout),
            serviceIntents: ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json")),
            logs: CoreLogCatalog(layout: layout)
        )
        let paths = CoreEndpointPaths(layout: layout)
        let server = DaemonServer(paths: paths, dispatcher: dispatcher)
        let serverExited = DispatchSemaphore(value: 0)
        let serverTask = Task.detached {
            defer { serverExited.signal() }
            try server.run()
        }
        var serverStopped = false
        var preserveRoot = false
        do {
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: paths.socketPath) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))

            let result = try runVal(valPath, root: root, preserveRoot: &preserveRoot)
            XCTAssertEqual(result.status, 0, "stdout: \(result.output)\nstderr: \(result.error)")
            XCTAssertEqual(result.error, "")
            let inventory = try JSONDecoder().decode(Inventory.self, from: Data(result.output.utf8))
            XCTAssertTrue(inventory.complete)
            XCTAssertEqual(inventory.services.map(\.service), ["mysql", "mailpit"])
            XCTAssertEqual(inventory.services.map(\.instance), ["default", "default"])
            XCTAssertFalse(inventory.services.contains { $0.state == "unavailable" })
            XCTAssertEqual(inventory.services.map(\.state), ["notInstalled", "notInstalled"])
            let mysql = try XCTUnwrap(inventory.services.first { $0.service == "mysql" })
            let mailpit = try XCTUnwrap(inventory.services.first { $0.service == "mailpit" })
            XCTAssertEqual(mysql.endpoints, [
                "tcp": "127.0.0.1:3306",
                "socket": layout.rootURL.appendingPathComponent("runtime/sockets/mysql/default.sock").path
            ])
            XCTAssertEqual(mailpit.endpoints, [
                "smtp": "127.0.0.1:\(MailpitModule.smtpPort)",
                "web": "http://127.0.0.1:\(MailpitModule.httpPort)"
            ])

            let stopError = try await stopServer(paths: paths, serverTask: serverTask, serverExited: serverExited)
            serverStopped = true
            if let stopError { throw NSError(domain: "ServiceListEndToEndTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Private Core exited with a shutdown error: \(stopError)"]) }
        } catch {
            let originalError = error
            if !serverStopped {
                do {
                    _ = try await stopServer(paths: paths, serverTask: serverTask, serverExited: serverExited)
                    serverStopped = true
                } catch {
                    preserveRoot = true
                    throw NSError(domain: "ServiceListEndToEndTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Private Core shutdown could not be confirmed; fixture preserved at \(root.path). Original failure: \(originalError). Shutdown failure: \(error)"])
                }
            }
            if !preserveRoot { try? FileManager.default.removeItem(at: root) }
            throw originalError
        }
        if !preserveRoot { try FileManager.default.removeItem(at: root) }
    }

    func testActualValChildReportsPartialInventoryWhenMySQLObservationFails() async throws {
        guard let valPath = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"] else {
            throw XCTSkip("Set VAELEN_VAL_EXECUTABLE to the actual built val binary by running Scripts/tests/val-service-list-test.sh.")
        }
        let root = URL(fileURLWithPath: "/private/tmp/vsl-partial-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let registry = ProjectRegistry(store: store)
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test", pid: getpid()),
            registry: registry,
            mysql: nil,
            mailpit: MailpitModule(layout: layout),
            serviceIntents: ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json")),
            logs: CoreLogCatalog(layout: layout)
        )
        let paths = CoreEndpointPaths(layout: layout)
        let server = DaemonServer(paths: paths, dispatcher: dispatcher)
        let serverExited = DispatchSemaphore(value: 0)
        let serverTask = Task.detached {
            defer { serverExited.signal() }
            try server.run()
        }
        var serverStopped = false
        var preserveRoot = false
        do {
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: paths.socketPath) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))

            let result = try runVal(valPath, root: root, preserveRoot: &preserveRoot)
            XCTAssertNotEqual(result.status, 0, "stdout: \(result.output)\nstderr: \(result.error)")
            XCTAssertFalse(result.error.isEmpty, "incomplete inventory should explain itself on stderr")
            XCTAssertTrue(result.error.localizedCaseInsensitiveContains("incomplete"), result.error)
            let inventory = try JSONDecoder().decode(Inventory.self, from: Data(result.output.utf8))
            XCTAssertFalse(inventory.complete)
            XCTAssertEqual(inventory.services.count, 2)
            let mysql = try XCTUnwrap(inventory.services.first { $0.service == "mysql" })
            XCTAssertEqual(mysql.state, "unavailable")
            XCTAssertFalse(try XCTUnwrap(mysql.observationError).isEmpty)
            let mailpit = try XCTUnwrap(inventory.services.first { $0.service == "mailpit" })
            XCTAssertEqual(mailpit.state, "notInstalled")
            XCTAssertEqual(mailpit.endpoints, [
                "smtp": "127.0.0.1:\(MailpitModule.smtpPort)",
                "web": "http://127.0.0.1:\(MailpitModule.httpPort)"
            ])

            let stopError = try await stopServer(paths: paths, serverTask: serverTask, serverExited: serverExited)
            serverStopped = true
            if let stopError { throw NSError(domain: "ServiceListEndToEndTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "Private Core exited with a shutdown error: \(stopError)"]) }
        } catch {
            let originalError = error
            if !serverStopped {
                do {
                    _ = try await stopServer(paths: paths, serverTask: serverTask, serverExited: serverExited)
                    serverStopped = true
                } catch {
                    preserveRoot = true
                    throw NSError(domain: "ServiceListEndToEndTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "Private Core shutdown could not be confirmed; fixture preserved at \(root.path). Original failure: \(originalError). Shutdown failure: \(error)"])
                }
            }
            if !preserveRoot { try? FileManager.default.removeItem(at: root) }
            throw originalError
        }
        if !preserveRoot { try FileManager.default.removeItem(at: root) }
    }

    private func runVal(_ path: String, root: URL, preserveRoot: inout Bool) throws -> (status: Int32, output: String, error: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = root.path
        environment["NO_COLOR"] = "1"
        let outputURL = root.appendingPathComponent("service-list.stdout")
        let errorURL = root.appendingPathComponent("service-list.stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil), FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw NSError(domain: "ServiceListEndToEndTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create private CLI output files"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["service", "list", "--json"]
        process.environment = environment
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var didExit = exited.wait(timeout: .now() + 10) == .success
        if !didExit {
            if process.isRunning { process.terminate() }
            didExit = exited.wait(timeout: .now() + 1) == .success
        }
        if !didExit {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            didExit = exited.wait(timeout: .now() + 2) == .success
        }
        guard didExit else {
            preserveRoot = true
            try? stdout.close()
            try? stderr.close()
            throw NSError(domain: "ServiceListEndToEndTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "val child exit could not be confirmed; fixture preserved at \(root.path)"])
        }
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        return (process.terminationStatus,
                String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
                String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
    }

    private func stopServer(paths: CoreEndpointPaths, serverTask: Task<Void, Error>, serverExited: DispatchSemaphore) async throws -> String? {
        let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "service-list-test-stop", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
        let finished = DispatchSemaphore(value: 0)
        let shutdownTask = Task.detached { () -> String? in
            defer { finished.signal() }
            do {
                try await client.connect()
                _ = try await client.shutdown()
                await client.disconnect()
                return nil
            } catch {
                await client.disconnect()
                return String(describing: error)
            }
        }
        guard Self.wait(finished, seconds: 3) else { throw NSError(domain: "ServiceListEndToEndTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Private Core shutdown request timed out"]) }
        let shutdownError = await shutdownTask.value
        guard Self.wait(serverExited, seconds: 3) else { throw NSError(domain: "ServiceListEndToEndTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Private Core did not exit after shutdown"]) }
        do {
            try await serverTask.value
            return shutdownError
        } catch {
            return shutdownError ?? String(describing: error)
        }
    }

    private static func wait(_ semaphore: DispatchSemaphore, seconds: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}
