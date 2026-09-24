import XCTest
@testable import VaelenCore

private final class StandardPortsXPCFakeConnection: StandardPortsHelperXPCConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var interruption: (@Sendable () -> Void)?
    private var invalidation: (@Sendable () -> Void)?
    private var errorHandler: (@Sendable (Error) -> Void)?
    private var capturedProxy: VaelenStandardPortsHelperProtocol?
    private(set) var configuredRemoteInterface = false
    private(set) var invalidations = 0

    func configureRemoteHelperInterface() { configuredRemoteInterface = true }
    func setHandlers(interruption: @escaping @Sendable () -> Void, invalidation: @escaping @Sendable () -> Void) {
        self.interruption = interruption
        self.invalidation = invalidation
    }
    func resume() {}
    func invalidate() { lock.lock(); invalidations += 1; lock.unlock() }
    func remoteProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> VaelenStandardPortsHelperProtocol? {
        self.errorHandler = errorHandler
        return capturedProxy
    }
    func use(_ proxy: VaelenStandardPortsHelperProtocol) { capturedProxy = proxy }
    func interrupt() { interruption?() }
    func invalidateRemotely() { invalidation?() }
    func failProxy(_ error: Error) { errorHandler?(error) }
}

private final class StandardPortsXPCFakeProxy: NSObject, VaelenStandardPortsHelperProtocol, @unchecked Sendable {
    let install: (((Data?, NSError?) -> Void) -> Void)?
    init(install: (((Data?, NSError?) -> Void) -> Void)? = nil) { self.install = install }
    func inspectionData(with reply: @escaping (Data?, NSError?) -> Void) { reply(nil, nil) }
    func installForwarding(with reply: @escaping (Data?, NSError?) -> Void) { install?(reply) }
    func removeForwarding(acquisition: Data, with reply: @escaping (NSError?) -> Void) { reply(nil) }
    func inspectTestResolver(with reply: @escaping (Data?, NSError?) -> Void) { reply(nil, nil) }
    func installTestResolver(port: Int, replacing: Data, with reply: @escaping (Data?, NSError?) -> Void) { reply(nil, nil) }
    func restoreTestResolver(expected: Data, preimage: Data, with reply: @escaping (NSError?) -> Void) { reply(nil) }
}

final class HelperRequestCompletionTests: XCTestCase {
    func testFirstTerminalXPCResultWinsAndLaterFailureDoesNotResumeTwice() async throws {
        let completionTask = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let completion = HelperRequestCompletion(continuation)
                completion.succeed(Data([1, 2, 3]))
                completion.fail(DNSCapabilityError.privilegeUnavailable)
                completion.succeed(Data([4]))
            }
        }

        let result = try await completionTask.value
        XCTAssertEqual(result, Data([1, 2, 3]))
    }

    func testStandardPortsMutationConfiguresRemoteHelperInterfaceAndReturnsAcquisition() async throws {
        let connection = StandardPortsXPCFakeConnection()
        let empty = StandardPortsFileSnapshot(exists: false, bytes: nil, owner: nil, group: nil, mode: nil)
        let acquisition = StandardPortsAcquisition(preimagePFConf: empty, preimageAnchor: empty, writtenPFConf: empty, writtenAnchor: empty, changedPFConf: false, changedAnchor: false, forwardingWasActive: false, pfToken: nil)
        connection.use(StandardPortsXPCFakeProxy { reply in reply(try? JSONEncoder().encode(acquisition), nil) })
        let gateway = HelperStandardPortsPrivileged(serviceName: "test", requestTimeout: 1, connectionFactory: { _ in connection })

        let result = try await gateway.installForwarding()

        XCTAssertTrue(connection.configuredRemoteInterface)
        XCTAssertEqual(result, acquisition)
    }

    func testStandardPortsXPCInterruptionCompletesOnceWithBoundedFailure() async {
        let connection = StandardPortsXPCFakeConnection()
        connection.use(StandardPortsXPCFakeProxy())
        let gateway = HelperStandardPortsPrivileged(serviceName: "test", requestTimeout: 0.05, connectionFactory: { _ in connection })

        let request = Task { try await gateway.installForwarding() }
        try? await Task.sleep(for: .milliseconds(10))
        connection.interrupt()
        do {
            _ = try await request.value
            XCTFail("Expected bounded helper failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("PF helper"))
        }
        connection.invalidateRemotely()
        connection.failProxy(StandardPortsPrivilegeError.unavailable)
        XCTAssertGreaterThan(connection.invalidations, 0)
    }
}
