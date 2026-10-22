import Foundation
import XCTest
import CryptoKit
@testable import VaelenCore

final class NodePackagesTests: XCTestCase {
    func testReviewedOfficialArchivesWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["VAELEN_NODE_ARCHIVE_DIRECTORY"] else { throw XCTSkip("Set VAELEN_NODE_ARCHIVE_DIRECTORY to cached official arm64 tar.gz archives.") }
        guard NodePackageManager.hostArchitecture == "arm64" else { throw XCTSkip("This catalog supports only macOS arm64.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("node-official-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveRoot = URL(fileURLWithPath: path)
        let manager = NodePackageManager(layout: .init(rootURL: root), catalog: NodeRelease.reviewed, acquire: { release, to in
            try FileManager.default.copyItem(at: archiveRoot.appendingPathComponent(release.archiveName), to: to)
        })
        for release in NodeRelease.reviewed {
            let installed = try manager.install(release.version)
            XCTAssertEqual(installed.artifactSHA256, release.sha256)
            let package = try manager.resolve(release.version)
            let output = try NodeProcess.output(package.executable, ["--version"], limit: 4096)
            XCTAssertEqual(String(decoding: output, as: UTF8.self), "v\(release.version)\n")
            let npmPath = URL(fileURLWithPath: package.executable).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
            let npm = try NodeProcess.output(package.executable, [npmPath.path, "--version"], limit: 4096)
            XCTAssertEqual(String(decoding: npm, as: UTF8.self), release.npmVersion + "\n")
            print("[NodeOfficial] version=\(release.version) sha256=\(installed.artifactSHA256) npm=\(release.npmVersion) installed-and-resolved=true")
        }
    }

    private func tar(_ values: [(String, UInt8, String, String)]) -> Data {
        var result = Data()
        for (path, kind, contents, link) in values {
            var header = [UInt8](repeating: 0, count: 512)
            func write(_ value: String, at offset: Int) { header.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8) }
            write(path, at: 0)
            write("0000755\0", at: 100)
            write(String(format: "%011o", contents.utf8.count) + "\0", at: 124)
            header[156] = kind
            write(link, at: 157)
            write("ustar\0", at: 257)
            for index in 148..<156 { header[index] = 32 }
            let checksum = header.reduce(0) { $0 + Int($1) }
            write(String(format: "%06o", checksum) + "\0 ", at: 148)
            result.append(contentsOf: header)
            result.append(contentsOf: contents.utf8)
            let padding = (512 - contents.utf8.count % 512) % 512
            result.append(Data(repeating: 0, count: padding))
        }
        result.append(Data(repeating: 0, count: 1024))
        return result
    }

    func testArchiveRejectsTraversalAbsolutePathsAndHardLinks() throws {
        for value: (String, UInt8, String, String) in [
            ("root/../escape", 48, "bad", ""), ("/root/absolute", 48, "bad", ""),
            ("other/file", 48, "bad", ""), ("root/hard", 49, "", "root/file"),
            ("root/link", 50, "", "../../escape"), ("root/link", 50, "", "/tmp/escape")
        ] {
            XCTAssertThrowsError(try NodeTarArchive.entries(tar([value]), root: "root"), value.0)
        }
        XCTAssertThrowsError(try NodeTarArchive.entries(tar([("root/file", 48, "a", ""), ("root/file", 48, "b", "")]), root: "root"))
    }

