import Foundation

/// Production Core-side gateway to the signed privileged helper.
///
/// Observation stays user-space (world-readable files); only mutation goes
/// over XPC. Any connection or authorization failure surfaces as
/// StandardPortsPrivilegeError.unavailable so Core reports truthfully that
/// standard ports require Vaelen.app approval.
public struct HelperStandardPortsPrivileged: StandardPortsPrivileged {
    private let serviceName: String
    public init(serviceName: String = "dev.vaelen.privileged-helper") { self.serviceName = serviceName }

    public func inspectForwarding() async throws -> StandardPortsInspection {
        // World-readable; no privilege needed and no reason to round-trip XPC.
        StandardPortsInspection(
            anchorContent: try? String(contentsOfFile: StandardPortsForwardingPolicy.anchorPath, encoding: .utf8),
            pfConfContent: try? String(contentsOfFile: StandardPortsForwardingPolicy.pfConfPath, encoding: .utf8),
            pfEnabled: nil
        )
    }

    public func installForwarding() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
            connection.exportedInterface = NSXPCInterface(with: VaelenStandardPortsHelperProtocol.self)
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                connection.invalidate()
                continuation.resume(throwing: StandardPortsPrivilegeError.unavailable)
            }) as? VaelenStandardPortsHelperProtocol else {
                connection.invalidate()
                continuation.resume(throwing: StandardPortsPrivilegeError.unavailable)
                return
            }
            proxy.installForwarding { token, _ in
                connection.invalidate()
                continuation.resume(returning: token as String?)
            }
        }
    }

    public func removeForwarding(pfToken: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
            connection.exportedInterface = NSXPCInterface(with: VaelenStandardPortsHelperProtocol.self)
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                connection.invalidate()
                continuation.resume(throwing: StandardPortsPrivilegeError.unavailable)
            }) as? VaelenStandardPortsHelperProtocol else {
                connection.invalidate()
                continuation.resume(throwing: StandardPortsPrivilegeError.unavailable)
                return
            }
            proxy.removeForwarding(pfToken: pfToken as NSString?) { error in
                connection.invalidate()
                if let error {
                    if error.domain == "dev.vaelen.privileged-helper", error.code == StandardPortsHelperError.ownershipMismatch.rawValue {
                        continuation.resume(throwing: StandardPortsError.ownershipMismatch)
                    } else {
                        continuation.resume(throwing: StandardPortsPrivilegeError.unavailable)
                    }
                    return
                }
                continuation.resume()
            }
        }
    }
}
