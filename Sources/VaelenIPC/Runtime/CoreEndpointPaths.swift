import Foundation

public struct CoreEndpointPaths: Sendable {
    public let root: URL
    public let sockets: URL
    public let locks: URL
    public let socket: URL
    public let lock: URL

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vaelen", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
        self.root = base
        self.sockets = base.appendingPathComponent("sockets", isDirectory: true)
        self.locks = base.appendingPathComponent("locks", isDirectory: true)
        self.socket = self.sockets.appendingPathComponent("core.sock", isDirectory: false)
        self.lock = self.locks.appendingPathComponent("vaelend.lock", isDirectory: false)
    }

    public func prepareDirectories() throws {
        let manager = FileManager.default
        for directory in [root, sockets, locks] {
            if !manager.fileExists(atPath: directory.path) {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    public var socketPath: String { socket.path }

    public func validateSocketPathLength() throws {
        let path = socket.path
        guard path.utf8.count < 104 else {
            throw CoreEndpointError.socketPathTooLong(path)
        }
    }
}

public enum CoreEndpointError: Error, Equatable, Sendable {
    case socketPathTooLong(String)
}
