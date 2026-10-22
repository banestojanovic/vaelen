import Foundation
import Darwin
import XCTest

final class ServiceListEndToEndTests: XCTestCase {
    private struct Inventory: Decodable {
        struct Service: Decodable {
            let service: String
            let state: String
        }

        let complete: Bool
        let services: [Service]
    }

    func testActualValChildReportsBothServicesUnavailableWhenCoreIsMissing() throws {
        guard let valPath = ProcessInfo.processInfo.environment["VAELEN_VAL_EXECUTABLE"] else {
            throw XCTSkip("Set VAELEN_VAL_EXECUTABLE to the actual built val binary by running Scripts/tests/val-service-list-test.sh.")
        }

        let root = URL(fileURLWithPath: "/private/tmp/vsl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var preserveRoot = false
        defer { if !preserveRoot { try? FileManager.default.removeItem(at: root) } }

        var environment = ProcessInfo.processInfo.environment
        environment["VAELEN_TEST_SUPPORT_ROOT_ENABLED"] = "1"
        environment["VAELEN_TEST_SUPPORT_ROOT"] = root.path
        environment["NO_COLOR"] = "1"

        let stdoutURL = root.appendingPathComponent("stdout")
        let stderrURL = root.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw NSError(domain: "ServiceListEndToEndTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create private CLI output files"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: valPath)
        process.arguments = ["service", "list", "--json"]
        process.environment = environment
        let stdoutFile = try FileHandle(forWritingTo: stdoutURL)
        let stderrFile = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutFile
        process.standardError = stderrFile
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var didExit = exited.wait(timeout: .now() + 10) == .success
        if !didExit {
            if process.isRunning { process.terminate() }
            didExit = exited.wait(timeout: .now() + 1) == .success
        }
        if !didExit {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            didExit = exited.wait(timeout: .now() + 2) == .success
        }
        guard didExit else {
            preserveRoot = true
            try? stdoutFile.close()
            try? stderrFile.close()
            XCTFail("val child exit could not be confirmed; fixture preserved at \(root.path)")
            return
        }
        process.waitUntilExit()
        try stdoutFile.close()
        try stderrFile.close()

        let stdout = String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 3, "stdout: \(stdout)\nstderr: \(stderr)")
        XCTAssertTrue(stderr.contains("Vaelen Core is not running"), stderr)

        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(stdout.utf8))
        XCTAssertFalse(inventory.complete)
        XCTAssertEqual(inventory.services.map(\.service), ["mysql", "mailpit"])
        XCTAssertEqual(inventory.services.map(\.state), ["unavailable", "unavailable"])
    }
}
