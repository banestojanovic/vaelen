import XCTest
import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

final class DispatcherTests: XCTestCase {
    func testDispatcherRejectsUnknownMethodStructurally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry)

        let result = await dispatcher.dispatch(IPCRequest(rawMethod: "project.future"), handshaken: true)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
    }
}
