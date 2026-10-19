import XCTest
@testable import VaelenCLI

final class LogsCommandTests: XCTestCase {
    func testParsesCatalogAndTailOptions() throws {
        guard case .logs(id: nil, lines: 100, json: true) = try VaelenCLIMain.parse(["logs", "--json"]) else { return XCTFail("Expected JSON catalog command") }
        guard case .logs(id: "caddy", lines: 100, json: false) = try VaelenCLIMain.parse(["logs", "caddy"]) else { return XCTFail("Expected default-size tail") }
        guard case .logs(id: "mysql", lines: 5, json: true) = try VaelenCLIMain.parse(["logs", "mysql", "--lines", "5", "--json"]) else { return XCTFail("Expected configured tail") }
    }

    func testRejectsInvalidLinesAndUnexpectedOptions() {
        for arguments in [["logs", "--lines", "0"], ["logs", "--lines", "10001"], ["logs", "--lines", "x"], ["logs", "--lines", "2"], ["logs", "caddy", "--other"], ["logs", "caddy", "mysql"], ["logs", "/tmp/private.log"]] {
            XCTAssertThrowsError(try VaelenCLIMain.parse(arguments), "Accepted invalid logs arguments \(arguments)")
        }
    }
}
