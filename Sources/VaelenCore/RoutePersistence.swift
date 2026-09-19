import Foundation
import SQLite3

public enum RouteTargetMutationError: Error, Equatable, Sendable {
    case routeNotFound
    case notFastCGI
    case expectedTargetMismatch
    case transitionAlreadyExists
    case transitionNotFound
    case transitionMismatch
    case persistenceFailed
}

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
    private let targetMutationHook: (() throws -> Void)?

    public init(store: SQLiteStateStore, targetMutationHook: (() throws -> Void)? = nil) { self.store = store; self.targetMutationHook = targetMutationHook }

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

    public func pendingTransitions() throws -> [RouteTargetTransition] {
        var transitions = [RouteTargetTransition]()
        try store.query("SELECT route_id,project_id,previous_route_json,desired_route_json,previous_provider_json,desired_provider_json,previous_socket,desired_socket,state FROM route_target_transitions ORDER BY route_id") { statement in
            guard let routeUUID = UUID(uuidString: store.columnString(statement, 0) ?? ""), let projectID = UUID(uuidString: store.columnString(statement, 1) ?? ""), let previousRoute = decodeRoute(statement, index: 2), let desiredRoute = decodeRoute(statement, index: 3), let previousProvider = decodeData(statement, index: 4), let desiredProvider = decodeData(statement, index: 5), let previousSocket = store.columnString(statement, 6), let desiredSocket = store.columnString(statement, 7), let state = RouteTargetTransitionState(rawValue: store.columnString(statement, 8) ?? "") else { throw SQLiteStateError.invalidRecord }
            guard previousRoute.id.rawValue == routeUUID, desiredRoute.id.rawValue == routeUUID, previousRoute.target.isFastCGI, desiredRoute.target.isFastCGI, previousRoute.target.fastCGISocket == previousSocket, desiredRoute.target.fastCGISocket == desiredSocket, (try? routeProviderFingerprint(previousRoute)) == previousProvider, (try? routeProviderFingerprint(desiredRoute)) == desiredProvider else { throw SQLiteStateError.invalidRecord }
            transitions.append(RouteTargetTransition(routeID: RouteID(rawValue: routeUUID), projectID: projectID, previousRoute: previousRoute, desiredRoute: desiredRoute, previousProviderFingerprint: previousProvider, desiredProviderFingerprint: desiredProvider, previousSocket: previousSocket, desiredSocket: desiredSocket, state: state))
        }
        return transitions
    }

    @discardableResult
    public func persistFastCGITargetTransition(id: RouteID, projectID: UUID, expectedSocket: String, desiredSocket: String) throws -> (intent: RouteIntent, transition: RouteTargetTransition) {
        try targetMutationHook?()
        return try store.transaction {
            var current: RouteIntent?
            var currentData: Data?
            try store.query("SELECT route_json,project_id,project_path FROM route_intents WHERE id = ?", bind: { store.bind(id.description, to: $0, index: 1) }) { statement in
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw SQLiteStateError.invalidRecord }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                currentData = data
                let route = try JSONDecoder().decode(Route.self, from: data)
                current = RouteIntent(route: route, projectID: store.columnString(statement, 1).flatMap(UUID.init(uuidString:)), projectPath: store.columnString(statement, 2))
            }
            guard let current, let currentData else { throw RouteTargetMutationError.routeNotFound }
            guard current.projectID == projectID else { throw RouteTargetMutationError.transitionMismatch }
            guard case .fastCGI(let currentSocket, let documentRoot) = current.route.target, currentSocket == expectedSocket else { throw RouteTargetMutationError.expectedTargetMismatch }
            var exists = false
            try store.query("SELECT route_id FROM route_target_transitions WHERE route_id = ?", bind: { store.bind(id.description, to: $0, index: 1) }) { _ in exists = true }
            guard !exists else { throw RouteTargetMutationError.transitionAlreadyExists }
            let desiredRoute = Route(id: current.route.id, hostname: current.route.hostname, target: .fastCGI(socketPath: desiredSocket, documentRoot: documentRoot), tls: current.route.tls)
            let desiredData = try JSONEncoder().encode(desiredRoute)
            let transition = RouteTargetTransition(routeID: id, projectID: projectID, previousRoute: current.route, desiredRoute: desiredRoute, previousProviderFingerprint: try routeProviderFingerprint(current.route), desiredProviderFingerprint: try routeProviderFingerprint(desiredRoute), previousSocket: currentSocket, desiredSocket: desiredSocket)
            try store.execute("INSERT INTO route_target_transitions (route_id,project_id,previous_route_json,desired_route_json,previous_provider_json,desired_provider_json,previous_socket,desired_socket,state) VALUES (?,?,?,?,?,?,?,?,?)", bind: { statement in
                store.bind(id.description, to: statement, index: 1); store.bind(projectID.uuidString, to: statement, index: 2); store.bind(currentData, to: statement, index: 3); store.bind(desiredData, to: statement, index: 4); store.bind(transition.previousProviderFingerprint, to: statement, index: 5); store.bind(transition.desiredProviderFingerprint, to: statement, index: 6); store.bind(currentSocket, to: statement, index: 7); store.bind(desiredSocket, to: statement, index: 8); store.bind(transition.state.rawValue, to: statement, index: 9)
            })
            try store.execute("UPDATE route_intents SET route_json = ? WHERE id = ? AND route_json = ?", bind: { statement in
                store.bind(desiredData, to: statement, index: 1); store.bind(id.description, to: statement, index: 2); store.bind(currentData, to: statement, index: 3)
            })
            var changed = 0
            try store.query("SELECT changes()") { changed = Int(sqlite3_column_int($0, 0)) }
            guard changed == 1 else { throw RouteTargetMutationError.expectedTargetMismatch }
            return (RouteIntent(route: desiredRoute, projectID: current.projectID, projectPath: current.projectPath), transition)
        }
    }

    public func completeFastCGITargetTransition(id: RouteID, projectID: UUID, desiredRoute: Route) throws {
        try store.transaction {
            var storedDesired: Route?
            try store.query("SELECT desired_route_json FROM route_target_transitions WHERE route_id = ? AND project_id = ?", bind: { statement in
                store.bind(id.description, to: statement, index: 1); store.bind(projectID.uuidString, to: statement, index: 2)
            }) { statement in storedDesired = decodeRoute(statement, index: 0) }
            guard storedDesired == desiredRoute else { throw RouteTargetMutationError.transitionMismatch }
            try store.execute("DELETE FROM route_target_transitions WHERE route_id = ? AND project_id = ?", bind: { statement in
                store.bind(id.description, to: statement, index: 1); store.bind(projectID.uuidString, to: statement, index: 2)
            })
            var changed = 0
            try store.query("SELECT changes()") { changed = Int(sqlite3_column_int($0, 0)) }
            guard changed == 1 else { throw RouteTargetMutationError.transitionNotFound }
        }
    }

    private func decodeRoute(_ statement: OpaquePointer, index: Int32) -> Route? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return try? JSONDecoder().decode(Route.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
    }

    private func decodeData(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    public func associateMetadata(id: RouteID, projectID: UUID, projectPath: String) throws {
        try store.query("UPDATE route_intents SET project_id = ?, project_path = ? WHERE id = ?", bind: { statement in
            store.bind(projectID.uuidString, to: statement, index: 1)
            store.bind(projectPath, to: statement, index: 2)
            store.bind(id.description, to: statement, index: 3)
        }) { _ in }
    }

}
