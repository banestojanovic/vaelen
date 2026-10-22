import Foundation
import SQLite3
import Darwin

public enum NodeError: Error, Equatable, Sendable, LocalizedError {
    case invalidVersion(String)
    case invalidState(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let value): return "Node requires an exact stable version, such as 24.22.1. Received \(value)."
        case .invalidState(let detail): return "Cannot read Node selection state. \(detail)"
        case .unavailable(let detail): return "Selected Node runtime is unavailable. \(detail)"
        }
    }
}

public struct NodeVersion: Hashable, Codable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && (part.count == 1 || part.first != "0") && UInt32(part) != nil
        }) else { throw NodeError.invalidVersion(value) }
        description = value
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(description) }
}

public struct NodeProjectRecord: Equatable, Sendable {
    public let id: ProjectID
    public let name: String
    public let path: String
    public let pin: NodeVersion?
    public init(id: ProjectID, name: String, path: String, pin: NodeVersion?) {
        self.id = id; self.name = name; self.path = path; self.pin = pin
    }
}

public enum NodeProjectBoundary {
    public static func select(_ records: [NodeProjectRecord], workingDirectory: String) -> NodeProjectRecord? {
        let paths = CanonicalPathService()
        let current = paths.canonicalize(workingDirectory).string
        return records.filter { record in
            let root = paths.canonicalize(record.path).string
            return current == root || current.hasPrefix(root == "/" ? root : root + "/")
        }.max { paths.canonicalize($0.path).string.count < paths.canonicalize($1.path).string.count }
    }
}

public struct NodePackageIdentity: Codable, Equatable, Sendable {
    public let version: NodeVersion
    public let platform: String
    public let architecture: String
    public let artifactSHA256: String
    public let receiptVersion: Int
}

public enum NodeResolution: Equatable, Sendable {
    case invocationPATH
    case managed(NodePackageIdentity, executable: String)
}

public struct ProjectNodeSelection: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let name: String
    public let path: String
    public let availability: PathAvailability
    public let pinnedVersion: NodeVersion?
    public let runtimeAvailable: Bool
    public let detail: String?

    public init(record: NodeProjectRecord, runtimeAvailable: Bool, detail: String? = nil) {
        projectID = record.id; name = record.name; path = record.path; pinnedVersion = record.pin
        availability = CanonicalPathService().availability(of: CanonicalPathService().canonicalize(record.path))
        self.runtimeAvailable = runtimeAvailable; self.detail = detail
    }
}

public struct NodePackageValidationSnapshot: Sendable {
    private let packages: [NodeVersion: Result<NodePackageIdentity, NodeError>]

    internal init(versions: [NodeVersion], resolve: (NodeVersion) throws -> NodePackageIdentity) {
        packages = Dictionary(uniqueKeysWithValues: Set(versions).map { version in
            let result: Result<NodePackageIdentity, NodeError>
            do { result = .success(try resolve(version)) }
            catch let error as NodeError { result = .failure(error) }
            catch { result = .failure(.unavailable(error.localizedDescription)) }
            return (version, result)
        })
    }

    public func package(_ version: NodeVersion) throws -> NodePackageIdentity {
        guard let result = packages[version] else { throw NodeError.unavailable("This exact version was not validated for this request.") }
        return try result.get()
    }

    public func selections(_ records: [NodeProjectRecord]) -> [ProjectNodeSelection] {
        records.map { record in
            guard let pin = record.pin else { return .init(record: record, runtimeAvailable: true) }
            do { _ = try package(pin); return .init(record: record, runtimeAvailable: true) }
            catch { return .init(record: record, runtimeAvailable: false, detail: error.localizedDescription) }
        }
    }
}

public struct NodeSelectionReader: Sendable {
    public let databaseURL: URL
    public init(databaseURL: URL) { self.databaseURL = databaseURL }

