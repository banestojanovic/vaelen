import Foundation
import Darwin
import Security
import XCTest
@testable import VaelenCore
import VaelenIPC
import VaelenDaemonSupport

final class ProjectDatabaseProvisioningEndToEndTests: XCTestCase {
    func testLaravelChildCredentialOutputIsRedactedAndRejected() throws {
        let candidates = [ProcessInfo.processInfo.environment["VAELEN_TEST_PHP_EXECUTABLE"], "/opt/homebrew/bin/php", "/usr/bin/php"].compactMap { $0 }
        guard let php = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("A PHP executable is required for the Laravel child negative control.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let secret = "known-credential-sentinel"
        let result = try runLaravelPHP(php: php, cwd: project, arguments: ["-r", "echo 'known-credential-sentinel';"], secret: Data(secret.utf8))
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.credentialOutputDetected)
        XCTAssertFalse(result.isSuccessful)
        XCTAssertFalse(result.output.contains(secret))
        XCTAssertEqual(result.output, "Laravel child output contained the generated credential")
    }

    func testInstalledMySQLProvisioningThroughValAndPrivateCore() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let val = environment["VAELEN_VAL_EXECUTABLE"],
              let mysqlRoot = environment["VAELEN_TEST_MYSQL_PACKAGE_ROOT"],
              let php = environment["VAELEN_TEST_PHP_EXECUTABLE"] else {
            throw XCTSkip("Run Scripts/tests/val-project-database-provisioning-test.sh with the verified local MySQL and PHP packages.")
        }
        let laravelAppRoot = environment["VAELEN_TEST_LARAVEL_APP_ROOT"]
        let laravelProbe = environment["VAELEN_TEST_LARAVEL_PROBE"]
        let laravelAcceptance = laravelAppRoot != nil && laravelProbe != nil
        XCTAssertEqual(laravelAppRoot == nil, laravelProbe == nil, "Laravel acceptance inputs must be supplied together")
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
        let envBytes = Data("APP_ENV=testing\nAPP_DEBUG=false\nCUSTOM_VALUE=keep\n".utf8)
        let laravelApp = laravelAppRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let laravelProbeURL = laravelProbe.map { URL(fileURLWithPath: $0) }
        let expectationURL = root.appendingPathComponent("laravel-expectation.json")

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
            try fm.createDirectory(at: neighbor, withIntermediateDirectories: true)
            if let laravelApp {
                try fm.copyItem(at: laravelApp, to: project)
            } else {
                try fm.createDirectory(at: project, withIntermediateDirectories: true)
                for directory in ["bootstrap", "config", "public"] {
                    try fm.createDirectory(at: project.appendingPathComponent(directory), withIntermediateDirectories: true)
                }
                try Data("<?php".utf8).write(to: project.appendingPathComponent("artisan"))
                try Data("<?php".utf8).write(to: project.appendingPathComponent("public/index.php"))
            }
            try envBytes.write(to: envURL)
            XCTAssertEqual(chmod(root.path, 0o700), 0)
            XCTAssertEqual(chmod(envURL.path, 0o600), 0)
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

