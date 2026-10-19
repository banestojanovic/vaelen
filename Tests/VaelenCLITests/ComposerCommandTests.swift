import Foundation
import XCTest
@testable import VaelenCLI

final class ComposerCommandTests: XCTestCase {
    func testSearchChecksEachPATHDirectoryComposerThenPHAR() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first path", isDirectory: true)
        let second = root.appendingPathComponent("second path", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        var phar = Data("#!/usr/bin/env php\n<?php echo 'first phar';\n".utf8)
        phar.append(contentsOf: [0, 255, 128, 65])
        try phar.write(to: first.appendingPathComponent("composer.phar"))
        try writePHP("<?php echo 'second composer';\n", to: second.appendingPathComponent("composer"))

        let found = try ComposerScriptLocator.resolve(path: "first path:second path", workingDirectory: root.path)
        XCTAssertEqual(found.path, first.appendingPathComponent("composer.phar").path)

        try writePHP("<?php echo 'first composer';\n", to: first.appendingPathComponent("composer"))
        let preferred = try ComposerScriptLocator.resolve(path: "first path:second path", workingDirectory: root.path)
        XCTAssertEqual(preferred.path, first.appendingPathComponent("composer").path)
    }

    func testRelativeAndEmptyPATHComponentsUseOriginalWorkingDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePHP("<?php echo 'current directory';\n", to: root.appendingPathComponent("composer"))
        try writePHP("<?php echo 'relative directory';\n", to: root.appendingPathComponent("relative").appendingPathComponent("composer"))

        XCTAssertEqual(try ComposerScriptLocator.resolve(path: "", workingDirectory: root.path).path, root.appendingPathComponent("composer").path)
        XCTAssertThrowsError(try ComposerScriptLocator.resolve(path: nil, workingDirectory: root.path))
        XCTAssertEqual(try ComposerScriptLocator.resolve(path: "relative", workingDirectory: root.path).path, root.appendingPathComponent("relative/composer").path)
    }

    func testRejectsShellShebangAndMalformedPHPOpener() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("composer")
        try writePHP("#!/bin/sh\n<?php echo 'not PHP';\n", to: candidate)
        XCTAssertThrowsError(try ComposerScriptLocator.resolve(path: root.path, workingDirectory: root.path))
        try writePHP("<?phpgarbage", to: candidate)
        XCTAssertThrowsError(try ComposerScriptLocator.resolve(path: root.path, workingDirectory: root.path))
    }

    func testSymlinkIsFollowedAndFirstIncompatibleCandidateStopsSearch() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.php")
        try writePHP("<?php echo 'target';\n", to: target)
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("composer"), withDestinationURL: target)
        try writePHP("<?php echo 'fallback';\n", to: second.appendingPathComponent("composer"))

        XCTAssertEqual(try ComposerScriptLocator.resolve(path: "first:second", workingDirectory: root.path).path, target.path)

        try Data("#!/bin/sh\necho unsafe\n".utf8).write(to: first.appendingPathComponent("composer"), options: .atomic)
        XCTAssertThrowsError(try ComposerScriptLocator.resolve(path: "first:second", workingDirectory: root.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains(first.appendingPathComponent("composer").path))
        }

        try FileManager.default.removeItem(at: first.appendingPathComponent("composer"))
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("composer"), withDestinationURL: root.appendingPathComponent("missing-target.php"))
        XCTAssertThrowsError(try ComposerScriptLocator.resolve(path: "first:second", workingDirectory: root.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains(first.appendingPathComponent("composer").path))
        }
    }

    func testMissingAndIncompatibleCandidatesHaveActionableErrors() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ComposerScriptLocator.resolve(path: nil, workingDirectory: root.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not found on PATH"))
        }
        let directory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n<?php echo 'not PHP';\n".utf8).write(to: directory.appendingPathComponent("composer"))
        XCTAssertThrowsError(try ComposerScriptLocator.resolve(path: "bin", workingDirectory: root.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a readable PHP script"))
        }
    }

    func testExecutionPlanKeepsPHPAndComposerArgumentsInOrder() {
        let plan = ComposerCommand.executionPlan(phpExecutable: "/managed PHP/php", scriptURL: URL(fileURLWithPath: "/tools/composer.phar"), arguments: ["--help", "-h", "--", "", "install"])
        XCTAssertEqual(plan.processArguments, ["/managed PHP/php", "/tools/composer.phar", "--help", "-h", "--", "", "install"])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("composer-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePHP(_ source: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(source.utf8).write(to: url, options: .atomic)
    }
}
