import Foundation
import XCTest
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

final class ServiceInstanceInventoryTests: XCTestCase {
    func testReadOnlyRequestReturnsEmptyAndPopulatedTypedCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-inventory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let repository = ServiceInstanceRepository(store: store)
        let dispatcher = try CoreRequestDispatcher(runtime: .init(version: "test", pid: 1), registry: registry, serviceInstances: repository)

        let emptyResponse = await dispatcher.dispatch(IPCRequest(method: .serviceInstances), handshaken: true).response
        guard case .serviceInstances(let empty) = emptyResponse.result else { return XCTFail("expected empty inventory") }
        XCTAssertTrue(empty.entries.isEmpty)

        let project = LinkedProjectRecord(id: ProjectID(), name: "app", canonicalPath: "/tmp/app")
        try ProjectRepository(store: store).upsert(project)
        let name = try ProjectInstanceName("shared")
        let record = try ServiceInstanceRecord(id: .init(kind: .mailpit, name: name), packageIdentifier: "vendor/mailpit@exact", endpoint: .mailpit(smtpPort: 1026, httpPort: 8026), dataDirectory: "/data/mailpit")
        try repository.saveInstance(record)
        let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("mail"), kind: .mailpit, instance: name, version: "exact")
        try repository.replaceProjectClaims([binding], for: project.id)
        try repository.setManualClaim(for: record.id, claimed: true)
        let response = await dispatcher.dispatch(IPCRequest(method: .serviceInstances), handshaken: true).response
        guard case .serviceInstances(let result) = response.result else { return XCTFail("expected populated inventory") }
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.instance.kind, .mailpit)
        XCTAssertEqual(entry.instance.name, name)
        XCTAssertEqual(entry.instance.packageIdentifier, "vendor/mailpit@exact")
        XCTAssertEqual(entry.instance.endpoint, .mailpit(smtpPort: 1026, httpPort: 8026))
        XCTAssertEqual(entry.instance.dataDirectory, "/data/mailpit")
        XCTAssertEqual(entry.owners, [.manual, .project(projectID: project.id, alias: binding.alias, version: "exact")])
        let decoded = try IPCCodec.decode(ResponseResult.self, from: IPCCodec.encode(ResponseResult.serviceInstances(result)))
        XCTAssertEqual(decoded, .serviceInstances(result))
    }
}
