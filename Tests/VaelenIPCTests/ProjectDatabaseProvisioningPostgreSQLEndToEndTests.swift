import Foundation
import CryptoKit
import Darwin
import Security
import XCTest
@testable import VaelenCore
import VaelenIPC
import VaelenDaemonSupport

final class ProjectDatabaseProvisioningPostgreSQLEndToEndTests: XCTestCase {
    func testInstalledPostgreSQLProvisioningThroughValAndPrivateCore() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let val = environment["VAELEN_VAL_EXECUTABLE"],
              let postgresRoot = environment["VAELEN_TEST_POSTGRESQL_PACKAGE_ROOT"],
              let php = environment["VAELEN_TEST_POSTGRESQL_PHP_EXECUTABLE"] else {
            throw XCTSkip("Run Scripts/tests/val-project-database-provisioning-test.sh with the verified local PostgreSQL and PHP packages.")
        }
        let fm = FileManager.default
        let packageRoot = URL(fileURLWithPath: postgresRoot, isDirectory: true)
        let expectedPackageRoot = URL(fileURLWithPath: "/Users/banes/.codex/worktrees/vaelen/service-data-backup-recovery-fixtures/extracted/postgresql-18.6", isDirectory: true)
        let packageExecutablesExist = ["postgres", "initdb", "psql"].allSatisfy {
            fm.isExecutableFile(atPath: packageRoot.appendingPathComponent("bin/\($0)").path)
        }
        guard packageRoot.standardizedFileURL == expectedPackageRoot.standardizedFileURL,
              packageExecutablesExist, fm.isExecutableFile(atPath: php) else {
            throw XCTSkip("The exact local PostgreSQL 18.6 package or PHP executable is unavailable.")
        }
        let version = try command(packageRoot.appendingPathComponent("bin/postgres").path, ["--version"])
        guard version.contains("18.6") else { throw XCTSkip("The local server package is not PostgreSQL 18.6.") }

