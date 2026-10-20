import Foundation
import SQLite3
import Darwin

public enum LocalProxyError: Error, Equatable, Sendable {
    case invalidHostname(String)
    case invalidUpstreamURL(String)
    case routeNotEligible
    case ownershipConflict
    case recordNotFound
    case recordMismatch
    case persistence(String)
    case invalidRecord
}

public struct LocalProxyConfiguration: Equatable, Sendable {
    public let hostname: String
    public let upstreamURL: URL

    public init(hostname: String, upstreamURL: String) throws {
        let normalizedHostname = hostname.lowercased()
        guard Self.validTestHostname(normalizedHostname) else {
            throw LocalProxyError.invalidHostname("Use a valid local hostname ending in .test.")
        }
        guard let components = URLComponents(string: upstreamURL), components.scheme?.lowercased() == "http",
              components.user == nil, components.password == nil,
              let rawHost = components.host, !rawHost.isEmpty,
              let port = components.port, (1...65535).contains(port),
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil,
              Self.isLoopback(rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) else {
            throw LocalProxyError.invalidUpstreamURL("Use an HTTP loopback URL with an explicit port and no credentials, path, query, or fragment.")
        }
        var normalized = components
        normalized.scheme = "http"
        if !rawHost.hasPrefix("[") { normalized.host = rawHost.lowercased() }
        self.hostname = normalizedHostname
        guard let url = normalized.url else { throw LocalProxyError.invalidUpstreamURL("The upstream URL could not be normalized.") }
        self.upstreamURL = url
    }

    private static func validTestHostname(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last == "test", value.count <= 253 else { return false }
        return labels.allSatisfy { label in
            label.count <= 63 && label.first?.isASCII == true && label.first?.isLetter == true ||
                label.count <= 63 && label.first?.isNumber == true
                ? label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } && !label.hasPrefix("-") && !label.hasSuffix("-")
                : false
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        var address4 = in_addr()
        if inet_pton(AF_INET, host, &address4) == 1 {
            return (UInt32(bigEndian: address4.s_addr) >> 24) == 127
        }
        var address6 = in6_addr()
        if inet_pton(AF_INET6, host, &address6) == 1 {
            return withUnsafeBytes(of: address6) { bytes in bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1 }
        }
        return false
    }

    fileprivate static func validates(route: Route) -> Bool {
        guard case .http(let host, let port) = route.target,
              let configuration = try? LocalProxyConfiguration(hostname: route.hostname, upstreamURL: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)") else { return false }
        return configuration.hostname == route.hostname && configuration.upstreamURL.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host.lowercased()
            && configuration.upstreamURL.port == port && route.tls == .disabled
    }
}

public enum LocalProxyPhase: String, Codable, Sendable { case prepared, active, deleting }

public struct LocalProxyRecord: Codable, Equatable, Sendable {
    public let routeID: RouteID
    public let route: Route
    public let phase: LocalProxyPhase

    public init(route: Route, phase: LocalProxyPhase) {
        self.routeID = route.id
        self.route = route
        self.phase = phase
    }
}

