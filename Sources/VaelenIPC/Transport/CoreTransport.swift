import Foundation
import Darwin

public protocol CoreTransport: Sendable {
    func connect() async throws
    func write(_ data: Data) async throws
    func read() async throws -> Data
    func disconnect() async
}

public enum CoreTransportError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case notConnected
    case peerIdentityUnavailable
    case unauthorizedPeer
    case systemCallFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Vaelen Core is unavailable. Try again or relaunch Vaelen."
        case .notConnected:
            return "The connection to Vaelen Core is no longer available. Retry the operation."
        case .peerIdentityUnavailable:
            return "Vaelen Core could not verify the local connection."
        case .unauthorizedPeer:
            return "Vaelen Core rejected the local connection as unauthorized."
        case .systemCallFailed(let operation, let code):
            let reason = String(cString: strerror(code))
            return "Vaelen Core IPC \(operation) failed: \(reason) (error \(code))."
        }
    }
}
