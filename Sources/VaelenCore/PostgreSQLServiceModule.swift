import Foundation
import Darwin
import CryptoKit

public enum PostgreSQLServiceError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedPackage
    case invalidPackage(String)
    case missingInstance
    case existingInstanceMismatch
    case nonemptyDataDirectory
    case portConflict(Int)
    case processIdentityMismatch
    case processFailure(String)
    case runningOrClaimed

    public var errorDescription: String? {
        switch self {
        case .unsupportedPackage: "PostgreSQL package postgresql-18.6 is unavailable."
        case .invalidPackage(let reason): "PostgreSQL package validation failed: \(reason)"
        case .missingInstance: "The named PostgreSQL instance does not exist."
        case .existingInstanceMismatch: "The named PostgreSQL instance already exists with different settings."
        case .nonemptyDataDirectory: "The PostgreSQL data directory is not empty; existing files were preserved."
        case .portConflict(let port): "Loopback port \(port) is already in use."
        case .processIdentityMismatch: "The PostgreSQL process identity could not be verified; it was left untouched."
        case .processFailure(let reason): reason
        case .runningOrClaimed: "The PostgreSQL instance must be stopped and unclaimed before removal."
        }
    }
}

private final class PostgreSQLProvisioningAdapter: ProjectDatabaseProvisioningEngine, @unchecked Sendable {
    private let module: PostgreSQLServiceModule
    private let target: VerifiedDatabaseTarget
    private let packageRoot: URL
    private let socketPath: String

    init(module: PostgreSQLServiceModule, target: VerifiedDatabaseTarget, packageRoot: URL, socketPath: String) {
        self.module = module
        self.target = target
        self.packageRoot = packageRoot
        self.socketPath = socketPath
    }

    func bound(to target: VerifiedDatabaseTarget) -> PostgreSQLProvisioningAdapter {
        PostgreSQLProvisioningAdapter(module: module, target: target, packageRoot: packageRoot, socketPath: socketPath)
    }

    func clusterIdentity(for target: VerifiedDatabaseTarget) throws -> String {
        guard target.record == self.target.record, target.binding == self.target.binding else { throw DatabaseProvisioningError.targetMismatch }
        let value = try query(database: "postgres", sql: "SELECT system_identifier::text FROM pg_control_system();")
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw DatabaseProvisioningError.engineFailure }
        return value
    }

    func checkAbsent(database: DatabaseName, user: DatabaseUserName) throws -> DatabaseProvisionDiagnostic? {
        let sql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_database WHERE datname = \(literal(database.value))) THEN 'database' WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = \(literal(user.value))) THEN 'user' ELSE '' END;"
        let result: String = try query(database: "postgres", sql: sql)
        switch result {
        case "database": return DatabaseProvisionDiagnostic.existingDatabase
        case "user": return DatabaseProvisionDiagnostic.existingUser
        case "": return nil
        default: throw DatabaseProvisioningError.engineFailure
        }
    }

    func createLockedUser(_ user: DatabaseUserName, password: SecretPassword) throws {
        _ = password
        try execute(database: "postgres", sql: "CREATE ROLE \(identifier(user.value)) WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;")
    }

    func createDatabase(_ database: DatabaseName) throws {
        throw DatabaseProvisioningError.engineFailure
    }

    func createDatabase(_ database: DatabaseName, owner: DatabaseUserName) throws {
        _ = try query(database: "postgres", sql: "CREATE DATABASE \(identifier(database.value)) OWNER \(identifier(owner.value)); REVOKE ALL PRIVILEGES ON DATABASE \(identifier(database.value)) FROM PUBLIC;")
    }

    func grantApplicationAccess(database: DatabaseName, user: DatabaseUserName) throws {
        _ = try query(database: "postgres", sql: "GRANT CONNECT, TEMPORARY ON DATABASE \(identifier(database.value)) TO \(identifier(user.value));")
        _ = try query(database: database.value, sql: "GRANT USAGE, CREATE ON SCHEMA public TO \(identifier(user.value));")
    }

    func enableLogin(user: DatabaseUserName) throws {
        throw DatabaseProvisioningError.engineFailure
    }

    func enableLogin(user: DatabaseUserName, database: DatabaseName, password: SecretPassword) throws {
        try module.installApplicationHBA(for: target, database: database, user: user)
        _ = try module.provisioningQuery(target, package: packageRoot, socketPath: socketPath, database: "postgres", sql: "ALTER ROLE \(identifier(user.value)) WITH LOGIN PASSWORD '__VAELEN_PASSWORD__';", password: password)
    }

    func authenticate(database: DatabaseName, user: DatabaseUserName, password: SecretPassword) throws {
        try module.authenticateApplication(target, package: packageRoot, socketPath: socketPath, database: database, user: user, password: password)
    }

    private func query(database: String, sql: String) throws -> String {
        try module.provisioningQuery(target, package: packageRoot, socketPath: socketPath, database: database, sql: sql)
    }

    private func execute(database: String, sql: String) throws {
        _ = try query(database: database, sql: sql)
    }

    private func identifier(_ value: String) -> String { "\"\(value)\"" }
    private func literal(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "''"))'" }
}

