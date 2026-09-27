import XCTest
@testable import VaelenCLI

final class HumanOutputTests: XCTestCase {
    func testListIsADiscoverabilityAliasForRootHelp() throws {
        guard case .help(path: ["list"]) = try VaelenCLIMain.parse(["list"]) else {
            return XCTFail("val list must return the command catalog")
        }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["list", "--json"]))
        XCTAssertTrue(VaelenCLIMain.usage.contains("Run val list for every command"))
        XCTAssertFalse(VaelenCLIMain.usage.contains("--json"))
        XCTAssertFalse(VaelenCLIMain.usage.contains("val unsecure"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["list"]).contains("Help & version"))
        XCTAssertTrue(String(VaelenCLIMain.helpText(for: ["list"]).filter { !$0.isWhitespace }).contains("valunsecure"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["list"]).contains("Usage: val list"))
    }

    func testDocumentedInvocationExamplesAreAcceptedByParserAndFocusedHelpExists() {
        for entry in CLIDocumentation.entries {
            XCTAssertFalse(entry.parserExamples.isEmpty, "No parser contract recorded for \(entry.forms)")
            for example in entry.parserExamples where !example.isEmpty {
                XCTAssertNoThrow(try VaelenCLIMain.parse(example), "Catalog form rejected by parser: \(example)")
            }
            if entry.path.count >= 2 {
                let focused = VaelenCLIMain.helpText(for: entry.path)
                XCTAssertTrue(focused.contains(entry.summary), "Focused help missing for \(entry.path)")
            }
        }
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["php"]).contains("versions"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["php"]).contains("Select shell PHP or server default"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["project"]).contains("status / inspect"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["mysql"]).contains("versions"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["mailpit"]).contains("status"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["web"]).contains("sites"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["runtime"]).contains("php"))
        XCTAssertTrue(VaelenCLIMain.helpText(for: ["networking"]).contains("route"))
    }

    func testCommandCatalogWrapsWideAndFortyColumnWithoutDroppingInvocations() {
        for width in [80, 40] {
            let text = CLIDocumentation.text(for: ["list"], width: width)
            XCTAssertTrue(text.contains("val link"))
            XCTAssertTrue(text.contains("val php default"))
            XCTAssertTrue(text.contains("val site info"))
            XCTAssertTrue(text.contains("<site-name>"))
            XCTAssertTrue(text.contains("--json"))
            XCTAssertLessThanOrEqual(text.split(separator: "\n").map(\.count).max() ?? 0, width)
        }
    }

    func testRootOverviewIsCuratedWhileListGroupsFormsUnderTheirCommands() {
        let root = CLIDocumentation.text(for: [], width: 80)
        XCTAssertTrue(root.contains("Run val list for every command"))
        XCTAssertTrue(root.contains("val link"))
        XCTAssertFalse(root.contains("val link --host"))
        XCTAssertFalse(root.contains("val php install"))

        let full = CLIDocumentation.text(for: ["list"], width: 100)
        XCTAssertTrue(full.contains("php subcommands"))
        XCTAssertTrue(full.contains("versions"))
        XCTAssertTrue(full.contains("val php default"))
        XCTAssertTrue(full.contains("val paths"))
        XCTAssertTrue(full.contains("-V"))
        XCTAssertEqual(full.components(separatedBy: "Read or change").count - 1, 1)
        XCTAssertFalse(full.contains("No such command"))
    }

    func testShortOverviewsStayUsefulAndFitFortyColumns() {
        for path in [[], ["php"], ["mysql"], ["mailpit"], ["project"], ["web"], ["runtime"], ["networking"]] {
            let text = CLIDocumentation.text(for: path, width: 40)
            XCTAssertLessThanOrEqual(text.components(separatedBy: "\n").map(\.count).max() ?? 0, 40, "Overview overflowed at \(path)")
            XCTAssertTrue(text.contains("val list"), "Overview must point to the complete reference: \(path)")
            XCTAssertFalse(text.contains("--json"), "Overview should not dump flags: \(path)")
            XCTAssertFalse(text.contains("+---"), "Command help should stay unboxed: \(path)")
        }
        XCTAssertTrue(CLIDocumentation.text(for: ["php"], width: 40).contains("versions"))
        XCTAssertTrue(CLIDocumentation.text(for: ["mysql"], width: 40).contains("initialize"))
        XCTAssertTrue(CLIDocumentation.text(for: ["mailpit"], width: 40).contains("open"))
        XCTAssertFalse(CLIDocumentation.text(for: ["list"], width: 40).contains("+---"))
        XCTAssertTrue(CLIDocumentation.text(for: ["list"], width: 40).contains("Projects"))
    }

    func testEveryImplementedTopLevelParserCommandHasCatalogCoverage() {
        let implemented: Set<String> = [
            "help", "list", "--version", "-V", "status", "doctor", "secure", "unsecure", "links", "edit", "parks", "paths", "parked", "sites", "open", "db", "site", "project", "link", "unlink", "park", "unpark", "php", "use", "isolate", "unisolate", "isolated", "which-php", "ini", "shell", "mysql", "routing", "route", "mailpit", "dns", "tls", "ports", "web", "runtime", "networking"
        ]
        let documented = Set(CLIDocumentation.entries.flatMap { entry in
            entry.forms.compactMap { form -> String? in
                let words = form.split(separator: " ").map(String.init)
                guard words.first == "val", let command = words.dropFirst().first else { return nil }
                return command.hasPrefix("<") || command.hasPrefix("[") ? nil : command
            }
        })
        XCTAssertTrue(implemented.isSubset(of: documented), "Missing parser commands from catalog: \(implemented.subtracting(documented).sorted())")
    }

    func testTrailingHelpResolvesTheLongestFocusedSubcommandWithArgumentsPresent() {
        XCTAssertTrue(CLIDocumentation.focusedText(for: ["php", "install", "8.4.23"]).contains("val php install <version>"))
        XCTAssertTrue(CLIDocumentation.focusedText(for: ["route", "add", "demo.test", "./public"]).contains("val route add <hostname> <document-root>"))
        XCTAssertTrue(CLIDocumentation.focusedText(for: ["link", "demo"]).contains("val link <site-name>"))
        XCTAssertTrue(CLIDocumentation.focusedText(for: ["project", "php", "demo"]).contains("val project php [project]"))
        XCTAssertTrue(CLIDocumentation.focusedText(for: ["paths"]).contains("val parks"))
        XCTAssertTrue(CLIDocumentation.focusedText(for: ["-V"]).contains("val -V"))
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
            ["parked"], ["parked", "--json"], ["sites"], ["sites", "--json"], ["open"], ["open", "app.test"],
            ["db"], ["db", "app"], ["site", "driver"], ["site", "driver", "app", "--json"],
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
            ["parked", "--bad"], ["sites", "--bad"], ["open", "one", "two"], ["db", "one", "two"],
            ["site", "unknown"], ["site", "driver", "--unknown"], ["site", "driver", "one", "two"],
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
        XCTAssertTrue(output.contains("/Users/example/Code"), output)
        XCTAssertTrue(output.contains("/a-very-long-project-name"), output)
        XCTAssertFalse(output.contains("+"))
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

    func testNarrowWrapAccountsForPrefixesAndBreaksLongUnbrokenValues() {
        let value = String(repeating: "very-long-hostname-segment", count: 3) + ".test"
        let output = HumanOutput.wrap(value, width: 40, firstPrefix: "  Host: ", nextPrefix: "        ")
        XCTAssertTrue(output.contains("very-long-hostname-segment"))
        XCTAssertTrue(output.contains(".test"))
        XCTAssertFalse(output.split(separator: "\n").contains { $0.count > 40 }, output)
    }

    func testTableAlignmentMeasuresANSIAsZeroWidth() {
        let output = HumanOutput.list(
            [["\u{001B}[32m✓ Healthy\u{001B}[0m", "short"], ["○ Off", "a much longer value"]],
            headers: ["State", "Detail"], empty: "None", width: 60
        )
        XCTAssertTrue(output.contains("Healthy"))
        XCTAssertTrue(output.contains("short"))
        XCTAssertTrue(output.contains("a much longer value"))
        XCTAssertTrue(output.contains("\u{001B}[32m"))
    }

    func testSemanticStatePaletteIsConsistentAndNonColorStatesAreMuted() {
        XCTAssertEqual(HumanOutput.stateColor("healthy"), 32)
        XCTAssertEqual(HumanOutput.stateColor("degraded"), 33)
        XCTAssertEqual(HumanOutput.stateColor("failed"), 31)
        XCTAssertEqual(HumanOutput.stateColor("unknown"), 90)
        XCTAssertEqual(HumanOutput.stateColor("Missing"), 90)
        XCTAssertEqual(HumanOutput.stateColor("ownedRunning"), 32)
        XCTAssertEqual(HumanOutput.stateColor("custom"), 0)
    }

    func testSuccessPresentationPreservesParagraphsAndPlainOutput() {
        let output = HumanOutput.success("Linked demo\n/Users/example/Code/a-project")
        XCTAssertEqual(output, "Linked demo\n/Users/example/Code/a-project")
        XCTAssertEqual(HumanOutput.state("Stopped"), "Stopped")
    }

    func testANSIWrappedLongHostPreservesEveryCharacterAndDoesNotSplitEscapeCodes() {
        let host = String(repeating: "long-host-segment-", count: 5) + ".test"
        let input = "\u{001B}[32m\(host)\u{001B}[0m"
        let output = HumanOutput.wrap(input, width: 40, firstPrefix: "  Host: ", nextPrefix: "        ")
        let pattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        let plain = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        XCTAssertEqual(plain.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "  Host: ", with: "").replacingOccurrences(of: "        ", with: ""), host)
        let escapeCount = output.components(separatedBy: "\u{001B}[").count - 1
        let ansiPattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        let matches = try! NSRegularExpression(pattern: ansiPattern).numberOfMatches(in: output, range: NSRange(output.startIndex..., in: output))
        XCTAssertEqual(escapeCount, matches)
        XCTAssertTrue(output.components(separatedBy: "\u{001B}[32m").count >= 3, output)
        XCTAssertTrue(output.hasSuffix("\u{001B}[0m"), output)
        XCTAssertFalse(output.split(separator: "\n").contains { $0.replacingOccurrences(of: pattern, with: "", options: .regularExpression).count > 40 }, output)
    }

    func testReportAlignsAndSemanticallyStylesLongValuesAtFortyColumns() {
        let green = HumanOutput.semantic("Healthy", tint: 32, color: true)
        let red = HumanOutput.semantic("Conflict", tint: 33, color: true)
        let output = HumanOutput.report("Routing status", rows: [("State", green), ("Detail", red + " · " + String(repeating: "/long/runtime/path", count: 5))], width: 40, color: false)
        XCTAssertTrue(output.hasPrefix("Routing status"))
        XCTAssertTrue(output.contains("\u{001B}[32mHealthy\u{001B}[0m"))
        XCTAssertTrue(output.contains("\u{001B}[33mConflict\u{001B}[0m"))
        let plainPattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        let lines = output.split(separator: "\n").map { line in
            line.replacingOccurrences(of: plainPattern, with: "", options: .regularExpression)
        }
        XCTAssertFalse(lines.contains { $0.count > 40 }, output)
        XCTAssertTrue(output.contains("/long/runtime/path"))
    }

    func testWrappingPreservesRepeatedSpacesAndUnicodeContentExactly() {
        let value = "Project  résumé  東京   path: /Users/banes/Code/space  name/長い-directory-segment"
        let wrapped = HumanOutput.wrap(value, width: 24)
        XCTAssertNotEqual(wrapped, value)
        XCTAssertEqual(wrapped.replacingOccurrences(of: "\n", with: ""), value)
    }

    func testColoredUnicodeAndRepeatedSpacesRemainAlignedAtFortyColumns() {
        let state = HumanOutput.semantic("Healthy", tint: 32, color: true)
        let rows = [("State", state), ("Path", "~/Code/東京  workspace/naïve/project")]
        let output = HumanOutput.report("Project status", rows: rows, width: 40, color: false)
        let sgr = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
        let plain = output.replacingOccurrences(of: sgr, with: "", options: .regularExpression)
        let lines = plain.components(separatedBy: "\n")
        XCTAssertTrue(plain.contains("~/Code/東京"), plain)
        XCTAssertTrue(plain.contains("workspace/naïve/project"), plain)
        XCTAssertFalse(plain.contains("+"), plain)
        XCTAssertTrue(output.contains("\u{001B}[32mHealthy\u{001B}[0m"))
        let colored = HumanOutput.report("Project status", rows: rows, width: 40, color: true)
        XCTAssertEqual(colored.replacingOccurrences(of: sgr, with: "", options: .regularExpression), plain)
    }

    func testLongIdentifierMovesBelowItsLabelInsteadOfSplittingAtFortyColumns() {
        let identifier = "99C6A3EC-9879-4F50-8CE6-3F95FEC337A8"
        let output = HumanOutput.list([[identifier, "example.test"]], headers: ["ID", "Hostname"], empty: "None", width: 40)
        XCTAssertTrue(output.contains("ID"), output)
        XCTAssertTrue(output.contains("99C6A3EC"), output)
        XCTAssertFalse(output.contains("+"), output)
        XCTAssertFalse(output.split(separator: "\n").contains { $0.count > 40 }, output)
    }

    func testPathWrapPrefersSlashComponentBoundaryWhenComponentFits() {
        let path = "root=/Users/banes/Code/callthewaiter/public"
        let output = HumanOutput.wrap(path, width: 40, firstPrefix: "Target: ", nextPrefix: "  ")
        XCTAssertTrue(output.split(separator: "\n").contains { $0.hasSuffix("/public") }, output)
    }
}
