import XCTest
import VaelenIPC

final class CoreUnavailableTests: XCTestCase {
    func testMissingCoreSocketFailsQuicklyWithoutWaitingForFallback() async throws {
        let missingSocket = "/tmp/v-\(UUID().uuidString.prefix(8)).sock"
        let client = VaelenCoreClient(
            transport: UnixSocketTransport(path: missingSocket),
            identity: .init(name: "val-test", version: "test")
        )
        let start = ContinuousClock.now
        do {
            try await client.connect()
            XCTFail("A missing Core socket must not connect")
        } catch CoreClientError.coreUnavailable {
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }
}
