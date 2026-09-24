import XCTest
import VaelenIPC

final class CoreUnavailableTests: XCTestCase {
    func testTransportFailuresHaveBoundedUserFacingDescriptions() {
        let message = CoreTransportError.systemCallFailed("connect", 2).localizedDescription
        let unavailable = CoreClientError.coreUnavailable.localizedDescription

        XCTAssertTrue(message.contains("Vaelen Core IPC connect failed"))
        XCTAssertFalse(message.contains("VaelenIPC.CoreTransportError error 2"))
        XCTAssertLessThanOrEqual(message.count, 200)
        XCTAssertEqual(unavailable, "Vaelen Core is unavailable. Try again or relaunch Vaelen.")
    }

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
