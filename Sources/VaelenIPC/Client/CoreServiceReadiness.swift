public enum CoreServiceReadiness: Equatable, Sendable {
    case checking
    case ready
    case attention
    case unavailable

    /// Summarizes a bounded set of independent service-status reads. A reported
    /// restoration issue takes precedence over in-flight reads so the UI can
    /// stop presenting an indefinite loader as soon as Core confirms trouble.
    public static func resolve(
        serviceIssues: [String: String],
        requiredReadCount: Int,
        completedReadCount: Int,
        successfulReadCount: Int,
        timedOut: Bool = false
    ) -> CoreServiceReadiness {
        if !serviceIssues.isEmpty { return .attention }
        if timedOut { return .unavailable }
        guard requiredReadCount >= 0, completedReadCount >= requiredReadCount else { return .checking }
        guard successfulReadCount >= requiredReadCount else { return .unavailable }
        return .ready
    }
}
