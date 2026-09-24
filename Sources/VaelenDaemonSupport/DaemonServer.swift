import Darwin
import Foundation
import OSLog
import VaelenIPC

public final class DaemonServer: @unchecked Sendable {
    private let paths: CoreEndpointPaths
    private let dispatcher: CoreRequestDispatcher
    private let parentPID: Int32?
    private let logger = Logger(subsystem: "dev.vaelen.daemon", category: "server")
    private var listener: Int32 = -1

    public init(paths: CoreEndpointPaths, dispatcher: CoreRequestDispatcher, parentPID: Int32? = nil) {
        self.paths = paths
        self.dispatcher = dispatcher
        self.parentPID = parentPID
    }

    public func run() throws {
        try paths.prepareDirectories()
        try paths.validateSocketPathLength()
        let lock = try DaemonLock(path: paths.lock.path)
        try lock.acquire()
        defer { lock.release() }
        try removeStaleSocketIfNeeded()
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CoreTransportError.systemCallFailed("socket", errno) }
        defer { close(listener); listener = -1; unlink(paths.socketPath) }
        var address = try makeUnixAddress(path: paths.socketPath)
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { throw CoreTransportError.systemCallFailed("bind", errno) }
        guard listen(listener, 16) == 0 else { throw CoreTransportError.systemCallFailed("listen", errno) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.socketPath)
        setNoSigPipe(listener)
        logger.info("Core daemon started")

        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.stop() }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        let parentMonitor = startParentMonitor()
        defer { parentMonitor?.cancel() }
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { if errno == EINTR { continue }; if listener < 0 { return }; throw CoreTransportError.systemCallFailed("accept", errno) }
            setNoSigPipe(client)
            let server = self
            Task.detached { [dispatcher, logger, server] in
                await Self.handle(client, dispatcher: dispatcher, logger: logger) {
                    guard await dispatcher.shouldExitAfterShutdownResponse() else { return }
                    let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
                    logger.notice("SHUTDOWN_TIMING Core exit requested epoch=\(timestamp, privacy: .public)")
                    server.stop()
                }
            }
        }
    }

    private func startParentMonitor() -> Task<Void, Never>? {
        guard let parentPID, parentPID > 1 else { return nil }
        let endpointPaths = paths
        let logger = logger
        return Task.detached { [weak self, dispatcher, endpointPaths, logger] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard getppid() != parentPID else { continue }
                let result = await dispatcher.shutdownForParentExit()
                let supportRoot = endpointPaths.root.deletingLastPathComponent()
                let activityURL = supportRoot.appendingPathComponent("state/activity")
                do {
                    try FileManager.default.createDirectory(at: activityURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("inactive\n".utf8).write(to: activityURL, options: .atomic)
                } catch {
                    logger.error("Core cleaned up after its GUI exited, but could not mark shell PHP inactive: \(String(describing: error), privacy: .public)")
                }
                if !result.completed {
                    logger.error("Best-effort parent-exit cleanup had incomplete components: \(result.components.filter { !$0.succeeded }.map(\.component).joined(separator: ", "), privacy: .public)")
                }
                self?.stop()
                return
            }
        }
    }

    private func stop() { let fd = listener; listener = -1; if fd >= 0 { close(fd) } }

    private static func handle(_ client: Int32, dispatcher: CoreRequestDispatcher, logger: Logger, afterResponse: @escaping @Sendable () async -> Void) async {
        defer { close(client) }
        do {
            try validatePeer(client)
            var decoder = FrameDecoder(); var handshaken = false
            while true {
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(client, &bytes, bytes.count)
                if count == 0 { return }
                if count < 0 { if errno == EINTR { continue }; throw CoreTransportError.systemCallFailed("read", errno) }
                for frame in try decoder.append(Data(bytes[0..<count])) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    let result = await dispatcher.dispatch(request, handshaken: handshaken)
                    handshaken = result.handshaken
                    try writeAll(client, data: FrameEncoder().encode(IPCCodec.encode(result.response)))
                    if request.knownMethod == .portsInstall {
                        logger.info("IPC ports.install response frame written; error payload returned: \(result.response.error != nil, privacy: .public)")
                    }
                    await afterResponse()
                }
            }
        } catch { logger.error("Client connection ended: \(String(describing: error), privacy: .public)") }
    }

    private static func validatePeer(_ client: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0 else { throw CoreTransportError.peerIdentityUnavailable }
        guard uid == getuid() else { throw CoreTransportError.unauthorizedPeer }
    }

    private static func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw CoreTransportError.systemCallFailed("write", errno) }
                offset += count
            }
        }
    }

    private func removeStaleSocketIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: paths.socketPath) else { return }
        var info = stat(); guard lstat(paths.socketPath, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw CoreTransportError.systemCallFailed("socket endpoint is not a socket", EEXIST) }
        guard info.st_uid == getuid() else { throw CoreTransportError.unauthorizedPeer }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0); guard probe >= 0 else { throw CoreTransportError.systemCallFailed("socket", errno) }; defer { close(probe) }
        var address = try makeUnixAddress(path: paths.socketPath)
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result == 0 { throw CoreTransportError.systemCallFailed("another daemon already owns the endpoint", EADDRINUSE) }
        guard errno == ECONNREFUSED || errno == ENOENT else { throw CoreTransportError.systemCallFailed("probe", errno) }
        guard unlink(paths.socketPath) == 0 else { throw CoreTransportError.systemCallFailed("unlink", errno) }
    }

    private func setNoSigPipe(_ fd: Int32) {
        var value: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
    }
}

public final class DaemonLock {
    private let fd: Int32
    public init(path: String) throws { let value = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600); guard value >= 0 else { throw CoreTransportError.systemCallFailed("open lock", errno) }; fd = value }
    public func acquire() throws { guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CoreTransportError.systemCallFailed("acquire daemon lock", errno) } }
    public func release() { _ = flock(fd, LOCK_UN); close(fd) }
}
