import Darwin
import Foundation

public final class UnixSocketTransport: CoreTransport, @unchecked Sendable {
    private let path: String
    private var fileDescriptor: Int32 = -1
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    public func connect() async throws {
        let path = self.path
        let descriptor = try await Task.detached { () throws -> Int32 in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CoreTransportError.systemCallFailed("socket", errno) }
            var address = try makeUnixAddress(path: path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                let error = errno
                close(fd)
                if error == ENOENT || error == ECONNREFUSED { throw CoreTransportError.unavailable }
                throw CoreTransportError.systemCallFailed("connect", error)
            }
            return fd
        }.value

        setDescriptor(descriptor)
    }

    public func write(_ data: Data) async throws {
        let fd = try descriptor()
        try await Task.detached {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < data.count {
                    let result = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw CoreTransportError.systemCallFailed("write", errno)
                    }
                    offset += result
                }
            }
        }.value
    }

    public func read() async throws -> Data {
        let fd = try descriptor()
        return try await Task.detached {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { return Data(buffer[0..<count]) }
                if count == 0 { throw CoreTransportError.peerClosed }
                if errno != EINTR { throw CoreTransportError.systemCallFailed("read", errno) }
            }
        }.value
    }

    public func disconnect() async {
        let fd = takeDescriptor()
        if fd >= 0 { close(fd) }
    }

    private func descriptor() throws -> Int32 {
        let fd = currentDescriptor()
        guard fd >= 0 else { throw CoreTransportError.notConnected }
        return fd
    }

    private func currentDescriptor() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fileDescriptor
    }

    private func setDescriptor(_ descriptor: Int32) {
        lock.lock()
        fileDescriptor = descriptor
        lock.unlock()
    }

    private func takeDescriptor() -> Int32 {
        lock.lock()
        let descriptor = fileDescriptor
        fileDescriptor = -1
        lock.unlock()
        return descriptor
    }
}

public func makeUnixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw CoreEndpointError.socketPathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes)
    }
    return address
}
