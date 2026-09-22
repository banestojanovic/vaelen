import XCTest
@testable import VaelenCLI

final class ProjectPHPCLIParsingTests: XCTestCase {
    func testProjectPHPSetAndReadFormsParse() throws {
        guard case .projectPHP(let selector, let version, let useDefault, let json) = try VaelenCLIMain.parse(["project", "php", "syncproof", "--version", "8.4.23", "--json"]) else { return XCTFail("project php version form did not parse") }
        XCTAssertEqual(selector, "syncproof")
        XCTAssertEqual(version, "8.4.23")
        XCTAssertFalse(useDefault)
        XCTAssertTrue(json)
        guard case .projectPHP(let readSelector, let readVersion, let readDefault, _) = try VaelenCLIMain.parse(["project", "php"]) else { return XCTFail("project php read form did not parse") }
        XCTAssertNil(readSelector); XCTAssertNil(readVersion); XCTAssertFalse(readDefault)
    }
}
