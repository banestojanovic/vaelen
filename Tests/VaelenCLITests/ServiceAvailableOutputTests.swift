import XCTest
@testable import VaelenCLI

final class ServiceAvailableOutputTests: XCTestCase {
    func testStableJSONListsOnlyImplementedDefaultServicesAndActions() throws {
        let json = try ServiceAvailableFormatter.json(ServiceAvailableCatalog.supported)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let services = try XCTUnwrap(object["services"] as? [[String: Any]])

        XCTAssertEqual(Set(object.keys), ["services"])
        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services[0]["name"] as? String, "mysql")
        XCTAssertEqual(services[0]["scope"] as? String, "default-only")
        XCTAssertEqual(services[0]["actions"] as? [String], ["versions", "install", "use", "initialize", "start", "stop", "status"])
        XCTAssertEqual(services[1]["name"] as? String, "mailpit")
        XCTAssertEqual(services[1]["scope"] as? String, "default-only")
        XCTAssertEqual(services[1]["actions"] as? [String], ["versions", "install", "start", "stop", "status", "open"])
        XCTAssertFalse(json.contains("postgres"))
        XCTAssertFalse(json.contains("redis"))
        XCTAssertEqual(json, try ServiceAvailableFormatter.json(ServiceAvailableCatalog.supported))
    }

    func testHumanOutputIdentifiesDefaultOnlySupport() {
        let human = ServiceAvailableFormatter.human(ServiceAvailableCatalog.supported)

        XCTAssertTrue(human.contains("default-only"))
        XCTAssertTrue(human.contains("MySQL"))
        XCTAssertTrue(human.contains("Mailpit"))
        XCTAssertFalse(human.contains("PostgreSQL"))
        XCTAssertFalse(human.contains("Redis"))
        XCTAssertFalse(human.localizedCaseInsensitiveContains("installed"))
        XCTAssertFalse(human.localizedCaseInsensitiveContains("running"))
        XCTAssertFalse(human.localizedCaseInsensitiveContains("health"))
    }
}
