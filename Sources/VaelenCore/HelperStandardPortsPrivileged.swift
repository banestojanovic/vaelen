import Foundation
import OSLog

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

    @discardableResult func succeed(_ data: Data) -> Bool { finish { $0.resume(returning: data) } }
    @discardableResult func fail(_ error: Error) -> Bool { finish { $0.resume(throwing: error) } }

    private func finish(_ action: (CheckedContinuation<Data, Error>) -> Void) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let pending { action(pending) }
        return pending != nil
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
    private let requestTimeout: TimeInterval
    private let connectionFactory: @Sendable (String) -> any StandardPortsHelperXPCConnection
    private let logger = Logger(subsystem: "dev.vaelen.daemon", category: "standard-ports-helper-xpc")

    public init(serviceName: String = "dev.vaelen.privileged-helper") {
        self.init(serviceName: serviceName, requestTimeout: 10, connectionFactory: { SystemStandardPortsHelperXPCConnection(serviceName: $0) })
    }

    init(serviceName: String, requestTimeout: TimeInterval, connectionFactory: @escaping @Sendable (String) -> any StandardPortsHelperXPCConnection) {
        self.serviceName = serviceName
        self.requestTimeout = requestTimeout
        self.connectionFactory = connectionFactory
    }

    public func inspectForwarding() async throws -> StandardPortsInspection {
        logger.debug("PF inspection request started")
        do {
            let data = try await call { $0.inspectionData(with: $1) }
            guard let value = try? JSONDecoder().decode(StandardPortsHelperInspection.self, from: data) else { throw StandardPortsPrivilegeError.unavailable }
            logger.debug("PF inspection response decoded; PF enabled state and forwarding state were returned")
            return StandardPortsInspection(anchorContent: value.anchorContent, pfConfContent: value.pfConfContent, pfEnabled: value.pfEnabled, forwardingActive: value.forwardingActive)
        } catch {
            logger.error("PF inspection request failed: \(String(describing: error), privacy: .public)")
            throw StandardPortsPrivilegeError.unavailable
        }
    }

    public func installForwarding() async throws -> StandardPortsAcquisition {
        logger.info("PF helper install request started")
        do {
            let data = try await call { $0.installForwarding(with: $1) }
            guard let acquisition = try? JSONDecoder().decode(StandardPortsAcquisition.self, from: data) else {
                throw StandardPortsError.unavailable("PF helper returned an invalid acquisition response")
            }
            logger.info("PF helper install acquisition response received")
            return acquisition
        } catch let error as StandardPortsError {
            throw error
        } catch let error as NSError {
            if error.domain == "dev.vaelen.privileged-helper", error.code == StandardPortsHelperError.ownershipMismatch.rawValue {
                throw StandardPortsError.externalConflict(error.localizedDescription)
            }
            throw StandardPortsError.unavailable("PF helper could not verify or activate forwarding: \(error.localizedDescription)")
        } catch {
            throw StandardPortsError.unavailable("PF helper request failed: \(error.localizedDescription)")
        }
    }

    public func removeForwarding(acquisition: StandardPortsAcquisition) async throws {
        let data = try JSONEncoder().encode(acquisition)
        do {
            _ = try await call { proxy, reply in
                proxy.removeForwarding(acquisition: data) { error in reply(Data(), error) }
            }
        } catch let error as NSError where error.domain == "dev.vaelen.privileged-helper" && error.code == StandardPortsHelperError.ownershipMismatch.rawValue {
            throw StandardPortsError.ownershipMismatch
        } catch let error as StandardPortsError {
            throw error
        } catch {
            throw StandardPortsPrivilegeError.unavailable
        }
    }

    private func call(_ operation: @escaping (VaelenStandardPortsHelperProtocol, @escaping (Data?, NSError?) -> Void) -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let completion = HelperRequestCompletion(continuation)
            let connection = connectionFactory(serviceName)
            connection.configureRemoteHelperInterface()
            connection.setHandlers(
                interruption: {
                    self.logger.error("PF helper XPC connection interrupted")
                    connection.invalidate()
                    completion.fail(StandardPortsPrivilegeError.unavailable)
                },
                invalidation: {
                    completion.fail(StandardPortsPrivilegeError.unavailable)
                }
            )
            connection.resume()
            guard let proxy = connection.remoteProxy(errorHandler: { error in
                self.logger.error("PF helper XPC proxy failed: \(String(describing: error), privacy: .public)")
                connection.invalidate()
                completion.fail(error)
            }) else {
                connection.invalidate()
                completion.fail(StandardPortsPrivilegeError.unavailable)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requestTimeout) {
                guard completion.fail(StandardPortsPrivilegeError.unavailable) else { return }
                self.logger.error("PF helper XPC request timed out after \(self.requestTimeout, privacy: .public) seconds")
                connection.invalidate()
            }
            operation(proxy) { data, error in
                if let error {
                    completion.fail(error)
                } else if let data {
                    completion.succeed(data)
                } else {
                    completion.fail(StandardPortsPrivilegeError.unavailable)
                }
                connection.invalidate()
            }
        }
    }
}

protocol StandardPortsHelperXPCConnection: AnyObject, Sendable {
    func configureRemoteHelperInterface()
    func setHandlers(interruption: @escaping @Sendable () -> Void, invalidation: @escaping @Sendable () -> Void)
    func resume()
    func invalidate()
    func remoteProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> VaelenStandardPortsHelperProtocol?
}

private final class SystemStandardPortsHelperXPCConnection: StandardPortsHelperXPCConnection, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(serviceName: String) { connection = NSXPCConnection(machServiceName: serviceName, options: .privileged) }
    func configureRemoteHelperInterface() {
        connection.remoteObjectInterface = NSXPCInterface(with: VaelenStandardPortsHelperProtocol.self)
    }
    func setHandlers(interruption: @escaping @Sendable () -> Void, invalidation: @escaping @Sendable () -> Void) {
        connection.interruptionHandler = interruption
        connection.invalidationHandler = invalidation
    }
    func resume() { connection.resume() }
    func invalidate() { connection.invalidate() }
    func remoteProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> VaelenStandardPortsHelperProtocol? {
        connection.remoteObjectProxyWithErrorHandler(errorHandler) as? VaelenStandardPortsHelperProtocol
    }
}
