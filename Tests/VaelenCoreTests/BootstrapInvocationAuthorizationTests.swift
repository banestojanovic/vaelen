import XCTest
@testable import VaelenCore

final class BootstrapInvocationAuthorizationTests: XCTestCase {
    private struct Authenticator: BootstrapReceiptAuthenticator {
        func mac(for _: Data) throws -> String { String(repeating: "0", count: 64) }
        func verifies(mac: String, for _: Data) throws -> Bool { mac == String(repeating: "0", count: 64) }
    }
    private actor Platform: BootstrapPlatform {
        var calls = 0
        func registrationObservation() async -> ObservationValue { calls == 0 ? .false : .true }
        func preflight() async -> Bool { true }
        func register() async throws { calls += 1 }
    }
    private func store() throws -> SQLiteStateStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-bootstrap-auth-").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
    }

    func testAuthorizationIsUnpredictableAndOneTime() throws {
        let store = try store()
        let first = try store.mintBootstrapInvocation()
        let second = try store.mintBootstrapInvocation()
        XCTAssertNotEqual(first.token, second.token)
        try store.consumeBootstrapInvocation(token: first.token)
        XCTAssertThrowsError(try store.consumeBootstrapInvocation(token: first.token))
        try store.consumeBootstrapInvocation(token: second.token)
    }

    func testForgedWrongIdentityAndWrongUserFailClosed() throws {
        let store = try store()
        let authorization = try store.mintBootstrapInvocation(user: "alice", uid: 501)
        XCTAssertThrowsError(try store.consumeBootstrapInvocation(token: authorization.token + "x", user: "alice", uid: 501))
        XCTAssertThrowsError(try store.consumeBootstrapInvocation(token: authorization.token, user: "mallory", uid: 501))
        let target = authorization.target
        let alteredTargets = [
            LifecycleTargetIdentity(bundleID: "other", agentLabel: target.agentLabel, bundleProgram: target.bundleProgram, endpoint: target.endpoint),
            LifecycleTargetIdentity(bundleID: target.bundleID, agentLabel: "other.agent", bundleProgram: target.bundleProgram, endpoint: target.endpoint),
            LifecycleTargetIdentity(bundleID: target.bundleID, agentLabel: target.agentLabel, bundleProgram: "Contents/Resources/other", endpoint: target.endpoint),
            LifecycleTargetIdentity(bundleID: target.bundleID, agentLabel: target.agentLabel, bundleProgram: target.bundleProgram, endpoint: "/tmp/other.sock")
        ]
        for alteredTarget in alteredTargets {
            XCTAssertThrowsError(try store.consumeBootstrapInvocation(token: authorization.token, target: alteredTarget, user: "alice", uid: 501))
        }
        XCTAssertThrowsError(try store.consumeBootstrapInvocation(token: authorization.token, operation: "unregister", user: "alice", uid: 501))
        XCTAssertThrowsError(try store.consumeBootstrapInvocation(token: authorization.token, user: "alice", uid: 502))
        try store.consumeBootstrapInvocation(token: authorization.token, user: "alice", uid: 501)
    }

    func testAuthorizationIsBoundToExactControllerPath() throws {
        let store = try store()
        let authorization = try store.mintBootstrapInvocation(controllerPath: LifecycleCanonicalIdentity.validationControllerURL.path)
        XCTAssertThrowsError(try store.consumeBootstrapInvocation(token: authorization.token, controllerPath: LifecycleCanonicalIdentity.installedControllerURL.path))
        try store.consumeBootstrapInvocation(token: authorization.token, controllerPath: LifecycleCanonicalIdentity.validationControllerURL.path)
    }

    func testExpiredAuthorizationFailsClosed() throws {
        let store = try store()
        let authorization = try store.mintBootstrapInvocation(expiresAt: Date().addingTimeInterval(1))
        XCTAssertThrowsError(try store.consumeBootstrapInvocation(token: authorization.token, now: Date().addingTimeInterval(2)))
    }

    func testValidAuthorizationAllowsExactlyOneBootstrapInvocation() async throws {
        let store = try store()
        let authorization = try store.mintBootstrapInvocation()
        let platform = Platform()
        let executor = CoreAbsentBootstrapExecutor(store: store, platform: platform,
                                                    lockEndpoint: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("runtime/sockets/core.sock").path,
                                                    authenticator: Authenticator())
        let receipt = try await executor.execute(explicitInvocationToken: authorization.token)
        XCTAssertEqual(receipt.phase, .succeeded)
        XCTAssertThrowsError(try store.consumeBootstrapInvocation(token: authorization.token))
        executor.releaseHandoffLock()
    }
}
