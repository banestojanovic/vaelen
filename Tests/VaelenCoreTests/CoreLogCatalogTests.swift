import Foundation
import Darwin
import XCTest
@testable import VaelenCore

final class CoreLogCatalogTests: XCTestCase {
    func testCatalogDistinguishesMissingEmptyAndAvailableWithoutCreatingFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("core-logs-\(UUID())", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.caddyLogsDirectoryURL, withIntermediateDirectories: true)
        try Data().write(to: layout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log"))
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let catalog = CoreLogCatalog(layout: layout)
        let results = Dictionary(uniqueKeysWithValues: catalog.list().map { ($0.id, $0) })
        XCTAssertEqual(results["caddy"]?.status, .empty)
        XCTAssertEqual(results["mysql"]?.status, .missing)
        XCTAssertEqual(results["mailpit"]?.status, .missing)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before)
        try FileManager.default.removeItem(at: root)
    }

    func testTailHonorsLineCountByteBoundAndReportsTruncation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("core-logs-\(UUID())", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.caddyLogsDirectoryURL, withIntermediateDirectories: true)
        try Data("one\ntwo\nthree\n".utf8).write(to: layout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log"))
        let catalog = CoreLogCatalog(layout: layout)
        let tail = try catalog.tail(id: "caddy", lines: 2)
        XCTAssertEqual(tail.text, "two\nthree")
        XCTAssertTrue(tail.truncated)
        XCTAssertEqual(tail.linesReturned, 2)
        XCTAssertThrowsError(try catalog.tail(id: "../../outside", lines: 1)) { XCTAssertEqual($0 as? CoreLogError, .unknownLog("../../outside")) }
        XCTAssertThrowsError(try catalog.tail(id: "caddy", lines: 0)) { XCTAssertEqual($0 as? CoreLogError, .invalidLineCount) }
        let large = String(repeating: "x", count: CoreLogCatalog.maxTailBytes + 500) + "\nlast\n"
        try Data(large.utf8).write(to: layout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log"))
        let bounded = try catalog.tail(id: "caddy", lines: 20)
        XCTAssertLessThanOrEqual(bounded.text.utf8.count, CoreLogCatalog.maxTailBytes)
        XCTAssertTrue(bounded.truncated)
        try FileManager.default.removeItem(at: root)
    }

    func testTailRejectsSymlinkOutsideOwnedLogDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("core-logs-\(UUID())", isDirectory: true)
        let outside = root.appendingPathComponent("outside.log")
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.caddyLogsDirectoryURL, withIntermediateDirectories: true)
        try Data("secret\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: layout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log"), withDestinationURL: outside)
        XCTAssertThrowsError(try CoreLogCatalog(layout: layout).tail(id: "caddy", lines: 1)) { XCTAssertEqual($0 as? CoreLogError, .unsafePath("caddy")) }
        try FileManager.default.removeItem(at: root)
    }

    func testNonRegularLogIsUnreadableWithoutBlocking() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("core-logs-\(UUID())", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.caddyLogsDirectoryURL, withIntermediateDirectories: true)
        let log = layout.caddyLogsDirectoryURL.appendingPathComponent("caddy.log")
        XCTAssertEqual(mkfifo(log.path, 0o600), 0)
        let catalog = CoreLogCatalog(layout: layout)
        XCTAssertEqual(catalog.list().first { $0.id == "caddy" }?.status, .unreadable)
        XCTAssertThrowsError(try catalog.tail(id: "caddy", lines: 1)) {
            XCTAssertEqual($0 as? CoreLogError, .unreadable("caddy"))
        }
        try FileManager.default.removeItem(at: root)
    }

    func testPHPLogIDsComeOnlyFromSafeInstalledVersionIdentifiers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("core-logs-\(UUID().uuidString)", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.phpLogsDirectoryURL, withIntermediateDirectories: true)
        try Data("php-fpm\n".utf8).write(to: layout.phpLogsDirectoryURL.appendingPathComponent("8.4.23.log"))
        let catalog = CoreLogCatalog(layout: layout, phpVersions: ["8.4.23", "../../external"])
        let logs = catalog.list()
        XCTAssertTrue(logs.contains { $0.id == "php-8.4.23" })
        XCTAssertFalse(logs.contains { $0.id == "php-../../external" })
        XCTAssertEqual(try catalog.tail(id: "php-8.4.23", lines: 1).text, "php-fpm")
        try FileManager.default.removeItem(at: root)
    }
}