        let root = URL(fileURLWithPath: "/private/tmp/vaelen-dbprov-\(UUID().uuidString)", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true))
        let endpoints = CoreEndpointPaths(layout: layout)
        let port = try PostgreSQLServiceModule.availableLoopbackPort()
        let namespace = "dev.vaelen.project-database.acceptance.\(UUID().uuidString)"
        let passwords = KeychainProjectDatabasePasswordStore(namespace: namespace)
        let serviceID = ServiceInstanceID(kind: .postgresql, name: try ProjectInstanceName("primary"))
        let module = PostgreSQLServiceModule(layout: layout, repository: ServiceInstanceRepository(store: try SQLiteStateStore(databaseURL: layout.databaseURL)), packageRoot: packageRoot)
        let packageID = PostgreSQLServiceModule.packageIdentifier
        var serverTask: Task<Void, Error>?
        var serverExited = DispatchSemaphore(value: 0)
        var coreStopped = false
        var preserveRoot = false
        var projectID: ProjectID?
        var postgresPID: Int32?
        let project = root.appendingPathComponent("project", isDirectory: true)
        let neighbor = root.appendingPathComponent("neighbor", isDirectory: true)
        let envURL = project.appendingPathComponent(".env")
        let envBytes = Data([0x23, 0x20, 0xff, 0x0a, 0x44, 0x42, 0x5f, 0x48, 0x4f, 0x53, 0x54, 0x3d, 0x6c, 0x6f, 0x63, 0x61, 0x6c, 0x0a])

        func makeDispatcher() throws -> CoreRequestDispatcher {
            let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
            let repository = ServiceInstanceRepository(store: store)
            return try CoreRequestDispatcher(
                runtime: CoreRuntime(version: "test", pid: getpid()),
                registry: ProjectRegistry(store: store),
                postgresql: module,
                serviceIntents: ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json")),
                serviceInstances: repository,
                databaseReceipts: ProjectDatabaseReceiptRepository(store: store),
                databasePasswords: passwords,
                logs: CoreLogCatalog(layout: layout)
            )
        }

        func launchCore(_ dispatcher: CoreRequestDispatcher, exited: DispatchSemaphore) -> Task<Void, Error> {
            let server = DaemonServer(paths: endpoints, dispatcher: dispatcher)
            return Task.detached { defer { exited.signal() }; await dispatcher.restoreServicesOnStartup(); try server.run() }
        }

        func runVal(_ args: [String], cwd: URL) throws -> (Int32, String, String) {
            let outputURL = root.appendingPathComponent("safe.stdout")
            let errorURL = root.appendingPathComponent("safe.stderr")
            fm.createFile(atPath: outputURL.path, contents: nil)
            fm.createFile(atPath: errorURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: val)
            process.arguments = args
            process.currentDirectoryURL = cwd
            process.environment = environment.merging([
                "VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1",
                "VAELEN_TEST_SUPPORT_ROOT": layout.rootURL.path,
                "NO_COLOR": "1"
            ]) { _, value in value }
            process.standardOutput = output
            process.standardError = error
            try process.run()
            try finish(process)
            try output.close()
            try error.close()
            return (process.terminationStatus,
                    String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
                    String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
        }

        do {
            try fm.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try fm.createDirectory(at: neighbor, withIntermediateDirectories: true)
            try envBytes.write(to: envURL)
            try Data("version: 2\nservices:\n  database:\n    kind: postgresql\n    instance: primary\n    version: \(packageID)\n".utf8).write(to: project.appendingPathComponent("vaelen.yml"))
            try Data("version: 2\nservices:\n  database:\n    kind: postgresql\n    instance: primary\n    version: \(packageID)\n".utf8).write(to: neighbor.appendingPathComponent("vaelen.yml"))

            try module.create(id: serviceID, port: port)
            let configURL = URL(fileURLWithPath: module.projectBindingSnapshot(for: serviceID).record!.dataDirectory).appendingPathComponent("postgresql.conf")
            let aggressiveLogging = "\nlog_statement = 'all'\nlog_duration = on\nlog_min_duration_statement = 0\nlog_min_duration_sample = 0\nlog_statement_sample_rate = 1\nlog_transaction_sample_rate = 1\nlog_min_error_statement = 'ERROR'\nlog_parameter_max_length = -1\nlog_parameter_max_length_on_error = -1\n"
            let originalConfig = try Data(contentsOf: configURL)
            try (originalConfig + Data(aggressiveLogging.utf8)).write(to: configURL, options: .atomic)
            try module.start(id: serviceID)
            XCTAssertEqual(try psql(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, sql: Data("SELECT current_setting('log_statement') || '|' || current_setting('log_duration') || '|' || current_setting('log_min_duration_statement') || '|' || current_setting('log_min_duration_sample') || '|' || current_setting('log_statement_sample_rate') || '|' || current_setting('log_transaction_sample_rate') || '|' || current_setting('log_min_error_statement') || '|' || current_setting('log_parameter_max_length') || '|' || current_setting('log_parameter_max_length_on_error');\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines), "all|on|0|0|1|1|error|-1|-1", "fixture must begin with aggressive server log settings")
            postgresPID = try module.status(id: serviceID).pid
            let snapshot = module.projectBindingSnapshot(for: serviceID)
            guard snapshot.health == "healthy", let record = snapshot.record else { throw FixtureError.childTimedOut }

            let dispatcher = try makeDispatcher()
            serverTask = launchCore(dispatcher, exited: serverExited)
            for _ in 0..<300 where !fm.fileExists(atPath: endpoints.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(fm.fileExists(atPath: endpoints.socketPath), "private Core socket must be ready")
            let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
            let registry = ProjectRegistry(store: store)
            let linked = try await registry.link(path: project, name: "dbprov-project")
            projectID = try XCTUnwrap(linked.id)
            let linkedNeighbor = try await registry.link(path: neighbor, name: "dbprov-neighbor")
            let neighborID = try XCTUnwrap(linkedNeighbor.id)
            let repository = ServiceInstanceRepository(store: store)
            let claimsBefore = try repository.projectClaims(for: projectID!)
            XCTAssertTrue(claimsBefore.isEmpty)
            let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .postgresql, instance: ProjectInstanceName("primary"), version: packageID)
            try repository.replaceProjectClaims([binding], materializing: [record], for: projectID!)
            let claims = try repository.projectClaims(for: projectID!)
            XCTAssertEqual(claims.count, 1)
            XCTAssertNotNil(postgresPID)
            XCTAssertEqual(try module.status(id: serviceID).health, "healthy")

            let sentinelDB = try DatabaseName("dbprov_sentinel")
            let sentinelUser = try DatabaseUserName("dbprov_sentinel_user")
            try seedSentinel(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, database: sentinelDB.value, user: sentinelUser.value)
            let collision = try runVal(["project", "db", "create", sentinelDB.value, "dbprov_unused_user", projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(collision.0, 0, collision.2 + collision.1)
            let collisionResult = try IPCCodec.decode(ProjectDatabaseAttemptResult.self, from: Data(collision.1.utf8))
            XCTAssertEqual(collisionResult.state, .refused)
            XCTAssertEqual(collisionResult.diagnostic, .existingDatabase)
            XCTAssertEqual(try psql(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, sql: Data("SELECT COUNT(*) FROM pg_roles WHERE rolname='dbprov_unused_user';\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines), "0", "database collision must refuse before creating the requested application role")
            XCTAssertEqual(try readSentinel(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, database: sentinelDB.value), "sentinel-preserved")

            let roleCollision = try runVal(["project", "db", "create", "dbprov_role_collision", sentinelUser.value, projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(roleCollision.0, 0, roleCollision.2 + roleCollision.1)
            let roleCollisionResult = try IPCCodec.decode(ProjectDatabaseAttemptResult.self, from: Data(roleCollision.1.utf8))
            XCTAssertEqual(roleCollisionResult.state, .refused)
            XCTAssertEqual(roleCollisionResult.diagnostic, .existingUser)
            XCTAssertEqual(try psql(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, sql: Data("SELECT COUNT(*) FROM pg_database WHERE datname='dbprov_role_collision';\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines), "0")

            let created = try runVal(["project", "db", "create", "dbprov_app", "dbprov_app_user", projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(created.0, 0, created.2 + created.1)
            let attempt = try IPCCodec.decode(ProjectDatabaseAttemptResult.self, from: Data(created.1.utf8))
            XCTAssertNotEqual(collisionResult.operationID, attempt.operationID, "each create request must use its own operation ID")
            XCTAssertEqual(attempt.state, .ready, "provisioning did not complete: state=\(attempt.state.rawValue) pending=\(String(describing: attempt.pendingEffect)) effects=\(attempt.confirmedEffects) uncertain=\(attempt.uncertainEffects) diagnostic=\(String(describing: attempt.diagnostic))")
            XCTAssertEqual(Set(attempt.confirmedEffects), Set(DatabaseProvisionEffect.allCases))
            let roleAttributes = try psql(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, sql: Data("SELECT rolcanlogin || '|' || rolsuper || '|' || rolcreatedb || '|' || rolcreaterole || '|' || rolinherit || '|' || rolreplication || '|' || rolbypassrls FROM pg_roles WHERE rolname='dbprov_app_user';\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(roleAttributes, "true|false|false|false|false|false|false", "application role must have only LOGIN enabled")

            let status = try runVal(["project", "db", "status", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(status.0, 0, status.2 + status.1)
            XCTAssertFalse(status.1.contains("password"))
            XCTAssertFalse(status.1.contains("secret"))
            let statusResult = try IPCCodec.decode(ProjectDatabaseAttemptResult.self, from: Data(status.1.utf8))
            XCTAssertEqual(statusResult.operationID, attempt.operationID)
            XCTAssertEqual(statusResult.state, .ready)

            try store.execute("UPDATE service_instances SET data_directory=? WHERE kind=? AND name=?", bind: { statement in
                store.bind(record.dataDirectory + "-replacement", to: statement, index: 1)
                store.bind("postgresql", to: statement, index: 2)
                store.bind("primary", to: statement, index: 3)
            })
            let changedRecordStatus = try runVal(["project", "db", "status", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertNotEqual(changedRecordStatus.0, 0, "status must refuse a changed saved service record")
            try store.execute("UPDATE service_instances SET data_directory=? WHERE kind=? AND name=?", bind: { statement in
                store.bind(record.dataDirectory, to: statement, index: 1)
                store.bind("postgresql", to: statement, index: 2)
                store.bind("primary", to: statement, index: 3)
            })
            try assertReplacementClusterIsRejected(
                module: module, serviceID: serviceID, dataDirectory: URL(fileURLWithPath: record.dataDirectory),
                packageRoot: packageRoot, val: val, operationID: attempt.operationID,
                projectID: projectID!, project: project, environment: environment, supportRoot: layout.rootURL
            )

            let wrongProjectReveal = try runValWithoutPersisting(["project", "db", "password", "reveal", attempt.operationID.rawValue.uuidString, neighborID.rawValue.uuidString], cwd: neighbor, executable: val, environment: environment, supportRoot: layout.rootURL)
            XCTAssertNotEqual(wrongProjectReveal.status, 0)
            XCTAssertFalse(wrongProjectReveal.output.contains("password"))

            let reveal = try revealInMemory(val: val, operationID: attempt.operationID, projectID: projectID!, cwd: project, environment: environment, supportRoot: layout.rootURL)
            let secretText = String(decoding: reveal.secret, as: UTF8.self)
            let recordForLogProbe = try XCTUnwrap(module.projectBindingSnapshot(for: serviceID).record)
            let liveClusterID = try psql(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, sql: Data("SELECT system_identifier::text FROM pg_control_system();\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
            let verifiedTarget = VerifiedDatabaseTarget(projectID: projectID!, binding: binding, record: recordForLogProbe, clusterIdentity: liveClusterID)
            let passwordMarker = "probe-\(UUID().uuidString)"
            let socketToken = String(SHA256.hash(data: Data((layout.rootURL.path + "\0primary").utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
            XCTAssertThrowsError(try module.provisioningQuery(
                verifiedTarget, package: packageRoot,
                socketPath: NSTemporaryDirectory() + "vpg-\(socketToken)",
                database: "postgres",
                sql: "ALTER ROLE vaelen_missing_probe_role WITH LOGIN PASSWORD '__VAELEN_PASSWORD__';",
                password: SecretPassword(bytes: Data(passwordMarker.utf8))
            )) { error in
                XCTAssertEqual(error as? DatabaseProvisioningError, .engineFailure)
            }
            let logsAfterFailure = (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "log" }
            for log in logsAfterFailure {
                XCTAssertFalse((try? Data(contentsOf: log))?.range(of: Data(passwordMarker.utf8)) != nil, "failed password SQL must not reach the PostgreSQL server log")
            }
            let hookMarker = "hook-probe-\(UUID().uuidString)"
            let adminRoleSQLName = NSUserName().replacingOccurrences(of: "\"", with: "\"\"")
            _ = try psql(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, sql: Data("ALTER ROLE \"\(adminRoleSQLName)\" SET session_preload_libraries = 'plpgsql';\n".utf8))
            let sessionPreloads = try psql(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, sql: Data("SELECT current_setting('session_preload_libraries');\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(sessionPreloads, "plpgsql")
            XCTAssertThrowsError(try module.provisioningQuery(
                verifiedTarget, package: packageRoot,
                socketPath: NSTemporaryDirectory() + "vpg-\(socketToken)",
                database: "postgres",
                sql: "ALTER ROLE vaelen_missing_hook_role WITH LOGIN PASSWORD '__VAELEN_PASSWORD__';",
                password: SecretPassword(bytes: Data(hookMarker.utf8))
            )) { error in
                XCTAssertEqual(error as? DatabaseProvisioningError, .engineFailure)
            }
            _ = try psql(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, sql: Data("ALTER ROLE \"\(adminRoleSQLName)\" RESET session_preload_libraries;\n".utf8))
            let logsAfterHook = (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "log" }
            for log in logsAfterHook {
                let data = try? Data(contentsOf: log)
                XCTAssertFalse(data?.range(of: Data(hookMarker.utf8)) != nil, "an active session preload must block secret SQL")
            }
            let wrongPassword = try runPDO(php: php, port: port, database: "dbprov_app", user: "dbprov_app_user", password: Data("wrong-password".utf8), sql: "SELECT 1;")
            XCTAssertNotEqual(wrongPassword.status, 0, "application account must reject an incorrect password")
            XCTAssertFalse(reveal.arguments.joined(separator: " ").contains(secretText))
            XCTAssertFalse(environment.values.contains(where: { $0.contains(secretText) }))
            XCTAssertFalse((created.1 + created.2 + status.1 + status.2).contains(secretText), "ordinary create and status output must not contain the credential")
            XCTAssertTrue(reveal.secret.count >= 32)
            let pdo = try runPDO(php: php, port: port, database: "dbprov_app", user: "dbprov_app_user", password: reveal.secret, sql: "CREATE TABLE migration_equivalent (id INT PRIMARY KEY, value VARCHAR(64) NOT NULL); INSERT INTO migration_equivalent VALUES (1, 'persisted-row'); SELECT value FROM migration_equivalent WHERE id = 1;")
            XCTAssertEqual(pdo.status, 0, pdo.error)
            XCTAssertEqual(pdo.output.trimmingCharacters(in: .whitespacesAndNewlines), "persisted-row")
            let wildcardGrant = try runPDO(php: php, port: port, database: "dbprov_sentinel", user: "dbprov_app_user", password: reveal.secret, sql: "CREATE TABLE denied_neighbor (id INT);")
            XCTAssertNotEqual(wildcardGrant.status, 0, "application user must not write to a neighboring database")
            let safeOutput = try Data(contentsOf: root.appendingPathComponent("safe.stdout")) + Data(contentsOf: root.appendingPathComponent("safe.stderr"))
            XCTAssertFalse(safeOutput.range(of: reveal.secret) != nil, "ordinary CLI output must not contain the revealed secret")
            let logFiles = (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "log" }
            for log in logFiles {
                XCTAssertFalse((try? Data(contentsOf: log))?.range(of: reveal.secret) != nil, "service logs must not contain the revealed secret")
            }

            let wrongStatus = try runVal(["project", "db", "status", attempt.operationID.rawValue.uuidString, neighborID.rawValue.uuidString, "--json"], cwd: neighbor)
            XCTAssertNotEqual(wrongStatus.0, 0)
            XCTAssertEqual(try Data(contentsOf: envURL), envBytes)
            XCTAssertEqual(try ServiceInstanceRepository(store: store).projectClaims(for: projectID!), claims)

            _ = try module.stop(id: serviceID)
            XCTAssertEqual(try module.status(id: serviceID).health, "stopped")
            let staleReveal = try runValWithoutPersisting(["project", "db", "password", "reveal", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString], cwd: project, executable: val, environment: environment, supportRoot: layout.rootURL)
            XCTAssertNotEqual(staleReveal.status, 0, "reveal must refuse a stopped, stale service target")
            try module.start(id: serviceID)
            postgresPID = try module.status(id: serviceID).pid
            let recovered = try runPDO(php: php, port: port, database: "dbprov_app", user: "dbprov_app_user", password: reveal.secret, sql: "SELECT value FROM migration_equivalent WHERE id = 1;")
            XCTAssertEqual(recovered.status, 0, recovered.error)
            XCTAssertEqual(recovered.output.trimmingCharacters(in: .whitespacesAndNewlines), "persisted-row")
            XCTAssertEqual(try readSentinel(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, database: sentinelDB.value), "sentinel-preserved")

            let stopClient = VaelenCoreClient(transport: UnixSocketTransport(path: endpoints.socketPath), identity: fixtureIdentity("dbprov-shutdown"))
            try await stopClient.connect()
            _ = try await stopClient.shutdown()
            await stopClient.disconnect()
            guard await wait(serverExited, seconds: 4) else { throw FixtureError.coreDidNotStop }
            _ = try await serverTask?.value
            coreStopped = true

            serverExited = DispatchSemaphore(value: 0)
            serverTask = launchCore(try makeDispatcher(), exited: serverExited)
            coreStopped = false
            for _ in 0..<300 where !fm.fileExists(atPath: endpoints.socketPath) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(fm.fileExists(atPath: endpoints.socketPath), "reopened private Core socket must be ready")
            let reopenedClient = VaelenCoreClient(transport: UnixSocketTransport(path: endpoints.socketPath), identity: fixtureIdentity("dbprov-reopened"))
            try await reopenedClient.connect()
            let reopenedStatus = try await reopenedClient.projectDatabaseStatus(selector: projectID!.rawValue.uuidString, workingDirectory: project.path, operationID: attempt.operationID)
            XCTAssertEqual(reopenedStatus.state, .ready)
            await reopenedClient.disconnect()
            let persisted = try runPDO(php: php, port: port, database: "dbprov_app", user: "dbprov_app_user", password: reveal.secret, sql: "SELECT value FROM migration_equivalent WHERE id = 1;")
            XCTAssertEqual(persisted.status, 0, persisted.error)
            XCTAssertEqual(persisted.output.trimmingCharacters(in: .whitespacesAndNewlines), "persisted-row")
            XCTAssertEqual(try readSentinel(packageRoot: packageRoot, layoutRoot: layout.rootURL, port: port, database: sentinelDB.value), "sentinel-preserved")

            let shutdownClient = VaelenCoreClient(transport: UnixSocketTransport(path: endpoints.socketPath), identity: fixtureIdentity("dbprov-final-shutdown"))
            try await shutdownClient.connect()
            _ = try await shutdownClient.shutdown()
            await shutdownClient.disconnect()
            guard await wait(serverExited, seconds: 4) else { throw FixtureError.coreDidNotStop }
            _ = try await serverTask?.value
            coreStopped = true
            _ = try module.stop(id: serviceID)
            XCTAssertEqual(try module.status(id: serviceID).health, "stopped")
            XCTAssertEqual(try Data(contentsOf: envURL), envBytes)
            XCTAssertEqual(try ServiceInstanceRepository(store: store).projectClaims(for: projectID!), claims)
            try removeCredentials(namespace: namespace)
            try assertCredentialsAbsent(namespace: namespace)
            try fm.removeItem(at: root)
            XCTAssertFalse(fm.fileExists(atPath: root.path))
            XCTAssertFalse(processExists(postgresPID))
            if let evidencePath = environment["VAELEN_PROJECT_DATABASE_EVIDENCE"] {
                let evidence = "result=PASS engine=postgresql package=18.6 create=ready databaseCollision=refused roleCollision=refused roleAttributes=login-only wrongPassword=rejected statusChangedServiceRecord=refused statusChangedCluster=refused passwordSQLLogSuppression=passed pdoMigration=passed neighboringDatabase=denied coreReopen=persisted env=unchanged claims=unchanged keychain=exact-items-deleted cleanup=confirmed\n"
                try Data(evidence.utf8).write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
            }
            print("PROJECT_DATABASE_PROVISIONING_EVIDENCE postgresql=18.6 port=\(port) create=ready collision=refused sentinel=preserved pdo=authenticated neighboringDatabase=denied coreReopen=persisted env=unchanged claims=unchanged keychain=exact-items-deleted cleanup=confirmed")
        } catch {
            if let serverTask, !coreStopped {
                let client = VaelenCoreClient(transport: UnixSocketTransport(path: endpoints.socketPath), identity: fixtureIdentity("dbprov-cleanup"))
                do {
                    try await client.connect()
                    _ = try await client.shutdown()
                    await client.disconnect()
                    if await wait(serverExited, seconds: 4) { _ = try? await serverTask.value; coreStopped = true }
                } catch { }
            }
            if !coreStopped { preserveRoot = true }
            if (try? module.status(id: serviceID).health) == "healthy" { try? module.stop(id: serviceID) }
            if (try? module.status(id: serviceID).health) == "healthy" || processExists(postgresPID) { preserveRoot = true }
            if !preserveRoot {
                try? removeCredentials(namespace: namespace)
                try? fm.removeItem(at: root)
            }
            throw NSError(domain: "ProjectDatabaseProvisioningEndToEnd", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture root \(preserveRoot ? "preserved" : "removed") at \(root.path). Original error: \(error)"])
        }
    }

    private enum FixtureError: Error { case childStillRunning, childTimedOut, coreDidNotStop, keychainItemUnidentified }

    private func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.childTimedOut }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw FixtureError.childTimedOut }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } })
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private func psql(packageRoot: URL, layoutRoot: URL, port: Int, sql: Data, database: String = "postgres") throws -> String {
        let process = Process()
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = packageRoot.appendingPathComponent("bin/psql")
        let token = String(SHA256.hash(data: Data((layoutRoot.path + "\0primary").utf8)).map { String(format: "%02x", $0) }.joined().prefix(24))
        process.arguments = ["-h", NSTemporaryDirectory() + "vpg-\(token)", "-p", "\(port)", "-U", NSUserName(), "-d", database, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1"]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/private/tmp", "PGPASSWORD": ""]
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(sql); try input.fileHandleForWriting.close()
        try finish(process)
        let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: "psql", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message]) }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func seedSentinel(packageRoot: URL, layoutRoot: URL, port: Int, database: String, user: String) throws {
        _ = try psql(packageRoot: packageRoot, layoutRoot: layoutRoot, port: port, sql: Data("CREATE ROLE \(user) LOGIN PASSWORD 'sentinel-local-only'; CREATE DATABASE \(database) OWNER \(user);".utf8))
        _ = try psql(packageRoot: packageRoot, layoutRoot: layoutRoot, port: port, sql: Data("CREATE TABLE marker (value VARCHAR(64)); INSERT INTO marker VALUES ('sentinel-preserved');".utf8), database: database)
    }

    private func assertReplacementClusterIsRejected(module: PostgreSQLServiceModule, serviceID: ServiceInstanceID, dataDirectory: URL, packageRoot: URL, val: String, operationID: DatabaseOperationID, projectID: ProjectID, project: URL, environment: [String: String], supportRoot: URL) throws {
        let fm = FileManager.default
        let backup = dataDirectory.deletingLastPathComponent().appendingPathComponent("original-cluster-\(UUID().uuidString)", isDirectory: true)
        try module.stop(id: serviceID)
        try fm.moveItem(at: dataDirectory, to: backup)
        do {
            _ = try command(packageRoot.appendingPathComponent("bin/initdb").path, ["-D", dataDirectory.path, "--encoding=UTF8", "--locale=C"])
            try module.start(id: serviceID)
            let replacedStatus = try runValWithoutPersisting(["project", "db", "status", operationID.rawValue.uuidString, projectID.rawValue.uuidString, "--json"], cwd: project, executable: val, environment: environment, supportRoot: supportRoot)
            XCTAssertNotEqual(replacedStatus.status, 0, "status must refuse a replacement cluster behind the same binding")
            _ = try module.stop(id: serviceID)
            try fm.removeItem(at: dataDirectory)
            try fm.moveItem(at: backup, to: dataDirectory)
            try module.start(id: serviceID)
        } catch {
            if (try? module.status(id: serviceID).health) == "healthy" { _ = try? module.stop(id: serviceID) }
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: dataDirectory)
                try? fm.moveItem(at: backup, to: dataDirectory)
                try? module.start(id: serviceID)
            }
            throw error
        }
    }

    private func readSentinel(packageRoot: URL, layoutRoot: URL, port: Int, database: String) throws -> String {
        try psql(packageRoot: packageRoot, layoutRoot: layoutRoot, port: port, sql: Data("SELECT value FROM marker;".utf8), database: database).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = error; process.environment = ["PATH": "/usr/bin:/bin"]
        try process.run(); try finish(process)
        guard process.terminationStatus == 0 else { throw NSError(domain: "fixture-command", code: Int(process.terminationStatus)) }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func runValWithoutPersisting(_ args: [String], cwd: URL, executable: String, environment: [String: String], supportRoot: URL) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = environment.merging(["VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1", "VAELEN_TEST_SUPPORT_ROOT": supportRoot.path, "NO_COLOR": "1"]) { _, value in value }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try finish(process)
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        _ = error.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }

    private func revealInMemory(val: String, operationID: DatabaseOperationID, projectID: ProjectID, cwd: URL, environment: [String: String], supportRoot: URL) throws -> (secret: Data, arguments: [String]) {
        let args = ["project", "db", "password", "reveal", operationID.rawValue.uuidString, projectID.rawValue.uuidString]
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: val)
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = environment.merging(["VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1", "VAELEN_TEST_SUPPORT_ROOT": supportRoot.path, "NO_COLOR": "1"]) { _, value in value }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try finish(process)
        let secret = output.fileHandleForReading.readDataToEndOfFile()
        let failure = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0, !secret.isEmpty else { throw NSError(domain: "val-reveal", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: failure]) }
        return (Data(secret.dropLastWhile { $0 == 10 || $0 == 13 }), args)
    }

    private func runPDO(php: String, port: Int, database: String, user: String, password: Data, sql: String) throws -> (status: Int32, output: String, error: String) {
        let code = "$p = rtrim(stream_get_contents(STDIN), \"\\n\"); $db = new PDO(\"pgsql:host=127.0.0.1;port=\(port);dbname=\(database)\", \"\(user)\", $p, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]); foreach (explode(\";\", \"\(sql)\") as $q) { if (trim($q) !== \"\") { $s = $db->query($q); if ($s && $s->columnCount()) { while ($r = $s->fetch(PDO::FETCH_NUM)) { echo $r[0], \"\\n\"; } } } }"
        let process = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: php)
        let arguments = ["-r", code]
        let processEnvironment = ["PATH": "/usr/bin:/bin", "HOME": "/private/tmp"]
        process.arguments = arguments
        process.environment = processEnvironment
        let passwordText = String(decoding: password, as: UTF8.self)
        XCTAssertFalse(arguments.contains(where: { $0.contains(passwordText) }), "PDO password must stay out of process arguments")
        XCTAssertFalse(processEnvironment.values.contains(where: { $0.contains(passwordText) }), "PDO password must stay out of process environment")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(password)
        try input.fileHandleForWriting.close()
        try finish(process)
        return (process.terminationStatus,
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func removeCredentials(namespace: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: namespace, kSecAttrSynchronizable: false, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: CFTypeRef?
        let lookup = SecItemCopyMatching(query as CFDictionary, &result)
        guard lookup == errSecSuccess || lookup == errSecItemNotFound else { throw NSError(domain: "fixture-keychain", code: Int(lookup)) }
        let items = (result as? [[CFString: Any]]) ?? []
        for item in items {
            guard let account = item[kSecAttrAccount] as? String else { throw FixtureError.keychainItemUnidentified }
            let exact: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: namespace, kSecAttrAccount: account, kSecAttrSynchronizable: false]
            let status = SecItemDelete(exact as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: "fixture-keychain", code: Int(status)) }
        }
    }

    private func assertCredentialsAbsent(namespace: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: namespace, kSecAttrSynchronizable: false, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecItemNotFound || (status == errSecSuccess && (result as? [[CFString: Any]])?.isEmpty == true) else {
            throw NSError(domain: "fixture-keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Fixture Keychain entries remain after cleanup."])
        }
    }

    private func fixtureIdentity(_ name: String) -> ClientIdentity {
        ClientIdentity(name: name, version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
    }

    private func waitForExit(_ process: Process, seconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while process.isRunning && Date() < deadline { usleep(10_000) }
        return !process.isRunning
    }

    private func finish(_ process: Process) throws {
        if !waitForExit(process, seconds: 30) {
            process.terminate()
            if !waitForExit(process, seconds: 2) {
                _ = kill(process.processIdentifier, SIGKILL)
                if !waitForExit(process, seconds: 2) { throw FixtureError.childStillRunning }
            }
            process.waitUntilExit()
            throw FixtureError.childTimedOut
        }
        process.waitUntilExit()
    }

    private func wait(_ semaphore: DispatchSemaphore, seconds: Int) async -> Bool {
        await Task.detached(priority: .utility) { Self.blockingWait(semaphore, seconds: seconds) }.value
    }

    nonisolated private static func blockingWait(_ semaphore: DispatchSemaphore, seconds: Int) -> Bool {
        semaphore.wait(timeout: .now() + .seconds(seconds)) == .success
    }

    private func processExists(_ pid: Int32?) -> Bool {
        guard let pid else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

private extension Data {
    func dropLastWhile(_ predicate: (UInt8) -> Bool) -> Data {
        var end = count
        while end > 0 && predicate(self[index(startIndex, offsetBy: end - 1)]) { end -= 1 }
        return Data(prefix(end))
    }
}
