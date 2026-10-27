import XCTest
import Darwin
import VaelenCore

final class PostgreSQLServiceLifecycleTests: XCTestCase {
    func testCreateHealthStopReopenAndNonDestructiveRemove() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let module = fixture.module()
        let id = try fixture.id("primary")
        let record = try module.create(id: id, port: fixture.freePort())
        XCTAssertEqual(record.packageIdentifier, "postgresql-18.6")
        XCTAssertEqual(try module.status(id: id).health, "stopped")
        try module.start(id: id)
        let running = try module.status(id: id)
        XCTAssertEqual(running.health, "healthy")
        XCTAssertTrue(running.queryOutput?.contains("1") == true)
        XCTAssertTrue(running.queryOutput?.contains("18.6") == true)
        XCTAssertTrue(running.queryOutput?.contains(record.dataDirectory) == true)
        let restartedCoreObservation = fixture.module(reopened: true)
        XCTAssertEqual(try restartedCoreObservation.status(id: id).health, "healthy")
        XCTAssertEqual(try restartedCoreObservation.status(id: id).pid, running.pid)
        let data = try Data(contentsOf: URL(fileURLWithPath: record.dataDirectory).appendingPathComponent("PG_VERSION"))
        try restartedCoreObservation.stop(id: id)
        XCTAssertEqual(try module.status(id: id).health, "stopped")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record.dataDirectory).appendingPathComponent("PG_VERSION")), data)
        let reopened = fixture.module(reopened: true)
        XCTAssertEqual(try reopened.status(id: id).health, "stopped")
        try reopened.start(id: id)
        XCTAssertEqual(try reopened.status(id: id).health, "healthy")
        try reopened.stop(id: id)
        try module.remove(id: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.dataDirectory))
    }

    func testNonemptyInitializationDirectoryIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let module = fixture.module()
        let id = try fixture.id("partial")
        let directory = fixture.layout.postgresqlInstancesDirectoryURL.appendingPathComponent(id.name.value, isDirectory: true).appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("keep")
        try Data("preserve".utf8).write(to: marker)
        XCTAssertThrowsError(try module.create(id: id, port: fixture.freePort()))
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
    }

    func testFailedManualClaimInsertRollsBackNewInstance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.store.execute("CREATE TRIGGER reject_manual_claim BEFORE INSERT ON manual_service_claims BEGIN SELECT RAISE(ABORT, 'claim rejected'); END")
        let id = try fixture.id("atomic")
        XCTAssertThrowsError(try fixture.module().create(id: id, port: fixture.freePort()))
        XCTAssertNil(try fixture.repository.instance(id))
        XCTAssertFalse(try fixture.repository.isManuallyClaimed(id))
    }

    func testPortConflictDoesNotDisturbUnrelatedListener() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let module = fixture.module()
        let id = try fixture.id("conflict")
        let port = try PostgreSQLServiceModule.availableLoopbackPort()
        _ = try module.create(id: id, port: port)
        let listener = try LoopbackListener(port: port)
        defer { listener.close() }
        XCTAssertThrowsError(try module.start(id: id)) { error in
            XCTAssertEqual(error as? PostgreSQLServiceError, .portConflict(port))
        }
        XCTAssertTrue(listener.isStillListening)
        XCTAssertEqual(try module.status(id: id).health, "stopped")
    }

    func testIdentityMismatchDoesNotSignalUnrelatedProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let module = fixture.module()
        let id = try fixture.id("identity")
        _ = try module.create(id: id, port: fixture.freePort())
        try module.start(id: id)
        let evidenceURL = fixture.layout.rootURL.appendingPathComponent("runtime/postgresql/identity/process.json")
        let originalEvidence = try Data(contentsOf: evidenceURL)
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["60"]; try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        let fake = ["pid": unrelated.processIdentifier, "startedAt": "not-the-recorded-start", "executable": "/bin/sleep", "command": "/bin/sleep 60", "dataDirectory": id.name.value, "port": 1, "psqlPath": "/bin/false"] as [String: Any]
        try JSONSerialization.data(withJSONObject: fake).write(to: evidenceURL, options: .atomic)
        let tampered = try Data(contentsOf: evidenceURL)
        XCTAssertThrowsError(try module.stop(id: id))
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertEqual(try Data(contentsOf: evidenceURL), tampered)
        try originalEvidence.write(to: evidenceURL, options: .atomic)
        try module.stop(id: id)
    }

    func testFailedGracefulShutdownPreservesEvidenceAndData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let module = fixture.module(shutdownTimeout: 0)
        let id = try fixture.id("shutdown")
        let record = try module.create(id: id, port: fixture.freePort())
        try module.start(id: id)
        let evidenceURL = fixture.layout.rootURL.appendingPathComponent("runtime/postgresql/shutdown/process.json")
        let evidence = try Data(contentsOf: evidenceURL)
        let dataPath = URL(fileURLWithPath: record.dataDirectory).appendingPathComponent("PG_VERSION")
        let data = try Data(contentsOf: dataPath)
        XCTAssertThrowsError(try module.stop(id: id))
        XCTAssertEqual(try Data(contentsOf: evidenceURL), evidence)
        XCTAssertEqual(try Data(contentsOf: dataPath), data)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (try? module.status(id: id).health) != "stopped" { usleep(50_000) }
        XCTAssertEqual(try module.status(id: id).health, "stopped")
    }

    func testRemoveRefusesRunningInstanceAndReleasesManualClaimWithoutDeletingData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let module = fixture.module()
        let id = try fixture.id("owned")
        _ = try module.create(id: id, port: fixture.freePort())
        try module.start(id: id)
        XCTAssertThrowsError(try module.remove(id: id))
        try module.stop(id: id)
        try module.remove(id: id)
        XCTAssertFalse(try fixture.repository.isManuallyClaimed(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.layout.postgresqlInstancesDirectoryURL.appendingPathComponent(id.name.value).appendingPathComponent("data").path))
    }

    func testRemoveRefusesProjectClaimAndKeepsClaimsAndData() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let module = fixture.module()
        let id = try fixture.id("shared")
        let record = try module.create(id: id, port: fixture.freePort())
        let projectDirectory = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: fixture.layout.databaseURL))
        guard let projectID = try await registry.link(path: projectDirectory).id else { return XCTFail("linked project lacks an id") }
        let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("database"), kind: .postgresql, instance: id.name)
        try fixture.repository.replaceProjectClaims([binding], for: projectID)
        XCTAssertThrowsError(try module.remove(id: id))
        XCTAssertTrue(try fixture.repository.isManuallyClaimed(id))
        XCTAssertEqual(try fixture.repository.instance(id), record)
        try fixture.repository.replaceProjectClaims([], for: projectID)
        try module.remove(id: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.dataDirectory))
    }

    private struct Fixture {
        let root: URL
        let layout: VaelenFilesystemLayout
        let repository: ServiceInstanceRepository
        let store: SQLiteStateStore
        let packageRoot: URL
        init() throws {
            guard let packagePath = ProcessInfo.processInfo.environment["VAELEN_TEST_POSTGRESQL_PACKAGE_ROOT"] else {
                throw XCTSkip("PostgreSQL package prerequisite unavailable; set VAELEN_TEST_POSTGRESQL_PACKAGE_ROOT to postgresql-18.6")
            }
            packageRoot = URL(fileURLWithPath: packagePath, isDirectory: true)
            guard !packagePath.isEmpty, FileManager.default.fileExists(atPath: packageRoot.path) else {
                throw NSError(domain: "PostgreSQL test fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid VAELEN_TEST_POSTGRESQL_PACKAGE_ROOT: \(packagePath)"])
            }
            root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-pg-test-\(UUID().uuidString)", isDirectory: true)
            layout = VaelenFilesystemLayout(rootURL: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try SQLiteStateStore(databaseURL: layout.databaseURL)
            repository = ServiceInstanceRepository(store: store)
        }
        func module(reopened: Bool = false, shutdownTimeout: TimeInterval = 10) -> PostgreSQLServiceModule {
            let selectedRepository = reopened ? ServiceInstanceRepository(store: try! SQLiteStateStore(databaseURL: layout.databaseURL)) : repository
            return PostgreSQLServiceModule(layout: layout, repository: selectedRepository, packageRoot: packageRoot, shutdownTimeout: shutdownTimeout)
        }
        func id(_ name: String) throws -> ServiceInstanceID { ServiceInstanceID(kind: .postgresql, name: try ProjectInstanceName(name)) }
        func freePort() throws -> Int { try PostgreSQLServiceModule.availableLoopbackPort() }
        func remove() {
            let manager = FileManager.default
            do {
                let instances = layout.postgresqlInstancesDirectoryURL
                let names = manager.fileExists(atPath: instances.path) ? try manager.contentsOfDirectory(atPath: instances.path) : []
                for name in names {
                    let instance = try id(name)
                    let service = module()
                    let health = try service.status(id: instance).health
                    if health != "stopped" && health != "not-created" {
                        try service.stop(id: instance)
                    }
                    let stopped = try service.status(id: instance).health
                    let pidFile = instances.appendingPathComponent(name).appendingPathComponent("data/postmaster.pid")
                    let evidence = layout.rootURL.appendingPathComponent("runtime/postgresql/\(name)/process.json")
                    guard (stopped == "stopped" || stopped == "not-created"),
                          !manager.fileExists(atPath: pidFile.path), !manager.fileExists(atPath: evidence.path) else {
                        throw NSError(domain: "PostgreSQL test fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Shutdown could not be confirmed for \(name)"])
                    }
                }
                try manager.removeItem(at: root)
            } catch {
                XCTFail("PostgreSQL fixture retained at \(root.path): \(error)")
            }
        }
    }

    private struct LoopbackListener {
        let descriptor: Int32
        init(port: Int) throws {
            descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw NSError(domain: "listener", code: 1) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian); address.sin_port = in_port_t(port).bigEndian
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, listen(descriptor, 4) == 0 else { Darwin.close(descriptor); throw NSError(domain: "listener", code: 2) }
        }
        var isStillListening: Bool {
            var address = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            return withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } } == 0
        }
        func close() { Darwin.close(descriptor) }
    }
}
