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
        XCTAssertEqual(SQLiteStateStore.schemaVersion, 8)
        let parentID = ProjectID()
        let nestedID = ProjectID()
        let siblingID = ProjectID()
        let unrelatedID = ProjectID()
        let node = NodePackageManager(layout: layout, catalog: [release]) { _, destination in
            try FileManager.default.copyItem(at: archive, to: destination)
        }
        let paths = CoreEndpointPaths(layout: layout)
        var generation: PrivateCoreGeneration? = nil
        do {
            let projectBefore = try snapshot([parent, nested, sibling, unrelated])
            do {
                let first = try startCoreGeneration(layout: layout, paths: paths, node: node)
                generation = first
                try first.projects.upsert(.init(id: parentID, name: "parent", canonicalPath: parent.path))
                try first.projects.upsert(.init(id: nestedID, name: "nested", canonicalPath: nested.path))
                try first.projects.upsert(.init(id: siblingID, name: "sibling", canonicalPath: sibling.path))
                try first.projects.upsert(.init(id: unrelatedID, name: "unrelated", canonicalPath: unrelated.path))
                try first.projects.setPHPOverride("8.4.23", for: parentID)
                try first.projects.setNodeOverride(try NodeVersion("22.18.0"), for: unrelatedID)
                try await waitForSocket(paths.socketPath)
                let install = try runVal(valPath, ["node", "install", "24.22.1"], cwd: parent, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
                XCTAssertEqual(install.status, 0, install.output + install.error)
                let packageURL = node.packagesURL.appendingPathComponent("24.22.1")
                let packageContents = try snapshot([packageURL])
                let repeatedInstall = try runVal(valPath, ["node", "install", "24.22.1"], cwd: parent, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
                XCTAssertEqual(repeatedInstall.status, 0, repeatedInstall.output + repeatedInstall.error)
                XCTAssertEqual(try snapshot([packageURL]), packageContents, "Repeated install must preserve the validated package contents.")

                let isolate = try runVal(valPath, ["node", "isolate", "24.22.1", parent.path], cwd: parent, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
                XCTAssertEqual(isolate.status, 0, isolate.output + isolate.error)
                let recordsAfterIsolate = try first.projects.nodeRecords()
                XCTAssertEqual(recordsAfterIsolate.first { $0.id == parentID }?.pin?.description, "24.22.1")
                XCTAssertNil(recordsAfterIsolate.first { $0.id == nestedID }?.pin)
                XCTAssertNil(recordsAfterIsolate.first { $0.id == siblingID }?.pin)
                XCTAssertEqual(recordsAfterIsolate.first { $0.id == unrelatedID }?.pin?.description, "22.18.0")
                try await first.stop()
                generation = nil
            }
            let second = try startCoreGeneration(layout: layout, paths: paths, node: node)
            generation = second
            try await waitForSocket(paths.socketPath)

            let restartedState = try runVal(valPath, ["node", "isolated", "--json"], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(restartedState.status, 0, restartedState.output + restartedState.error)
            let decodedState = try JSONDecoder().decode(NodeCommandResult.self, from: Data(restartedState.output.utf8)).nodeResult
            XCTAssertEqual(decodedState.selections.filter { $0.projectID == parentID }.map { $0.pinnedVersion?.description }, ["24.22.1"])
            XCTAssertEqual(decodedState.selections.filter { $0.projectID == unrelatedID }.map { $0.pinnedVersion?.description }, ["22.18.0"])

            let unregisteredChild = parent.appendingPathComponent("unregistered-child", isDirectory: true)
            try FileManager.default.createDirectory(at: unregisteredChild, withIntermediateDirectories: true)
            for cwd in [parent, unregisteredChild] {
                let nodeVersion = try runVal(valPath, ["node", "exec", "--", "node", "--version"], cwd: cwd, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
                XCTAssertEqual(nodeVersion.status, 0, nodeVersion.error)
                XCTAssertEqual(nodeVersion.output, "v24.22.1\n")
                let npmVersion = try runVal(valPath, ["node", "exec", "--", "npm", "--version"], cwd: cwd, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
                XCTAssertEqual(npmVersion.status, 0, npmVersion.error)
                XCTAssertEqual(npmVersion.output, "11.19.1\n")
            }
            for cwd in [nested, sibling] {
                let nodeVersion = try runVal(valPath, ["node", "exec", "--", "node", "--version"], cwd: cwd, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
                XCTAssertEqual(nodeVersion.status, 0, nodeVersion.error)
                XCTAssertEqual(nodeVersion.output, "v99.0.0\n")
                let npmVersion = try runVal(valPath, ["node", "exec", "--", "npm", "--version"], cwd: cwd, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
                XCTAssertEqual(npmVersion.status, 0, npmVersion.error)
                XCTAssertEqual(npmVersion.output, "v99.0.0\n")
            }

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
            let listing = try runVal(valPath, ["node", "list", "--json"], cwd: parent, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(listing.status, 0, listing.output + listing.error)
            XCTAssertTrue(listing.output.contains("24.22.1"), listing.output)
            XCTAssertTrue(listing.output.contains(parentID.description), listing.output)

            let clearExisting = try runVal(valPath, ["node", "use-default", parentID.description], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(clearExisting.status, 0, clearExisting.output + clearExisting.error)
            for cwd in [parent, unregisteredChild] {
                let nodeVersion = try runVal(valPath, ["node", "exec", "--", "node", "--version"], cwd: cwd, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
                XCTAssertEqual(nodeVersion.status, 0, nodeVersion.error)
                XCTAssertEqual(nodeVersion.output, "v99.0.0\n")
                let npmVersion = try runVal(valPath, ["node", "exec", "--", "npm", "--version"], cwd: cwd, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
                XCTAssertEqual(npmVersion.status, 0, npmVersion.error)
                XCTAssertEqual(npmVersion.output, "v99.0.0\n")
            }
            let afterClear = try runVal(valPath, ["node", "isolated", "--json"], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(afterClear.status, 0, afterClear.output + afterClear.error)
            let clearedState = try JSONDecoder().decode(NodeCommandResult.self, from: Data(afterClear.output.utf8)).nodeResult
            XCTAssertFalse(clearedState.selections.contains { $0.projectID == parentID })
            XCTAssertEqual(clearedState.selections.filter { $0.projectID == unrelatedID }.map { $0.pinnedVersion?.description }, ["22.18.0"])

            let repin = try runVal(valPath, ["node", "isolate", "24.22.1", parent.path], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(repin.status, 0, repin.output + repin.error)
            let repinnedState = try runVal(valPath, ["node", "isolated", "--json"], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(repinnedState.status, 0, repinnedState.output + repinnedState.error)
            let repinnedDecoded = try JSONDecoder().decode(NodeCommandResult.self, from: Data(repinnedState.output.utf8)).nodeResult
            XCTAssertEqual(repinnedDecoded.selections.filter { $0.projectID == parentID }.map { $0.pinnedVersion?.description }, ["24.22.1"])

            XCTAssertEqual(try snapshot([parent, nested, sibling, unrelated]), projectBefore)
            try FileManager.default.removeItem(at: parent)
            let missingListing = try runVal(valPath, ["node", "isolated", "--json"], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(missingListing.status, 0, missingListing.output + missingListing.error)
            XCTAssertTrue(missingListing.output.contains(parentID.description), missingListing.output)
            XCTAssertTrue(missingListing.output.contains("missing"), missingListing.output)
            let missingState = try JSONDecoder().decode(NodeCommandResult.self, from: Data(missingListing.output.utf8)).nodeResult
            XCTAssertEqual(missingState.selections.filter { $0.projectID == parentID }.map { $0.pinnedVersion?.description }, ["24.22.1"])
            let clear = try runVal(valPath, ["node", "use-default", parentID.description], cwd: sibling, root: root, path: fakeBin.path, preserveRoot: &preserveRoot)
            XCTAssertEqual(clear.status, 0, clear.output + clear.error)
            XCTAssertNil(try second.projects.nodeRecords().first { $0.id == parentID }?.pin)
            XCTAssertNil(try second.projects.nodeRecords().first { $0.id == siblingID }?.pin)
            XCTAssertEqual(try second.projects.nodeRecords().first { $0.id == unrelatedID }?.pin?.description, "22.18.0")
            XCTAssertEqual(try second.projects.phpOverride(for: parentID), "8.4.23")

            try await second.stop()
            generation = nil
        } catch {
            let failure = error
            if let activeGeneration = generation {
                do { try await activeGeneration.stop(); generation = nil }
                catch {
                    let terminationConfirmed = activeGeneration.serverExitConfirmed
                    if !terminationConfirmed { preserveRoot = true }
                    let fixtureDisposition = preserveRoot
                        ? "Fixture preserved at \(root.path) because \(terminationConfirmed ? "a CLI child" : "the Private Core server") exit was not confirmed."
                        : "Fixture will be removed because process exit was confirmed."
                    XCTFail("Private Core shutdown failed. Termination confirmed: \(terminationConfirmed). \(fixtureDisposition) Shutdown error: \(error). Original error: \(failure)")
                }
            }
            throw failure
        }
    }

    private func startCoreGeneration(layout: VaelenFilesystemLayout, paths: CoreEndpointPaths, node: NodePackageManager) throws -> PrivateCoreGeneration {
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let projects = ProjectRepository(store: store)
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: ProjectRegistry(store: store), node: node, serviceIntents: .init(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json")))
        let server = DaemonServer(paths: paths, dispatcher: dispatcher)
        let exited = DispatchSemaphore(value: 0)
        let task = Task.detached { defer { exited.signal() }; try server.run() }
        return PrivateCoreGeneration(projects: projects, paths: paths, task: task, exited: exited)
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

    fileprivate static func wait(_ semaphore: DispatchSemaphore, seconds: TimeInterval) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }
}

private final class PrivateCoreGeneration {
    let projects: ProjectRepository
    private let paths: CoreEndpointPaths
    private let task: Task<Void, Error>
    private let exited: DispatchSemaphore
    private var shutdownRequest: (task: Task<Void, Error>, finished: DispatchSemaphore)?
    private(set) var serverExitConfirmed = false

    init(projects: ProjectRepository, paths: CoreEndpointPaths, task: Task<Void, Error>, exited: DispatchSemaphore) {
        self.projects = projects
        self.paths = paths
        self.task = task
        self.exited = exited
    }

    func stop() async throws {
        if shutdownRequest == nil {
            let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "node-cli-test-stop", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
            let finished = DispatchSemaphore(value: 0)
            let task = Task.detached { () throws -> Void in
                defer { finished.signal() }
                do { try await client.connect(); _ = try await client.shutdown(); await client.disconnect() }
                catch { await client.disconnect(); throw error }
            }
            shutdownRequest = (task, finished)
        }
        guard let shutdownRequest else { throw NSError(domain: "NodeCLIIntegrationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Private Core shutdown request was not started."]) }
        guard NodeCLIIntegrationTests.wait(shutdownRequest.finished, seconds: 3) else { throw NSError(domain: "NodeCLIIntegrationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Private Core shutdown request timed out."]) }
        self.shutdownRequest = nil
        try await shutdownRequest.task.value
        if !serverExitConfirmed {
            guard NodeCLIIntegrationTests.wait(exited, seconds: 3) else { throw NSError(domain: "NodeCLIIntegrationTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Private Core exit was not confirmed."]) }
            serverExitConfirmed = true
        }
        _ = try await task.value
    }
}
