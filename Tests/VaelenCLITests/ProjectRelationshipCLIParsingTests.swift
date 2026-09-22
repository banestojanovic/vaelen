import XCTest
@testable import VaelenCLI

final class ProjectRelationshipCLIParsingTests: XCTestCase {
    func testParkCommandsRequireAnExplicitPath() throws {
        guard case .park(let path) = try VaelenCLIMain.parse(["park", "workspace"]) else {
            return XCTFail("park did not parse")
        }
        XCTAssertEqual(path, "workspace")

        guard case .unpark(let unparkedPath) = try VaelenCLIMain.parse(["unpark", "workspace"]) else {
            return XCTFail("unpark did not parse")
        }
        XCTAssertEqual(unparkedPath, "workspace")
        XCTAssertThrowsError(try VaelenCLIMain.parse(["park"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["unpark"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["park", "one", "two"]))
    }

    func testLinkCommandsAcceptOnlyAnExplicitPath() throws {
        guard case .link(let path) = try VaelenCLIMain.parse(["link", "project"]) else {
            return XCTFail("link did not parse")
        }
        XCTAssertEqual(path, "project")

        guard case .unlink(let unlinkedPath) = try VaelenCLIMain.parse(["unlink", "project"]) else {
            return XCTFail("unlink did not parse")
        }
        XCTAssertEqual(unlinkedPath, "project")
        XCTAssertThrowsError(try VaelenCLIMain.parse(["link"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["unlink"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["unlink", "--name", "project"]))
    }

    func testRelationshipListsSupportOnlyTheStructuredOutputOption() throws {
        guard case .parks(json: false) = try VaelenCLIMain.parse(["parks"]) else {
            return XCTFail("parks did not parse")
        }
        guard case .parks(json: true) = try VaelenCLIMain.parse(["parks", "--json"]) else {
            return XCTFail("parks --json did not parse")
        }
        guard case .links(json: false) = try VaelenCLIMain.parse(["links"]) else {
            return XCTFail("links did not parse")
        }
        guard case .links(json: true) = try VaelenCLIMain.parse(["links", "--json"]) else {
            return XCTFail("links --json did not parse")
        }
        guard case .parks(json: false) = try VaelenCLIMain.parse(["paths"]) else {
            return XCTFail("legacy paths alias did not parse")
        }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["parks", "unexpected"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["links", "--json", "unexpected"]))
    }

    func testHelpDocumentsProjectRelationshipSyntax() throws {
        for command in [
            "val park <directory>", "val parks [--json]", "val unpark <directory>",
            "val link <project-directory>", "val links [--json]", "val unlink <project-directory>"
        ] {
            XCTAssertTrue(VaelenCLIMain.usage.contains(command), "missing help entry: \(command)")
        }
        guard case .help = try VaelenCLIMain.parse(["--help"]) else {
            return XCTFail("--help did not parse")
        }
    }

    func testEmptyRelationshipListsHaveClearHumanOutput() {
        XCTAssertEqual(VaelenCLIMain.parkedPathsOutput([]), "No parked folders.")
        XCTAssertEqual(VaelenCLIMain.linkedProjectsOutput([]), "No linked projects.")
    }
}
