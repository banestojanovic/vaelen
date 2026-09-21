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
    /// Set only after Core has completed the initialization required to serve
    /// product requests. The default preserves the existing test/runtime
    /// construction contract.
    public let isReady: Bool

    public init(version: String, pid: Int32 = Int32(getpid()), isReady: Bool = true) {
        self.status = CoreRuntimeStatus(state: .running, version: version, pid: pid)
        self.isReady = isReady
    }
}
