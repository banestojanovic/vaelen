import Foundation
import Darwin
import XCTest
@testable import VaelenCore
@testable import VaelenCLI

final class NodeCommandTests: XCTestCase {
    func testParserRequiresExactVersionAndExplicitExecSeparator() throws {
        guard case .nodeExec(let arguments) = try VaelenCLIMain.parse(["node", "exec", "--", "node", "", "--version"]) else { return XCTFail("Expected exec") }
        XCTAssertEqual(arguments, ["node", "", "--version"])
        for args in [["node", "exec", "node"], ["node", "install", "latest"], ["node", "isolate", "24"], ["node", "use-default", "a", "b"]] {
            XCTAssertThrowsError(try VaelenCLIMain.parse(args))
        }
    }

    func testInvocationPATHIsPreservedWithoutCreatingSupportRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plan = try NodeExecCommand.plan(arguments: ["node", "", "a b"], workingDirectory: "/tmp", environment: ["PATH": "relative::/system"], layout: .init(rootURL: root))
        XCTAssertEqual(plan.arguments, ["node", "", "a b"])
        XCTAssertEqual(plan.path, "relative::/system")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testManagedEntrypointModeTamperingNeverExecutesInvocationPATHSentinel() throws {
        guard let val = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"],
              let archiveDirectory = ProcessInfo.processInfo.environment["VAELEN_NODE_ARCHIVE_DIRECTORY"] else {
            throw XCTSkip("Set VAELEN_VAL_EXECUTABLE and VAELEN_NODE_ARCHIVE_DIRECTORY for the managed CLI regression.")
        }
        guard NodePackageManager.hostArchitecture == "arm64" else { throw XCTSkip("The official catalog supports macOS arm64.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("node-mode-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let bin = root.appendingPathComponent("invocation-bin")
        let sentinel = root.appendingPathComponent("sentinel")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"))
        let release = NodeRelease.reviewed[0]
        let manager = NodePackageManager(layout: layout, catalog: NodeRelease.reviewed) { release, destination in
            try FileManager.default.copyItem(at: URL(fileURLWithPath: archiveDirectory).appendingPathComponent(release.archiveName), to: destination)
        }
        _ = try manager.install(release.version)
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let repository = ProjectRepository(store: store)
        let id = ProjectID()
        try repository.upsert(.init(id: id, name: "project", canonicalPath: project.path, customName: nil))
        try repository.setNodeOverride(release.version, for: id)
        for command in ["npm", "npx", "corepack"] {
            let fallback = bin.appendingPathComponent(command)
            try Data("#!/bin/sh\n: > '\(sentinel.path)'\n".utf8).write(to: fallback)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback.path)
            let entrypoint = manager.packagesURL.appendingPathComponent(release.version.description + "/bin/" + command).resolvingSymlinksInPath()
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entrypoint.path)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: val)
            child.arguments = ["node", "exec", "--", command, "--version"]
            child.currentDirectoryURL = project
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = bin.path
            environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
            environment["VAELEN_TEST_SUPPORT_ROOT"] = layout.rootURL.path
            child.environment = environment
            let errors = Pipe()
            child.standardOutput = FileHandle.nullDevice
            child.standardError = errors
            try child.run()
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 1, "\(command): \(detail)")
            XCTAssertTrue(detail.contains("unavailable"), "\(command): \(detail)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path), command)
            try? FileManager.default.removeItem(at: sentinel)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entrypoint.path)
        }
    }

    func testManagedSupportRootWithColonNeverFallsBackToInvocationPATH() throws {
        guard let val = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"],
              let archiveDirectory = ProcessInfo.processInfo.environment["VAELEN_NODE_ARCHIVE_DIRECTORY"] else {
            throw XCTSkip("Set VAELEN_VAL_EXECUTABLE and VAELEN_NODE_ARCHIVE_DIRECTORY for the managed CLI regression.")
        }
        guard NodePackageManager.hostArchitecture == "arm64" else { throw XCTSkip("The official catalog supports macOS arm64.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("node:colon-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("node-invocation-bin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bin) }
        let sentinel = root.appendingPathComponent("path-sentinel")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fallback = bin.appendingPathComponent("node")
        try Data("#!/bin/sh\nprintf 'v99.0.0\\n'\n: > '\(sentinel.path)'\n".utf8).write(to: fallback)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback.path)

        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"))
        let release = try XCTUnwrap(NodeRelease.reviewed.first { $0.version.description == "24.22.1" && $0.architecture == NodePackageManager.hostArchitecture })
        let manager = NodePackageManager(layout: layout, catalog: [release]) { release, destination in
            try FileManager.default.copyItem(at: URL(fileURLWithPath: archiveDirectory).appendingPathComponent(release.archiveName), to: destination)
        }
        _ = try manager.install(release.version)
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let repository = ProjectRepository(store: store)
        let projectID = ProjectID()
        try repository.upsert(.init(id: projectID, name: "project", canonicalPath: project.path))
        try repository.setNodeOverride(release.version, for: projectID)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: val)
        child.arguments = ["node", "exec", "--", "node", "--version"]
        child.currentDirectoryURL = project
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = layout.rootURL.path
        child.environment = environment
        let output = Pipe()
        let errors = Pipe()
        child.standardOutput = output
        child.standardError = errors
        try child.run()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path), "A colon in the managed path must never execute the invocation PATH fallback.")
        if child.terminationStatus == 0 {
            XCTAssertEqual(stdout, "v24.22.1\n", stderr)
        } else {
            XCTAssertEqual(child.terminationStatus, 1, stderr)
            XCTAssertTrue(stderr.localizedCaseInsensitiveContains("unavailable") || stderr.localizedCaseInsensitiveContains("path"), stderr)
        }
    }

    func testActualValOfflineExecPreservesArgvCwdIOAndStatusAndFailsClosed() throws {
        guard let val = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"] else { throw XCTSkip("Set VAELEN_VAL_EXECUTABLE to the built val binary.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("node-cli-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project with spaces")
        let bin = root.appendingPathComponent("system-bin")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        try Data("#!/bin/sh\nprintf 'cwd=%s\\n' \"$PWD\"\nprintf 'arg=<%s>\\n' \"$@\"\n/bin/cat\nprintf 'node-stderr\\n' >&2\nexit 23\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        let support = root.appendingPathComponent("support")
        func run(arguments: [String] = ["node", "exec", "--", "node", "", "a b", "--flag"]) throws -> (String, String, Int32) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: val)
            process.arguments = arguments
            process.currentDirectoryURL = project
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = bin.path
            env["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
            env["VAELEN_TEST_SUPPORT_ROOT"] = support.path
            process.environment = env
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data("stdin-payload\n".utf8))
            try input.fileHandleForWriting.close()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self), process.terminationStatus)
        }
        let first = try run()
        XCTAssertEqual(first.2, 23)
        let physical = try XCTUnwrap(realpath(project.path, nil))
        defer { free(physical) }
        XCTAssertEqual(first.0, "cwd=\(String(cString: physical))\narg=<>\narg=<a b>\narg=<--flag>\nstdin-payload\n")
        XCTAssertEqual(first.1, "node-stderr\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        let childHelp = try run(arguments: ["node", "exec", "--", "node", "--help"])
        XCTAssertEqual(childHelp.2, 23)
        XCTAssertTrue(childHelp.0.contains("arg=<--help>"), childHelp.0)
        let commandHelp = try run(arguments: ["node", "exec", "--help"])
        XCTAssertEqual(commandHelp.2, 0)
        XCTAssertTrue(commandHelp.0.contains("val node exec -- COMMAND [ARGUMENT...]"), commandHelp.0)
        let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout(rootURL: support).databaseURL)
        let repository = ProjectRepository(store: store)
        let id = ProjectID()
        try repository.upsert(.init(id: id, name: "project", canonicalPath: project.path, customName: nil))
        try repository.setNodeOverride(try NodeVersion("24.22.1"), for: id)
        let unavailable = try run()
        XCTAssertEqual(unavailable.2, 1)
        XCTAssertTrue(unavailable.0.isEmpty)
        XCTAssertTrue(unavailable.1.contains("unavailable"), unavailable.1)
        try repository.setNodeOverride(nil, for: id)
        let cleared = try run()
        XCTAssertEqual(cleared.2, 23)
    }
}
