import Foundation
import XCTest
import VaelenTestSupport
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

final class LogsIPCIntegrationTests: XCTestCase {
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
        let serverTask = Task.detached { try server.run() }
        do {
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: paths.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))
            let stateBefore = try snapshot(layout.stateDirectoryURL)
            let logsBefore = try snapshot(layout.logsDirectoryURL)

            let list = try runVal(valPath, arguments: ["logs", "--json"], root: root)
            XCTAssertEqual(list.status, 0, list.output)
            XCTAssertTrue(list.output.contains("\"id\":\"mysql\""), list.output)
            XCTAssertTrue(list.output.contains("\"status\":\"available\""), list.output)
            let humanList = try runVal(valPath, arguments: ["logs"], root: root)
            XCTAssertEqual(humanList.status, 0, humanList.output)
            XCTAssertTrue(humanList.output.contains("mysql\tMySQL\tavailable"), humanList.output)
            XCTAssertEqual(humanList.error, "")
            let defaultTail = try runVal(valPath, arguments: ["logs", "mailpit"], root: root)
            XCTAssertEqual(defaultTail.status, 0, defaultTail.output)
            XCTAssertEqual(defaultTail.output, "mailpit-one\n")
            XCTAssertEqual(defaultTail.error, "")
            let humanTail = try runVal(valPath, arguments: ["logs", "mysql", "--lines", "2"], root: root)
            XCTAssertEqual(humanTail.status, 0, humanTail.output)
            XCTAssertEqual(humanTail.output, "mysql-two\nmysql-three\n")
            XCTAssertEqual(humanTail.error, "[truncated] Returned 2 lines within the bounded log tail.\n")
            let tail = try runVal(valPath, arguments: ["logs", "mysql", "--lines", "2", "--json"], root: root)
            XCTAssertEqual(tail.status, 0, tail.output)
            XCTAssertTrue(tail.output.contains("mysql-two\\nmysql-three"), tail.output)
            XCTAssertEqual(tail.error, "")
            XCTAssertEqual(try snapshot(layout.logsDirectoryURL), logsBefore)
            XCTAssertEqual(try snapshot(layout.stateDirectoryURL), stateBefore)

            let shutdown = makeShutdownClient(paths: paths)
            try await shutdown.connect()
            _ = try await shutdown.shutdown()
            await shutdown.disconnect()
            _ = try await serverTask.value
        } catch {
            let shutdown = makeShutdownClient(paths: paths)
            try? await shutdown.connect()
            _ = try? await shutdown.shutdown()
            await shutdown.disconnect()
            _ = try? await serverTask.value
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try FileManager.default.removeItem(at: root)
    }

    private func runVal(_ path: String, arguments: [String], root: URL) throws -> (status: Int32, output: String, error: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = root.path
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe(); let error = Pipe(); process.standardOutput = output; process.standardError = error
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); let errorBytes = error.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self), String(decoding: errorBytes, as: UTF8.self))
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

private extension FileManager {
    func subcontents(at url: URL) throws -> [URL] {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { value in
            guard let item = value as? URL, (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return nil }
            return item
        }
    }
}
