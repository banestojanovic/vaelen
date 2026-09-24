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

    func testLinkAcceptsOptionalCurrentDirectoryPathButUnlinkRequiresAnExplicitPath() throws {
        // Current-directory linking is the supported product contract. Keep
        // this assertion aligned with the committed CLI parser, not the older
        // explicit-path-only behavior.
        guard case .link(let currentDirectoryPath) = try VaelenCLIMain.parse(["link"]) else {
            return XCTFail("link without a path should use the current directory")
        }
        XCTAssertNil(currentDirectoryPath)

        guard case .link(let path) = try VaelenCLIMain.parse(["link", "project"]) else {
            return XCTFail("link did not parse")
        }
        XCTAssertEqual(path, "project")

        guard case .unlink(let unlinkedPath) = try VaelenCLIMain.parse(["unlink", "project"]) else {
            return XCTFail("unlink did not parse")
        }
        XCTAssertEqual(unlinkedPath, "project")
        XCTAssertThrowsError(try VaelenCLIMain.parse(["unlink"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["unlink", "--name", "project"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["link", "one", "two"]))
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
        let helpEntries = [
            ("park", "Usage: val park <workspace-folder>"),
            ("parks", "Usage: val parks [--json]"),
            ("unpark", "Usage: val unpark <workspace-folder>"),
            ("link", "Usage: val link [project-directory]"),
            ("links", "Usage: val links [--json]"),
            ("unlink", "Usage: val unlink <project-directory>")
        ]
        for (command, entry) in helpEntries {
            XCTAssertTrue(VaelenCLIMain.helpText(for: [command]).contains(entry), "missing current help entry for \(command)")
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
