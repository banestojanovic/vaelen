import Foundation
import Darwin

/// Explicit developer-only state isolation hook. The two-part opt-in prevents
/// an incidental inherited path variable from redirecting normal product
/// state. Production runtime launches leave both variables unset.
public enum VaelenTestRuntimePaths {
    public static func isolatedSupportRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] == "1",
              let path = environment["VAELEN_TEST_SUPPORT_ROOT"],
              path.hasPrefix("/"), path != "/" else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

public struct VaelenFilesystemLayout: Sendable {
    public let rootURL: URL
    private let explicitLogsDirectoryURL: URL?
    private let usesRootLocalDirectories: Bool

    public init(rootURL: URL? = nil, fileManager: FileManager = .default, logsDirectoryURL: URL? = nil) {
        let root: URL
        if let rootURL {
            root = rootURL
        } else {
            if let isolatedRoot = VaelenTestRuntimePaths.isolatedSupportRoot() {
                root = isolatedRoot
            } else {
                root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vaelen", isDirectory: true)
            }
        }
        self.rootURL = root.standardizedFileURL
        self.explicitLogsDirectoryURL = logsDirectoryURL?.standardizedFileURL
        self.usesRootLocalDirectories = rootURL != nil || VaelenTestRuntimePaths.isolatedSupportRoot() != nil
    }

    public var stateDirectoryURL: URL { rootURL.appendingPathComponent("state", isDirectory: true) }
    public var databaseURL: URL { stateDirectoryURL.appendingPathComponent("vaelen.sqlite") }
    public var localProxyDatabaseURL: URL { stateDirectoryURL.appendingPathComponent("local-proxy-ownership.sqlite") }
    public var packagesDirectoryURL: URL { rootURL.appendingPathComponent("packages", isDirectory: true) }
    public var phpPackagesDirectoryURL: URL { packagesDirectoryURL.appendingPathComponent("php", isDirectory: true) }
    public var caddyPackagesDirectoryURL: URL { packagesDirectoryURL.appendingPathComponent("caddy", isDirectory: true) }
    public var mysqlPackagesDirectoryURL: URL { packagesDirectoryURL.appendingPathComponent("mysql", isDirectory: true) }
    public var mailpitPackagesDirectoryURL: URL { packagesDirectoryURL.appendingPathComponent("mailpit", isDirectory: true) }
    public var instancesDirectoryURL: URL { rootURL.appendingPathComponent("instances", isDirectory: true) }
    public var phpInstancesDirectoryURL: URL { instancesDirectoryURL.appendingPathComponent("php", isDirectory: true) }
    public var caddyInstancesDirectoryURL: URL { instancesDirectoryURL.appendingPathComponent("caddy", isDirectory: true) }
    public var mysqlInstancesDirectoryURL: URL { instancesDirectoryURL.appendingPathComponent("mysql", isDirectory: true) }
    public var mailpitInstancesDirectoryURL: URL { instancesDirectoryURL.appendingPathComponent("mailpit", isDirectory: true) }
    public var configurationDirectoryURL: URL { rootURL.appendingPathComponent("config", isDirectory: true) }
    public var routingConfigurationDirectoryURL: URL { configurationDirectoryURL.appendingPathComponent("routing", isDirectory: true) }
    public var routingRuntimeDirectoryURL: URL { rootURL.appendingPathComponent("runtime/routing", isDirectory: true) }
    public var cacheDirectoryURL: URL {
        if usesRootLocalDirectories { return rootURL.appendingPathComponent("cache", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Vaelen", isDirectory: true)
    }
    public var downloadsDirectoryURL: URL { cacheDirectoryURL.appendingPathComponent("downloads", isDirectory: true) }
    public var stagingDirectoryURL: URL { cacheDirectoryURL.appendingPathComponent("staging", isDirectory: true) }
    public var logsDirectoryURL: URL {
        if let explicitLogsDirectoryURL { return explicitLogsDirectoryURL }
        if usesRootLocalDirectories { return rootURL.appendingPathComponent("logs", isDirectory: true) }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Vaelen", isDirectory: true)
    }
    public var phpLogsDirectoryURL: URL { logsDirectoryURL.appendingPathComponent("modules/php", isDirectory: true) }
    public var caddyLogsDirectoryURL: URL { logsDirectoryURL.appendingPathComponent("caddy", isDirectory: true) }
    public var mysqlLogsDirectoryURL: URL { logsDirectoryURL.appendingPathComponent("modules/mysql", isDirectory: true) }
    public var mailpitLogsDirectoryURL: URL { logsDirectoryURL.appendingPathComponent("modules/mailpit", isDirectory: true) }
    public var dnsInstancesDirectoryURL: URL { instancesDirectoryURL.appendingPathComponent("dns", isDirectory: true) }
    public var dnsLogsDirectoryURL: URL { logsDirectoryURL.appendingPathComponent("dns", isDirectory: true) }
    public var tlsDirectoryURL: URL { rootURL.appendingPathComponent("tls", isDirectory: true) }
    public var tlsCertificatesDirectoryURL: URL { tlsDirectoryURL.appendingPathComponent("certificates", isDirectory: true) }
    public var tlsLeafDirectoryURL: URL { tlsCertificatesDirectoryURL.appendingPathComponent("leaf", isDirectory: true) }
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