    public func records() throws -> [NodeProjectRecord] {
        let manager = FileManager.default
        var info = stat()
        if lstat(databaseURL.path, &info) != 0 {
            guard errno == ENOENT else { throw NodeError.invalidState("The database path is unreadable.") }
            return []
        }
        let values = try databaseURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw NodeError.invalidState("The database must be a regular file.") }
        let handle = try FileHandle(forReadingFrom: databaseURL)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 100) ?? Data()
        guard header.count == 100, header.prefix(16) == Data("SQLite format 3\0".utf8), header[18] == 1, header[19] == 1,
              !manager.fileExists(atPath: databaseURL.path + "-wal"), !manager.fileExists(atPath: databaseURL.path + "-shm") else {
            throw NodeError.invalidState("Corrupt or WAL state is unsupported by the strictly read-only resolver.")
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.resolvingSymlinksInPath().path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite handle."
            sqlite3_close(database)
            throw NodeError.invalidState("Unable to open the existing database read-only. \(detail)")
        }
        defer { sqlite3_close(database) }
        func query(_ sql: String, row: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw NodeError.invalidState("Invalid database schema.") }
            defer { sqlite3_finalize(statement) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW { try row(statement); status = sqlite3_step(statement) }
            guard status == SQLITE_DONE else { throw NodeError.invalidState("Database read failed.") }
        }
        try query("PRAGMA user_version") { guard sqlite3_column_int($0, 0) == SQLiteStateStore.schemaVersion else { throw NodeError.invalidState("Restart Core to upgrade incompatible state.") } }
        try query("PRAGMA quick_check") {
            guard let value = sqlite3_column_text($0, 0), String(cString: value) == "ok" else { throw NodeError.invalidState("Database integrity check failed.") }
        }
        func string(_ statement: OpaquePointer, _ index: Int32) throws -> String {
            guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let raw = sqlite3_column_text(statement, index), let value = String(bytes: UnsafeBufferPointer(start: raw, count: Int(sqlite3_column_bytes(statement, index))), encoding: .utf8), !value.utf8.contains(0) else { throw NodeError.invalidState("Invalid project record.") }
            return value
        }
        var result = [NodeProjectRecord]()
        try query("SELECT id,name,canonical_path,node_override_version FROM projects WHERE registration_kind = 'linked' ORDER BY canonical_path") { statement in
            guard let uuid = UUID(uuidString: try string(statement, 0)) else { throw NodeError.invalidState("Invalid project identity.") }
            let path = try string(statement, 2)
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw NodeError.invalidState("Invalid linked root.") }
            let pin = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : try NodeVersion(string(statement, 3))
            result.append(NodeProjectRecord(id: ProjectID(rawValue: uuid), name: try string(statement, 1), path: path, pin: pin))
        }
        return result
    }
}

extension ProjectRepository {
    public func nodeRecords() throws -> [NodeProjectRecord] {
        var result = [NodeProjectRecord]()
        try store.query("SELECT id,name,canonical_path,node_override_version FROM projects ORDER BY canonical_path") { statement in
            guard let id = UUID(uuidString: store.columnString(statement, 0) ?? ""), let name = store.columnString(statement, 1), let path = store.columnString(statement, 2) else { throw SQLiteStateError.invalidRecord }
            result.append(NodeProjectRecord(id: ProjectID(rawValue: id), name: name, path: path, pin: try store.columnString(statement, 3).map(NodeVersion.init)))
        }
        return result
    }

    public func setNodeOverride(_ version: NodeVersion?, for projectID: ProjectID) throws {
        guard try all().contains(where: { $0.id == projectID }) else { throw ProjectRegistryError.projectNotFound }
        try store.query("UPDATE projects SET node_override_version = ? WHERE id = ?", bind: { statement in
            if let version { store.bind(version.description, to: statement, index: 1) }
            store.bind(projectID.description, to: statement, index: 2)
        }) { _ in }
    }
}