public struct PostgreSQLServiceStatus: Equatable, Sendable {
    public let record: ServiceInstanceRecord?
    public let health: String
    public let pid: Int32?
    public let queryOutput: String?
}

public final class PostgreSQLServiceModule: @unchecked Sendable {
    public static let packageIdentifier = "postgresql-18.6"
    private let layout: VaelenFilesystemLayout
    private let repository: ServiceInstanceRepository
    private let packageSource: URL
    private let shutdownTimeout: TimeInterval
    private let manager = FileManager.default
    private let lock = NSRecursiveLock()
    private var ownedProcesses: [String: Process] = [:]

    public init(layout: VaelenFilesystemLayout, repository: ServiceInstanceRepository, packageRoot: URL? = nil, shutdownTimeout: TimeInterval = 10) {
        self.layout = layout
        self.repository = repository
        self.packageSource = (packageRoot ?? layout.postgresqlPackagesDirectoryURL.appendingPathComponent(Self.packageIdentifier, isDirectory: true)).resolvingSymlinksInPath().standardizedFileURL
        self.shutdownTimeout = shutdownTimeout
    }

    public static func availableLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PostgreSQLServiceError.processFailure("Could not allocate a loopback socket.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw PostgreSQLServiceError.processFailure("Could not reserve a loopback port.") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard read == 0 else { throw PostgreSQLServiceError.processFailure("Could not read the reserved loopback port.") }
        return Int(UInt16(bigEndian: actual.sin_port))
    }

    public func create(id: ServiceInstanceID, port: Int) throws -> ServiceInstanceRecord {
        lock.lock(); defer { lock.unlock() }
        guard id.kind == .postgresql, (1...65535).contains(port) else { throw SQLiteStateError.invalidRecord }
        let package = try validatedPackage()
        let paths = instancePaths(id)
        let record = try ServiceInstanceRecord(id: id, packageIdentifier: Self.packageIdentifier, endpoint: .postgresql(port: port), dataDirectory: paths.data.path)
        if let existing = try repository.instance(id) {
            guard existing == record else { throw PostgreSQLServiceError.existingInstanceMismatch }
            try repository.saveManuallyClaimedInstance(existing)
            return existing
        }
        try manager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if manager.fileExists(atPath: paths.data.path) {
            let contents = try manager.contentsOfDirectory(atPath: paths.data.path)
            guard contents.isEmpty else { throw PostgreSQLServiceError.nonemptyDataDirectory }
        } else {
            try manager.createDirectory(at: paths.data, withIntermediateDirectories: true)
        }
        let initdb = try run(package.appendingPathComponent("bin/initdb"), ["-D", paths.data.path, "--encoding=UTF8", "--locale=C"], timeout: 60)
        guard initdb.status == 0 else { throw PostgreSQLServiceError.processFailure(initdb.output) }
        try repository.saveManuallyClaimedInstance(record)
        return record
    }

