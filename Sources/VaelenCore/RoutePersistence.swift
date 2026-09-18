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
        var routeIDs = Set<RouteID>()
        try store.query("SELECT id,route_json,project_id,project_path FROM route_intents ORDER BY id") { statement in
            guard let rowID = UUID(uuidString: store.columnString(statement, 0) ?? ""), let bytes = sqlite3_column_blob(statement, 1) else { throw SQLiteStateError.invalidRecord }
            let length = Int(sqlite3_column_bytes(statement, 1))
            let route: Route
            do {
                route = try JSONDecoder().decode(Route.self, from: Data(bytes: bytes, count: length))
            } catch {
                throw SQLiteStateError.invalidRecord
            }
            guard route.id.rawValue == rowID, (try? route.validated()) == route, routeIDs.insert(route.id).inserted else { throw SQLiteStateError.invalidRecord }
            let rawProjectID = store.columnString(statement, 2)
            let projectID: UUID?
            if let rawProjectID {
                guard let decoded = UUID(uuidString: rawProjectID) else { throw SQLiteStateError.invalidRecord }
                projectID = decoded
            } else {
                projectID = nil
            }
            intents.append(RouteIntent(route: route, projectID: projectID, projectPath: store.columnString(statement, 3)))
        }
        return intents
    }

    public func associateMetadata(id: RouteID, projectID: UUID, projectPath: String) throws {
        try store.query("UPDATE route_intents SET project_id = ?, project_path = ? WHERE id = ?", bind: { statement in
            store.bind(projectID.uuidString, to: statement, index: 1)
            store.bind(projectPath, to: statement, index: 2)
            store.bind(id.description, to: statement, index: 3)
        }) { _ in }
    }
}
