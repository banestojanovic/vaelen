import Foundation
import CryptoKit
import Darwin

public struct NodeRelease: Codable, Equatable, Sendable {
    public let version: NodeVersion
    public let architecture: String
    public let sha256: String
    public let npmVersion: String
    public let contentManifestSHA256: String
    public var archiveName: String { "node-v\(version)-darwin-\(architecture).tar.gz" }
    public var directoryName: String { "node-v\(version)-darwin-\(architecture)" }
    public var url: URL { URL(string: "https://nodejs.org/dist/v\(version)/\(archiveName)")! }

    public static let reviewed: [NodeRelease] = [
        .init(version: try! NodeVersion("24.22.1"), architecture: "arm64", sha256: "89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7", npmVersion: "11.19.1", contentManifestSHA256: "9d88d435cc73b19ad457e9e0d938458bd85a242c1ec222b2b7d1e24d09f60a90"),
        .init(version: try! NodeVersion("26.12.1"), architecture: "arm64", sha256: "1901d539912c02afa10d1cc126943a8855a7eedebe830119463470db5e6c59e8", npmVersion: "11.20.0", contentManifestSHA256: "56bc8b5d2fb81060b8ed5b3bfbcd64dc33d76dc038b2a74babc66c876f875f00")
    ]
}

internal enum NodeProcess {
    static func output(_ executable: String, _ arguments: [String], limit: Int, timeout: TimeInterval = 30) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/var/empty"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume()
        defer { timer.cancel(); try? pipe.fileHandleForReading.close() }
        var output = Data()
        while let bytes = try pipe.fileHandleForReading.read(upToCount: 65_536), !bytes.isEmpty {
            guard output.count + bytes.count <= limit else {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw NodeError.unavailable("Process output exceeded its bound.")
            }
            output.append(bytes)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw NodeError.unavailable("\(URL(fileURLWithPath: executable).lastPathComponent) failed.") }
        return output
    }
}

internal struct NodeTarEntry {
    let path: String
    let kind: UInt8
    let contents: Data
    let link: String
    let executable: Bool
}

internal enum NodeTarArchive {
    static func entries(_ data: Data, root: String) throws -> [NodeTarEntry] {
        guard data.count <= 512 * 1024 * 1024 else { throw NodeError.unavailable("Archive exceeds its extracted size bound.") }
        var entries = [NodeTarEntry]()
        var names = Set<String>()
        var offset = 0
        func text(_ bytes: Data) throws -> String {
            guard let value = String(data: bytes.prefix { $0 != 0 }, encoding: .utf8) else { throw NodeError.unavailable("Invalid archive text.") }
            return value
        }
        func octal(_ bytes: Data) throws -> Int {
            let value = try text(bytes).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...55).contains($0) }), let number = Int(value, radix: 8) else { throw NodeError.unavailable("Invalid archive number.") }
            return number
        }
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                guard data.count >= offset + 1024, data[offset...].allSatisfy({ $0 == 0 }) else { throw NodeError.unavailable("Invalid archive terminator.") }
                return entries
            }
            let checksum = try octal(header.subdata(in: 148..<156))
            let actual = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            guard checksum == actual else { throw NodeError.unavailable("Archive header checksum mismatch.") }
            guard header.subdata(in: 257..<262) == Data("ustar".utf8) else { throw NodeError.unavailable("Only reviewed ustar archives are supported.") }
            let name = try text(header.subdata(in: 0..<100))
            let prefix = try text(header.subdata(in: 345..<500))
            let path = (prefix.isEmpty ? name : prefix + "/" + name).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !prefix.hasPrefix("/"), components.first == Substring(root), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), names.insert(path).inserted else { throw NodeError.unavailable("Unsafe or duplicate archive path.") }
            let kind = header[156]
            guard [0, 48, 50, 53].contains(kind) else { throw NodeError.unavailable("Unsupported archive entry type.") }
            let size = try octal(header.subdata(in: 124..<136))
            guard size <= 256 * 1024 * 1024, offset + 512 + size <= data.count, entries.count < 20_000 else { throw NodeError.unavailable("Invalid archive entry size.") }
            let link = try text(header.subdata(in: 157..<257))
            if kind == 50 {
                guard size == 0, !link.isEmpty, !link.hasPrefix("/") else { throw NodeError.unavailable("Unsafe archive link.") }
                let resolved = URL(fileURLWithPath: "/" + path).deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL.path
                guard resolved.hasPrefix("/" + root + "/") else { throw NodeError.unavailable("Archive link escapes its package.") }
            }
            if kind == 53 && size != 0 { throw NodeError.unavailable("Directory contains archive data.") }
            entries.append(NodeTarEntry(path: path, kind: kind, contents: data.subdata(in: (offset + 512)..<(offset + 512 + size)), link: link, executable: try octal(header.subdata(in: 100..<108)) & 0o111 != 0))
            offset += 512 + ((size + 511) / 512) * 512
        }
        throw NodeError.unavailable("Truncated archive.")
    }

    static func extract(_ entries: [NodeTarEntry], into directory: URL) throws {
        let manager = FileManager.default
        let links = Set(entries.filter { $0.kind == 50 }.map(\.path))
        let files = Set(entries.filter { $0.kind == 0 || $0.kind == 48 }.map(\.path))
        for entry in entries {
            var parent = (entry.path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !links.contains(parent), !files.contains(parent) else { throw NodeError.unavailable("Archive entry has a non-directory parent.") }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for entry in entries where entry.kind != 50 {
            let target = directory.appendingPathComponent(entry.path)
            if entry.kind == 53 { try manager.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]) }
            else {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try entry.contents.write(to: target, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: entry.executable ? 0o755 : 0o644], ofItemAtPath: target.path)
            }
        }
        for entry in entries where entry.kind == 50 {
            let target = directory.appendingPathComponent(entry.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: target.path, withDestinationPath: entry.link)
        }
    }
}

