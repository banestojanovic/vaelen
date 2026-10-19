import Darwin
import Foundation

struct ComposerExecutionPlan {
    let phpExecutable: String
    let scriptPath: String
    let arguments: [String]

    var processArguments: [String] {
        [phpExecutable, scriptPath] + arguments
    }
}

enum ComposerScriptError: Error, LocalizedError {
    case notFound
    case incompatible(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Composer was not found on PATH. Install Composer and ensure ‘composer’ or ‘composer.phar’ is on PATH."
        case .incompatible(let path):
            return "The Composer candidate at \(path) is not a readable PHP script or PHAR stub. Put a compatible Composer launcher on PATH."
        case .launchFailed(let detail):
            return "Unable to start Composer with the selected PHP executable: \(detail)"
        }
    }
}

enum ComposerScriptLocator {
    private static let headerLimit = 4096

    static func resolve(path: String?, workingDirectory: String) throws -> URL {
        guard let path else { throw ComposerScriptError.notFound }
        let directories = path.split(separator: ":", omittingEmptySubsequences: false)
        for component in directories {
            let rawDirectory = String(component)
            let directory: URL
            if rawDirectory.isEmpty {
                directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            } else if rawDirectory.hasPrefix("/") {
                directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
            } else {
                directory = URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(rawDirectory, isDirectory: true)
            }
            for name in ["composer", "composer.phar"] {
                let candidate = directory.appendingPathComponent(name)
                guard hasDirectoryEntry(at: candidate) else { continue }
                guard isCompatiblePHPStub(at: candidate) else { throw ComposerScriptError.incompatible(candidate.path) }
                return candidate.standardizedFileURL.resolvingSymlinksInPath()
            }
        }
        throw ComposerScriptError.notFound
    }

    private static func hasDirectoryEntry(at url: URL) -> Bool {
        url.path.withCString { path in
            var metadata = stat()
            return lstat(path, &metadata) == 0
        }
    }

    private static func isCompatiblePHPStub(at url: URL) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath()
        guard let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: resolvedURL.path),
              let handle = try? FileHandle(forReadingFrom: resolvedURL) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: headerLimit) else { return false }
        let header = Array(bytes)
        var index = 0
        if header.starts(with: [UInt8(ascii: "#"), UInt8(ascii: "!")]) {
            guard let newline = header.firstIndex(of: 10),
                  let shebang = String(bytes: header[..<newline], encoding: .utf8)?.lowercased(),
                  shebang.contains("php") else { return false }
            index = newline + 1
        }
        while index < header.count, [9, 10, 11, 12, 13, 32].contains(header[index]) { index += 1 }
        let opener = Array("<?php".utf8)
        guard header.count >= index + opener.count,
              Array(header[index..<(index + opener.count)]) == opener else { return false }
        let afterOpener = index + opener.count
        if afterOpener == header.count { return values.fileSize == header.count }
        return [9, 10, 11, 12, 13, 32, 63].contains(header[afterOpener])
    }
}

enum ComposerCommand {
    static func executionPlan(phpExecutable: String, scriptURL: URL, arguments: [String]) -> ComposerExecutionPlan {
        ComposerExecutionPlan(phpExecutable: phpExecutable, scriptPath: scriptURL.path, arguments: arguments)
    }

    static func replaceProcess(with plan: ComposerExecutionPlan) throws -> Never {
        let strings = plan.processArguments
        var pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        guard let executable = pointers.first, let executable else { throw ComposerScriptError.launchFailed("invalid executable path") }
        _ = pointers.withUnsafeMutableBufferPointer { buffer in execv(executable, buffer.baseAddress) }
        throw ComposerScriptError.launchFailed(String(cString: strerror(errno)))
    }
}
