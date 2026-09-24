import XCTest
import Darwin
@testable import VaelenCore

final class MySQLRuntimeLifecycleTests: XCTestCase {
    func testConfiguredInstanceMigratesTo3306WithoutReinitializingData() throws {
        guard !isPortListening(3306) else { throw XCTSkip("canonical MySQL port is occupied") }
        let installedLayout = VaelenFilesystemLayout()
        let installed = try JSONDecoder().decode(MySQLPackage.self, from: Data(contentsOf: installedLayout.mysqlPackagesDirectoryURL.appendingPathComponent("8.4.11/.vaelen-package.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-port-migration-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true), logsDirectoryURL: root.appendingPathComponent("logs", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
        try Data(installed.version.utf8).write(to: layout.configurationDirectoryURL.appendingPathComponent("mysql-default.json"))
        let legacyPort = try availableLoopbackPort()
        let legacy = MySQLModule(layout: layout, port: legacyPort, instanceName: "migration", tcpEnabled: true, packageOverride: installed)
        try legacy.initialize()
        XCTAssertEqual(legacy.status().state, MySQLState.stopped)
        XCTAssertEqual(legacy.status().port, legacyPort)
        let legacyInstance = layout.mysqlInstancesDirectoryURL.appendingPathComponent("migration")
        let legacyStatus = try legacy.start()
        _ = try command(installed.clientPath, ["--defaults-extra-file=\(legacyInstance.appendingPathComponent("client.cnf").path)", "--protocol=socket", "--socket=\(legacyStatus.socket)", "-e", "CREATE DATABASE syncproof; CREATE TABLE syncproof.vaelen_migration_probe (value VARCHAR(32)); INSERT INTO syncproof.vaelen_migration_probe VALUES ('preserved'); ALTER USER 'root'@'localhost' IDENTIFIED BY 'legacy-password';"])
        try Data("[client]\nuser=root\npassword=legacy-password\nprotocol=socket\nsocket=\(legacyStatus.socket)\n".utf8).write(to: legacyInstance.appendingPathComponent("client.cnf"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyInstance.appendingPathComponent("client.cnf").path)
        _ = try legacy.stop()
        var legacyMetadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: legacyInstance.appendingPathComponent("metadata.json"))) as? [String: Any])
        legacyMetadata.removeValue(forKey: "rootPasswordMode")
        try JSONSerialization.data(withJSONObject: legacyMetadata, options: [.sortedKeys]).write(to: legacyInstance.appendingPathComponent("metadata.json"), options: .atomic)

        let migrated = MySQLModule(layout: layout, port: 3306, instanceName: "migration", tcpEnabled: true, packageOverride: installed)
        defer { if migrated.status().pid != nil { _ = try? migrated.stop() } }
        let status = try migrated.start()
        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.port, 3306)
        let metadataURL = layout.mysqlInstancesDirectoryURL.appendingPathComponent("migration/metadata.json")
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        XCTAssertEqual(metadata["port"] as? Int, 3306)
        let query = try command(installed.clientPath, ["--no-defaults", "--protocol=tcp", "--connect-timeout=2", "-h127.0.0.1", "-P3306", "-uroot", "--password=", "-Nse", "SELECT @@port, EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name='syncproof'), (SELECT value FROM syncproof.vaelen_migration_probe LIMIT 1)"])
        XCTAssertTrue(query.hasSuffix("3306\t1\tpreserved"), "root/empty-password at 127.0.0.1:3306 must work while preserving schema data: \(query)")
        let migratedMetadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        XCTAssertEqual(migratedMetadata["rootPasswordMode"] as? String, "empty")
        XCTAssertEqual(try migrated.stop().state, .stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.mysqlInstancesDirectoryURL.appendingPathComponent("migration/data/mysql").path), "migration must preserve the initialized data directory")

