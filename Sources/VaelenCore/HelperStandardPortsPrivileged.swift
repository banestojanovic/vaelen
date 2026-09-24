import Foundation

/// Production DNS gateway. The privileged protocol exposes only the fixed
/// resolver target; snapshots are data and never include caller-selected paths.
public struct HelperPrivilegedDNS: PrivilegedDNSHelper {
    private let serviceName: String
    public init(serviceName: String = "dev.vaelen.privileged-helper") { self.serviceName = serviceName }

    public func inspectTestResolver() async throws -> ResolverInspection {
        let data = try await call { proxy, done in proxy.inspectTestResolver { data, error in done(data, error) } }
        let snapshot = try JSONDecoder().decode(ResolverFileSnapshot.self, from: data)
        return ResolverInspection(exists: snapshot.exists, content: snapshot.bytes.map { String(decoding: $0, as: UTF8.self) }, ownership: snapshot.exists ? .external : .none, snapshot: snapshot)
    }
    public func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot {
        guard (1024...65535).contains(port), let replacing else { throw DNSCapabilityError.resolverConflict("Invalid fixed-target resolver acquisition request") }
        let data = try JSONEncoder().encode(replacing)
        let result = try await call { proxy, done in proxy.installTestResolver(port: port, replacing: data) { data, error in done(data, error) } }
        return try JSONDecoder().decode(ResolverFileSnapshot.self, from: result)
    }
    public func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws {
        let expectedData = try JSONEncoder().encode(expected), previousData = try JSONEncoder().encode(restore)
        _ = try await call { proxy, done in proxy.restoreTestResolver(expected: expectedData, preimage: previousData) { error in done(Data(), error) } }
    }

    private func call(_ operation: @escaping (VaelenStandardPortsHelperProtocol, @escaping (Data?, NSError?) -> Void) -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let completion = HelperRequestCompletion(continuation)
            let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: VaelenStandardPortsHelperProtocol.self)
            connection.interruptionHandler = {
                connection.invalidate()
                completion.fail(DNSCapabilityError.privilegeUnavailable)
            }
            connection.invalidationHandler = {
                completion.fail(DNSCapabilityError.privilegeUnavailable)
            }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                connection.invalidate()
                _ = error // detailed XPC errors are intentionally presented as helper unavailability
                completion.fail(DNSCapabilityError.privilegeUnavailable)
            }) as? VaelenStandardPortsHelperProtocol else {
                connection.invalidate()
                completion.fail(DNSCapabilityError.privilegeUnavailable)
                return
            }
            operation(proxy) { data, error in
                if let error {
                    connection.invalidate()
                    completion.fail(DNSCapabilityError.resolverConflict(error.localizedDescription))
                } else if let data {
                    completion.succeed(data)
                    connection.invalidate()
                } else {
                    connection.invalidate()
                    completion.fail(DNSCapabilityError.privilegeUnavailable)
                }
            }

            // A lost helper can otherwise leave DNS commands and the GUI busy
            // state waiting on a reply forever. This bound is only for one
            // privileged request; it does not infer whether a mutation ran.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                connection.invalidate()
                completion.fail(DNSCapabilityError.privilegeUnavailable)
            }
        }
    }
}

/// NSXPC may report an interruption/invalidation and subsequently invoke the
/// proxy error handler. Gate all terminal paths so the checked continuation is
/// resumed exactly once.
final class HelperRequestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

    func succeed(_ data: Data) { finish { $0.resume(returning: data) } }
    func fail(_ error: Error) { finish { $0.resume(throwing: error) } }

    private func finish(_ action: (CheckedContinuation<Data, Error>) -> Void) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let pending { action(pending) }
    }
}

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
