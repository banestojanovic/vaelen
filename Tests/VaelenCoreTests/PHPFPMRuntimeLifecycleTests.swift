import XCTest
import Darwin
@testable import VaelenCore

final class PHPFPMRuntimeLifecycleTests: XCTestCase {
    func testRelaunchedCoreStopsRecordedFPMMasterWithoutKillingSiblingProcesses() throws {
        let defaultLayout = VaelenFilesystemLayout()
        let packageURL = defaultLayout.phpPackagesDirectoryURL.appendingPathComponent("8.4.23/.vaelen-package.json")
        let installed = try JSONDecoder().decode(PHPPackage.self, from: Data(contentsOf: packageURL))
        let fixture = try IsolatedPHPFixture(installedPackage: installed)
        defer { _ = fixture.cleanup() }

        let started = try fixture.module.start(requestedVersion: installed.version)
        let pid = try XCTUnwrap(started.pid)
        let manifestURL = fixture.root.appendingPathComponent("fixture-manifest.json")
        let relaunchedCore = PHPModule(layout: fixture.layout, location: FilePHPManifestLocation(manifestURL: manifestURL))

        XCTAssertEqual(try relaunchedCore.stop(requestedVersion: installed.version).state, .stopped)
        XCTAssertProcessGone(pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.processRecordURL.path))
    }

    func testPHPFPMIsolationRegressionLeavesNormalRuntimeStoppedAndUnrelatedProcessUntouched() throws {
        let defaultLayout = VaelenFilesystemLayout()
        let packageURL = defaultLayout.phpPackagesDirectoryURL.appendingPathComponent("8.4.23/.vaelen-package.json")
        let installed = try JSONDecoder().decode(PHPPackage.self, from: Data(contentsOf: packageURL))
        let fpm = URL(fileURLWithPath: installed.fpmPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fpm.path))
        let hash = try command("/usr/bin/shasum", ["-a", "256", fpm.path])
        print("PHP-FPM acceptance executable: \(fpm.path)\nSHA-256: \(hash)")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        var managedCleanupSucceeded = true
        var externalCleanupSucceeded = true
        defer {
            if managedCleanupSucceeded && externalCleanupSucceeded { try? FileManager.default.removeItem(at: root) }
            else { print("Preserving PHP-FPM test root because child cleanup was not verified: \(root.path)") }
        }
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("core", isDirectory: true), logsDirectoryURL: root.appendingPathComponent("logs", isDirectory: true))
        let packageDirectory = layout.phpPackagesDirectoryURL.appendingPathComponent("8.4.23", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let isolatedPackage = PHPPackage(version: installed.version, architecture: installed.architecture, packagePath: packageDirectory.path, cliPath: installed.cliPath, fpmPath: installed.fpmPath, source: installed.source, cliSHA256: installed.cliSHA256, fpmSHA256: installed.fpmSHA256, installedAt: installed.installedAt)
        try JSONEncoder().encode(isolatedPackage).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
        try FileManager.default.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
        try Data("8.4.23".utf8).write(to: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"), options: .atomic)
        let manifestURL = root.appendingPathComponent("fixture-manifest.json")
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: "8.4.23", platform: "macos", architecture: "arm64", artifacts: [:], verification: .init(algorithm: "sha256", authenticity: "isolated-installed-runtime"))
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: manifestURL))
        XCTAssertEqual(try module.resolveEligible("8.4.23").fpmPath, installed.fpmPath)
        let normalRecord = defaultLayout.phpInstancesDirectoryURL.appendingPathComponent("8.4.23/process.json")
        let normalSocket = defaultLayout.rootURL.appendingPathComponent("runtime/sockets/php/php-8.4.23.sock")
        let normalConfig = defaultLayout.phpInstancesDirectoryURL.appendingPathComponent("8.4.23/config/php-fpm.conf")
        let normalDefault = defaultLayout.configurationDirectoryURL.appendingPathComponent("php-default.json")
        let normalLog = defaultLayout.phpLogsDirectoryURL.appendingPathComponent("8.4.23.log")
        let normalRecordBefore = try? Data(contentsOf: normalRecord)
        let normalSocketBefore = unixSocketIdentity(normalSocket.path)
        let normalConfigBefore = try? Data(contentsOf: normalConfig)
        let normalDefaultBefore = try? Data(contentsOf: normalDefault)
        let normalLogBefore = try? Data(contentsOf: normalLog)
        let normalProcessesBefore = processTreePIDsForFPMConfig(normalConfig.path)
        guard normalRecordBefore == nil, normalSocketBefore == nil, normalProcessesBefore.isEmpty else {
            throw XCTSkip("PHP-FPM isolation regression requires normal Vaelen PHP-FPM to begin stopped")
        }
        let isolatedRecord = layout.phpInstancesDirectoryURL.appendingPathComponent("8.4.23/process.json")
        var recordToRestoreAfterIdentityTest: Data?
        defer {
            if let original = recordToRestoreAfterIdentityTest {
                try? original.write(to: isolatedRecord)
            }
            if FileManager.default.fileExists(atPath: isolatedRecord.path) {
                do { _ = try module.stop(requestedVersion: "8.4.23") }
                catch { managedCleanupSucceeded = false; XCTFail("Managed FPM cleanup failed after test body: \(error)") }
            }
            if FileManager.default.fileExists(atPath: isolatedRecord.path) || FileManager.default.fileExists(atPath: layout.rootURL.appendingPathComponent("runtime/sockets/php/php-8.4.23.sock").path) {
                managedCleanupSucceeded = false
                XCTFail("Managed FPM record or socket remains in isolated test root")
            }
            XCTAssertEqual(try? Data(contentsOf: normalRecord), normalRecordBefore, "isolated test must not change the normal PHP process record")
            XCTAssertEqual(unixSocketIdentity(normalSocket.path), normalSocketBefore, "isolated test must not change the normal PHP socket")
            XCTAssertEqual(try? Data(contentsOf: normalConfig), normalConfigBefore, "isolated test must not change normal PHP-FPM configuration")
            XCTAssertEqual(try? Data(contentsOf: normalDefault), normalDefaultBefore, "isolated test must not change normal PHP intent")
            XCTAssertEqual(try? Data(contentsOf: normalLog), normalLogBefore, "isolated test must not change the normal PHP log")
            XCTAssertEqual(processTreePIDsForFPMConfig(normalConfig.path), normalProcessesBefore, "isolated test must not start or stop normal PHP-FPM processes")
        }

        // Competing FPM master uses the same executable but a different,
        // isolated configuration and socket. Module stop must leave it alone.
        let externalConfig = root.appendingPathComponent("external.conf")
        let externalSocket = root.appendingPathComponent("external.sock")
        let externalLog = root.appendingPathComponent("external.log")
        let externalPIDFile = root.appendingPathComponent("external.pid")
        let user = NSUserName()
        let externalContents = "[global]\ndaemonize = no\npid = \(externalPIDFile.path)\nerror_log = \(externalLog.path)\n\n[external]\nuser = \(user)\ngroup = \(user)\nlisten = \(externalSocket.path)\nlisten.mode = 0600\npm = dynamic\npm.max_children = 1\npm.start_servers = 1\npm.min_spare_servers = 1\npm.max_spare_servers = 1\n"
        try Data(externalContents.utf8).write(to: externalConfig)
        let externalLogHandle = try FileHandle(forWritingTo: createFileIfNeeded(externalLog))
        let external = Process(); external.executableURL = fpm; external.arguments = ["-y", externalConfig.path, "-F"]; external.standardOutput = externalLogHandle; external.standardError = externalLogHandle
        try external.run()
        var externalWorkerPIDs = [Int32]()
        defer { externalCleanupSucceeded = cleanup(external, socket: externalSocket.path, knownWorkers: externalWorkerPIDs) }
        try waitForSocket(externalSocket.path)
        externalWorkerPIDs = childPIDs(of: external.processIdentifier)
        XCTAssertFalse(externalWorkerPIDs.isEmpty, "expected the FPM master to create a worker")

        let managedSocket = layout.rootURL.appendingPathComponent("runtime/sockets/php/php-8.4.23.sock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedSocket.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpInstancesDirectoryURL.appendingPathComponent("8.4.23/process.json").path))

        for cycle in 1...2 {
            let started = try module.start(requestedVersion: "8.4.23")
            XCTAssertEqual(started.state, .running, "cycle \(cycle): \(started.health)")
            XCTAssertEqual(started.health, "healthy")
            XCTAssertTrue(FileManager.default.fileExists(atPath: managedSocket.path))
            XCTAssertTrue(isUnixSocket(managedSocket.path))
            let masterPID = try XCTUnwrap(started.pid)
            let commandLine = try command("/bin/ps", ["-p", "\(masterPID)", "-o", "command="])
            XCTAssertTrue(commandLine.contains("php-fpm: master process"), commandLine)
            XCTAssertTrue(commandLine.contains("php-fpm.conf"), commandLine)
            let executableEvidence = try command("/usr/sbin/lsof", ["-p", "\(masterPID)", "-a", "-d", "txt", "-Fn"])
            XCTAssertTrue(executableEvidence.split(separator: "\n").contains(Substring("n\(installed.fpmPath)")), executableEvidence)
            let workers = childPIDs(of: masterPID)
            XCTAssertFalse(workers.isEmpty, "cycle \(cycle): FPM master should have a worker")
            print("PHP-FPM cycle \(cycle) started: master=\(masterPID), workers=\(workers), socket=\(normalSocket.path) exists=\(isUnixSocket(normalSocket.path)), status=\(started.state.rawValue)/\(started.health)")
            XCTAssertEqual(try module.status(requestedVersion: "8.4.23").state, .running)
            XCTAssertEqual(try module.status(requestedVersion: "8.4.23").health, "healthy")

            let stopped = try module.stop(requestedVersion: "8.4.23")
            XCTAssertEqual(stopped.state, .stopped)
            XCTAssertNil(stopped.pid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: normalSocket.path), "cycle \(cycle): owned socket remains")
            XCTAssertFalse(isUnixSocket(normalSocket.path))
            XCTAssertProcessGone(masterPID)
            for worker in workers { XCTAssertProcessGone(worker) }
            XCTAssertEqual(try module.status(requestedVersion: "8.4.23").state, .stopped)
            XCTAssertTrue(external.isRunning, "unrelated same-binary FPM master must remain live")
            XCTAssertTrue(isUnixSocket(externalSocket.path), "unrelated socket must remain intact")
            for worker in externalWorkerPIDs { XCTAssertEqual(kill(worker, 0), 0, "unrelated worker must remain") }
            print("PHP-FPM cycle \(cycle) stopped: masterAlive=\(kill(masterPID, 0) == 0), workersAlive=\(workers.map { kill($0, 0) == 0 }), socketExists=\(FileManager.default.fileExists(atPath: normalSocket.path)), unrelatedMasterAlive=\(external.isRunning), unrelatedSocketExists=\(isUnixSocket(externalSocket.path))")
        }

        let mismatchStart = try module.start(requestedVersion: "8.4.23")
        let mismatchPID = try XCTUnwrap(mismatchStart.pid)
        let recordURL = isolatedRecord
        let originalRecord = try Data(contentsOf: recordURL)
        var mismatchedRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: originalRecord) as? [String: Any])
        mismatchedRecord["executable"] = "/not/the/launched/php-fpm"
        try JSONSerialization.data(withJSONObject: mismatchedRecord).write(to: recordURL, options: .atomic)
        XCTAssertEqual(try module.stop(requestedVersion: "8.4.23").state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path), "stale Vaelen bookkeeping should not block cleanup")
        XCTAssertTrue(moduleProcessIsLive(mismatchPID), "identity mismatch must not signal the live FPM master")
        XCTAssertTrue(isUnixSocket(managedSocket.path), "identity mismatch must not remove the owned socket")
        recordToRestoreAfterIdentityTest = originalRecord
        try originalRecord.write(to: recordURL, options: .atomic)
        recordToRestoreAfterIdentityTest = nil
        XCTAssertEqual(try module.stop(requestedVersion: "8.4.23").state, .stopped)
        XCTAssertFalse(moduleProcessIsLive(mismatchPID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedSocket.path))
        XCTAssertTrue(external.isRunning, "unrelated FPM must still be running after mismatch recovery")

        let restartStart = try module.start(requestedVersion: "8.4.23")
        let restartPID = try XCTUnwrap(restartStart.pid)
        let relaunchedCore = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: manifestURL))
        XCTAssertEqual(try relaunchedCore.stop(requestedVersion: "8.4.23").state, .stopped)
        XCTAssertProcessGone(restartPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedSocket.path))
        XCTAssertTrue(external.isRunning, "Core restart cleanup must leave unrelated FPM untouched")
    }

    private func createFileIfNeeded(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        return url
    }

    private func waitForSocket(_ path: String) throws {
        for _ in 0..<100 { if isUnixSocket(path) { return }; usleep(20_000) }
        throw NSError(domain: "PHPFPMRuntimeLifecycleTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "PHP-FPM did not create isolated socket at \(path)"])
    }

    private func childPIDs(of parent: Int32) -> [Int32] {
        guard let output = try? command("/bin/ps", ["-axo", "pid=,ppid="]) else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap { row in
            let fields = row.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, Int32(fields[1]) == parent else { return nil }
            return Int32(fields[0])
        }
    }

    private func processTreePIDsForFPMConfig(_ configPath: String) -> Set<Int32> {
        guard let output = try? command("/bin/ps", ["-axo", "pid=,ppid=,command="]) else { return [] }
        let rows = output.split(whereSeparator: \.isNewline).compactMap { row -> (Int32, Int32, String)? in
            let fields = row.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return (pid, parent, String(fields[2]))
        }
        var tree = Set(rows.filter { $0.2.contains("php-fpm: master process") && $0.2.contains(configPath) }.map(\.0))
        var changed = true
        while changed {
            changed = false
            for (pid, parent, _) in rows where tree.contains(parent) && !tree.contains(pid) {
                tree.insert(pid); changed = true
            }
        }
        return tree
    }

    private func isUnixSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private func unixSocketIdentity(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_uid)"
    }

    private func moduleProcessIsLive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func XCTAssertProcessGone(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<50 { if kill(pid, 0) != 0 { XCTAssertNotEqual(errno, EPERM, file: file, line: line); return }; usleep(20_000) }
        XCTFail("process \(pid) remained live", file: file, line: line)
    }

    private func cleanup(_ process: Process, socket: String, knownWorkers: [Int32]) -> Bool {
        let pid = process.processIdentifier
        let executable = process.executableURL?.standardizedFileURL.path
        guard let executable else { XCTFail("External PHP-FPM test child lost its executable identity"); return false }
        let socketBefore = unixSocketIdentity(socket)
        let allWorkers = Set(knownWorkers + childPIDs(of: pid))
        if process.isRunning {
            let commandLine = (try? command("/bin/ps", ["-p", "\(pid)", "-o", "command="])) ?? ""
            let executableEvidence = (try? command("/usr/sbin/lsof", ["-p", "\(pid)", "-a", "-d", "txt", "-Fn"])) ?? ""
            guard commandLine.contains("php-fpm: master process"),
                  let config = process.arguments?.dropFirst().first,
                  commandLine.contains(config),
                  executableEvidence.split(separator: "\n").contains(Substring("n\(executable)")) else {
                XCTFail("Refusing to signal test FPM child after its launch identity no longer matches")
                return false
            }
            _ = kill(pid, SIGQUIT) // PHP-FPM's graceful stop; the Process handle and identity above belong to this test.
        }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        guard !process.isRunning else { XCTFail("External PHP-FPM did not gracefully exit"); return false }
        process.waitUntilExit()
        for worker in allWorkers {
            let workerDeadline = Date().addingTimeInterval(2)
            while moduleProcessIsLive(worker), Date() < workerDeadline { usleep(25_000) }
            guard !moduleProcessIsLive(worker) else { XCTFail("External PHP-FPM worker \(worker) remained after graceful master exit"); return false }
        }
        if let socketBefore {
            guard let socketAfter = unixSocketIdentity(socket), socketAfter == socketBefore else {
                if FileManager.default.fileExists(atPath: socket) { XCTFail("External PHP-FPM socket identity changed during cleanup; leaving it untouched") }
                return !FileManager.default.fileExists(atPath: socket)
            }
            do { try FileManager.default.removeItem(atPath: socket) }
            catch { XCTFail("Could not remove verified isolated PHP-FPM socket: \(error)"); return false }
        }
        return !FileManager.default.fileExists(atPath: socket)
    }

    private func command(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "PHPFPMRuntimeLifecycleTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
