import Darwin
import Foundation
import OSLog
import VaelenCore
import VaelenIPC

final class DaemonServer: @unchecked Sendable {
    private let runtime: CoreRuntime
    private let paths: CoreEndpointPaths
    private let logger = Logger(subsystem: "dev.vaelen.daemon", category: "core")
    private var listener: Int32 = -1

    init(runtime: CoreRuntime, paths: CoreEndpointPaths) {
        self.runtime = runtime
        self.paths = paths
    }

    func run() throws {
        try paths.prepareDirectories()
        try paths.validateSocketPathLength()
        let lock = try DaemonLock(path: paths.lock.path)
        try lock.acquire()
        defer { lock.release() }

        try removeStaleSocketIfNeeded()
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CoreTransportError.systemCallFailed("socket", errno) }
        defer {
            close(listener)
            listener = -1
            unlink(paths.socketPath)
        }

        var address = try makeUnixAddress(path: paths.socketPath)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw CoreTransportError.systemCallFailed("bind", errno) }
        guard listen(listener, 16) == 0 else { throw CoreTransportError.systemCallFailed("listen", errno) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.socketPath)
        logger.info("Core daemon started with pid \(self.runtime.status.pid)")

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        signalSource.setEventHandler { [weak self] in self?.stop() }
        signalSource.resume()
        let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        terminationSource.setEventHandler { [weak self] in self?.stop() }
        terminationSource.resume()
        defer {
            signalSource.cancel()
            terminationSource.cancel()
        }

        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if listener < 0 { return }
                throw CoreTransportError.systemCallFailed("accept", errno)
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                handle(client)
            }
        }
    }

    private func stop() {
        let fd = listener
        listener = -1
        if fd >= 0 { close(fd) }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        do {
            try validatePeer(client)
            var decoder = FrameDecoder()
            var handshaken = false
            while true {
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(client, &bytes, bytes.count)
                if count == 0 { return }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CoreTransportError.systemCallFailed("read", errno)
                }
                for frame in try decoder.append(Data(bytes[0..<count])) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    let response = dispatch(request, handshaken: &handshaken)
                    let output = try FrameEncoder().encode(IPCCodec.encode(response))
                    try writeAll(client, data: output)
                }
            }
        } catch {
            logger.error("Client connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    private func dispatch(_ request: IPCRequest, handshaken: inout Bool) -> IPCResponse {
        guard request.protocolVersion == .v1 else {
            return IPCResponse(id: request.id, error: IPCErrorPayload(code: .protocolIncompatible, message: "Client and Core protocol versions are incompatible.", details: ["clientProtocolVersion": "\(request.protocolVersion.rawValue)", "coreProtocolVersion": "\(ProtocolVersion.v1.rawValue)"]))
        }
        if request.method == .handshake {
            handshaken = true
            return IPCResponse(id: request.id, result: .handshake(HandshakeResult(protocolVersion: .v1, coreVersion: runtime.status.version)))
        }
        guard handshaken else {
            return IPCResponse(id: request.id, error: IPCErrorPayload(code: .invalidRequest, message: "Handshake is required before other requests."))
        }
        guard request.method == .status else {
            return IPCResponse(id: request.id, error: IPCErrorPayload(code: .invalidRequest, message: "Unknown Core method."))
        }
        return IPCResponse(id: request.id, result: .status(CoreStatusResponse(core: runtime.status, protocolVersion: .v1)))
    }

    private func validatePeer(_ client: Int32) throws {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0 else {
            throw CoreTransportError.peerIdentityUnavailable
        }
        guard peerUID == getuid() else { throw CoreTransportError.unauthorizedPeer }
    }

    private func writeAll(_ fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CoreTransportError.systemCallFailed("write", errno)
                }
                offset += count
            }
        }
    }

    private func removeStaleSocketIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: paths.socketPath) else { return }
        var info = stat()
        guard lstat(paths.socketPath, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw CoreTransportError.systemCallFailed("socket endpoint is not a socket", EEXIST)
        }
        guard info.st_uid == getuid() else { throw CoreTransportError.unauthorizedPeer }

        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw CoreTransportError.systemCallFailed("socket", errno) }
        defer { close(probe) }
        var address = try makeUnixAddress(path: paths.socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { throw CoreTransportError.systemCallFailed("another daemon already owns the endpoint", EADDRINUSE) }
        guard errno == ECONNREFUSED || errno == ENOENT else { throw CoreTransportError.systemCallFailed("probe", errno) }
        guard unlink(paths.socketPath) == 0 else { throw CoreTransportError.systemCallFailed("unlink", errno) }
    }
}

final class DaemonLock {
    private let fd: Int32
    init(path: String) throws {
        let value = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard value >= 0 else { throw CoreTransportError.systemCallFailed("open lock", errno) }
        self.fd = value
    }
    func acquire() throws {
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CoreTransportError.systemCallFailed("acquire daemon lock", errno) }
    }
    func release() { _ = flock(fd, LOCK_UN); close(fd) }
}
