import XCTest
@testable import VaelenCore

final class CoreRuntimeTests: XCTestCase {
    func testRuntimeProvidesTypedAuthoritativeStatus() {
        let runtime = CoreRuntime(version: "0.0.1-dev", pid: 1234)

        XCTAssertEqual(runtime.status.state, .running)
        XCTAssertEqual(runtime.status.version, "0.0.1-dev")
        XCTAssertEqual(runtime.status.pid, 1234)
    }
}
