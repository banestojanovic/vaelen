import XCTest
@testable import VaelenCLI

final class HumanOutputTests: XCTestCase {
    func testListIsADiscoverabilityAliasForRootHelp() throws {
        guard case .help = try VaelenCLIMain.parse(["list"]) else {
            return XCTFail("val list must return the command catalog")
        }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["list", "--json"]))
        XCTAssertTrue(VaelenCLIMain.usage.contains("Discoverability"))
        XCTAssertTrue(VaelenCLIMain.usage.contains("Run “val list”"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["list"]).contains("Usage: val list"))
    }

    func testStructuredOutputFlagsRejectUnknownAndDuplicateOptions() throws {
        guard case .status(json: true) = try VaelenCLIMain.parse(["status", "--json"]) else {
            return XCTFail("status --json did not parse")
        }
        for invalid in [
            ["status", "--unknown"], ["status", "--json", "--unknown"],
            ["php", "versions", "--json", "extra"], ["mysql", "status", "--no"],
            ["mailpit", "status", "--json", "extra"], ["route", "list", "--json", "extra"],
            ["dns", "install", "--takeover", "extra"], ["tls", "status", "--no"],
            ["ports", "status", "--no"]
        ] {
            XCTAssertThrowsError(try VaelenCLIMain.parse(invalid), "Accepted invalid arguments: \(invalid)")
        }
    }

    func testCurrentCommandSurfaceParsesAndRejectsExtraArguments() {
        let valid: [[String]] = [
            ["status"], ["status", "--json"], ["doctor"], ["links"], ["links", "--json"],
            ["parks"], ["paths", "--json"], ["link"], ["link", "/tmp/project"], ["unlink", "/tmp/project"],
            ["park"], ["park", "/tmp/workspace"], ["unpark"], ["unpark", "/tmp/workspace"],
            ["secure"], ["secure", "demo.test"], ["unsecure", "demo.test"],
            ["project", "status"], ["project", "inspect", "demo", "--json"], ["project", "doctor"],
            ["project", "plan"], ["project", "activate"], ["project", "php", "demo", "--version", "8.4"],
            ["php", "versions"], ["php", "default"], ["php", "default", "set", "8.4"],
            ["php", "install", "8.4"], ["php", "update", "8.4"], ["php", "remove", "8.4"],
            ["php", "operation"], ["php", "use", "8.4"], ["php", "start", "8.4"], ["php", "stop", "8.4"],
            ["php", "status", "8.4"], ["php", "exec", "--", "-v"], ["php", "resolve", "--path"],
            ["shell", "status"], ["shell", "install"], ["shell", "uninstall"],
            ["mysql", "versions"], ["mysql", "install", "8.4"], ["mysql", "use", "8.4"],
            ["mysql", "initialize"], ["mysql", "start"], ["mysql", "stop"], ["mysql", "status"],
            ["mailpit", "versions"], ["mailpit", "install", "latest"], ["mailpit", "start"], ["mailpit", "stop"],
            ["mailpit", "status"], ["mailpit", "open"], ["routing", "status"], ["routing", "start"], ["routing", "stop"],
            ["route", "list"], ["route", "add", "demo.test", "/tmp/public"],
            ["route", "add", "demo.test", "/tmp/public", "--tls"],
            ["route", "remove", "00000000-0000-0000-0000-000000000001"],
            ["route", "associate", "00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"],
            ["dns", "status"], ["dns", "install"], ["dns", "install", "--takeover"], ["dns", "remove"],
            ["tls", "status"], ["tls", "install"], ["tls", "remove"], ["tls", "trust"], ["tls", "untrust"],
            ["ports", "status"], ["ports", "install"], ["ports", "remove"]
        ]
        for args in valid {
            XCTAssertNoThrow(try VaelenCLIMain.parse(args), "Rejected documented command: \(args)")
        }

        let invalid: [[String]] = [
            ["status", "--bad"], ["doctor", "--bad"], ["links", "--bad"], ["parks", "--bad"],
            ["secure", "one", "two"], ["link", "one", "two"], ["unlink", "/tmp/project", "extra"],
            ["park", "one", "two"], ["unpark", "one", "two"], ["project", "status", "a", "b"],
            ["project", "php", "--version"], ["php", "versions", "--bad"], ["php", "install", "8.4", "extra"],
            ["php", "status", "8.4", "--bad"], ["php", "exec", "-v"], ["php", "resolve", "--bad"],
            ["shell", "status", "extra"], ["mysql", "status", "--bad"], ["mysql", "start", "extra"],
            ["mailpit", "versions", "extra"], ["routing", "status", "extra"], ["route", "list", "--bad"],
            ["route", "add", "demo.test", "/tmp/public", "--bad"], ["dns", "install", "--takeover", "--bad"],
            ["tls", "status", "--bad"], ["ports", "status", "--bad"], ["not-a-command"]
        ]
        for args in invalid {
            XCTAssertThrowsError(try VaelenCLIMain.parse(args), "Accepted invalid command: \(args)")
        }
    }

    func testNarrowListKeepsFullValuesWithinFortyColumns() {
        let output = HumanOutput.list(
            [["demo", "/Users/example/Code/a-very-long-project-name", "available"]],
            headers: ["Project", "Path", "Availability"], empty: "No projects.", width: 40
        )
        let compact = output.filter { !$0.isWhitespace }
        XCTAssertTrue(compact.contains("/Users/example/Code/a-very-long-project-name"))
        XCTAssertFalse(output.split(separator: "\n").contains { $0.count > 40 }, output)
    }

    func testAlignedStatusWrapsWithoutLosingText() {
        let output = HumanOutput.wrap("This actionable explanation includes the exact next step: run val doctor before retrying.", width: 32)
        XCTAssertTrue(output.contains("val doctor"))
        XCTAssertFalse(output.split(separator: "\n").contains { $0.count > 32 }, output)
    }

    func testHumanErrorAndWarningArePlainByDefaultWhenPiped() {
        XCTAssertFalse(HumanOutput.error("retry safely").contains("\u{001B}["))
        XCTAssertFalse(HumanOutput.warning("inspect status").contains("\u{001B}["))
    }
}
