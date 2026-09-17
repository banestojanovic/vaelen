import Foundation

public enum CoreState: String, Codable, Sendable {
    case running
}

public struct CoreRuntimeStatus: Codable, Equatable, Sendable {
    public let state: CoreState
    public let version: String
    public let pid: Int32

    public init(state: CoreState, version: String, pid: Int32) {
        self.state = state
        self.version = version
        self.pid = pid
    }
}

public struct CoreRuntime: Sendable {
    public let status: CoreRuntimeStatus

    public init(version: String, pid: Int32 = Int32(getpid())) {
        self.status = CoreRuntimeStatus(state: .running, version: version, pid: pid)
    }
}
