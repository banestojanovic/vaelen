import Foundation

public protocol CoreTransport: Sendable {
    func connect() async throws
    func write(_ data: Data) async throws
    func read() async throws -> Data
    func disconnect() async
}

public enum CoreTransportError: Error, Equatable, Sendable {
    case unavailable
    /// The peer accepted the connection and then closed it. This is not
    /// evidence that the endpoint was absent.
    case peerClosed
    case notConnected
    case peerIdentityUnavailable
    case unauthorizedPeer
    case systemCallFailed(String, Int32)
}