private struct NodePackageReceipt: Codable {
    let identity: NodePackageIdentity
    let files: [String: String]
    let links: [String: String]
}

public struct NodePackageManager: Sendable {
    public let layout: VaelenFilesystemLayout
    private let catalog: [NodeRelease]
    private let acquire: @Sendable (NodeRelease, URL) throws -> Void
    public init(layout: VaelenFilesystemLayout = .init()) {
        self.layout = layout; catalog = NodeRelease.reviewed; acquire = Self.download
    }
    internal init(layout: VaelenFilesystemLayout, catalog: [NodeRelease], acquire: @escaping @Sendable (NodeRelease, URL) throws -> Void) {
        self.layout = layout; self.catalog = catalog; self.acquire = acquire
    }
    public var packagesURL: URL { layout.rootURL.resolvingSymlinksInPath().appendingPathComponent("packages/node", isDirectory: true) }
    public static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    internal static func contentManifestDigest(files: [String: String], links: [String: String]) -> String {
        let content = files.keys.sorted().map { "F\0" + $0 + "\0" + files[$0]! + "\n" }.joined()
            + links.keys.sorted().map { "L\0" + $0 + "\0" + links[$0]! + "\n" }.joined()
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func resolve(_ version: NodeVersion) throws -> (identity: NodePackageIdentity, executable: String) {
        do { return try validatedPackage(version) }
        catch let error as NodeError { throw error }
        catch { throw NodeError.unavailable(error.localizedDescription) }
    }

    private func validatedPackage(_ version: NodeVersion) throws -> (identity: NodePackageIdentity, executable: String) {
        guard let release = catalog.first(where: { $0.version == version && $0.architecture == Self.hostArchitecture }) else { throw NodeError.unavailable("This exact version and architecture has no reviewed catalog entry.") }
        let root = packagesURL.appendingPathComponent(version.description).standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path else { throw NodeError.unavailable("Package path is redirected by a symbolic link.") }
        let receiptURL = root.appendingPathComponent(".vaelen-node.json")
        let metadata = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true, (metadata.fileSize ?? Int.max) < 4 * 1024 * 1024 else { throw NodeError.unavailable("Invalid package receipt file.") }
        guard let data = try? Data(contentsOf: receiptURL), data.count < 4 * 1024 * 1024, let receipt = try? JSONDecoder().decode(NodePackageReceipt.self, from: data), receipt.identity.version == version, receipt.identity.platform == "darwin", receipt.identity.architecture == release.architecture, receipt.identity.artifactSHA256 == release.sha256, receipt.identity.receiptVersion == 1,
              receipt.files["bin/node"] != nil, receipt.files["lib/node_modules/npm/bin/npm-cli.js"] != nil, receipt.links["bin/npm"] == "../lib/node_modules/npm/bin/npm-cli.js" else { throw NodeError.unavailable("The owned package receipt is missing or invalid.") }
        guard Self.contentManifestDigest(files: receipt.files, links: receipt.links) == release.contentManifestSHA256 else { throw NodeError.unavailable("Package receipt content does not match the reviewed release.") }
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { throw NodeError.unavailable("Cannot enumerate package contents.") }
        for case let relative as String in enumerator {
            if relative == ".vaelen-node.json" { continue }
            let file = root.appendingPathComponent(relative)
            let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            if metadata.isSymbolicLink == true {
                guard receipt.links[relative] != nil else { throw NodeError.unavailable("Unowned package link.") }
            } else if metadata.isRegularFile == true {
                guard receipt.files[relative] != nil else { throw NodeError.unavailable("Unowned package file.") }
            } else if metadata.isDirectory != true { throw NodeError.unavailable("Unsupported package entry.") }
        }
        for (path, hash) in receipt.files {
            guard safeRelative(path), hash.count == 64 else { throw NodeError.unavailable("Invalid package receipt path.") }
            let file = root.appendingPathComponent(path)
            let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard file.resolvingSymlinksInPath().path == file.path, metadata.isRegularFile == true, metadata.isSymbolicLink != true, digest(try Data(contentsOf: file, options: .mappedIfSafe)) == hash else { throw NodeError.unavailable("Package content is missing or corrupt at \(path).") }
        }
        for (path, target) in receipt.links {
            guard safeRelative(path), !target.hasPrefix("/"), try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(path).path) == target,
                  root.appendingPathComponent(path).resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw NodeError.unavailable("Package link is missing or corrupt.") }
        }
        try validateEntrypoints(root: root, receipt: receipt)
        return (receipt.identity, root.appendingPathComponent("bin/node").path)
    }

    private func validateEntrypoints(root: URL, receipt: NodePackageReceipt) throws {
        for path in Array(receipt.files.keys) + Array(receipt.links.keys) where path.hasPrefix("bin/") {
            let entrypoint = root.appendingPathComponent(path)
            let target = entrypoint.resolvingSymlinksInPath()
            guard target.path.hasPrefix(root.path + "/"),
                  receipt.files[String(target.path.dropFirst(root.path.count + 1))] != nil,
                  FileManager.default.isExecutableFile(atPath: entrypoint.path) else {
                throw NodeError.unavailable("Package entry point is missing or not executable at \(path).")
            }
        }
    }

    private func safeRelative(_ path: String) -> Bool { !path.hasPrefix("/") && !path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } }

    public func install(_ version: NodeVersion) throws -> NodePackageIdentity {
        guard let release = catalog.first(where: { $0.version == version && $0.architecture == Self.hostArchitecture }) else { throw NodeError.unavailable("Only reviewed macOS arm64 releases are supported in this slice.") }
        let manager = FileManager.default
        let final = packagesURL.appendingPathComponent(version.description)
        if (try? final.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil { return try resolve(version).identity }
        let canonicalPackages = packagesURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalPackages.path == packagesURL.standardizedFileURL.path else { throw NodeError.unavailable("Package directory is redirected by a symbolic link.") }
        try manager.createDirectory(at: packagesURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = packagesURL.appendingPathComponent(".stage-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("download.tar.gz")
        try acquire(release, archive)
        let compressed = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard compressed.count <= 104857600, digest(compressed) == release.sha256 else { throw NodeError.unavailable("Official archive SHA-256 mismatch.") }
        let data = try NodeProcess.output("/usr/bin/gzip", ["-dc", archive.path], limit: 512 * 1024 * 1024)
        let entries = try NodeTarArchive.entries(data, root: release.directoryName)
        try NodeTarArchive.extract(entries, into: stage)
        let extracted = stage.appendingPathComponent(release.directoryName)
        for entry in entries where entry.kind == 50 {
            guard stage.appendingPathComponent(entry.path).resolvingSymlinksInPath().path.hasPrefix(extracted.path + "/") else { throw NodeError.unavailable("Archive link resolves outside its package.") }
        }
        let node = extracted.appendingPathComponent("bin/node")
        let probe = try NodeProcess.output(node.path, ["-p", "JSON.stringify({version:process.versions.node,platform:process.platform,arch:process.arch})"], limit: 4096)
        struct Probe: Decodable { let version: String; let platform: String; let arch: String }
        let observed = try JSONDecoder().decode(Probe.self, from: probe)
        guard observed.version == version.description, observed.platform == "darwin", observed.arch == release.architecture else { throw NodeError.unavailable("Node runtime identity mismatch.") }
        let npm = extracted.appendingPathComponent("lib/node_modules/npm")
        let npmPackage = try JSONSerialization.jsonObject(with: Data(contentsOf: npm.appendingPathComponent("package.json"))) as? [String: Any]
        guard npmPackage?["name"] as? String == "npm", npmPackage?["version"] as? String == release.npmVersion, (npmPackage?["bin"] as? [String: String])?["npm"] == "bin/npm-cli.js", manager.fileExists(atPath: npm.appendingPathComponent("bin/npm-cli.js").path), try manager.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("bin/npm").path) == "../lib/node_modules/npm/bin/npm-cli.js" else { throw NodeError.unavailable("npm version or entry point is invalid.") }
        let identity = NodePackageIdentity(version: version, platform: "darwin", architecture: release.architecture, artifactSHA256: release.sha256, receiptVersion: 1)
        var files = [String: String](), links = [String: String]()
        for entry in entries {
            let relative = String(entry.path.dropFirst(release.directoryName.count + 1))
            if entry.kind == 0 || entry.kind == 48 { files[relative] = digest(entry.contents) }
            if entry.kind == 50 { links[relative] = entry.link }
        }
        let receipt = NodePackageReceipt(identity: identity, files: files, links: links)
        guard Self.contentManifestDigest(files: files, links: links) == release.contentManifestSHA256 else { throw NodeError.unavailable("Extracted content does not match the reviewed manifest.") }
        try validateEntrypoints(root: extracted, receipt: receipt)
        try JSONEncoder().encode(receipt).write(to: extracted.appendingPathComponent(".vaelen-node.json"), options: .withoutOverwriting)
        guard renamex_np(extracted.path, final.path, UInt32(RENAME_EXCL)) == 0 else { throw NodeError.unavailable("Package publication refused an existing destination.") }
        return identity
    }

    private static func download(_ release: NodeRelease, to archive: URL) throws {
        _ = try NodeProcess.output("/usr/bin/curl", ["--disable", "--fail", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "0", "--max-time", "90", "--connect-timeout", "15", "--max-filesize", "104857600", "--output", archive.path, release.url.absoluteString], limit: 4096, timeout: 95)
    }

    public func resolution(records: [NodeProjectRecord], workingDirectory: String) throws -> NodeResolution {
        guard let pin = NodeProjectBoundary.select(records, workingDirectory: workingDirectory)?.pin else { return .invocationPATH }
        let package = try resolve(pin)
        return .managed(package.identity, executable: package.executable)
    }

    public func validationSnapshot(records: [NodeProjectRecord], including versions: [NodeVersion] = []) -> NodePackageValidationSnapshot {
        NodePackageValidationSnapshot(versions: catalog.map(\.version) + records.compactMap(\.pin) + versions) {
            try resolve($0).identity
        }
    }

    public func selections(_ records: [NodeProjectRecord]) -> [ProjectNodeSelection] {
        validationSnapshot(records: records).selections(records)
    }
}
