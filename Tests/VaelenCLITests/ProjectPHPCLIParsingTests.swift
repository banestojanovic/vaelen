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

    func testPHPResolverPathCommandParses() throws {
        guard case .phpResolvePath = try VaelenCLIMain.parse(["php", "resolve", "--path"]) else {
            return XCTFail("PHP shell resolver command did not parse")
        }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["php", "resolve"]))
    }

    func testShellIntegrationLifecycleCommandsParse() throws {
        guard case .shellStatus = try VaelenCLIMain.parse(["shell", "status"]) else { return XCTFail("shell status did not parse") }
        guard case .shellInstall = try VaelenCLIMain.parse(["shell", "install"]) else { return XCTFail("shell install did not parse") }
        guard case .shellUninstall = try VaelenCLIMain.parse(["shell", "uninstall"]) else { return XCTFail("shell uninstall did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["shell", "unknown"]))
    }
}