            var reviewedEnvironment = Data("# preserve this comment\r\nDB_CONNECTION=sqlite\r\nCUSTOM_VALUE=keep\r\n".utf8)
            try reviewedEnvironment.write(to: envURL)
            XCTAssertEqual(chmod(envURL.path, 0o600), 0)
            var reviewFileInfo = stat()
            XCTAssertEqual(lstat(envURL.path, &reviewFileInfo), 0)
            XCTAssertEqual(reviewFileInfo.st_uid, getuid())
            XCTAssertEqual(reviewFileInfo.st_mode & 0o777, 0o600)
            XCTAssertEqual(reviewFileInfo.st_nlink, 1)
            XCTAssertEqual(reviewFileInfo.st_flags, 0)
            XCTAssertNoThrow(try ConnectionFileBoundary().inspect(envURL))
            let connectionReviewOutput = try runVal(["project", "db", "connection", "review", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(connectionReviewOutput.0, 0, connectionReviewOutput.2 + connectionReviewOutput.1)
            XCTAssertFalse((connectionReviewOutput.1 + connectionReviewOutput.2).contains(secretText), "connection review must not disclose the credential")
            let connectionReview = try IPCCodec.decode(ProjectDatabaseConnectionReviewResult.self, from: Data(connectionReviewOutput.1.utf8)).review
            XCTAssertEqual(connectionReview.edits.first(where: { $0.key == "DB_PASSWORD" })?.value, "managed password (hidden)")
            XCTAssertEqual(connectionReview.edits.count, 6)

            let wrongProjectApply = try runVal(["project", "db", "connection", "apply", attempt.operationID.rawValue.uuidString, "--confirmation", connectionReview.confirmation.uuidString, neighborID.rawValue.uuidString], cwd: neighbor)
            XCTAssertNotEqual(wrongProjectApply.0, 0)
            XCTAssertFalse((wrongProjectApply.1 + wrongProjectApply.2).contains(secretText))
            let replayApply = try runVal(["project", "db", "connection", "apply", attempt.operationID.rawValue.uuidString, "--confirmation", connectionReview.confirmation.uuidString, projectID!.rawValue.uuidString], cwd: project)
            XCTAssertNotEqual(replayApply.0, 0, "single-use confirmation must reject replay")
            XCTAssertEqual(try Data(contentsOf: envURL), reviewedEnvironment)

            let editorBytes = reviewedEnvironment + Data("# editor change before approval\n".utf8)
            try editorBytes.write(to: envURL)
            XCTAssertEqual(chmod(envURL.path, 0o600), 0)
            reviewedEnvironment = editorBytes
            let staleReviewOutput = try runVal(["project", "db", "connection", "review", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            let staleReview = try IPCCodec.decode(ProjectDatabaseConnectionReviewResult.self, from: Data(staleReviewOutput.1.utf8)).review
            let staleEditorBytes = reviewedEnvironment + Data("# later edit\n".utf8)
            try staleEditorBytes.write(to: envURL)
            XCTAssertEqual(chmod(envURL.path, 0o600), 0)
            let staleApply = try runVal(["project", "db", "connection", "apply", attempt.operationID.rawValue.uuidString, "--confirmation", staleReview.confirmation.uuidString, projectID!.rawValue.uuidString], cwd: project)
            XCTAssertNotEqual(staleApply.0, 0, "changed .env snapshot must reject approval")
            XCTAssertEqual(try Data(contentsOf: envURL), staleEditorBytes)
            reviewedEnvironment = staleEditorBytes

            let receiptReviewOutput = try runVal(["project", "db", "connection", "review", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            let receiptReview = try IPCCodec.decode(ProjectDatabaseConnectionReviewResult.self, from: Data(receiptReviewOutput.1.utf8)).review
            let wrongReceiptApply = try runVal(["project", "db", "connection", "apply", collisionResult.operationID.rawValue.uuidString, "--confirmation", receiptReview.confirmation.uuidString, projectID!.rawValue.uuidString], cwd: project)
            XCTAssertNotEqual(wrongReceiptApply.0, 0, "confirmation must remain bound to the reviewed ready receipt")
            XCTAssertEqual(try Data(contentsOf: envURL), reviewedEnvironment)

            let serviceReviewOutput = try runVal(["project", "db", "connection", "review", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            let serviceReview = try IPCCodec.decode(ProjectDatabaseConnectionReviewResult.self, from: Data(serviceReviewOutput.1.utf8)).review
            try stopFixtureMySQL(module: module, root: root, timeout: 10)
            let changedServiceApply = try runVal(["project", "db", "connection", "apply", attempt.operationID.rawValue.uuidString, "--confirmation", serviceReview.confirmation.uuidString, projectID!.rawValue.uuidString], cwd: project)
            XCTAssertNotEqual(changedServiceApply.0, 0, "changed service health must reject approval")
            mysqlPID = try module.start().pid

            let passwordReviewOutput = try runVal(["project", "db", "connection", "review", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            let passwordReview = try IPCCodec.decode(ProjectDatabaseConnectionReviewResult.self, from: Data(passwordReviewOutput.1.utf8)).review
            let passwordQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: namespace, kSecAttrAccount: attempt.operationID.rawValue.uuidString]
            XCTAssertEqual(SecItemUpdate(passwordQuery as CFDictionary, [kSecValueData: Data("changed-after-review".utf8)] as CFDictionary), errSecSuccess)
            let passwordApply = try runVal(["project", "db", "connection", "apply", attempt.operationID.rawValue.uuidString, "--confirmation", passwordReview.confirmation.uuidString, projectID!.rawValue.uuidString], cwd: project)
            XCTAssertNotEqual(passwordApply.0, 0)
            XCTAssertEqual(try Data(contentsOf: envURL), reviewedEnvironment)
            XCTAssertEqual(SecItemUpdate(passwordQuery as CFDictionary, [kSecValueData: reveal.secret] as CFDictionary), errSecSuccess)
            try fm.moveItem(at: project.appendingPathComponent("artisan"), to: project.appendingPathComponent("artisan.saved"))
            let nonLaravelReview = try runVal(["project", "db", "connection", "review", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString], cwd: project)
            XCTAssertNotEqual(nonLaravelReview.0, 0)
            try fm.moveItem(at: project.appendingPathComponent("artisan.saved"), to: project.appendingPathComponent("artisan"))

            let finalReviewOutput = try runVal(["project", "db", "connection", "review", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            let finalReview = try IPCCodec.decode(ProjectDatabaseConnectionReviewResult.self, from: Data(finalReviewOutput.1.utf8)).review
            let connectionApplyOutput = try runVal(["project", "db", "connection", "apply", attempt.operationID.rawValue.uuidString, "--confirmation", finalReview.confirmation.uuidString, projectID!.rawValue.uuidString, "--json"], cwd: project)
            XCTAssertEqual(connectionApplyOutput.0, 0, connectionApplyOutput.2 + connectionApplyOutput.1)
            XCTAssertFalse((connectionApplyOutput.1 + connectionApplyOutput.2).contains(secretText), "connection apply result must not disclose the credential")
            let connectionApply = try IPCCodec.decode(ProjectDatabaseConnectionResult.self, from: Data(connectionApplyOutput.1.utf8))
            XCTAssertEqual(connectionApply.state, "applied")
            let appliedEnvironment = try Data(contentsOf: envURL)
            XCTAssertTrue(appliedEnvironment.range(of: Data("# preserve this comment\r\n".utf8)) != nil)
            XCTAssertTrue(appliedEnvironment.range(of: Data("CUSTOM_VALUE=keep\r\n".utf8)) != nil)
            XCTAssertTrue(appliedEnvironment.range(of: reveal.secret) != nil, "approved password must be written to .env")
            XCTAssertTrue(try Data(contentsOf: envURL) == appliedEnvironment, "Laravel acceptance must use the exact bytes written by apply")
            let generatedEnvironment = try generatedDotenvValues(appliedEnvironment)
            XCTAssertEqual(generatedEnvironment["DB_CONNECTION"], "mysql")
            XCTAssertEqual(generatedEnvironment["DB_HOST"], "127.0.0.1")
            XCTAssertEqual(generatedEnvironment["DB_PORT"], String(port))
            XCTAssertEqual(generatedEnvironment["DB_DATABASE"], "dbprov_app")
            XCTAssertEqual(generatedEnvironment["DB_USERNAME"], "dbprov_app_user")
            let generatedPassword = try XCTUnwrap(generatedEnvironment["DB_PASSWORD"])
            XCTAssertTrue(Data(generatedPassword.utf8) == reveal.secret, "applied password matches the in-memory Keychain reveal")
            let generatedPort = try XCTUnwrap(Int(generatedEnvironment["DB_PORT"]!))
            let generatedPasswordBytes = Data(generatedPassword.utf8)
            if laravelAcceptance, let laravelProbeURL {
                let expectation = LaravelConnectionExpectation(
                    defaultConnection: "mysql",
                    host: "127.0.0.1",
                    port: String(port),
                    database: "dbprov_app",
                    username: "dbprov_app_user",
                    password: String(decoding: reveal.secret, as: UTF8.self)
                )
                let expectationData = try JSONEncoder().encode(expectation)
                try expectationData.write(to: expectationURL, options: .atomic)
                XCTAssertEqual(chmod(expectationURL.path, 0o600), 0)
                let wrongExpectation = LaravelConnectionExpectation(values: expectation.values.merging(["database.connections.mysql.port": "1"]) { _, replacement in replacement })
                let wrongExpectationURL = root.appendingPathComponent("laravel-wrong-expectation.json")
                try JSONEncoder().encode(wrongExpectation).write(to: wrongExpectationURL, options: .atomic)
                XCTAssertEqual(chmod(wrongExpectationURL.path, 0o600), 0)
                let wrongExpectationRun = try runLaravelProbe(php: php, probe: laravelProbeURL, phase: "uncached", expectation: wrongExpectationURL, cwd: project, secret: reveal.secret)
                XCTAssertNotEqual(wrongExpectationRun.status, 0)
                XCTAssertTrue(wrongExpectationRun.output.contains("field=database.connections.mysql.port"))
                XCTAssertFalse(wrongExpectationRun.credentialOutputDetected)
                try fm.removeItem(at: wrongExpectationURL)

                let missingCacheRun = try runLaravelProbe(php: php, probe: laravelProbeURL, phase: "cached", expectation: expectationURL, cwd: project, secret: reveal.secret)
                XCTAssertNotEqual(missingCacheRun.status, 0)
                XCTAssertTrue(missingCacheRun.output.contains("phase=cached config cache"))
                XCTAssertFalse(missingCacheRun.credentialOutputDetected)

                let uncachedRun = try runLaravelProbe(php: php, probe: laravelProbeURL, phase: "uncached", expectation: expectationURL, cwd: project, secret: reveal.secret)
                XCTAssertEqual(uncachedRun.status, 0, "uncached Laravel probe failed")
                XCTAssertEqual(uncachedRun.output.trimmingCharacters(in: .whitespacesAndNewlines), "LARAVEL_CONNECTION uncached PASS")
                XCTAssertFalse(uncachedRun.credentialOutputDetected)

                let configCacheRun = try runLaravelArtisan(php: php, cwd: project, secret: reveal.secret)
                XCTAssertTrue(configCacheRun.isSuccessful, "Laravel config:cache failed or disclosed the credential")
                XCTAssertFalse(configCacheRun.credentialOutputDetected)
                let configCacheURL = project.appendingPathComponent("bootstrap/cache/config.php")
                XCTAssertEqual(chmod(configCacheURL.path, 0o600), 0)
                var cacheInfo = stat()
                XCTAssertEqual(lstat(configCacheURL.path, &cacheInfo), 0)
                XCTAssertTrue((cacheInfo.st_mode & 0o170000) == 0o100000)
                XCTAssertEqual(cacheInfo.st_mode & 0o777, 0o600)
                var appliedFileInfo = stat()
                XCTAssertEqual(lstat(envURL.path, &appliedFileInfo), 0)
                let heldEnvironment = root.appendingPathComponent("applied-env-held")
                try fm.moveItem(at: envURL, to: heldEnvironment)
                let cachedRun: LaravelChildResult
                do {
                    cachedRun = try runLaravelProbe(php: php, probe: laravelProbeURL, phase: "cached", expectation: expectationURL, cwd: project, secret: reveal.secret)
                    XCTAssertFalse(fm.fileExists(atPath: envURL.path))
                } catch {
                    try fm.moveItem(at: heldEnvironment, to: envURL)
                    throw error
                }
                try fm.moveItem(at: heldEnvironment, to: envURL)
                XCTAssertEqual(cachedRun.status, 0, "cached Laravel probe failed")
                XCTAssertEqual(cachedRun.output.trimmingCharacters(in: .whitespacesAndNewlines), "LARAVEL_CONNECTION cached PASS")
                XCTAssertFalse(cachedRun.credentialOutputDetected)
                XCTAssertTrue(fm.fileExists(atPath: envURL.path))
                XCTAssertTrue(try Data(contentsOf: envURL) == appliedEnvironment, "Laravel acceptance must restore the identical .env file")
                var restoredFileInfo = stat()
                XCTAssertEqual(lstat(envURL.path, &restoredFileInfo), 0)
                XCTAssertEqual(restoredFileInfo.st_dev, appliedFileInfo.st_dev)
                XCTAssertEqual(restoredFileInfo.st_ino, appliedFileInfo.st_ino)
                try fm.removeItem(at: configCacheURL)
                try fm.removeItem(at: expectationURL)
            }
            var appliedInfo = stat()
            XCTAssertEqual(lstat(envURL.path, &appliedInfo), 0)
            XCTAssertEqual(appliedInfo.st_mode & 0o777, 0o600)
            let connectionStatus = try runVal(["project", "db", "connection", "status", projectID!.rawValue.uuidString], cwd: project)
            XCTAssertEqual(connectionStatus.0, 0, connectionStatus.2 + connectionStatus.1)
            let retainedReview = try runVal(["project", "db", "connection", "review", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString], cwd: project)
            XCTAssertNotEqual(retainedReview.0, 0, "a retained transaction blocks another review")
            let recoveryID = connectionApply.recoveryID
            XCTAssertTrue(connectionStatus.1.contains(recoveryID.uuidString))
            XCTAssertTrue(connectionStatus.1.contains("applied"))

            let recoveryClient = VaelenCoreClient(transport: UnixSocketTransport(path: endpoints.socketPath), identity: fixtureIdentity("connection-recovery"))
            try await recoveryClient.connect()
            do {
                try await recoveryClient.unlink(path: project.path, name: nil, workingDirectory: project.path)
                XCTFail("unlink must refuse retained connection recovery")
            } catch let CoreClientError.remote(payload) {
                XCTAssertEqual(payload.code, .invalidRequest)
                XCTAssertTrue(payload.message.contains("recovery"))
            }
            let stillLinked = try await registry.linkedProject(id: projectID!)
            XCTAssertEqual(stillLinked?.id, projectID)
            let statusAfterUnlink = try await recoveryClient.projectDatabaseConnectionRecovery(.init(selector: projectID!.rawValue.uuidString, workingDirectory: project.path, recoveryAction: .status))
            XCTAssertTrue(statusAfterUnlink.recoveries.contains { $0.id == recoveryID })
            let restoreReview = try await recoveryClient.projectDatabaseConnectionRecovery(.init(selector: projectID!.rawValue.uuidString, workingDirectory: project.path, recoveryAction: .reviewRestore, recoveryID: recoveryID))
            let restoreToken = try XCTUnwrap(restoreReview.review?.confirmation)
            let restored = try await recoveryClient.projectDatabaseConnectionRecovery(.init(selector: projectID!.rawValue.uuidString, workingDirectory: project.path, recoveryAction: .restore, recoveryID: recoveryID, confirmation: restoreToken))
            XCTAssertEqual(restored.outcome?.state, "restored")
            XCTAssertEqual(try Data(contentsOf: envURL), reviewedEnvironment)
            let discardReview = try await recoveryClient.projectDatabaseConnectionRecovery(.init(selector: projectID!.rawValue.uuidString, workingDirectory: project.path, recoveryAction: .reviewDiscard, recoveryID: recoveryID))
            let discardToken = try XCTUnwrap(discardReview.review?.confirmation)
            let discarded = try await recoveryClient.projectDatabaseConnectionRecovery(.init(selector: projectID!.rawValue.uuidString, workingDirectory: project.path, recoveryAction: .discard, recoveryID: recoveryID, confirmation: discardToken))
            XCTAssertEqual(discarded.outcome?.state, "discarded")
            await recoveryClient.disconnect()

            let pdo = try runPDO(php: php, port: generatedPort, database: generatedEnvironment["DB_DATABASE"]!, user: generatedEnvironment["DB_USERNAME"]!, password: generatedPasswordBytes, sql: "CREATE TABLE migration_equivalent (id INT PRIMARY KEY, value VARCHAR(64) NOT NULL); INSERT INTO migration_equivalent VALUES (1, 'persisted-row'); SELECT value FROM migration_equivalent WHERE id = 1;")
            XCTAssertEqual(pdo.status, 0, pdo.error)
            XCTAssertEqual(pdo.output.trimmingCharacters(in: .whitespacesAndNewlines), "persisted-row")
            let wildcardGrant = try runPDO(php: php, port: generatedPort, database: wildcardNeighbor, user: generatedEnvironment["DB_USERNAME"]!, password: generatedPasswordBytes, sql: "CREATE TABLE denied_neighbor (id INT);")
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
            XCTAssertEqual(try Data(contentsOf: envURL), reviewedEnvironment)
            XCTAssertEqual(try ServiceInstanceRepository(store: store).claims(for: serviceID), claims)

            try stopFixtureMySQL(module: module, root: root, timeout: 10)
            let staleReveal = try runValWithoutPersisting(["project", "db", "password", "reveal", attempt.operationID.rawValue.uuidString, projectID!.rawValue.uuidString], cwd: project, executable: val, environment: environment, supportRoot: layout.rootURL)
            XCTAssertNotEqual(staleReveal.status, 0, "reveal must refuse a stopped, stale service target")
            mysqlPID = try module.start().pid
            let recovered = try runPDO(php: php, port: generatedPort, database: generatedEnvironment["DB_DATABASE"]!, user: generatedEnvironment["DB_USERNAME"]!, password: generatedPasswordBytes, sql: "SELECT value FROM migration_equivalent WHERE id = 1;")
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
            XCTAssertEqual(try ServiceInstanceRepository(store: store).claims(for: serviceID), claims)
            try await reopenedClient.unlink(path: project.path, name: nil, workingDirectory: project.path)
            let unlinkedProject = try await registry.linkedProject(id: projectID!)
            XCTAssertNil(unlinkedProject, "explicitly discarded recovery permits project unlink")
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
            XCTAssertEqual(try Data(contentsOf: envURL), reviewedEnvironment)
            XCTAssertTrue(try ServiceInstanceRepository(store: store).claims(for: serviceID).isEmpty, "unlink releases the project service claim after recovery is discarded")
            try removeCredentials(namespace: namespace)
            try fm.removeItem(at: root)
            XCTAssertFalse(fm.fileExists(atPath: root.path))
            if let evidencePath = environment["VAELEN_PROJECT_DATABASE_EVIDENCE"] {
                let laravelEvidence = laravelAcceptance ? " laravel=13.39.0 phpdotenv=5.8.0 uncached=boot-query cached=boot-query dotenvMarker=uncached-only wrongExpectation=refused missingCache=refused cacheMode=0600" : ""
                let evidence = "result=PASS engine=mysql package=8.4.11 create=ready databaseCollision=refused userCollision=refused existingUserUnchanged=yes requestedDatabaseAbsent=yes pdoMigration=passed neighboringDatabase=denied coreReopen=persisted env=restore-reviewed-bytes claims=unchanged keychain=exact-items-deleted cleanup=confirmed processTable=clear processRecord=absent socket=absent root=removed\(laravelEvidence)\n"
                try Data(evidence.utf8).write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
            }
            let laravelEvidence = laravelAcceptance ? " laravel=13.39.0 phpdotenv=5.8.0 uncached=boot-query cached=boot-query dotenvMarker=uncached-only wrongExpectation=refused missingCache=refused cacheMode=0600" : ""
            print("PROJECT_DATABASE_PROVISIONING_EVIDENCE mysql=8.4.11 port=\(port) create=ready collision=refused sentinel=preserved pdo=authenticated neighboringDatabase=denied coreReopen=persisted env=unchanged claims=unchanged keychain=exact-items-deleted cleanup=confirmed processTable=clear processRecord=absent socket=absent root=removed\(laravelEvidence)")
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

    private enum FixtureError: Error { case childStillRunning, childTimedOut, coreDidNotStop, keychainItemUnidentified, invalidGeneratedEnvironment }

    private struct LaravelConnectionExpectation: Encodable {
        let values: [String: String]

        func encode(to encoder: Encoder) throws { try values.encode(to: encoder) }

        init(defaultConnection: String, host: String, port: String, database: String, username: String, password: String) {
            values = [
                "database.default": defaultConnection,
                "database.connections.mysql.host": host,
                "database.connections.mysql.port": port,
                "database.connections.mysql.database": database,
                "database.connections.mysql.username": username,
                "database.connections.mysql.password": password
            ]
        }

        init(values: [String: String]) { self.values = values }
    }

    private struct LaravelChildResult {
        let status: Int32
        let output: String
        let credentialOutputDetected: Bool
        var isSuccessful: Bool { status == 0 && !credentialOutputDetected }
    }

    private func runLaravelProbe(php: String, probe: URL, phase: String, expectation: URL, cwd: URL, secret: Data) throws -> LaravelChildResult {
        try runLaravelPHP(php: php, cwd: cwd, arguments: [probe.path, phase, expectation.path], secret: secret)
    }

    private func runLaravelArtisan(php: String, cwd: URL, secret: Data) throws -> LaravelChildResult {
        try runLaravelPHP(php: php, cwd: cwd, arguments: ["artisan", "config:cache"], secret: secret, restrictiveUmask: true)
    }

    private func runLaravelPHP(php: String, cwd: URL, arguments: [String], secret: Data, restrictiveUmask: Bool = false) throws -> LaravelChildResult {
        let process = Process(), output = Pipe(), error = Pipe()
        let privateHome = cwd.deletingLastPathComponent().appendingPathComponent("laravel-child-home", isDirectory: true)
        try FileManager.default.createDirectory(at: privateHome, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(privateHome.path, 0o700), 0)
        if restrictiveUmask {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "umask 077; exec \"$1\" -d display_errors=0 -d log_errors=0 artisan config:cache", "sh", php]
        } else {
            process.executableURL = URL(fileURLWithPath: php)
            process.arguments = ["-d", "display_errors=0", "-d", "log_errors=0"] + arguments
        }
        process.currentDirectoryURL = cwd
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": privateHome.path, "TMPDIR": privateHome.path, "LC_ALL": "C", "PHP_DISPLAY_ERRORS": "0", "PHP_LOG_ERRORS": "0"]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try finish(process)
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        let combined = stdout + stderr
        guard !secret.isEmpty, combined.range(of: secret) == nil else {
            return LaravelChildResult(status: process.terminationStatus, output: "Laravel child output contained the generated credential", credentialOutputDetected: true)
        }
        return LaravelChildResult(status: process.terminationStatus, output: String(decoding: stdout, as: UTF8.self) + String(decoding: stderr, as: UTF8.self), credentialOutputDetected: false)
    }

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

    private func generatedDotenvValues(_ bytes: Data) throws -> [String: String] {
        guard let text = String(data: bytes, encoding: .utf8) else { throw FixtureError.invalidGeneratedEnvironment }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals])
            let raw = String(trimmed[trimmed.index(after: equals)...])
            if raw.count >= 2, let first = raw.first, (first == "'" || first == "\""), raw.last == first {
                let inner = Array(raw.dropFirst().dropLast().utf8)
                var decoded = [UInt8](); var index = 0
                while index < inner.count {
                    if inner[index] == 92, index + 1 < inner.count { index += 1 }
                    decoded.append(inner[index]); index += 1
                }
                values[key] = String(decoding: decoded, as: UTF8.self)
            } else {
                values[key] = raw.trimmingCharacters(in: .whitespaces)
            }
        }
        return values
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
