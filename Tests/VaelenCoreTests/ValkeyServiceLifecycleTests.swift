import Foundation
import XCTest
@testable import VaelenCore

final class ValkeyServiceLifecycleTests: XCTestCase {
    func testMissingPinnedPackageRefusesCreationWithoutClaimOrData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-valkey-lifecycle-\\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let repository = ServiceInstanceRepository(store: store)
        let module = ValkeyServiceModule(layout: layout, repository: repository)
        let id = ServiceInstanceID(kind: .valkey, name: try ProjectInstanceName("cache"))

        XCTAssertThrowsError(try module.create(id: id, port: 16379)) { error in
            XCTAssertEqual(error as? ValkeyServiceError, .unsupportedPackage)
        }
        XCTAssertNil(try repository.instance(id))
        XCTAssertFalse(try repository.isManuallyClaimed(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.valkeyInstancesDirectoryURL.appendingPathComponent("cache").path))
    }
}
