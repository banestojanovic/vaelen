import Foundation

/// XPC contract for Vaelen's privileged standard-ports helper.
///
/// The API is deliberately parameterless apart from an opaque PF token:
/// the helper implements Vaelen's fixed forwarding policy compiled into
/// StandardPortsForwardingPolicy and never accepts addresses, ports, file
/// paths, or PF syntax from callers. A compromised Core therefore cannot
/// turn the helper into generic root execution.
@objc public protocol VaelenStandardPortsHelperProtocol {
    /// Returns JSON-encoded StandardPortsHelperInspection.
    func inspectionData(with reply: @escaping (Data?, NSError?) -> Void)
    /// Installs the fixed policy. Replies with the PF enable token when the
    /// helper enabled PF, nil when PF was already enabled.
    func installForwarding(with reply: @escaping (NSString?, NSError?) -> Void)
    /// Removes the fixed policy. pfToken is the opaque token previously
    /// issued by installForwarding; nil/unknown tokens leave PF enabled.
    func removeForwarding(pfToken: NSString?, with reply: @escaping (NSError?) -> Void)
    /// DNS operations have a fixed target compiled into the helper. Snapshot
    /// data contains file state only; it cannot select a path.
    func inspectTestResolver(with reply: @escaping (Data?, NSError?) -> Void)
    func installTestResolver(port: Int, replacing: Data, with reply: @escaping (Data?, NSError?) -> Void)
    func restoreTestResolver(expected: Data, preimage: Data, with reply: @escaping (NSError?) -> Void)
}

public struct StandardPortsHelperInspection: Codable, Sendable {
    public let anchorContent: String?
    public let pfConfContent: String?
    public let pfEnabled: Bool?
    public init(anchorContent: String?, pfConfContent: String?, pfEnabled: Bool?) { self.anchorContent = anchorContent; self.pfConfContent = pfConfContent; self.pfEnabled = pfEnabled }
}

public enum StandardPortsHelperError: Int, Error {
    case ownershipMismatch = 100
    case pfFailure = 101
    case filesystemFailure = 102

    public var nsError: NSError {
        NSError(domain: "dev.vaelen.privileged-helper", code: rawValue, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private var description: String {
        switch self {
        case .ownershipMismatch: return "PF state is owned externally; refusing to modify it"
        case .pfFailure: return "pfctl operation failed"
        case .filesystemFailure: return "privileged file operation failed"
        }
    }
}