        let restarted = try migrated.start()
        XCTAssertEqual(restarted.state, .running, "the normalization marker makes migration idempotent")
        let repeated = try command(installed.clientPath, ["--no-defaults", "--protocol=tcp", "--connect-timeout=2", "-h127.0.0.1", "-P3306", "-uroot", "--password=", "-Nse", "SELECT value FROM syncproof.vaelen_migration_probe"])
        XCTAssertTrue(repeated.hasSuffix("preserved"), repeated)
        _ = try migrated.stop()
    }

    func testRelaunchedCoreStopsRecordedMySQLInstanceWithoutProcessHandle() throws {
        let installedLayout = VaelenFilesystemLayout()
        let installed = try JSONDecoder().decode(MySQLPackage.self, from: Data(contentsOf: installedLayout.mysqlPackagesDirectoryURL.appendingPathComponent("8.4.11/.vaelen-package.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mysql-core-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeModule(named: "restart", root: root, installed: installed)
        let originalCore = fixture.module
        defer { if originalCore.status().pid != nil { _ = try? originalCore.stop() } }

        try originalCore.initialize()
        let started = try originalCore.start()
        let pid = try XCTUnwrap(started.pid)
        let relaunchedCore = try makeModule(named: "restart", root: root, installed: installed).module

        XCTAssertEqual(try relaunchedCore.stop().state, .stopped)
        XCTAssertProcessGone(pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.socket))
    }

    func testStartReconcilesOnlyProvenExitedRuntimeSocketAndPIDArtifacts() throws {
        let installedLayout = VaelenFilesystemLayout()
        let installed = try JSONDecoder().decode(MySQLPackage.self, from: Data(contentsOf: installedLayout.mysqlPackagesDirectoryURL.appendingPathComponent("8.4.11/.vaelen-package.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mysql-stale-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeModule(named: "stale", root: root, installed: installed)
        let module = fixture.module
        try module.initialize()

        let instance = fixture.layout.mysqlInstancesDirectoryURL.appendingPathComponent("stale")
        let pidFile = instance.appendingPathComponent("mysqld.pid")
        let socketPath = module.status().socket
        try Data("2147483647\n".utf8).write(to: pidFile)
        let socketMaker = Process()
        socketMaker.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        socketMaker.arguments = ["-c", "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()", socketPath]
        try socketMaker.run()
        socketMaker.waitUntilExit()
        XCTAssertEqual(socketMaker.terminationStatus, 0)
        XCTAssertTrue(isSocket(socketPath))
        let staleSocketIdentity = try fileIdentity(socketPath)

        let started = try module.start()
        XCTAssertEqual(started.state, .running)
        let pid = try XCTUnwrap(started.pid)
        XCTAssertEqual(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "\(pid)")
        XCTAssertTrue(isSocket(socketPath))
        XCTAssertNotEqual(try fileIdentity(socketPath), staleSocketIdentity, "MySQL must bind a new socket after the proven stale socket is removed")
        defer { if module.status().pid != nil { _ = try? module.stop() } }
        XCTAssertEqual(try module.stop().state, .stopped)
        XCTAssertProcessGone(pid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: started.datadir).appendingPathComponent("mysql").path), "runtime recovery must preserve database files")
    }

    func testStartReadinessIsBoundedWhenMysqlAdminHangs() throws {
        let installedLayout = VaelenFilesystemLayout()
        let installed = try JSONDecoder().decode(MySQLPackage.self, from: Data(contentsOf: installedLayout.mysqlPackagesDirectoryURL.appendingPathComponent("8.4.11/.vaelen-package.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-ping-timeout-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true), logsDirectoryURL: root.appendingPathComponent("logs", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
        try Data(installed.version.utf8).write(to: layout.configurationDirectoryURL.appendingPathComponent("mysql-default.json"))

        let modeFile = root.appendingPathComponent("mysqladmin-mode")
        let wrapper = root.appendingPathComponent("mysqladmin-wrapper.sh")
        let script = "#!/bin/sh\nif [ \"$(cat '\(modeFile.path)' 2>/dev/null)\" = hang ]; then\n  for arg in \"$@\"; do [ \"$arg\" = ping ] && exec /bin/sleep 30; done\nfi\nexec '\(installed.adminPath)' \"$@\"\n"
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let package = MySQLPackage(version: installed.version, architecture: installed.architecture, packagePath: installed.packagePath, serverPath: installed.serverPath, clientPath: installed.clientPath, adminPath: wrapper.path, source: installed.source, artifactSHA256: installed.artifactSHA256, signatureURL: installed.signatureURL, license: installed.license, installedAt: installed.installedAt)
        let module = MySQLModule(layout: layout, port: 0, instanceName: "timeout", tcpEnabled: false, packageOverride: package, clientCommandTimeout: 1.5, shutdownTimeout: 2)
        try module.initialize()
        try Data("hang".utf8).write(to: modeFile)

        let startedAt = Date()
        XCTAssertThrowsError(try module.start()) { error in
            guard case let MySQLModuleError.processFailed(message) = error else { return XCTFail("unexpected error: \(error)") }
            XCTAssertFalse(message.contains("remains live"), message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 18, "a wedged mysqladmin readiness probe must not leave Start pending")
        XCTAssertEqual(module.status().state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.mysqlInstancesDirectoryURL.appendingPathComponent("timeout/process.json").path))
    }

    func testStopRetainsOwnershipAcrossClientAndServerShutdownTimeouts() throws {
        let installedLayout = VaelenFilesystemLayout()
        let installed = try JSONDecoder().decode(MySQLPackage.self, from: Data(contentsOf: installedLayout.mysqlPackagesDirectoryURL.appendingPathComponent("8.4.11/.vaelen-package.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-timeout-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelatedFixture = try makeModule(named: "unrelated", root: root.appendingPathComponent("unrelated"), installed: installed)
        let unrelated = unrelatedFixture.module
        defer { if unrelated.status().pid != nil { _ = try? unrelated.stop() } }
        try unrelated.initialize()
        let unrelatedStatus = try unrelated.start()
        let unrelatedPID = try XCTUnwrap(unrelatedStatus.pid)

        for (name, expectedMessage) in [("client-timeout", "client command timed out"), ("server-timeout", "did not stop within the graceful shutdown timeout")] {
            let fixtureRoot = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
            let modeFile = fixtureRoot.appendingPathComponent("mode")
            let wrapper = fixtureRoot.appendingPathComponent("mysqladmin-test-wrapper.sh")
            let script = "#!/bin/sh\nif [ -f '\(modeFile.path)' ]; then mode=$(cat '\(modeFile.path)'); else mode=real; fi\ncase \"$mode\" in hang) exec /bin/sleep 30 ;; noop) exit 0 ;; esac\nexec '\(installed.adminPath)' \"$@\"\n"
            try Data(script.utf8).write(to: wrapper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            let package = MySQLPackage(version: installed.version, architecture: installed.architecture, packagePath: installed.packagePath, serverPath: installed.serverPath, clientPath: installed.clientPath, adminPath: wrapper.path, source: installed.source, artifactSHA256: installed.artifactSHA256, signatureURL: installed.signatureURL, license: installed.license, installedAt: installed.installedAt)
            let fixture = try makeModule(named: name, root: fixtureRoot, installed: package, clientCommandTimeout: 1.5, shutdownTimeout: 0.3)
            let module = fixture.module
            defer { if module.status().pid != nil { _ = try? module.stop() } }
            try module.initialize()
            print("timeout acceptance: \(name) initialized")
            let sentinel = URL(fileURLWithPath: module.status().datadir).appendingPathComponent("preserve.txt")
            try Data("preserve".utf8).write(to: sentinel)
            let started = try module.start()
            try Data((name == "client-timeout" ? "hang" : "noop").utf8).write(to: modeFile, options: .atomic)
            let pid = try XCTUnwrap(started.pid)
            let instance = fixture.layout.mysqlInstancesDirectoryURL.appendingPathComponent(name)
            let pidFile = instance.appendingPathComponent("mysqld.pid")
            let recordFile = instance.appendingPathComponent("process.json")
            let originalRecord = try Data(contentsOf: recordFile)
            let originalSocketIdentity = try fileIdentity(started.socket)
            let originalPIDIdentity = try fileIdentity(pidFile.path)

            XCTAssertThrowsError(try module.stop(), "\(name) must report shutdown failure") { error in
                guard case let MySQLModuleError.processFailed(message) = error else { return XCTFail("unexpected error: \(error)") }
                XCTAssertTrue(message.contains(expectedMessage), message)
            }
            XCTAssertTrue(moduleProcessIsLive(pid), "owned server must still be live after \(name)")
            XCTAssertEqual(try Data(contentsOf: recordFile), originalRecord, "diagnostic process record must remain intact")
            XCTAssertEqual(try fileIdentity(started.socket), originalSocketIdentity)
            XCTAssertEqual(try fileIdentity(pidFile.path), originalPIDIdentity)
            XCTAssertTrue(isSocket(started.socket))
            XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
            XCTAssertEqual(unrelated.status().pid, unrelatedPID)
            XCTAssertTrue(isSocket(unrelatedStatus.socket))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))

            // Switch the fixture's client to a real authenticated mysqladmin
            // shutdown request, then prove the same provider can retry.
            try Data("real".utf8).write(to: modeFile, options: .atomic)
            module.shutdownTimeout = 5
            XCTAssertEqual(try module.stop().state, .stopped)
            XCTAssertProcessGone(pid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: started.socket))
            XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: recordFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
            XCTAssertEqual(unrelated.status().pid, unrelatedPID)
            print("MySQL \(name): reported failure, retained live PID/socket/PID-file/process record, then retry stopped PID \(pid); unrelated PID \(unrelatedPID) remained live")
        }

        XCTAssertEqual(try unrelated.stop().state, .stopped)
        XCTAssertProcessGone(unrelatedPID)
    }

    func testManagedMySQLIsolatedLifecyclePreservesUnrelatedSameBinaryServer() throws {
        let installedLayout = VaelenFilesystemLayout()
        let installed = try JSONDecoder().decode(MySQLPackage.self, from: Data(contentsOf: installedLayout.mysqlPackagesDirectoryURL.appendingPathComponent("8.4.11/.vaelen-package.json")))
        let serverURL = URL(fileURLWithPath: installed.serverPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: serverURL.path))
        let hash = try command("/usr/bin/shasum", ["-a", "256", serverURL.path])
        print("MySQL acceptance executable: \(serverURL.path)\nSHA-256: \(hash)")

        let beforeListeners = try command("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"])
        guard !beforeListeners.contains(":3306 "), !beforeListeners.contains(":13306 "), processIDs(named: "mysqld").isEmpty else {
            throw XCTSkip("MySQL lifecycle acceptance requires canonical ports and mysqld to be inactive")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let moduleFixture = try makeModule(named: "acceptance", root: root.appendingPathComponent("managed"), installed: installed)
        let unrelatedFixture = try makeModule(named: "unrelated", root: root.appendingPathComponent("unrelated"), installed: installed)
        print("MySQL isolated acceptance root: \(root.path)\nmanaged support: \(moduleFixture.layout.rootURL.path)\nmanaged logs: \(moduleFixture.layout.mysqlLogsDirectoryURL.path)\nmanaged instance: \(moduleFixture.layout.mysqlInstancesDirectoryURL.appendingPathComponent("acceptance").path)\nunrelated support: \(unrelatedFixture.layout.rootURL.path)\nunrelated logs: \(unrelatedFixture.layout.mysqlLogsDirectoryURL.path)\nunrelated instance: \(unrelatedFixture.layout.mysqlInstancesDirectoryURL.appendingPathComponent("unrelated").path)")
        let module = moduleFixture.module
        let unrelated = unrelatedFixture.module
        defer {
            if module.status().pid != nil { _ = try? module.stop() }
            if unrelated.status().pid != nil { _ = try? unrelated.stop() }
        }

        try module.initialize()
        let initializedStatus = try module.start()
        let rootLogin = try command(installed.clientPath, ["--defaults-extra-file=\(moduleFixture.layout.mysqlInstancesDirectoryURL.appendingPathComponent("acceptance/client.cnf").path)", "--protocol=socket", "--socket=\(initializedStatus.socket)", "-Nse", "SELECT CURRENT_USER()"])
        XCTAssertTrue(rootLogin.hasSuffix("root@localhost"), "Vaelen-managed MySQL should accept its generated local credentials")
        _ = try module.stop()
        try unrelated.initialize()
        let unrelatedStatus = try unrelated.start()
        let unrelatedPID = try XCTUnwrap(unrelatedStatus.pid)
        XCTAssertEqual(unrelatedStatus.state, .running)
        XCTAssertTrue(isSocket(unrelatedStatus.socket))
        let tcpOwnersAfterStart = (try? command("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN"])) ?? ""
        XCTAssertFalse(isPortListening(3306), tcpOwnersAfterStart)
        XCTAssertFalse(isPortListening(13306), tcpOwnersAfterStart)

        let managedData = URL(fileURLWithPath: module.status().datadir)
        let sentinel = managedData.appendingPathComponent("acceptance-preservation.txt")
        try Data("keep this isolated MySQL data directory".utf8).write(to: sentinel)
        let paths = moduleFixture.layout.mysqlInstancesDirectoryURL.appendingPathComponent("acceptance")
        let pidFile = paths.appendingPathComponent("mysqld.pid")
        let processRecord = paths.appendingPathComponent("process.json")

        for cycle in 1...2 {
            let started = try module.start()
            if cycle == 1 { print("managed socket: \(started.socket)\nmanaged datadir: \(started.datadir)\nmanaged config: \(paths.appendingPathComponent("my.cnf").path)\nmanaged log: \(moduleFixture.layout.mysqlLogsDirectoryURL.appendingPathComponent("acceptance.log").path)") }
            let pid = try XCTUnwrap(started.pid)
            XCTAssertEqual(started.state, .running)
            XCTAssertEqual(started.health, "healthy")
            XCTAssertEqual(started.executablePath, installed.serverPath)
            XCTAssertTrue(started.datadir.hasPrefix(moduleFixture.layout.rootURL.path))
            XCTAssertTrue(isSocket(started.socket))
            XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: processRecord.path))
            XCTAssertFalse(isPortListening(3306))
            XCTAssertFalse(isPortListening(13306))
            let commandLine = try command("/bin/ps", ["-p", "\(pid)", "-o", "command="])
            XCTAssertTrue(commandLine.contains(installed.serverPath), commandLine)
            XCTAssertTrue(commandLine.contains("my.cnf"), commandLine)
            let networking = try command(installed.clientPath, ["--defaults-extra-file=\(moduleFixture.layout.mysqlInstancesDirectoryURL.appendingPathComponent("acceptance/client.cnf").path)", "--protocol=socket", "--socket=\(started.socket)", "-Nse", "SELECT @@GLOBAL.skip_networking"])
            XCTAssertEqual(networking, "1")

            let stopped = try module.stop()
            XCTAssertEqual(stopped.state, .stopped)
            XCTAssertNil(stopped.pid)
            XCTAssertProcessGone(pid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: started.socket))
            XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: processRecord.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: managedData.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
            XCTAssertEqual(module.status().state, .stopped)
            XCTAssertEqual(unrelated.status().state, .running, "unrelated instance must remain healthy")
            XCTAssertEqual(unrelated.status().pid, unrelatedPID)
            XCTAssertTrue(isSocket(unrelatedStatus.socket))
            XCTAssertFalse(isPortListening(3306))
            XCTAssertFalse(isPortListening(13306))
            print("MySQL cycle \(cycle): master=\(pid) stopped, socket/PID record removed; unrelated master=\(unrelatedPID) remains running; data sentinel preserved")
        }

        // Prove that a corrupted stored identity does not cause a shutdown
        // request to be sent to the still-live, handle-owned server.
        let mismatchStatus = try module.start()
        let mismatchPID = try XCTUnwrap(mismatchStatus.pid)
        let original = try Data(contentsOf: processRecord)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        fields["executable"] = "/not/the/launched/mysqld"
        let corrupted = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
        try corrupted.write(to: processRecord, options: .atomic)
        XCTAssertThrowsError(try module.stop(), "an unverifiable live PID must not be detached from its ownership record") { error in
            guard case MySQLModuleError.processIdentityMismatch = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: processRecord), corrupted, "the live process identity evidence must be retained")
        XCTAssertTrue(moduleProcessIsLive(mismatchPID))
        XCTAssertTrue(isSocket(mismatchStatus.socket))
        try original.write(to: processRecord, options: .atomic)
        XCTAssertEqual(try module.stop().state, .stopped)
        XCTAssertProcessGone(mismatchPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(unrelated.status().pid, unrelatedPID)
        XCTAssertTrue(unrelatedStatus.socket.withCString { access($0, F_OK) == 0 })

        let restartedServer = try module.start()
        let restartedPID = try XCTUnwrap(restartedServer.pid)
        let relaunchedCore = try makeModule(named: "acceptance", root: root.appendingPathComponent("managed"), installed: installed).module
        XCTAssertEqual(try relaunchedCore.stop().state, .stopped)
        XCTAssertProcessGone(restartedPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restartedServer.socket))
        XCTAssertEqual(unrelated.status().state, .running, "Core restart cleanup must leave the unrelated server running")

        // Exercise the retained Process handle observing a server that exits
        // outside the provider's normal shutdown path.
        let exitedStatus = try module.start()
        let exitedPID = try XCTUnwrap(exitedStatus.pid)
        XCTAssertEqual(kill(exitedPID, SIGTERM), 0)
        for _ in 0..<100 where moduleProcessIsLive(exitedPID) { usleep(20_000) }
        XCTAssertFalse(moduleProcessIsLive(exitedPID))
        XCTAssertEqual(module.status().state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exitedStatus.socket))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: processRecord.path))

        XCTAssertEqual(try unrelated.stop().state, .stopped)
        XCTAssertProcessGone(unrelatedPID)
    }

    private func makeModule(named name: String, root: URL, installed: MySQLPackage, clientCommandTimeout: TimeInterval = 10, shutdownTimeout: TimeInterval = 8) throws -> (module: MySQLModule, layout: VaelenFilesystemLayout) {
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true), logsDirectoryURL: logs)
        try FileManager.default.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
        try Data(installed.version.utf8).write(to: layout.configurationDirectoryURL.appendingPathComponent("mysql-default.json"), options: .atomic)
        return (MySQLModule(layout: layout, port: 0, instanceName: name, tcpEnabled: false, packageOverride: installed, clientCommandTimeout: clientCommandTimeout, shutdownTimeout: shutdownTimeout), layout)
    }

    private func isPortListening(_ port: Int) -> Bool {
        let output = (try? command("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"])) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: "MySQLRuntimeLifecycleTests", code: 10) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw NSError(domain: "MySQLRuntimeLifecycleTests", code: 11) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw NSError(domain: "MySQLRuntimeLifecycleTests", code: 12) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private func fileIdentity(_ path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw NSError(domain: "MySQLRuntimeLifecycleTests", code: Int(errno), userInfo: [NSFilePathErrorKey: path]) }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private func moduleProcessIsLive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private func processIDs(named name: String) -> [Int32] {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); process.arguments = ["-x", name]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).compactMap { Int32($0) } ?? []
    }

    private func XCTAssertProcessGone(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<100 { if !moduleProcessIsLive(pid) { return }; usleep(20_000) }
        XCTFail("MySQL PID \(pid) remained live", file: file, line: line)
    }

    private func command(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "MySQLRuntimeLifecycleTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