    public func status(id: ServiceInstanceID) throws -> PostgreSQLServiceStatus {
        lock.lock(); defer { lock.unlock() }
        guard let record = try repository.instance(id) else { return PostgreSQLServiceStatus(record: nil, health: "not-created", pid: nil, queryOutput: nil) }
        guard let evidence = readEvidence(id) else { return PostgreSQLServiceStatus(record: record, health: "stopped", pid: nil, queryOutput: nil) }
        guard processExists(evidence.pid) else {
            try? manager.removeItem(at: instancePaths(id).evidence)
            return PostgreSQLServiceStatus(record: record, health: "stopped", pid: nil, queryOutput: nil)
        }
        guard processMatches(evidence, record: record) else { return PostgreSQLServiceStatus(record: record, health: "identity-unverified", pid: evidence.pid, queryOutput: nil) }
        guard let package = try? validatedPackage(), package.appendingPathComponent("bin/psql").path == evidence.psqlPath else {
            return PostgreSQLServiceStatus(record: record, health: "identity-unverified", pid: evidence.pid, queryOutput: nil)
        }
        let check = try? run(package.appendingPathComponent("bin/psql"), ["-h", "127.0.0.1", "-p", "\(record.endpoint.portNumbers.first)", "-d", "postgres", "-At", "-c", "SELECT 1, current_setting('server_version'), current_setting('data_directory')"], timeout: 8)
        guard let check, check.status == 0 else { return PostgreSQLServiceStatus(record: record, health: "unhealthy", pid: evidence.pid, queryOutput: check?.output) }
        let output = check.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedVersion = output.split(separator: "|").dropFirst().first.map(String.init)
        let expectedDirectory = output.split(separator: "|").dropFirst(2).first.map(String.init)
        guard output.hasPrefix("1|18.6"), expectedVersion?.hasPrefix("18.") == true,
              URL(fileURLWithPath: expectedDirectory ?? "").standardizedFileURL.path == URL(fileURLWithPath: record.dataDirectory).standardizedFileURL.path else {
            return PostgreSQLServiceStatus(record: record, health: "unhealthy", pid: evidence.pid, queryOutput: output)
        }
        return PostgreSQLServiceStatus(record: record, health: "healthy", pid: evidence.pid, queryOutput: output)
    }

