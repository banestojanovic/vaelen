import Foundation
import XCTest
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

final class NodeIPCTests: XCTestCase {
    func testNodeEnvelopesRoundTripWithoutPHPShapeCollisions() throws {
        let params = RequestParams.nodeCommand(.init(.init(action: .isolate, version: try NodeVersion("24.22.1"), selector: "project", workingDirectory: "/tmp/project")))
        XCTAssertEqual(try IPCCodec.decode(RequestParams.self, from: IPCCodec.encode(params)), params)
        let record = NodeProjectRecord(id: ProjectID(), name: "project", path: "/tmp/project", pin: try NodeVersion("24.22.1"))
        let response = ResponseResult.nodeCommand(.init(.init(releases: NodeRelease.reviewed, selections: [.init(record: record, runtimeAvailable: false)])))
        XCTAssertEqual(try IPCCodec.decode(ResponseResult.self, from: IPCCodec.encode(response)), response)
        let php = ResponseResult.projectPHPSelections(.init(selections: []))
        XCTAssertEqual(try IPCCodec.decode(ResponseResult.self, from: IPCCodec.encode(php)), php)
        let phpRequest = RequestParams.phpVersion(.init(version: "8.4.23"))
        XCTAssertEqual(try IPCCodec.decode(RequestParams.self, from: IPCCodec.encode(phpRequest)), phpRequest)
    }

    func testCoreListsMissingPinAndClearsMissingProjectWithoutChangingPHP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let repository = ProjectRepository(store: store)
        let id = ProjectID()
        try repository.upsert(.init(id: id, name: "missing", canonicalPath: root.appendingPathComponent("missing").path, customName: nil))
        try repository.setPHPOverride("8.4.23", for: id)
        try repository.setNodeOverride(try NodeVersion("24.22.1"), for: id)
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: ProjectRegistry(store: store), node: .init(layout: layout), serviceIntents: .init(url: root.appendingPathComponent("intents.json")))
        func request(_ action: NodeCommandAction, version: NodeVersion? = nil, selector: String? = nil) throws -> IPCRequest {
            let value = IPCRequest(method: .nodeCommand, params: .nodeCommand(.init(.init(action: action, version: version, selector: selector, workingDirectory: root.path))))
            return try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(value))
        }
        let listed = await dispatcher.dispatch(try request(.isolated), handshaken: true).response
        guard case .nodeCommand(let result) = listed.result else { return XCTFail("Expected unique Node response. \(listed)") }
        XCTAssertEqual(result.nodeResult.selections.count, 1)
        XCTAssertEqual(result.nodeResult.selections[0].projectID, id)
        XCTAssertEqual(result.nodeResult.selections[0].availability, .missing)
        XCTAssertFalse(result.nodeResult.selections[0].runtimeAvailable)
        let failed = await dispatcher.dispatch(try request(.isolate, version: NodeVersion("26.12.1"), selector: id.description), handshaken: true).response
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(try repository.nodeRecords().first?.pin?.description, "24.22.1")
        let cleared = await dispatcher.dispatch(try request(.useDefault, selector: id.description), handshaken: true).response
        XCTAssertNil(cleared.error)
        XCTAssertNil(try repository.nodeRecords().first?.pin)
        XCTAssertEqual(try repository.phpOverride(for: id), "8.4.23")
    }
}
