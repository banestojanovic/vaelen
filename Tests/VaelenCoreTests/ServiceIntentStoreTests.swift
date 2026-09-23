import XCTest
@testable import VaelenCore

final class ServiceIntentStoreTests: XCTestCase {
    func testOnlyExplicitEnabledChoicesSurviveReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-service-intents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state/service-intents.json")

        var store = ServiceIntentStore(url: url)
        XCTAssertTrue(try store.enabledServices().isEmpty)
        try store.set("php:8.4.23", enabled: true)
        try store.set("mysql", enabled: true)
        try store.set("php:8.3.29", enabled: false)

        store = ServiceIntentStore(url: url)
        XCTAssertEqual(try store.enabledServices(), ["php:8.4.23", "mysql"])
        try store.set("php:8.4.23", enabled: false)
        XCTAssertEqual(try ServiceIntentStore(url: url).enabledServices(), ["mysql"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
