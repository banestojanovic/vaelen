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

    func testHerdStylePHPAliasesPreserveDistinctSelectionScopes() throws {
        guard case .phpUse("8.4.23") = try VaelenCLIMain.parse(["use", "8.4.23"]) else { return XCTFail("use must select CLI PHP") }
        guard case .projectPHP(selector: nil, version: "8.4.23", useDefault: false, json: false) = try VaelenCLIMain.parse(["isolate", "8.4.23"]) else { return XCTFail("isolate must set current project override") }
        guard case .projectPHP(selector: "demo", version: nil, useDefault: true, json: false) = try VaelenCLIMain.parse(["unisolate", "demo"]) else { return XCTFail("unisolate must clear the override") }
        guard case .isolated = try VaelenCLIMain.parse(["isolated"]) else { return XCTFail("isolated must list overrides") }
        guard case .phpResolvePath = try VaelenCLIMain.parse(["which-php"]) else { return XCTFail("which-php must resolve project-effective PHP") }
        guard case .phpINI(version: nil) = try VaelenCLIMain.parse(["ini"]) else { return XCTFail("ini without a version must use effective PHP") }
        guard case .phpINI(version: "8.4.23") = try VaelenCLIMain.parse(["ini", "8.4.23"]) else { return XCTFail("ini version form did not parse") }
        guard case .phpExec(version: nil, effective: true, arguments: ["artisan", "about"]) = try VaelenCLIMain.parse(["php", "exec", "--effective", "--", "artisan", "about"]) else { return XCTFail("effective PHP execution did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["use"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["isolate"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["php", "exec", "--effective", "artisan"]))
    }

    func testShellIntegrationLifecycleCommandsParse() throws {
        guard case .shellStatus = try VaelenCLIMain.parse(["shell", "status"]) else { return XCTFail("shell status did not parse") }
        guard case .shellInstall = try VaelenCLIMain.parse(["shell", "install"]) else { return XCTFail("shell install did not parse") }
        guard case .shellUninstall = try VaelenCLIMain.parse(["shell", "uninstall"]) else { return XCTFail("shell uninstall did not parse") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["shell", "unknown"]))
    }
}
