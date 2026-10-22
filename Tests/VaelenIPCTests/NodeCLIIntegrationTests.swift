import Darwin
import Foundation
import XCTest
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport
@testable import VaelenCLI

final class NodeCLIIntegrationTests: XCTestCase {
    func testActualValUsesPrivateCoreForNodeSelectionLifecycle() async throws {
        guard let valPath = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"],
              FileManager.default.isExecutableFile(atPath: valPath) else {
            throw XCTSkip("Set VAELEN_VAL_EXECUTABLE to the built val executable.")
        }
        guard let archiveDirectory = ProcessInfo.processInfo.environment["VAELEN_NODE_ARCHIVE_DIRECTORY"] else {
            throw XCTSkip("Set VAELEN_NODE_ARCHIVE_DIRECTORY to a directory containing the reviewed Node 24.22.1 macOS arm64 archive.")
        }
        let release = try XCTUnwrap(NodeRelease.reviewed.first { $0.version.description == "24.22.1" && $0.architecture == NodePackageManager.hostArchitecture })
        let archive = URL(fileURLWithPath: archiveDirectory).appendingPathComponent(release.archiveName)
        guard FileManager.default.isReadableFile(atPath: archive.path) else {
            throw XCTSkip("Reviewed Node archive prerequisite is absent: \(archive.path)")
        }

        let root = URL(fileURLWithPath: "/private/tmp/vn-\(UUID().uuidString.prefix(10))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var preserveRoot = false
        defer { if !preserveRoot { try? FileManager.default.removeItem(at: root) } }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let nested = parent.appendingPathComponent("nested", isDirectory: true)
        let sibling = root.appendingPathComponent("sibling", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        for project in [parent, nested, sibling, unrelated] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("fixture-\(project.lastPathComponent)\n".utf8).write(to: project.appendingPathComponent("content.txt"))
        }
        let fakeBin = root.appendingPathComponent("invocation-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        for name in ["node", "npm"] {
            let executable = fakeBin.appendingPathComponent(name)
            try Data("#!/bin/sh\nprintf 'v99.0.0\\n'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        XCTAssertEqual(SQLiteStateStore.schemaVersion, 8)
        let projects = ProjectRepository(store: store)
        let parentID = ProjectID()
        let nestedID = ProjectID()
        let siblingID = ProjectID()
        let unrelatedID = ProjectID()
        try projects.upsert(.init(id: parentID, name: "parent", canonicalPath: parent.path))
        try projects.upsert(.init(id: nestedID, name: "nested", canonicalPath: nested.path))
        try projects.upsert(.init(id: siblingID, name: "sibling", canonicalPath: sibling.path))
        try projects.upsert(.init(id: unrelatedID, name: "unrelated", canonicalPath: unrelated.path))
        try projects.setPHPOverride("8.4.23", for: parentID)
        try projects.setNodeOverride(try NodeVersion("22.18.0"), for: unrelatedID)
        let node = NodePackageManager(layout: layout, catalog: [release]) { _, destination in
            try FileManager.default.copyItem(at: archive, to: destination)
        }
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: ProjectRegistry(store: store), node: node, serviceIntents: .init(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json")))
        let paths = CoreEndpointPaths(layout: layout)
        let server = DaemonServer(paths: paths, dispatcher: dispatcher)
        let serverExited = DispatchSemaphore(value: 0)
        let serverTask = Task.detached { defer { serverExited.signal() }; try server.run() }
        var serverStopped = false
        do {
            try await waitForSocket(paths.socketPath)
            let projectBefore = try snapshot([parent, nested, sibling, unrelated])
            let install = try runVal(valPath, ["node", "install", "24.22.1"], cwd: parent, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(install.status, 0, install.output + install.error)
            let packageURL = node.packagesURL.appendingPathComponent("24.22.1")
            let packageContents = try snapshot([packageURL])
            let repeatedInstall = try runVal(valPath, ["node", "install", "24.22.1"], cwd: parent, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(repeatedInstall.status, 0, repeatedInstall.output + repeatedInstall.error)
            XCTAssertEqual(try snapshot([packageURL]), packageContents, "Repeated install must preserve the validated package contents.")

            let isolate = try runVal(valPath, ["node", "isolate", "24.22.1", parent.path], cwd: parent, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(isolate.status, 0, isolate.output + isolate.error)
            let recordsAfterIsolate = try projects.nodeRecords()
            XCTAssertEqual(recordsAfterIsolate.first { $0.id == parentID }?.pin?.description, "24.22.1")
            XCTAssertNil(recordsAfterIsolate.first { $0.id == nestedID }?.pin)
            XCTAssertNil(recordsAfterIsolate.first { $0.id == siblingID }?.pin)
            XCTAssertEqual(recordsAfterIsolate.first { $0.id == unrelatedID }?.pin?.description, "22.18.0")
            XCTAssertEqual(try runVal(valPath, ["node", "exec", "--", "node", "--version"], cwd: parent, root: root, path: fakeBin.path, preserveRoot: &preserveRoot).output, "v24.22.1\n")
            XCTAssertEqual(try runVal(valPath, ["node", "exec", "--", "node", "--version"], cwd: nested, root: root, path: fakeBin.path, preserveRoot: &preserveRoot).output, "v99.0.0\n")
            XCTAssertEqual(try runVal(valPath, ["node", "exec", "--", "node", "--version"], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot).output, "v99.0.0\n")

            let shellHome = root.appendingPathComponent("shell-home", isDirectory: true)
            let resolver = shellHome.appendingPathComponent("Library/Application Support/Vaelen/bin/vaelen-php-resolver")
            try FileManager.default.createDirectory(at: resolver.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: valPath), to: resolver)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resolver.path)
            let pinnedShell = try runShell(home: shellHome, support: layout.rootURL, cwd: parent, path: fakeBin.path)
            XCTAssertEqual(pinnedShell.status, 0, pinnedShell.error)
            XCTAssertEqual(pinnedShell.output, "v24.22.1\n11.19.1\n")
            let defaultShell = try runShell(home: shellHome, support: layout.rootURL, cwd: sibling, path: fakeBin.path)
            XCTAssertEqual(defaultShell.status, 0, defaultShell.error)
            XCTAssertEqual(defaultShell.output, "v99.0.0\nv99.0.0\n")

            let isolated = try runVal(valPath, ["node", "isolated", "--json"], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(isolated.status, 0, isolated.output + isolated.error)
            XCTAssertTrue(isolated.output.contains(parentID.description), isolated.output)
            XCTAssertTrue(isolated.output.contains("24.22.1"), isolated.output)
            XCTAssertTrue(isolated.output.contains(unrelatedID.description), isolated.output)
            let listing = try runVal(valPath, ["node", "list", "--json"], cwd: parent, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(listing.status, 0, listing.output + listing.error)
            XCTAssertTrue(listing.output.contains("24.22.1"), listing.output)
            XCTAssertTrue(listing.output.contains(parentID.description), listing.output)

            XCTAssertEqual(try snapshot([parent, nested, sibling, unrelated]), projectBefore)
            try FileManager.default.removeItem(at: parent)
            let missingListing = try runVal(valPath, ["node", "isolated", "--json"], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(missingListing.status, 0, missingListing.output + missingListing.error)
            XCTAssertTrue(missingListing.output.contains(parentID.description), missingListing.output)
            XCTAssertTrue(missingListing.output.contains("missing"), missingListing.output)
            let clear = try runVal(valPath, ["node", "use-default", parentID.description], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(clear.status, 0, clear.output + clear.error)
            XCTAssertNil(try projects.nodeRecords().first { $0.id == parentID }?.pin)
            XCTAssertNil(try projects.nodeRecords().first { $0.id == siblingID }?.pin)
            XCTAssertEqual(try projects.nodeRecords().first { $0.id == unrelatedID }?.pin?.description, "22.18.0")
            XCTAssertEqual(try projects.phpOverride(for: parentID), "8.4.23")

            try await stopServer(paths: paths, serverTask: serverTask, serverExited: serverExited)
            serverStopped = true
        } catch {
            let failure = error
            if !serverStopped {
                do { try await stopServer(paths: paths, serverTask: serverTask, serverExited: serverExited); serverStopped = true }
                catch { preserveRoot = true; XCTFail("Private Core shutdown could not be confirmed. Fixture preserved at \(root.path). Shutdown error: \(error). Original error: \(failure)") }
            }
            throw failure
        }
    }

    private func runVal(_ executable: String, _ arguments: [String], cwd: URL, root: URL, path: String, preserveRoot: inout Bool) throws -> (status: Int32, output: String, error: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = root.appendingPathComponent("support").path
        environment["PATH"] = path + ":/usr/bin:/bin"
        environment["NO_COLOR"] = "1"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        let outURL = root.appendingPathComponent("child-\(UUID().uuidString).out")
        let errURL = root.appendingPathComponent("child-\(UUID().uuidString).err")
        _ = FileManager.default.createFile(atPath: outURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var didExit = Self.wait(exited, seconds: 15)
        if !didExit { if process.isRunning { process.terminate() }; didExit = Self.wait(exited, seconds: 1) }
        if !didExit { if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }; didExit = Self.wait(exited, seconds: 2) }
        guard didExit else { preserveRoot = true; throw NSError(domain: "NodeCLIIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "CLI child exit unconfirmed; fixture preserved at \(root.path)"]) }
        process.waitUntilExit()
        try out.close(); try err.close()
        let result = (process.terminationStatus, String(decoding: try Data(contentsOf: outURL), as: UTF8.self), String(decoding: try Data(contentsOf: errURL), as: UTF8.self))
        try FileManager.default.removeItem(at: outURL); try FileManager.default.removeItem(at: errURL)
        return result
    }

    private func runShell(home: URL, support: URL, cwd: URL, path: String) throws -> (status: Int32, output: String, error: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = support.path
        environment["PATH"] = path + ":/usr/bin:/bin"
        environment["NO_COLOR"] = "1"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", PHPShellIntegration.shellBlock + "\nnode --version\nnpm --version\n"]
        process.currentDirectoryURL = cwd
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func waitForSocket(_ path: String) async throws {
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "NodeCLIIntegrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Private Core socket did not appear."])
    }

    private func stopServer(paths: CoreEndpointPaths, serverTask: Task<Void, Error>, serverExited: DispatchSemaphore) async throws {
        let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "node-cli-test-stop", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
        let finished = DispatchSemaphore(value: 0)
        let shutdown = Task.detached { defer { finished.signal() }; do { try await client.connect(); _ = try await client.shutdown(); await client.disconnect() } catch { await client.disconnect() } }
        guard Self.wait(finished, seconds: 3) else { throw NSError(domain: "NodeCLIIntegrationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Private Core shutdown request timed out."]) }
        await shutdown.value
        guard Self.wait(serverExited, seconds: 3) else { throw NSError(domain: "NodeCLIIntegrationTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Private Core exit was not confirmed."]) }
        _ = try await serverTask.value
    }

    private func snapshot(_ roots: [URL]) throws -> [String: Data] {
        var result = [String: Data]()
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])!
            for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                result[url.path] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private static func wait(_ semaphore: DispatchSemaphore, seconds: TimeInterval) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }
}
