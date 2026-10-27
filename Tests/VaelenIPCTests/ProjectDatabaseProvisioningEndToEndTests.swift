import Foundation
import Darwin
import Security
import XCTest
@testable import VaelenCore
import VaelenIPC
import VaelenDaemonSupport

final class ProjectDatabaseProvisioningEndToEndTests: XCTestCase {
    func testInstalledMySQLProvisioningThroughValAndPrivateCore() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let val = environment["VAELEN_VAL_EXECUTABLE"],
              let mysqlRoot = environment["VAELEN_TEST_MYSQL_PACKAGE_ROOT"],
              let php = environment["VAELEN_TEST_PHP_EXECUTABLE"] else {
            throw XCTSkip("Run Scripts/tests/val-project-database-provisioning-test.sh with the verified local MySQL and PHP packages.")
        }
        let fm = FileManager.default
        let packageRoot = URL(fileURLWithPath: mysqlRoot, isDirectory: true)
        let package = try JSONDecoder().decode(MySQLPackage.self, from: Data(contentsOf: packageRoot.appendingPathComponent(".vaelen-package.json")))
        guard package.version == MySQLModule.defaultVersion,
              package.architecture == "arm64",
              package.artifactSHA256 == MySQLManifest.official8_4_11.artifactSHA256,
              package.packagePath == packageRoot.path,
              [package.serverPath, package.clientPath, package.adminPath].allSatisfy({ fm.isExecutableFile(atPath: $0) }),
              fm.isExecutableFile(atPath: php) else {
            throw XCTSkip("The installed MySQL or PHP package failed its local provenance preflight.")
        }

