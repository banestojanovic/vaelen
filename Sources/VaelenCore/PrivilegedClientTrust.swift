/// Code-signing identity facts extracted from a validated macOS SecCode.
public struct VaelenSigningIdentity: Equatable, Sendable {
    public let identifier: String
    public let teamIdentifier: String

    public init(identifier: String, teamIdentifier: String) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
    }
}

/// The daemon accepts only the bundled Vaelen Core signed by the daemon's own
/// team. Callers must first validate both SecCode objects against Apple's trust chain.
public enum VaelenPrivilegedClientTrust {
    public static let coreIdentifier = "vaelend"
    public static let helperIdentifier = "dev.vaelen.privileged-helper"

    public static func permits(client: VaelenSigningIdentity?, helper: VaelenSigningIdentity?) -> Bool {
        guard let client, let helper else { return false }
        return client.identifier == coreIdentifier
            && helper.identifier == helperIdentifier
            && !client.teamIdentifier.isEmpty
            && client.teamIdentifier == helper.teamIdentifier
    }
}