// SQLite serializes access to this repository's FULLMUTEX connection.
public final class LocalProxyRepository: @unchecked Sendable {
    private let database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: databaseURL.deletingLastPathComponent().path)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw LocalProxyError.persistence("Could not open local proxy ownership database.")
        }
        guard let handle else { throw LocalProxyError.persistence("Could not open local proxy ownership database.") }
        database = handle
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            try run("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            let version = try scalar("SELECT value FROM metadata WHERE key = 'version'")
            if let version, version != "1" { throw LocalProxyError.invalidRecord }
            if version == nil { try run("INSERT INTO metadata (key,value) VALUES ('version','1')") }
            try run("CREATE TABLE IF NOT EXISTS proxies (route_id TEXT PRIMARY KEY NOT NULL, route_json BLOB NOT NULL, phase TEXT NOT NULL CHECK (phase IN ('prepared','active','deleting')))")
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func createPrepared(route: Route, expectedRoute: Route) throws {
        guard route == expectedRoute, route.id == expectedRoute.id,
              LocalProxyConfiguration.validates(route: route) else { throw LocalProxyError.routeNotEligible }
        guard (try? route.validated()) == route, route.hostname == route.hostname.lowercased() else { throw LocalProxyError.routeNotEligible }
        try insert(route, phase: .prepared)
    }

    public func activate(routeID: RouteID, expectedRoute: Route) throws { try transition(routeID, expectedRoute, to: .active, from: [.prepared]) }
    public func markDeleting(routeID: RouteID, expectedRoute: Route) throws { try transition(routeID, expectedRoute, to: .deleting, from: [.prepared, .active]) }

    public func removeRecord(routeID: RouteID, expectedRoute: Route) throws {
        guard let record = try list().first(where: { $0.routeID == routeID }) else { throw LocalProxyError.recordNotFound }
        guard record.route == expectedRoute else { throw LocalProxyError.recordMismatch }
        guard record.phase == .deleting else { throw LocalProxyError.recordMismatch }
        try execute("DELETE FROM proxies WHERE route_id = ? AND route_json = ? AND phase = 'deleting'", id: routeID, route: expectedRoute)
        guard sqlite3_changes(database) == 1 else { throw LocalProxyError.recordMismatch }
    }

    public func list() throws -> [LocalProxyRecord] {
        var result = [LocalProxyRecord]()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT route_id,route_json,phase FROM proxies ORDER BY route_id", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0), let blob = sqlite3_column_blob(statement, 1),
                  let phaseRaw = sqlite3_column_text(statement, 2), let uuid = UUID(uuidString: String(cString: rawID)),
                  let phase = LocalProxyPhase(rawValue: String(cString: phaseRaw)) else { throw LocalProxyError.invalidRecord }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let route = try? JSONDecoder().decode(Route.self, from: data), route.id.rawValue == uuid,
                  (try? route.validated()) == route, case .http = route.target, route.tls == .disabled else { throw LocalProxyError.invalidRecord }
            result.append(LocalProxyRecord(route: route, phase: phase))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw failure() }
        return result
    }

    private func insert(_ route: Route, phase: LocalProxyPhase) throws {
        guard try list().allSatisfy({ $0.routeID != route.id }) else { throw LocalProxyError.ownershipConflict }
        let data = try encoder.encode(route)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO proxies (route_id,route_json,phase) VALUES (?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, route.id.description, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        sqlite3_bind_text(statement, 3, phase.rawValue, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw LocalProxyError.ownershipConflict }
    }

    private func transition(_ id: RouteID, _ route: Route, to phase: LocalProxyPhase, from phases: [LocalProxyPhase]) throws {
        guard let record = try list().first(where: { $0.routeID == id }) else { throw LocalProxyError.recordNotFound }
        guard record.route == route else { throw LocalProxyError.recordMismatch }
        guard phases.contains(record.phase) else { throw LocalProxyError.recordMismatch }
        try execute("UPDATE proxies SET phase = ? WHERE route_id = ? AND route_json = ? AND phase = ?", id: id, route: route, phase: phase, prior: record.phase)
        guard sqlite3_changes(database) == 1 else { throw LocalProxyError.recordMismatch }
    }

    private func execute(_ sql: String, id: RouteID, route: Route, phase: LocalProxyPhase? = nil, prior: LocalProxyPhase? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let phase { sqlite3_bind_text(statement, index, phase.rawValue, -1, transient); index += 1 }
        sqlite3_bind_text(statement, index, id.description, -1, transient); index += 1
        let data = try encoder.encode(route)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
        if let prior { sqlite3_bind_text(statement, index + 1, prior.rawValue, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func run(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func scalar(_ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func failure() -> LocalProxyError { .persistence(database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "Unknown SQLite error.") }
}