    public func projectBindingSnapshot(for id: ServiceInstanceID) -> ModuleOwnedServiceSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard id.kind == .postgresql, let record = try? repository.instance(id),
              let status = try? self.status(id: id), status.record == record else {
            return .init(record: nil, health: "identity-unverified")
        }
        return .init(record: record, health: status.health)
    }

    public func provisionDatabase(_ request: ProjectDatabaseCreation, record: ServiceInstanceRecord, receipts: ProjectDatabaseReceiptRepository, passwords: any ProjectDatabasePasswordStore, retryFailedBeforeDDL: Bool = false) throws -> DatabaseProvisionAttempt {
        let target = VerifiedDatabaseTarget(projectID: request.projectID, binding: request.binding, record: record, clusterIdentity: "")
        return try withDatabaseProvisioning(target) { engine in
            let identity = try engine.clusterIdentity(for: target)
            let verified = VerifiedDatabaseTarget(projectID: request.projectID, binding: request.binding, record: record, clusterIdentity: identity)
            let bound = engine.bound(to: verified)
            let provisioner = ProjectDatabaseProvisioner(receipts: receipts, passwords: passwords, engine: bound)
            return try retryFailedBeforeDDL ? provisioner.retry(request, target: verified) : provisioner.create(request, target: verified)
        }
    }

    public func revealDatabasePassword(for attempt: DatabaseProvisionAttempt, record: ServiceInstanceRecord, passwords: any ProjectDatabasePasswordStore) throws -> String {
        guard attempt.state == .ready, attempt.request.projectID == attempt.target.projectID,
              attempt.request.binding == attempt.target.binding, attempt.target.record == record else { throw DatabaseProvisioningError.targetMismatch }
        return try withDatabaseProvisioning(attempt.target) { engine in
            guard try engine.clusterIdentity(for: attempt.target) == attempt.target.clusterIdentity else { throw DatabaseProvisioningError.targetMismatch }
            let password = try passwords.load(for: attempt.request.operationID)
            return try password.withBytes { bytes in
                guard let value = String(bytes: bytes, encoding: .utf8), !value.isEmpty else { throw DatabaseProvisioningError.secretUnavailable }
                return value
            }
        }
    }

    public func databaseTargetMatches(_ attempt: DatabaseProvisionAttempt) -> Bool {
        guard attempt.request.binding == attempt.target.binding, attempt.request.projectID == attempt.target.projectID else { return false }
        return (try? withDatabaseProvisioning(attempt.target) { engine in
            try engine.clusterIdentity(for: attempt.target) == attempt.target.clusterIdentity
        }) == true
    }

    private func withDatabaseProvisioning<T>(_ target: VerifiedDatabaseTarget, _ operation: (PostgreSQLProvisioningAdapter) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let id = target.record.id
        guard target.binding.kind == .postgresql, target.binding.instance == id.name,
              target.binding.version == nil || target.binding.version == Self.packageIdentifier,
              id.kind == .postgresql, target.record.packageIdentifier == Self.packageIdentifier,
              target.record.endpoint.kind == .postgresql, try repository.instance(id) == target.record,
              let state = try? status(id: id), state.record == target.record, state.health == "healthy",
              let package = try? validatedPackage(), let evidence = readEvidence(id),
              evidence.psqlPath == package.appendingPathComponent("bin/psql").path else {
            throw DatabaseProvisioningError.targetMismatch
        }
        let adapter = PostgreSQLProvisioningAdapter(module: self, target: target, packageRoot: package, socketPath: instancePaths(id).socket.path)
        if !target.clusterIdentity.isEmpty, try adapter.clusterIdentity(for: target) != target.clusterIdentity {
            throw DatabaseProvisioningError.targetMismatch
        }
        return try operation(adapter)
    }

    func provisioningQuery(_ target: VerifiedDatabaseTarget, package: URL, socketPath: String, database: String, sql: String, password: SecretPassword? = nil, secretFileInput: Data? = nil, host: String? = nil, user: String? = nil) throws -> String {
        let arguments = ["-X", "-w", "-h", host ?? socketPath, "-p", "\(target.record.endpoint.portNumbers.first)", "-U", user ?? NSUserName(), "-d", database, "-v", "ON_ERROR_STOP=1", "-qAt"]
        let input: Data
        if let password {
            let secretStatement = try password.withBytes { bytes -> String in
                guard let value = String(bytes: bytes, encoding: .utf8), !value.isEmpty else { throw DatabaseProvisioningError.secretUnavailable }
                return sql.replacingOccurrences(of: "__VAELEN_PASSWORD__", with: value.replacingOccurrences(of: "'", with: "''"))
            }
            let settings = """
            SET log_statement = 'none';
            SET log_duration = off;
            SET log_min_duration_statement = -1;
            SET log_min_duration_sample = -1;
            SET log_statement_sample_rate = 0;
            SET log_transaction_sample_rate = 0;
            SET log_min_error_statement = 'PANIC';
            SET log_parameter_max_length = 0;
            SET log_parameter_max_length_on_error = 0;
            DO $vaelen_log_guard$ BEGIN
              IF NOT (current_setting('log_statement', true) = 'none'
              AND current_setting('log_duration', true) = 'off'
              AND current_setting('log_min_duration_statement', true) = '-1'
              AND current_setting('log_min_duration_sample', true) = '-1'
              AND current_setting('log_statement_sample_rate', true) = '0'
              AND current_setting('log_transaction_sample_rate', true) = '0'
              AND current_setting('log_min_error_statement', true) = 'panic'
              AND current_setting('log_parameter_max_length', true) = '0'
              AND current_setting('log_parameter_max_length_on_error', true) = '0'
              AND COALESCE(current_setting('shared_preload_libraries', true), '') = ''
              AND COALESCE(current_setting('session_preload_libraries', true), '') = ''
              AND COALESCE(current_setting('local_preload_libraries', true), '') = ''
              AND NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgaudit')) THEN
                RAISE EXCEPTION 'PostgreSQL password statement logging could not be suppressed';
              END IF;
            END $vaelen_log_guard$;
            \(secretStatement)
            """
            input = Data(settings.utf8)
        } else {
            input = Data((sql + "\n").utf8)
        }
        let result = try run(package.appendingPathComponent("bin/psql"), arguments, timeout: 8, input: input, secretFileInput: secretFileInput)
        guard result.status == 0 else { throw DatabaseProvisioningError.engineFailure }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate func installApplicationHBA(for target: VerifiedDatabaseTarget, database: DatabaseName, user: DatabaseUserName) throws {
        let path = URL(fileURLWithPath: target.record.dataDirectory, isDirectory: true).appendingPathComponent("pg_hba.conf")
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DatabaseProvisioningError.targetMismatch }
        let current = try String(contentsOf: path, encoding: .utf8)
        let rule = "host \(database.value) \(user.value) 127.0.0.1/32 scram-sha-256"
        guard !current.split(separator: "\n", omittingEmptySubsequences: false).contains(Substring(rule)) else { return }
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try Data((rule + "\n" + current + separator).utf8).write(to: path, options: .atomic)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path.path)
        }
        let package = try validatedPackage()
        let output = try provisioningQuery(target, package: package, socketPath: instancePaths(target.record.id).socket.path, database: "postgres", sql: "SELECT pg_reload_conf();")
        guard output == "t" else { throw DatabaseProvisioningError.engineFailure }
    }

    fileprivate func authenticateApplication(_ target: VerifiedDatabaseTarget, package: URL, socketPath: String, database: DatabaseName, user: DatabaseUserName, password: SecretPassword) throws {
        let passfile = try password.withBytes { bytes in
            guard let value = String(bytes: bytes, encoding: .utf8), !value.isEmpty,
                  !value.contains(":") && !value.contains("\\") else { throw DatabaseProvisioningError.secretUnavailable }
            return Data("127.0.0.1:\(target.record.endpoint.portNumbers.first):\(database.value):\(user.value):\(value)\n".utf8)
        }
        let query = "SELECT current_database() || '|' || current_user;"
        let output = try provisioningQuery(target, package: package, socketPath: socketPath, database: database.value, sql: query, secretFileInput: passfile, host: "127.0.0.1", user: user.value)
        guard output == "\(database.value)|\(user.value)" else { throw DatabaseProvisioningError.engineFailure }
    }

    public func start(id: ServiceInstanceID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = try repository.instance(id) else { throw PostgreSQLServiceError.missingInstance }
        if let status = try? self.status(id: id), status.health == "healthy" { return }
        if let evidence = readEvidence(id), processExists(evidence.pid) { throw PostgreSQLServiceError.processIdentityMismatch }
        let package = try validatedPackage()
        let port = record.endpoint.portNumbers.first
        guard portIsFree(port) else { throw PostgreSQLServiceError.portConflict(port) }
        let paths = instancePaths(id)
        try manager.createDirectory(at: paths.socket, withIntermediateDirectories: true)
        try manager.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        let options = "-h 127.0.0.1 -p \(port) -k \(paths.socket.path)"
        try manager.createDirectory(at: paths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: paths.log.path) { manager.createFile(atPath: paths.log.path, contents: nil) }
        let log = try FileHandle(forWritingTo: paths.log)
        try log.seekToEnd()
        let server = Process(); server.executableURL = package.appendingPathComponent("bin/postgres")
        server.arguments = ["-D", paths.data.path, "-h", "127.0.0.1", "-p", "\(port)", "-k", paths.socket.path]
        server.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": layout.rootURL.path, "LC_ALL": "C", "TZ": "UTC"]
        server.standardOutput = log; server.standardError = log
        try server.run()
        let pid = server.processIdentifier
        let identityDeadline = Date().addingTimeInterval(5)
        var identity: (startedAt: String, executable: String, command: String)?
        while Date() < identityDeadline {
            identity = processIdentity(pid)
            if identity != nil { break }
            usleep(20_000)
        }
        guard let identity, identity.command.contains(paths.data.path), canonicalPath(identity.executable) == canonicalPath(package.appendingPathComponent("bin/postgres").path) else {
            if server.isRunning { server.terminate(); server.waitUntilExit() }
            let logText = (try? String(contentsOf: paths.log, encoding: .utf8)) ?? ""
            throw PostgreSQLServiceError.processFailure("PostgreSQL process identity did not match after start. pid=\(pid) observed=\(String(describing: identity)) expected=\(package.appendingPathComponent("bin/postgres").path) log=\(logText)")
        }
        let evidence = ProcessEvidence(pid: pid, startedAt: identity.startedAt, executable: identity.executable, command: identity.command, dataDirectory: paths.data.path, port: port, psqlPath: package.appendingPathComponent("bin/psql").path)
        try JSONEncoder().encode(evidence).write(to: paths.evidence, options: .atomic)
        ownedProcesses[id.name.value] = server
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try status(id: id).health == "healthy" { return }
            usleep(100_000)
        }
        throw PostgreSQLServiceError.processFailure("PostgreSQL started but did not pass its exact data-directory and version health check; process evidence was retained.")
    }

    public func stop(id: ServiceInstanceID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = try repository.instance(id) else { throw PostgreSQLServiceError.missingInstance }
        guard let evidence = readEvidence(id) else { return }
        guard processMatches(evidence, record: record) else { throw PostgreSQLServiceError.processIdentityMismatch }
        let package = try validatedPackage()
        guard kill(evidence.pid, SIGTERM) == 0 || errno == ESRCH else { throw PostgreSQLServiceError.processFailure("PostgreSQL graceful shutdown signal failed; process evidence and data were retained.") }
        let deadline = Date().addingTimeInterval(shutdownTimeout)
        while Date() < deadline && processExists(evidence.pid) { usleep(50_000) }
        guard !processExists(evidence.pid) else { throw PostgreSQLServiceError.processFailure("PostgreSQL did not stop before the deadline; process evidence and data were retained.") }
        ownedProcesses.removeValue(forKey: id.name.value)
        try? manager.removeItem(at: instancePaths(id).evidence)
    }

    public func remove(id: ServiceInstanceID) throws {
        lock.lock(); defer { lock.unlock() }
        guard let record = try repository.instance(id) else { throw PostgreSQLServiceError.missingInstance }
        guard try status(id: id).health == "stopped" else { throw PostgreSQLServiceError.runningOrClaimed }
        do { try repository.removeStoppedInstance(id) }
        catch { throw PostgreSQLServiceError.runningOrClaimed }
        _ = record
    }

    private struct ProcessEvidence: Codable {
        let pid: Int32
        let startedAt: String
        let executable: String
        let command: String
        let dataDirectory: String
        let port: Int
        let psqlPath: String
    }
    private struct Paths {
        let root: URL; let data: URL; let socket: URL; let runtime: URL; let log: URL; let evidence: URL
    }
    private func instancePaths(_ id: ServiceInstanceID) -> Paths {
        let root = layout.postgresqlInstancesDirectoryURL.appendingPathComponent(id.name.value, isDirectory: true)
        let runtime = layout.rootURL.appendingPathComponent("runtime/postgresql/\(id.name.value)", isDirectory: true)
        let socketToken = String(SHA256.hash(data: Data((layout.rootURL.path + "\u{0}" + id.name.value).utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
        let socket = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("vpg-\(socketToken)", isDirectory: true)
        return Paths(root: root, data: root.appendingPathComponent("data", isDirectory: true), socket: socket, runtime: runtime, log: layout.logsDirectoryURL.appendingPathComponent("postgresql/\(id.name.value).log"), evidence: runtime.appendingPathComponent("process.json"))
    }
    private func validatedPackage() throws -> URL {
        if isExecutable(packageSource.appendingPathComponent("bin/postgres")), isExecutable(packageSource.appendingPathComponent("bin/initdb")), isExecutable(packageSource.appendingPathComponent("bin/psql")) {
            guard packageSource.lastPathComponent == Self.packageIdentifier,
                  (try? packageSource.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw PostgreSQLServiceError.invalidPackage("package root must be the exact postgresql-18.6 directory") }
            let version = try? run(packageSource.appendingPathComponent("bin/postgres"), ["--version"], timeout: 3)
            guard version?.status == 0, version?.output.contains("18.6") == true else { throw PostgreSQLServiceError.invalidPackage("unexpected PostgreSQL executable version") }
            return packageSource
        }
        throw PostgreSQLServiceError.unsupportedPackage
    }

    private func isExecutable(_ url: URL) -> Bool { manager.isExecutableFile(atPath: url.path) }
    private func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, input: Data = Data(), secretFileInput: Data? = nil) throws -> (status: Int32, output: String) {
        try manager.createDirectory(at: layout.cacheDirectoryURL.appendingPathComponent("postgresql-command-logs", isDirectory: true), withIntermediateDirectories: true)
        let logURL = layout.cacheDirectoryURL.appendingPathComponent("postgresql-command-logs", isDirectory: true).appendingPathComponent(UUID().uuidString)
        let fd = open(logURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw PostgreSQLServiceError.processFailure("Could not create a private command log.") }
        close(fd)
        defer { try? manager.removeItem(at: logURL) }
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw PostgreSQLServiceError.processFailure("Could not initialize command output redirection.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        _ = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logURL.path, O_WRONLY | O_APPEND, 0o600)
        _ = posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        var inputPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&inputPipe) == 0 else { throw PostgreSQLServiceError.processFailure("Could not create a private command input channel.") }
        var secretFileDescriptor: Int32?
        defer {
            if inputPipe[0] >= 0 { close(inputPipe[0]) }
            if inputPipe[1] >= 0 { close(inputPipe[1]) }
            if let secretFileDescriptor { close(secretFileDescriptor) }
        }
        guard posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, inputPipe[1]) == 0 else {
            throw PostgreSQLServiceError.processFailure("Could not configure the private command input channel.")
        }
        if let secretFileInput {
            let descriptor = try anonymousCredentialDescriptor(secretFileInput)
            secretFileDescriptor = descriptor
            guard posix_spawn_file_actions_adddup2(&actions, descriptor, 9) == 0,
                  (descriptor == 9 || posix_spawn_file_actions_addclose(&actions, descriptor) == 0) else {
                throw PostgreSQLServiceError.processFailure("Could not configure the private credential channel.")
            }
        }
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        var environmentStrings: [String] = []
        var environmentPointers: [UnsafeMutablePointer<CChar>?] = []
        if secretFileInput != nil {
            var index = 0
            while let entry = environ[index] {
                let value = String(cString: entry)
                if !value.hasPrefix("PGPASSFILE=") { environmentStrings.append(value) }
                index += 1
            }
            environmentStrings.append("PGPASSFILE=/dev/fd/9")
            environmentPointers = environmentStrings.map { strdup($0) }
            environmentPointers.append(nil)
        }
        defer { environmentPointers.forEach { if let value = $0 { free(value) } } }
        let spawnResult: Int32
        if secretFileInput == nil {
            spawnResult = posix_spawn(&pid, executable.path, &actions, nil, &argv, environ)
        } else {
            spawnResult = posix_spawn(&pid, executable.path, &actions, nil, &argv, &environmentPointers)
        }
        guard spawnResult == 0 else { throw PostgreSQLServiceError.processFailure("Could not launch command \(executable.path): \(spawnResult)") }
        close(inputPipe[0]); inputPipe[0] = -1
        if let descriptor = secretFileDescriptor { close(descriptor); secretFileDescriptor = nil }
        func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return true }
                var offset = 0
                while offset < data.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                    if count < 0 { if errno == EINTR { continue }; return false }
                    offset += count
                }
                return true
            }
        }
        guard writeAll(input, to: inputPipe[1]) else { _ = kill(pid, SIGTERM); throw PostgreSQLServiceError.processFailure("Could not deliver private command input.") }
        close(inputPipe[1]); inputPipe[1] = -1
        let deadline = Date().addingTimeInterval(timeout)
        var waitStatus: Int32 = 0
        while true {
            let waited = waitpid(pid, &waitStatus, WNOHANG)
            if waited == pid { break }
            if waited < 0 {
                if errno == EINTR { continue }
                throw PostgreSQLServiceError.processFailure("Could not observe command exit: \(executable.path)")
            }
            if Date() >= deadline {
                _ = kill(pid, SIGTERM)
                let terminationDeadline = Date().addingTimeInterval(1)
                repeat {
                    let reaped = waitpid(pid, &waitStatus, WNOHANG)
                    if reaped == pid { break }
                    if reaped < 0 && errno != EINTR { break }
                    usleep(20_000)
                } while Date() < terminationDeadline
                if waitpid(pid, &waitStatus, WNOHANG) == 0 { _ = kill(pid, SIGKILL); _ = waitpid(pid, &waitStatus, 0) }
                throw PostgreSQLServiceError.processFailure("Command timed out: \(executable.path)")
            }
            usleep(20_000)
        }
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let code = (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
        return (code, output)
    }

    private func anonymousCredentialDescriptor(_ data: Data) throws -> Int32 {
        // libpq rejects passfiles with group/world permissions, which an anonymous pipe has.
        var template = Array((NSTemporaryDirectory() + "vaelen-pgpass.XXXXXX").utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in mkstemp(buffer.baseAddress!) }
        guard descriptor >= 0 else { throw PostgreSQLServiceError.processFailure("Could not create a private PostgreSQL credential descriptor.") }
        let path = String(cString: template)
        var keepDescriptor = false
        defer {
            if !keepDescriptor {
                _ = unlink(path)
                close(descriptor)
            }
        }
        guard fchmod(descriptor, 0o600) == 0, unlink(path) == 0 else {
            throw PostgreSQLServiceError.processFailure("Could not secure the private PostgreSQL credential descriptor.")
        }
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                offset += count
            }
            return true
        }
        guard written, lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw PostgreSQLServiceError.processFailure("Could not prepare the private PostgreSQL credential descriptor.")
        }
        keepDescriptor = true
        return descriptor
    }

    private func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian); address.sin_port = in_port_t(port).bigEndian
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
    private func readEvidence(_ id: ServiceInstanceID) -> ProcessEvidence? { try? JSONDecoder().decode(ProcessEvidence.self, from: Data(contentsOf: instancePaths(id).evidence)) }
    private func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func processIdentity(_ pid: Int32) -> (startedAt: String, executable: String, command: String)? {
        guard let ps = try? run(URL(fileURLWithPath: "/bin/ps"), ["-p", "\(pid)", "-o", "lstart=,command="], timeout: 3), ps.status == 0,
              let executable = procPath(pid) else { return nil }
        let parts = ps.output.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 5, whereSeparator: \.isWhitespace)
        guard parts.count >= 6 else { return nil }
        return (parts.prefix(5).joined(separator: " "), canonicalPath(executable), parts.dropFirst(5).joined(separator: " "))
    }
    private func procPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return count > 0 ? String(cString: buffer) : nil
    }
    private func processMatches(_ evidence: ProcessEvidence, record: ServiceInstanceRecord) -> Bool {
        guard evidence.dataDirectory == record.dataDirectory, evidence.port == record.endpoint.portNumbers.first,
              let identity = processIdentity(evidence.pid) else { return false }
        return identity.startedAt == evidence.startedAt && identity.executable == evidence.executable && identity.command == evidence.command && identity.command.contains(record.dataDirectory)
    }
    private func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
