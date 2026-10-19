import Foundation
import Darwin
import XCTest
import VaelenTestSupport
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

final class LogsIPCIntegrationTests: XCTestCase {
    func testCLIChildTimeoutLeavesUnrelatedProcessRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logs-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var preserveRoot = false
        defer { if !preserveRoot { try? FileManager.default.removeItem(at: root) } }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer {
            if unrelated.isRunning {
                unrelated.terminate()
                unrelated.waitUntilExit()
            }
        }

        XCTAssertEqual(kill(unrelated.processIdentifier, 0), 0)
        XCTAssertThrowsError(try runOwnedCLIChild(
            executable: "/bin/sh",
            arguments: ["-c", "exec /bin/sleep 30"],
            timeout: .milliseconds(100),
            terminationGrace: .milliseconds(500),
            outputDirectory: root
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("exited with status"), error.localizedDescription)
            if let childError = error as? OwnedCLIChildError, case .exitUnconfirmed = childError { preserveRoot = true }
        }
        XCTAssertEqual(kill(unrelated.processIdentifier, 0), 0, "timeout handling must not terminate an unrelated process")
    }

    func testActualValChildListsAndTailsOverPrivateCoreSocketWithoutMutation() async throws {
        guard let valPath = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"] else {
            throw XCTSkip("Set VAELEN_VAL_EXECUTABLE to the actual built val binary by running Scripts/tests/val-logs-ipc-test.sh.")
        }
        let root = URL(fileURLWithPath: "/private/tmp/vl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
        for directory in [layout.caddyLogsDirectoryURL, layout.mysqlLogsDirectoryURL, layout.mailpitLogsDirectoryURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("caddy-one\ncaddy-two\n".utf8).write(to: layout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log"))
        try Data("mysql-one\nmysql-two\nmysql-three\n".utf8).write(to: layout.mysqlLogsDirectoryURL.appendingPathComponent("default.log"))
        try Data("mailpit-one\n".utf8).write(to: layout.mailpitLogsDirectoryURL.appendingPathComponent("default.log"))
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let registry = ProjectRegistry(store: store)
        let intents = ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json"))
        let catalog = CoreLogCatalog(layout: layout)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, serviceIntents: intents, logs: catalog)
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
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: paths.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))
            let stateBefore = try snapshot(layout.stateDirectoryURL)
            let logsBefore = try snapshot(layout.logsDirectoryURL)

            let list = try runVal(valPath, arguments: ["logs", "--json"], root: root, preserveRoot: &preserveRoot)
            XCTAssertEqual(list.status, 0, list.output)
            XCTAssertTrue(list.output.contains("\"id\":\"mysql\""), list.output)
            XCTAssertTrue(list.output.contains("\"status\":\"available\""), list.output)
            let humanList = try runVal(valPath, arguments: ["logs"], root: root, preserveRoot: &preserveRoot)
            XCTAssertEqual(humanList.status, 0, humanList.output)
            XCTAssertTrue(humanList.output.contains("mysql\tMySQL\tavailable"), humanList.output)
            XCTAssertEqual(humanList.error, "")
            let defaultTail = try runVal(valPath, arguments: ["logs", "mailpit"], root: root, preserveRoot: &preserveRoot)
            XCTAssertEqual(defaultTail.status, 0, defaultTail.output)
            XCTAssertEqual(defaultTail.output, "mailpit-one\n")
            XCTAssertEqual(defaultTail.error, "")
            let humanTail = try runVal(valPath, arguments: ["logs", "mysql", "--lines", "2"], root: root, preserveRoot: &preserveRoot)
            XCTAssertEqual(humanTail.status, 0, humanTail.output)
            XCTAssertEqual(humanTail.output, "mysql-two\nmysql-three\n")
            XCTAssertEqual(humanTail.error, "[truncated] Returned 2 lines within the bounded log tail.\n")
            let tail = try runVal(valPath, arguments: ["logs", "mysql", "--lines", "2", "--json"], root: root, preserveRoot: &preserveRoot)
            XCTAssertEqual(tail.status, 0, tail.output)
            XCTAssertTrue(tail.output.contains("mysql-two\\nmysql-three"), tail.output)
            XCTAssertEqual(tail.error, "")
            XCTAssertEqual(try snapshot(layout.logsDirectoryURL), logsBefore)
            XCTAssertEqual(try snapshot(layout.stateDirectoryURL), stateBefore)

            let shutdownError = try await stopServer(paths: paths, serverTask: serverTask, serverExited: serverExited)
            serverStopped = true
            if let shutdownError { throw NSError(domain: "LogsIPCIntegrationTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Private Core exited with a shutdown error: \(shutdownError)"]) }
        } catch {
            let originalError = error
            if error is FixtureShutdownUnconfirmed {
                preserveRoot = true
                throw NSError(domain: "LogsIPCIntegrationTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Private Core shutdown could not be confirmed; fixture preserved at \(root.path). Original failure: \(originalError)"])
            }
            if !serverStopped {
                do {
                    _ = try await stopServer(paths: paths, serverTask: serverTask, serverExited: serverExited)
                    serverStopped = true
                } catch {
                    preserveRoot = true
                    throw NSError(domain: "LogsIPCIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not confirm private Core shutdown; fixture preserved at \(root.path). Original failure: \(originalError). Shutdown failure: \(error)"])
                }
            }
            if !preserveRoot { try? FileManager.default.removeItem(at: root) }
            throw originalError
        }
        if !preserveRoot { try FileManager.default.removeItem(at: root) }
    }

    private func runVal(_ path: String, arguments: [String], root: URL, preserveRoot: inout Bool) throws -> (status: Int32, output: String, error: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = root.path
        environment["NO_COLOR"] = "1"
        do {
            let result = try runOwnedCLIChild(executable: path, arguments: arguments, environment: environment, timeout: .seconds(10), terminationGrace: .seconds(1), outputDirectory: root)
            return (result.status, result.output, result.error)
        } catch let error as OwnedCLIChildError {
            if case .exitUnconfirmed = error { preserveRoot = true }
            throw error
        }
    }

    private func runOwnedCLIChild(executable: String, arguments: [String], environment: [String: String]? = nil, timeout: Duration, terminationGrace: Duration, outputDirectory: URL) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let outputURL = outputDirectory.appendingPathComponent("logs-child-\(UUID().uuidString).stdout")
        let errorURL = outputDirectory.appendingPathComponent("logs-child-\(UUID().uuidString).stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil), FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw NSError(domain: "LogsIPCIntegrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create private CLI output files in \(outputDirectory.path)"])
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        process.standardOutput = output
        process.standardError = error
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var didExit = Self.wait(exited, duration: timeout)
        let timedOut = !didExit
        if !didExit {
            if process.isRunning { process.terminate() }
            didExit = Self.wait(exited, duration: terminationGrace)
        }
        if !didExit {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            didExit = Self.wait(exited, duration: .seconds(2))
        }
        guard didExit else {
            try? output.close()
            try? error.close()
            throw OwnedCLIChildError.exitUnconfirmed(pid: process.processIdentifier, output: outputURL, error: errorURL)
        }
        process.waitUntilExit()
        try output.close()
        try error.close()
        let stdout = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        try FileManager.default.removeItem(at: outputURL)
        try FileManager.default.removeItem(at: errorURL)
        guard !timedOut else { throw OwnedCLIChildError.timedOut(pid: process.processIdentifier, status: process.terminationStatus) }
        return (process.terminationStatus, stdout, stderr)
    }

    private func stopServer(paths: CoreEndpointPaths, serverTask: Task<Void, Error>, serverExited: DispatchSemaphore) async throws -> String? {
        let client = makeShutdownClient(paths: paths)
        let shutdownFinished = DispatchSemaphore(value: 0)
        let shutdownTask = Task.detached { () -> String? in
            defer { shutdownFinished.signal() }
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
        guard Self.wait(shutdownFinished, duration: .seconds(3)) else {
            throw FixtureShutdownUnconfirmed.requestTimedOut
        }
        let shutdownError = await shutdownTask.value
        guard Self.wait(serverExited, duration: .seconds(3)) else {
            throw FixtureShutdownUnconfirmed.serverExitUnconfirmed(shutdownError)
        }
        do {
            _ = try await serverTask.value
            return shutdownError
        } catch {
            return shutdownError ?? String(describing: error)
        }
    }

    private static func wait(_ semaphore: DispatchSemaphore, duration: Duration) -> Bool {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return semaphore.wait(timeout: .now() + seconds) == .success
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let urls = try FileManager.default.subcontents(at: directory)
        return Dictionary(uniqueKeysWithValues: urls.map { ($0.path, (try? Data(contentsOf: $0)) ?? Data()) })
    }

    private func makeShutdownClient(paths: CoreEndpointPaths) -> VaelenCoreClient {
        VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "logs-test-stop", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
    }
}

private enum OwnedCLIChildError: LocalizedError {
    case timedOut(pid: Int32, status: Int32)
    case exitUnconfirmed(pid: Int32, output: URL, error: URL)

    var errorDescription: String? {
        switch self {
        case .timedOut(let pid, let status): "val child \(pid) timed out and exited with status \(status)"
        case .exitUnconfirmed(let pid, let output, let error): "val child \(pid) timed out and exit could not be confirmed; stdout preserved at \(output.path), stderr preserved at \(error.path)"
        }
    }
}

private enum FixtureShutdownUnconfirmed: LocalizedError {
    case requestTimedOut
    case serverExitUnconfirmed(String?)

    var errorDescription: String? {
        switch self {
        case .requestTimedOut: "private Core shutdown request timed out"
        case .serverExitUnconfirmed(let detail): "private Core did not exit after shutdown\(detail.map { ": \($0)" } ?? "")"
        }
    }
}

private extension FileManager {
    func subcontents(at url: URL) throws -> [URL] {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { value in
            guard let item = value as? URL, (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return nil }
            return item
        }
    }
}
