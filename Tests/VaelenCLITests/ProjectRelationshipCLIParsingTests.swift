import XCTest
@testable import VaelenCLI

final class ProjectRelationshipCLIParsingTests: XCTestCase {
    func testParkCommandsAcceptCurrentDirectoryOrExplicitPath() throws {
        guard case .park(let currentParkPath) = try VaelenCLIMain.parse(["park"]) else {
            return XCTFail("park without a path should use the current directory")
        }
        XCTAssertNil(currentParkPath)
        guard case .park(let path) = try VaelenCLIMain.parse(["park", "workspace"]) else {
            return XCTFail("park did not parse")
        }
        XCTAssertEqual(path, "workspace")

        guard case .unpark(let unparkedPath) = try VaelenCLIMain.parse(["unpark", "workspace"]) else {
            return XCTFail("unpark did not parse")
        }
        XCTAssertEqual(unparkedPath, "workspace")
        guard case .unpark(let currentUnparkPath) = try VaelenCLIMain.parse(["unpark"]) else {
            return XCTFail("unpark without a path should use the current directory")
        }
        XCTAssertNil(currentUnparkPath)
        for args in [["park", "one", "two"], ["unpark", "one", "two"]] {
            XCTAssertThrowsError(try VaelenCLIMain.parse(args)) { error in
                XCTAssertTrue(String(describing: error).contains("Usage: val \(args[0]) [workspace-folder]"))
                XCTAssertFalse(String(describing: error).contains("Usage: val <command>"))
            }
        }
    }

    func testUnparkVerificationUsesTheResolvedCurrentDirectoryTarget() {
        XCTAssertEqual(
            VaelenCLIMain.unparkTargetPath(nil, workingDirectory: "/tmp/workspace"),
            "/tmp/workspace"
        )
    }

    func testLinkAcceptsOptionalCurrentDirectoryPathButUnlinkRequiresAnExplicitPath() throws {
        // Current-directory linking is the supported product contract. Keep
        // this assertion aligned with the committed CLI parser, not the older
        // explicit-path-only behavior.
        guard case .link(let currentDirectoryPath, nil) = try VaelenCLIMain.parse(["link"]) else {
            return XCTFail("link without a path should use the current directory")
        }
        XCTAssertNil(currentDirectoryPath)

        guard case .link(let path, nil) = try VaelenCLIMain.parse(["link", "project"]) else {
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
        guard case .edit(selector: nil) = try VaelenCLIMain.parse(["edit"]) else { return XCTFail("edit should support current-directory project selection") }
        guard case .edit(selector: "sample") = try VaelenCLIMain.parse(["edit", "sample"]) else { return XCTFail("edit selector was not parsed") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["edit", "one", "two"]))
    }

    func testHelpDocumentsProjectRelationshipSyntax() throws {
        let helpEntries = [
            ("park", "Usage: val park [workspace-folder]"),
            ("parks", "Usage: val parks [--json]"),
            ("unpark", "Usage: val unpark [workspace-folder]"),
            ("link", "Usage: val link [project-directory]"),
            ("links", "Usage: val links [--json]"),
            ("edit", "Usage: val edit [project]"),
            ("unlink", "Usage: val unlink <project-directory>")
        ]
        for (command, entry) in helpEntries {
            XCTAssertTrue(VaelenCLIMain.helpText(for: [command]).contains(entry), "missing current help entry for \(command)")
        }
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["php"]).contains("config [version]"))
        guard case .phpConfig(version: nil) = try VaelenCLIMain.parse(["php", "config"]) else { return XCTFail("PHP config should open the managed configuration folder") }
        guard case .phpConfig(version: "8.4.23") = try VaelenCLIMain.parse(["php", "config", "8.4.23"]) else { return XCTFail("PHP config version should select the version-specific FPM ini") }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["php", "config", "8.4.23", "unexpected"]))
        guard case .help = try VaelenCLIMain.parse(["--help"]) else {
            return XCTFail("--help did not parse")
        }
    }

    func testEmptyRelationshipListsHaveClearHumanOutput() {
        XCTAssertEqual(VaelenCLIMain.parkedPathsOutput([]), "No parked folders.")
        XCTAssertEqual(VaelenCLIMain.linkedProjectsOutput([]), "Linked projects\nNo linked projects.")
    }
}
