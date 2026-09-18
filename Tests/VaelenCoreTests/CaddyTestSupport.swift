import Foundation
import Darwin
import VaelenCore

enum CaddyTestSupport {
    static func configuration() throws -> CaddyRuntimeConfiguration {
        let httpPort = try availablePort()
        var httpsPort = try availablePort()
        while httpsPort == httpPort {
            httpsPort = try availablePort()
        }
        return CaddyRuntimeConfiguration(httpPort: httpPort, httpsPort: httpsPort)
    }

    static func removeIfPresent(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CaddyRuntimeError.processFailed("socket") }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw CaddyRuntimeError.processFailed("bind") }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw CaddyRuntimeError.processFailed("getsockname") }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }
}
