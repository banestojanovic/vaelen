import Foundation
import SQLite3

public final class ProjectRepository: @unchecked Sendable {
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store }

    public func upsert(_ record: LinkedProjectRecord) throws {
        try store.query("INSERT INTO projects (id,name,custom_name,canonical_path,registration_kind) VALUES (?,?,?,?, 'linked') ON CONFLICT(canonical_path) DO UPDATE SET name=excluded.name, custom_name=excluded.custom_name", bind: { statement in
            store.bind(record.id.description, to: statement, index: 1); store.bind(record.name, to: statement, index: 2); record.customName.map { store.bind($0, to: statement, index: 3) }; store.bind(record.canonicalPath, to: statement, index: 4)
        }) { _ in }
    }
    public func phpOverride(for projectID: ProjectID) throws -> String? {
        var value: String?
        try store.query("SELECT php_override_version FROM projects WHERE id = ?", bind: { store.bind(projectID.description, to: $0, index: 1) }) { value = store.columnString($0, 0) }
        return value
    }
    public func setPHPOverride(_ version: String?, for projectID: ProjectID) throws {
        try store.query("UPDATE projects SET php_override_version = ? WHERE id = ?", bind: { statement in
            if let version { store.bind(version, to: statement, index: 1) }
            store.bind(projectID.description, to: statement, index: 2)
        }) { _ in }
    }
    public func remove(canonicalPath: String) throws {
        try store.query("DELETE FROM projects WHERE canonical_path = ?", bind: { store.bind(canonicalPath, to: $0, index: 1) }) { _ in }
    }
    public func all() throws -> [LinkedProjectRecord] {
        var records = [LinkedProjectRecord]()
        try store.query("SELECT id,name,custom_name,canonical_path FROM projects ORDER BY canonical_path") { statement in
            guard let id = UUID(uuidString: store.columnString(statement, 0) ?? ""), let name = store.columnString(statement, 1), let path = store.columnString(statement, 3) else { throw SQLiteStateError.invalidRecord }
            records.append(LinkedProjectRecord(id: ProjectID(rawValue: id), name: name, canonicalPath: path, customName: store.columnString(statement, 2)))
        }
        return records
    }
}

public final class ParkedPathRepository: @unchecked Sendable {
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store }
    public func upsert(_ record: ParkedPathRecord) throws {
        try store.query("INSERT INTO parked_paths (id,canonical_path) VALUES (?,?) ON CONFLICT(canonical_path) DO NOTHING", bind: { statement in
            store.bind(record.id.description, to: statement, index: 1); store.bind(record.canonicalPath, to: statement, index: 2)
        }) { _ in }
    }
    public func remove(canonicalPath: String) throws { try store.query("DELETE FROM parked_paths WHERE canonical_path = ?", bind: { store.bind(canonicalPath, to: $0, index: 1) }) { _ in } }
    public func all() throws -> [ParkedPathRecord] {
        var records = [ParkedPathRecord]()
        try store.query("SELECT id,canonical_path FROM parked_paths ORDER BY canonical_path") { statement in
            guard let id = UUID(uuidString: store.columnString(statement, 0) ?? ""), let path = store.columnString(statement, 1) else { throw SQLiteStateError.invalidRecord }
            records.append(ParkedPathRecord(id: ParkedPathID(rawValue: id), canonicalPath: path))
        }
        return records
    }
}
