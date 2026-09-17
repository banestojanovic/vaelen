import Foundation
import Darwin

public struct VaelenFilesystemLayout: Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = (rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vaelen", isDirectory: true)).standardizedFileURL
    }

    public var stateDirectoryURL: URL { rootURL.appendingPathComponent("state", isDirectory: true) }
    public var databaseURL: URL { stateDirectoryURL.appendingPathComponent("vaelen.sqlite") }
}

public enum PathAvailability: String, Codable, Sendable { case available, missing, unreadable, notDirectory }

public struct CanonicalPath: Hashable, Codable, Sendable, CustomStringConvertible {
    public let url: URL
    public var string: String { url.path }
    public var description: String { string }

    public init(url: URL) { self.url = url }
}

public struct CanonicalPathService: @unchecked Sendable {
    private let fileManager: FileManager
    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func currentWorkingDirectory() -> CanonicalPath {
        canonicalize(URL(fileURLWithPath: fileManager.currentDirectoryPath))
    }

    public func canonicalize(_ path: String) -> CanonicalPath {
        let expanded = (path == "~" || path.hasPrefix("~/"))
            ? (path as NSString).expandingTildeInPath
            : path
        return canonicalize(URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath)))
    }

    public func canonicalize(_ path: String, relativeTo workingDirectory: String) -> CanonicalPath {
        let expanded = (path == "~" || path.hasPrefix("~/")) ? (path as NSString).expandingTildeInPath : path
        return canonicalize(URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workingDirectory)))
    }

    public func canonicalize(_ url: URL) -> CanonicalPath {
        let absolute = url.isFileURL ? url.absoluteURL : URL(fileURLWithPath: url.path)
        let standardized = absolute.standardizedFileURL
        // Resolving only existing paths avoids inventing a target for a missing registration.
        let result = fileManager.fileExists(atPath: standardized.path)
            ? standardized.resolvingSymlinksInPath().standardizedFileURL
            : standardized
        return CanonicalPath(url: result)
    }

    public func availability(of path: CanonicalPath) -> PathAvailability {
        var info = stat()
        guard lstat(path.string, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .notDirectory }
        return access(path.string, R_OK | X_OK) == 0 ? .available : .unreadable
    }
}
