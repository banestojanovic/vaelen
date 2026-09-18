import Foundation
import SQLite3

public struct RouteIntent: Codable, Equatable, Sendable {
    public let route: Route
    public let projectID: UUID?
    public let projectPath: String?

    public init(route: Route, projectID: UUID? = nil, projectPath: String? = nil) {
        self.route = route
        self.projectID = projectID
        self.projectPath = projectPath
    }
}

public final class RouteIntentRepository: @unchecked Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) { self.store = store }

    public func upsert(_ intent: RouteIntent) throws {
        let data = try JSONEncoder().encode(intent.route)
        try store.query("INSERT INTO route_intents (id,route_json,project_id,project_path) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET route_json=excluded.route_json, project_id=excluded.project_id, project_path=excluded.project_path", bind: { statement in
            store.bind(intent.route.id.description, to: statement, index: 1)
            _ = data.withUnsafeBytes { buffer in sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            if let projectID = intent.projectID { store.bind(projectID.uuidString, to: statement, index: 3) }
            if let projectPath = intent.projectPath { store.bind(projectPath, to: statement, index: 4) }
        }) { _ in }
    }

    public func remove(id: RouteID) throws {
        try store.query("DELETE FROM route_intents WHERE id = ?", bind: { store.bind(id.description, to: $0, index: 1) }) { _ in }
    }

    public func all() throws -> [RouteIntent] {
        var intents = [RouteIntent]()
        try store.query("SELECT route_json,project_id,project_path FROM route_intents ORDER BY id") { statement in
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw SQLiteStateError.invalidRecord }
            let length = Int(sqlite3_column_bytes(statement, 0))
            let route = try JSONDecoder().decode(Route.self, from: Data(bytes: bytes, count: length))
            let projectID = store.columnString(statement, 1).flatMap(UUID.init(uuidString:))
            intents.append(RouteIntent(route: route, projectID: projectID, projectPath: store.columnString(statement, 2)))
        }
        return intents
    }
}