    func testArchiveRejectsSymlinkParentsBeforeWritingAndAllowsContainedNpmLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dangerous = try NodeTarArchive.entries(tar([("root/link", 50, "", "target"), ("root/link/file", 48, "bad", "")]), root: "root")
        XCTAssertThrowsError(try NodeTarArchive.extract(dangerous, into: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let entries = try NodeTarArchive.entries(tar([("root/bin/npm", 50, "", "../lib/npm.js"), ("root/lib/npm.js", 48, "safe", "")]), root: "root")
        try NodeTarArchive.extract(entries, into: root)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("root/bin/npm"), encoding: .utf8), "safe")
    }

    func testStagedInstallationIsIdempotentAndCorruptionAndUnownedPathsFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let version = try NodeVersion("24.22.1")
        let name = "node-v24.22.1-darwin-" + NodePackageManager.hostArchitecture
        let node = "#!/bin/sh\nprintf '%s\\n' '{\"version\":\"24.22.1\",\"platform\":\"darwin\",\"arch\":\"\(NodePackageManager.hostArchitecture)\"}'\n"
        let data = tar([
            (name + "/bin/node", 48, node, ""),
            (name + "/bin/npm", 50, "", "../lib/node_modules/npm/bin/npm-cli.js"),
            (name + "/lib/node_modules/npm/package.json", 48, "{\"name\":\"npm\",\"version\":\"11.19.1\",\"bin\":{\"npm\":\"bin/npm-cli.js\"}}", ""),
            (name + "/lib/node_modules/npm/bin/npm-cli.js", 48, "npm fixture", "")
        ])
        let raw = root.appendingPathComponent("fixture.tar")
        try data.write(to: raw)
        let compressed = try NodeProcess.output("/usr/bin/gzip", ["-c", raw.path], limit: 1_000_000)
        let sha = SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined()
        var files = [String: String](), links = [String: String]()
        for entry in try NodeTarArchive.entries(data, root: name) {
            let relative = String(entry.path.dropFirst(name.count + 1))
            if entry.kind == 48 { files[relative] = SHA256.hash(data: entry.contents).map { String(format: "%02x", $0) }.joined() }
            if entry.kind == 50 { links[relative] = entry.link }
        }
        let release = NodeRelease(version: version, architecture: NodePackageManager.hostArchitecture, sha256: sha, npmVersion: "11.19.1", contentManifestSHA256: NodePackageManager.contentManifestDigest(files: files, links: links))
        let layout = VaelenFilesystemLayout(rootURL: root)
        let manager = NodePackageManager(layout: layout, catalog: [release], acquire: { _, to in try compressed.write(to: to) })
        let installed = try manager.install(version)
        XCTAssertEqual(installed.artifactSHA256, sha)
        XCTAssertEqual(try manager.install(version), installed)
        XCTAssertEqual(try manager.resolve(version).identity, installed)
        let records = [NodeProjectRecord(id: ProjectID(), name: "project", path: root.path, pin: version)]
        XCTAssertTrue(manager.validationSnapshot(records: records).selections(records).allSatisfy(\.runtimeAvailable))
        let npm = manager.packagesURL.appendingPathComponent("24.22.1/lib/node_modules/npm/bin/npm-cli.js")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: npm.path)
        XCTAssertThrowsError(try manager.resolve(version))
        XCTAssertThrowsError(try manager.install(version))
        XCTAssertTrue(manager.validationSnapshot(records: records).selections(records).allSatisfy { !$0.runtimeAvailable })
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npm.path)
        let link = manager.packagesURL.appendingPathComponent("24.22.1/bin/npm")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "node")
        XCTAssertThrowsError(try manager.resolve(version))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../lib/node_modules/npm/bin/npm-cli.js")
        XCTAssertEqual(try manager.resolve(version).identity, installed)
        try Data("corrupt".utf8).write(to: manager.packagesURL.appendingPathComponent("24.22.1/bin/node"))
        XCTAssertThrowsError(try manager.resolve(version))
        XCTAssertThrowsError(try manager.install(version))
        try FileManager.default.removeItem(at: manager.packagesURL.appendingPathComponent("24.22.1"))
        let failing = NodePackageManager(layout: layout, catalog: [release], acquire: { _, to in try Data("bad hash".utf8).write(to: to) })
        XCTAssertThrowsError(try failing.install(version))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: manager.packagesURL.path).isEmpty)
        let unowned = manager.packagesURL.appendingPathComponent("24.22.1")
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: unowned.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try manager.install(version))
        XCTAssertEqual(try String(contentsOf: unowned.appendingPathComponent("sentinel"), encoding: .utf8), "preserve")
    }
}

extension NodePackagesTests {
    func testValidationSnapshotChecksEachExactVersionOnceAndRefreshesNextRequest() throws {
        let version = try NodeVersion("24.22.1")
        let other = try NodeVersion("26.12.1")
        let identity = NodePackageIdentity(version: version, platform: "darwin", architecture: "arm64", artifactSHA256: "fixture", receiptVersion: 1)
        var calls = [NodeVersion: Int]()
        var corrupted = false
        func snapshot() -> NodePackageValidationSnapshot {
            NodePackageValidationSnapshot(versions: [version, version, other, version]) { requested in
                calls[requested, default: 0] += 1
                guard requested == version, !corrupted else { throw NodeError.unavailable("Fixture corruption.") }
                return identity
            }
        }
        let records = (0..<3).map { index in NodeProjectRecord(id: ProjectID(), name: "project-\(index)", path: "/tmp/project-\(index)", pin: version) }
        let first = snapshot()
        XCTAssertTrue(first.selections(records).allSatisfy(\.runtimeAvailable))
        XCTAssertEqual(try first.package(version), identity)
        XCTAssertThrowsError(try first.package(other))
        XCTAssertEqual(calls, [version: 1, other: 1])
        corrupted = true
        let second = snapshot()
        XCTAssertTrue(second.selections(records).allSatisfy { !$0.runtimeAvailable })
        XCTAssertThrowsError(try second.package(version))
        XCTAssertEqual(calls, [version: 2, other: 2])
    }
}
