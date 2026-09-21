import XCTest
@testable import VaelenCore

final class LifecycleProcessIdentityTests: XCTestCase {
    private let path = "/Applications/Vaelen.app/Contents/Resources/vaelend"
    private func identity(pid: Int32 = 42, start: String = "10.20", uid: UInt32 = 501, path: String? = nil) -> LifecycleProcessIdentity { .init(pid: pid, startIdentity: start, uid: uid, executablePath: path ?? self.path) }
    func testSamePIDWithChangedStartIdentityFailsClosed() { XCTAssertEqual(LifecycleProcessIdentityValidator.evaluate(first: identity(), second: identity(start: "10.21"), expectedPath: path, expectedUID: 501), .unknown) }
    func testChangedExecutableAndUIDDoNotMatch() {
        XCTAssertEqual(LifecycleProcessIdentityValidator.evaluate(first: identity(path: "/tmp/other"), second: identity(path: "/tmp/other"), expectedPath: path, expectedUID: 501), .false)
        XCTAssertEqual(LifecycleProcessIdentityValidator.evaluate(first: identity(uid: 502), second: identity(uid: 502), expectedPath: path, expectedUID: 501), .false)
    }
    func testMissingProcessAndRecheckFailureFailClosed() {
        XCTAssertEqual(LifecycleProcessIdentityValidator.evaluate(first: nil, second: nil, expectedPath: path, expectedUID: 501), .false)
        XCTAssertEqual(LifecycleProcessIdentityValidator.evaluate(first: identity(), second: nil, expectedPath: path, expectedUID: 501), .unknown)
        XCTAssertEqual(LifecycleProcessIdentityValidator.evaluate(first: identity(), second: identity(pid: 43), expectedPath: path, expectedUID: 501), .unknown)
    }
    func testInabilityToEstablishIdentityFailsClosed() { XCTAssertEqual(LifecycleProcessIdentityValidator.evaluate(first: identity(), second: identity(), expectedPath: path, expectedUID: 501, readable: false), .unknown) }
}