        let root = URL(fileURLWithPath: "/private/tmp/vaelen-dbprov-\(UUID().uuidString)", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true))
        let endpoints = CoreEndpointPaths(layout: layout)
        let port = try availablePort()
        let namespace = "dev.vaelen.project-database.acceptance.\(UUID().uuidString)"
        let passwords = KeychainProjectDatabasePasswordStore(namespace: namespace)
        let module = MySQLModule(layout: layout, port: port, instanceName: "default", tcpEnabled: true, packageOverride: package)
        let packageID = "mysql-\(package.version)"
        let serviceID = ServiceInstanceID(kind: .mysql, name: try ProjectInstanceName("default"))
        var serverTask: Task<Void, Error>?
        var serverExited = DispatchSemaphore(value: 0)
        var coreStopped = false
        var preserveRoot = false
        var projectID: ProjectID?
        var mysqlPID: Int32?
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
                mysql: module,
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
            try Data("version: 2\nservices:\n  database:\n    kind: mysql\n    instance: default\n    version: \(packageID)\n".utf8).write(to: project.appendingPathComponent("vaelen.yml"))
            try Data("version: 2\nservices:\n  database:\n    kind: mysql\n    instance: default\n    version: \(packageID)\n".utf8).write(to: neighbor.appendingPathComponent("vaelen.yml"))

            try module.initialize()
            _ = try module.start()
            mysqlPID = module.status().pid
            let snapshot = module.projectBindingSnapshot()
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
            let claimsBefore = try repository.claims(for: serviceID)
            XCTAssertTrue(claimsBefore.isEmpty)
            let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .mysql, instance: ProjectInstanceName("default"), version: packageID)
            try repository.replaceProjectClaims([binding], materializing: [record], for: projectID!)
            let claims = try repository.claims(for: serviceID)
            XCTAssertEqual(claims.count, 1)
            XCTAssertNotNil(mysqlPID)
            XCTAssertEqual(module.status().state, .running)

            let sentinelDB = try DatabaseName("dbprov_sentinel")
            let sentinelUser = try DatabaseUserName("dbprov_sentinel_user")
            try seedSentinel(module: module, package: package, database: sentinelDB, user: sentinelUser)
            let sentinelGrants = try mysqlClient(package: package, socket: module.status().socket, sql: Data("SHOW GRANTS FOR '\(sentinelUser.value)'@'127.0.0.1';\n".utf8))
            let wildcardNeighbor = "dbprovXapp"
            _ = try mysqlClient(package: package, socket: module.status().socket, sql: Data("CREATE DATABASE `\(wildcardNeighbor)`;\n".utf8))
            let collision = try runVal(["project", "db", "create", sentinelDB.value, "dbprov_unused_user", projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(collision.0, 0, collision.2 + collision.1)
            let collisionResult = try IPCCodec.decode(ProjectDatabaseAttemptResult.self, from: Data(collision.1.utf8))
            XCTAssertEqual(collisionResult.state, .refused)
            XCTAssertEqual(collisionResult.diagnostic, .existingDatabase)
            XCTAssertEqual(try mysqlClient(package: package, socket: module.status().socket, sql: Data("SELECT COUNT(*) FROM mysql.user WHERE User='dbprov_unused_user';\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines), "0", "database collision must refuse before creating the requested application user")
            XCTAssertEqual(try readSentinel(module: module, package: package, database: sentinelDB, user: sentinelUser), "sentinel-preserved")

            let roleCollisionDatabase = try DatabaseName("dbprov_user_collision")
            let roleCollision = try runVal(["project", "db", "create", roleCollisionDatabase.value, sentinelUser.value, projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(roleCollision.0, 0, roleCollision.2 + roleCollision.1)
            let roleCollisionResult = try IPCCodec.decode(ProjectDatabaseAttemptResult.self, from: Data(roleCollision.1.utf8))
            XCTAssertEqual(roleCollisionResult.state, .refused)
            XCTAssertEqual(roleCollisionResult.diagnostic, .existingUser)
            XCTAssertEqual(try mysqlClient(package: package, socket: module.status().socket, sql: Data("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='\(roleCollisionDatabase.value)';\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines), "0", "user collision must not create the requested database")
            XCTAssertEqual(try mysqlClient(package: package, socket: module.status().socket, sql: Data("SHOW GRANTS FOR '\(sentinelUser.value)'@'127.0.0.1';\n".utf8)), sentinelGrants, "existing account grants must remain unchanged")
            XCTAssertEqual(try readSentinel(module: module, package: package, database: sentinelDB, user: sentinelUser), "sentinel-preserved")

            let created = try runVal(["project", "db", "create", "dbprov_app", "dbprov_app_user", projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(created.0, 0, created.2 + created.1)
            let attempt = try IPCCodec.decode(ProjectDatabaseAttemptResult.self, from: Data(created.1.utf8))
            XCTAssertNotEqual(collisionResult.operationID, attempt.operationID, "each create request must use its own operation ID")
            XCTAssertEqual(attempt.state, .ready, "provisioning did not complete: state=\(attempt.state.rawValue) pending=\(String(describing: attempt.pendingEffect)) effects=\(attempt.confirmedEffects) uncertain=\(attempt.uncertainEffects) diagnostic=\(String(describing: attempt.diagnostic))")
            XCTAssertEqual(Set(attempt.confirmedEffects), Set(DatabaseProvisionEffect.allCases))

            let status = try runVal(["project", "db", "status", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(status.0, 0, status.2 + status.1)
            XCTAssertFalse(status.1.contains("password"))
            XCTAssertFalse(status.1.contains("secret"))
            let statusResult = try IPCCodec.decode(ProjectDatabaseAttemptResult.self, from: Data(status.1.utf8))
            XCTAssertEqual(statusResult.operationID, attempt.operationID)
            XCTAssertEqual(statusResult.state, .ready)

            let wrongProjectReveal = try runValWithoutPersisting(["project", "db", "password", "reveal", attempt.operationID.rawValue.uuidString, neighborID.rawValue.uuidString], cwd: neighbor, executable: val, environment: environment, supportRoot: layout.rootURL)
            XCTAssertNotEqual(wrongProjectReveal.status, 0)
            XCTAssertFalse(wrongProjectReveal.output.contains("password"))

            let reveal = try revealInMemory(val: val, operationID: attempt.operationID, projectID: projectID!, cwd: project, environment: environment, supportRoot: layout.rootURL)
            let secretText = String(decoding: reveal.secret, as: UTF8.self)
            XCTAssertFalse(reveal.arguments.joined(separator: " ").contains(secretText))
            XCTAssertFalse(environment.values.contains(where: { $0.contains(secretText) }))
            XCTAssertFalse((created.1 + created.2 + status.1 + status.2).contains(secretText), "ordinary create and status output must not contain the credential")
            XCTAssertTrue(reveal.secret.count >= 32)
            let pdo = try runPDO(php: php, port: port, database: "dbprov_app", user: "dbprov_app_user", password: reveal.secret, sql: "CREATE TABLE migration_equivalent (id INT PRIMARY KEY, value VARCHAR(64) NOT NULL); INSERT INTO migration_equivalent VALUES (1, 'persisted-row'); SELECT value FROM migration_equivalent WHERE id = 1;")
            XCTAssertEqual(pdo.status, 0, pdo.error)
            XCTAssertEqual(pdo.output.trimmingCharacters(in: .whitespacesAndNewlines), "persisted-row")
            let wildcardGrant = try runPDO(php: php, port: port, database: wildcardNeighbor, user: "dbprov_app_user", password: reveal.secret, sql: "CREATE TABLE denied_neighbor (id INT);")
            XCTAssertNotEqual(wildcardGrant.status, 0, "application user must not write to a neighboring database")
            XCTAssertEqual(try mysqlClient(package: package, socket: module.status().socket, sql: Data("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='\(wildcardNeighbor)';\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines), "1", "escaped database underscores must not grant wildcard neighbors")
            let safeOutput = try Data(contentsOf: root.appendingPathComponent("safe.stdout")) + Data(contentsOf: root.appendingPathComponent("safe.stderr"))
            XCTAssertFalse(safeOutput.range(of: reveal.secret) != nil, "ordinary CLI output must not contain the revealed secret")
            let logFiles = (fm.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "log" }
            for log in logFiles {
                XCTAssertFalse((try? Data(contentsOf: log))?.range(of: reveal.secret) != nil, "service logs must not contain the revealed secret")
            }

            let wrongStatus = try runVal(["project", "db", "status", attempt.operationID.rawValue.uuidString, neighborID.rawValue.uuidString, "--json"], cwd: neighbor)
            XCTAssertNotEqual(wrongStatus.0, 0)
            XCTAssertEqual(try Data(contentsOf: envURL), envBytes)
            XCTAssertEqual(try ServiceInstanceRepository(store: store).claims(for: serviceID), claims)

            try stopFixtureMySQL(module: module, root: root, timeout: 10)
            let staleReveal = try runValWithoutPersisting(["project", "db", "password", "reveal", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString], cwd: project, executable: val, environment: environment, supportRoot: layout.rootURL)
            XCTAssertNotEqual(staleReveal.status, 0, "reveal must refuse a stopped, stale service target")
            mysqlPID = try module.start().pid
            let recovered = try runPDO(php: php, port: port, database: "dbprov_app", user: "dbprov_app_user", password: reveal.secret, sql: "SELECT value FROM migration_equivalent WHERE id = 1;")
            XCTAssertEqual(recovered.status, 0, recovered.error)
            XCTAssertEqual(recovered.output.trimmingCharacters(in: .whitespacesAndNewlines), "persisted-row")

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

            let shutdownClient = VaelenCoreClient(transport: UnixSocketTransport(path: endpoints.socketPath), identity: fixtureIdentity("dbprov-final-shutdown"))
            try await shutdownClient.connect()
            _ = try await shutdownClient.shutdown()
            await shutdownClient.disconnect()
            guard await wait(serverExited, seconds: 4) else { throw FixtureError.coreDidNotStop }
            _ = try await serverTask?.value
            coreStopped = true
            try stopFixtureMySQL(module: module, root: root, timeout: 10)
            XCTAssertEqual(module.status().state, .stopped)
            XCTAssertEqual(try Data(contentsOf: envURL), envBytes)
            XCTAssertEqual(try ServiceInstanceRepository(store: store).claims(for: serviceID), claims)
            try removeCredentials(namespace: namespace)
            try fm.removeItem(at: root)
            XCTAssertFalse(fm.fileExists(atPath: root.path))
            if let evidencePath = environment["VAELEN_PROJECT_DATABASE_EVIDENCE"] {
                let evidence = "result=PASS engine=mysql package=8.4.11 create=ready databaseCollision=refused userCollision=refused existingUserUnchanged=yes requestedDatabaseAbsent=yes pdoMigration=passed neighboringDatabase=denied coreReopen=persisted env=unchanged claims=unchanged keychain=exact-items-deleted cleanup=confirmed processTable=clear processRecord=absent socket=absent root=removed\n"
                try Data(evidence.utf8).write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
            }
            print("PROJECT_DATABASE_PROVISIONING_EVIDENCE mysql=8.4.11 port=\(port) create=ready collision=refused sentinel=preserved pdo=authenticated neighboringDatabase=denied coreReopen=persisted env=unchanged claims=unchanged keychain=exact-items-deleted cleanup=confirmed processTable=clear processRecord=absent socket=absent root=removed")
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
            var cleanupFailure: String?
            if serverTask != nil && !coreStopped { preserveRoot = true }
            if !preserveRoot {
                do { try stopFixtureMySQL(module: module, root: root, timeout: 10) }
                catch { preserveRoot = true; cleanupFailure = String(describing: error) }
            }
            if !preserveRoot {
                do {
                    try removeCredentials(namespace: namespace)
                    try fm.removeItem(at: root)
                } catch { preserveRoot = true; cleanupFailure = String(describing: error) }
            }
            throw NSError(domain: "ProjectDatabaseProvisioningEndToEnd", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture root \(preserveRoot ? "preserved" : "removed") at \(root.path). Original error: \(error)\(cleanupFailure.map { ". Cleanup verification failed: \($0)" } ?? "")"])
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

    private func seedSentinel(module: MySQLModule, package: MySQLPackage, database: DatabaseName, user: DatabaseUserName) throws {
        let sql = Data("CREATE DATABASE `\(database.value)`; CREATE USER '\(user.value)'@'127.0.0.1' IDENTIFIED BY 'sentinel-local-only'; GRANT ALL PRIVILEGES ON `\(database.value)`.* TO '\(user.value)'@'127.0.0.1'; FLUSH PRIVILEGES; CREATE TABLE `\(database.value)`.marker (value VARCHAR(64)); INSERT INTO `\(database.value)`.marker VALUES ('sentinel-preserved');\n".utf8)
        _ = try mysqlClient(package: package, socket: module.status().socket, sql: sql)
    }

    private func readSentinel(module: MySQLModule, package: MySQLPackage, database: DatabaseName, user: DatabaseUserName) throws -> String {
        _ = user
        return try mysqlClient(package: package, socket: module.status().socket, sql: Data("SELECT value FROM `\(database.value)`.marker;\n".utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mysqlClient(package: MySQLPackage, socket: String, sql: Data) throws -> String {
        let process = Process()
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: package.clientPath)
        process.arguments = ["--no-defaults", "--protocol=socket", "--socket=\(socket)", "-uroot", "--batch", "--skip-column-names"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(sql)
        try input.fileHandleForWriting.close()
        try finish(process)
        let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: "mysql-client", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message]) }
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
        let code = "$p = rtrim(stream_get_contents(STDIN), \"\\n\"); $db = new PDO(\"mysql:host=127.0.0.1;port=\(port);dbname=\(database)\", \"\(user)\", $p, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]); foreach (explode(\";\", \"\(sql)\") as $q) { if (trim($q) !== \"\") { $s = $db->query($q); if ($s && $s->columnCount()) { while ($r = $s->fetch(PDO::FETCH_NUM)) { echo $r[0], \"\\n\"; } } } }"
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
        var remaining: CFTypeRef?
        let verify = SecItemCopyMatching(query as CFDictionary, &remaining)
        guard verify == errSecItemNotFound else { throw NSError(domain: "fixture-keychain", code: Int(verify), userInfo: [NSLocalizedDescriptionKey: "Fixture credentials remain or could not be verified"]) }
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

    private struct CleanupObservation {
        let status: MySQLStatus
        let processes: [String]
        let processRecordExists: Bool
        let socketExists: Bool
        let rootExists: Bool

        var clean: Bool {
            status.state == .stopped && processes.isEmpty && !processRecordExists && !socketExists && rootExists
        }
    }

    private func stopFixtureMySQL(module: MySQLModule, root: URL, timeout: TimeInterval) throws {
        let recordURL = root.appendingPathComponent("support/instances/mysql/default/process.json")
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?
        var last: CleanupObservation?
        while Date() < deadline {
            if module.status().state == .running { _ = try module.stop() }
            let status = module.status()
            let observation = CleanupObservation(
                status: status,
                processes: try processCommands().filter { $0.contains(root.path) },
                processRecordExists: FileManager.default.fileExists(atPath: recordURL.path),
                socketExists: FileManager.default.fileExists(atPath: status.socket),
                rootExists: FileManager.default.fileExists(atPath: root.path)
            )
            last = observation
            if observation.clean {
                if stableSince == nil { stableSince = Date() }
                if Date().timeIntervalSince(stableSince!) >= 1 { return }
            } else {
                stableSince = nil
            }
            usleep(50_000)
        }
        throw NSError(domain: "ProjectDatabaseProvisioningEndToEnd", code: 2, userInfo: [NSLocalizedDescriptionKey: "MySQL fixture shutdown was not confirmed. observation=\(String(describing: last))"])
    }

    private func processCommands() throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError.childTimedOut }
        return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
    }

}

private extension Data {
    func dropLastWhile(_ predicate: (UInt8) -> Bool) -> Data {
        var end = count
        while end > 0 && predicate(self[index(startIndex, offsetBy: end - 1)]) { end -= 1 }
        return Data(prefix(end))
    }
}
