import Foundation
import XCTest
@testable import VaelenCLI

final class PHPShellIntegrationTests: XCTestCase {
    func testInactiveVaelenFallsThroughToExternalPHP() throws {
        let result = try runShell(resolverExit: 3, resolverOutput: "Vaelen Core is not running.", activity: "inactive")

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "external --version\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testActiveVaelenDoesNotFallThroughWhenCoreIsUnavailable() throws {
        let result = try runShell(resolverExit: 3, resolverOutput: "Vaelen Core is not running.", activity: "active")

        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "Vaelen Core is not running.\n")
    }

    func testRunningCoreDoesNotFallThroughWhenResolverCannotReachIt() throws {
        let result = try runShell(resolverExit: 3, resolverOutput: "Vaelen Core is not running.", activity: "active")

        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "Vaelen Core is not running.\n")
    }

    func testUnknownActivityDoesNotSilentlySelectExternalPHP() throws {
        let result = try runShell(resolverExit: 3, resolverOutput: "Vaelen Core is not running.", activity: nil)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("Vaelen activity is unknown"))
    }

    func testManagedPHPRemainsAuthoritative() throws {
        let result = try runShell(resolverExit: 0, resolverOutput: "managed", activity: "active", createManagedPHP: true)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "managed --version\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testManagedPHPSetsItsPerVersionPHPRC() throws {
        let result = try runShell(resolverExit: 0, resolverOutput: "managed", activity: "active", createManagedPHP: true, reportManagedConfiguration: true)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.hasPrefix("managed --version ["), result.stdout)
        XCTAssertTrue(result.stdout.contains("/Library/Application Support/Vaelen/config/php/versions/8.4.23/cli.ini]"), result.stdout)
        XCTAssertEqual(result.stderr, "")
    }

    func testActiveVaelenWithMissingSelectedRuntimeDoesNotFallThrough() throws {
        let result = try runShell(resolverExit: 0, resolverOutput: "missing", activity: "active")

        XCTAssertEqual(result.status, 127)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(result.stderr.contains("Vaelen could not resolve an executable PHP runtime"))
    }

    func testNodePassesArgumentsAndPropagatesOutputAndExitStatus() throws {
        let result = try runShell(resolverExit: 0, resolverOutput: "", activity: "active", command: "node --trace-warnings 'argument with spaces'", helperExit: 23)

        XCTAssertEqual(result.status, 23)
        XCTAssertEqual(result.stdout, "helper <node> <exec> <--> <node> <--trace-warnings> <argument with spaces>\n")
        XCTAssertEqual(result.stderr, "helper error\n")
    }

    func testNpmPassesArgumentsAndPropagatesOutputAndExitStatus() throws {
        let result = try runShell(resolverExit: 0, resolverOutput: "", activity: "active", command: "npm install 'package with spaces'", helperExit: 24)

        XCTAssertEqual(result.status, 24)
        XCTAssertEqual(result.stdout, "helper <node> <exec> <--> <npm> <install> <package with spaces>\n")
        XCTAssertEqual(result.stderr, "helper error\n")
    }

    private func runShell(
        resolverExit: Int32,
        resolverOutput: String,
        activity: String?,
        createManagedPHP: Bool = false,
        reportManagedConfiguration: Bool = false,
        command: String = "php --version",
        helperExit: Int32? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-shell-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let resolver = root.appendingPathComponent("Library/Application Support/Vaelen/bin/vaelen-php-resolver")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resolver.deletingLastPathComponent(), withIntermediateDirectories: true)

        let resolverPrint = createManagedPHP ? "printf '%s\\n' \"$HOME/Library/Application Support/Vaelen/packages/php/8.4.23/php\"" : "printf '%s\\n' '\(resolverOutput)'"
        try executable("#!/bin/sh\n\(resolverPrint)\nexit \(resolverExit)\n", at: resolver)
        try executable("#!/bin/sh\nprintf 'external'\nprintf ' %s' \"$@\"\nprintf '\\n'\n", at: bin.appendingPathComponent("php"))
        if let helperExit {
            try executable("#!/bin/sh\nprintf 'helper'; for arg in \"$@\"; do printf ' <%s>' \"$arg\"; done; printf '\\n'\nprintf 'helper error\\n' >&2\nexit \(helperExit)\n", at: resolver)
        }
        let activityFile = root.appendingPathComponent("Library/Application Support/Vaelen/state/activity")
        if let activity {
            try FileManager.default.createDirectory(at: activityFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((activity + "\n").utf8).write(to: activityFile)
        }

        if createManagedPHP {
            let managedScript = reportManagedConfiguration
                ? "#!/bin/sh\nprintf 'managed'; printf ' %s' \"$@\"; printf ' [%s]\\n' \"$PHPRC\"\n"
                : "#!/bin/sh\nprintf 'managed'\nprintf ' %s' \"$@\"\nprintf '\\n'\n"
            try executable(managedScript, at: root.appendingPathComponent("Library/Application Support/Vaelen/packages/php/8.4.23/php"))
            let ini = root.appendingPathComponent("Library/Application Support/Vaelen/config/php/versions/8.4.23/cli.ini")
            try FileManager.default.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("memory_limit = 128M\n".utf8).write(to: ini)
        }

        let script = PHPShellIntegration.shellBlock + "\n" + command + "\n"
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": root.path, "PATH": "\(bin.path):/usr/bin:/bin"]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func executable(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
