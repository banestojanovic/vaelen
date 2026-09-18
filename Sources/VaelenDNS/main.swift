import Foundation
import Darwin
import VaelenDNSCore

let arguments = CommandLine.arguments
let port = Int(arguments.drop(while: { $0 != "--port" }).dropFirst().first ?? "53535") ?? 53535
guard (1024...65535).contains(port) else { exit(64) }

let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
defer { close(socketFD) }
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = UInt16(port).bigEndian
address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }

while true {
    var buffer = [UInt8](repeating: 0, count: 4096)
    var peer = sockaddr_storage()
    var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let count = withUnsafeMutablePointer(to: &peer) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &buffer, buffer.count, 0, $0, &peerLength) }
    }
    guard count > 0, let reply = DNSWire.response(for: Array(buffer.prefix(Int(count)))) else { continue }
    reply.withUnsafeBytes { bytes in
        withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(socketFD, bytes.baseAddress, reply.count, 0, $0, peerLength) }
        }
    }
}
