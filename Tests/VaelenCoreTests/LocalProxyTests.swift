import XCTest
import SQLite3
@testable import VaelenCore

final class LocalProxyTests: XCTestCase {
    func testConfigurationAllowsOnlyLoopbackHTTPAndNormalizesHost() throws {
        XCTAssertEqual(try LocalProxyConfiguration(hostname: "app.test", upstreamURL: "http://LOCALHOST:8080/").upstreamURL.absoluteString, "http://localhost:8080/")
        XCTAssertNoThrow(try LocalProxyConfiguration(hostname: "app.test", upstreamURL: "http://127.42.0.1:65535"))
        XCTAssertNoThrow(try LocalProxyConfiguration(hostname: "app.test", upstreamURL: "http://[::1]:8080"))
        for hostname in ["App.test", "app.local", "-app.test", "app..test"] {
            XCTAssertThrowsError(try LocalProxyConfiguration(hostname: hostname, upstreamURL: "http://localhost:8080"))
        }
        for url in ["https://localhost:8080", "http://localhost", "http://localhost:0", "http://localhost:65536", "http://user@localhost:80", "http://localhost:80/path", "http://localhost:80?x=1", "http://example.com:80", "http://127.0.0.1.evil:80"] {
            XCTAssertThrowsError(try LocalProxyConfiguration(hostname: "app.test", upstreamURL: url), url)
        }
    }

    func testOwnershipPersistsExactRouteAcrossLifecycleAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("proxy.sqlite")
        let repository = try LocalProxyRepository(databaseURL: path)
        let route = Route(hostname: "app.test", target: .http(host: "127.0.0.1", port: 8080), tls: .disabled)
        try repository.createPrepared(route: route, expectedRoute: route)
        XCTAssertEqual(try repository.list(), [LocalProxyRecord(route: route, phase: .prepared)])
        let reopened = try LocalProxyRepository(databaseURL: path)
        try reopened.activate(routeID: route.id, expectedRoute: route)
        XCTAssertEqual(try reopened.list(), [LocalProxyRecord(route: route, phase: .active)])
        try reopened.markDeleting(routeID: route.id, expectedRoute: route)
        XCTAssertEqual(try reopened.list(), [LocalProxyRecord(route: route, phase: .deleting)])
        try reopened.removeRecord(routeID: route.id, expectedRoute: route)
        XCTAssertTrue(try reopened.list().isEmpty)
    }

    func testRejectsDuplicateOwnershipAndRouteMismatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LocalProxyRepository(databaseURL: root.appendingPathComponent("proxy.sqlite"))
        let route = Route(hostname: "app.test", target: .http(host: "127.0.0.1", port: 8080), tls: .disabled)
        try repository.createPrepared(route: route, expectedRoute: route)
        XCTAssertThrowsError(try repository.createPrepared(route: route, expectedRoute: route)) { XCTAssertEqual($0 as? LocalProxyError, .ownershipConflict) }
        let changed = Route(id: route.id, hostname: route.hostname, target: .http(host: "127.0.0.1", port: 8081), tls: .disabled)
        XCTAssertThrowsError(try repository.activate(routeID: route.id, expectedRoute: changed)) { XCTAssertEqual($0 as? LocalProxyError, .recordMismatch) }
        XCTAssertThrowsError(try repository.createPrepared(route: changed, expectedRoute: route)) { XCTAssertEqual($0 as? LocalProxyError, .routeNotEligible) }
        XCTAssertThrowsError(try repository.activate(routeID: RouteID(), expectedRoute: route)) { XCTAssertEqual($0 as? LocalProxyError, .recordNotFound) }
        XCTAssertThrowsError(try repository.createPrepared(route: Route(hostname: "app.test", target: .http(host: "127.0.0.1", port: 80)), expectedRoute: Route(hostname: "app.test", target: .http(host: "127.0.0.1", port: 80))))
    }

    func testMalformedStoredRecordFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("proxy.sqlite")
        let repository = try LocalProxyRepository(databaseURL: path)
        let route = Route(hostname: "app.test", target: .http(host: "127.0.0.1", port: 8080), tls: .disabled)
        try repository.createPrepared(route: route, expectedRoute: route)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE proxies SET route_json = X'00'", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try repository.list()) { XCTAssertEqual($0 as? LocalProxyError, .invalidRecord) }
    }
}
