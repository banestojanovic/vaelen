import Foundation
import Darwin
import XCTest
@testable import VaelenCore
import VaelenIPC
import VaelenDaemonSupport

private struct RecoveryDNSHelper: PrivilegedDNSHelper {
    func inspectTestResolver() async throws -> ResolverInspection { ResolverInspection(exists: false, content: nil, ownership: .none) }
    func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot { throw DNSCapabilityError.privilegeUnavailable }
    func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws { throw DNSCapabilityError.privilegeUnavailable }
}

private struct RecoveryDNSResponder: DNSResponderControlling {
    func validateExecutable() async throws {}
    func status() async -> DNSResponderStatus { DNSResponderStatus(state: .stopped) }
    func start() async throws -> DNSResponderIdentity { throw DNSCapabilityError.processFailed("recovery fixture responder is disabled") }
    func stop(expected: DNSResponderIdentity, timeout: TimeInterval) async throws -> DNSResponderStatus { DNSResponderStatus(state: .stopped) }
}

final class CoreProjectServiceRestartRecoveryEndToEndTests: XCTestCase {
    private enum Runtime {
        case mysql(MySQLModule)
        case postgresql(PostgreSQLServiceModule, ServiceInstanceID)
        case valkey(ValkeyServiceModule, ServiceInstanceID)

        func record() throws -> ServiceInstanceRecord {
            switch self {
            case .mysql(let module):
                guard let record = module.projectBindingSnapshot().record else { throw FixtureError.missingRecord }
                return record
            case .postgresql(let module, let id):
                return try XCTUnwrap(try module.status(id: id).record)
            case .valkey(let module, let id):
                return try XCTUnwrap(try module.status(id: id).record)
            }
        }

        func health() throws -> (String, Int32?) {
            switch self {
            case .mysql(let module):
                let status = module.status()
                return (status.health, status.pid)
            case .postgresql(let module, let id):
                let status = try module.status(id: id)
                return (status.health, status.pid)
            case .valkey(let module, let id):
                let status = try module.status(id: id)
                return (status.health, status.pid)
            }
        }

        func start() throws {
            switch self {
            case .mysql(let module): _ = try module.start()
            case .postgresql(let module, let id): try module.start(id: id)
            case .valkey(let module, let id): try module.start(id: id)
            }
        }

        func stop() throws {
            switch self {
            case .mysql(let module): _ = try module.stop()
            case .postgresql(let module, let id): try module.stop(id: id)
            case .valkey(let module, let id): try module.stop(id: id)
            }
        }

        func dispatcher(layout: VaelenFilesystemLayout, store: SQLiteStateStore, repository: ServiceInstanceRepository, intents: ServiceIntentStore) throws -> CoreRequestDispatcher {
            let dns = DNSCapability(layout: layout, helper: RecoveryDNSHelper(), responder: RecoveryDNSResponder(), port: 49_173)
            let paths = StandardPortsPaths(anchorPath: layout.rootURL.appendingPathComponent("pf/anchor").path, pfConfPath: layout.rootURL.appendingPathComponent("pf/pf.conf").path)
            let ports = StandardPortsCapability(privileged: UnavailableStandardPortsPrivileged(paths: paths), paths: paths, portOccupied: { _ in false }, backendHealthy: { false })
            switch self {
            case .mysql(let module):
                return try CoreRequestDispatcher(runtime: .init(version: "test", pid: getpid()), registry: ProjectRegistry(store: store), mysql: module, dns: dns, ports: ports, serviceIntents: intents, serviceInstances: repository, logs: CoreLogCatalog(layout: layout))
            case .postgresql(let module, _):
                return try CoreRequestDispatcher(runtime: .init(version: "test", pid: getpid()), registry: ProjectRegistry(store: store), postgresql: module, dns: dns, ports: ports, serviceIntents: intents, serviceInstances: repository, logs: CoreLogCatalog(layout: layout))
            case .valkey(let module, _):
                return try CoreRequestDispatcher(runtime: .init(version: "test", pid: getpid()), registry: ProjectRegistry(store: store), valkey: module, dns: dns, ports: ports, serviceIntents: intents, serviceInstances: repository, logs: CoreLogCatalog(layout: layout))
            }
        }
    }

    private enum FixtureError: Error {
        case missingRecord
        case packageUnavailable
        case runtimeDidNotStop
        case rootDidNotDelete
        case processDidNotExit(Int32)
        case assertionsFailed(String)
    }

    func testFreshCoreRecoversProjectClaimedMySQLFromReopenedSQLite() async throws {
        guard let installed = MySQLModule(layout: .init()).installedVersions().first(where: { $0.version == MySQLManifest.official8_4_11.version && $0.artifactSHA256 == MySQLManifest.official8_4_11.artifactSHA256 }) else { throw XCTSkip("Installed MySQL 8.4.11 is required; no package download or install is attempted.") }
        let port = try availablePort()
        try await exercise(kind: .mysql, packageIdentifier: "mysql-\(installed.version)", port: port) { layout, _ in
            Runtime.mysql(MySQLModule(layout: layout, manifest: .official8_4_11, port: port, instanceName: "default", tcpEnabled: true, packageOverride: installed))
        }
    }

    func testFreshCoreRecoversProjectClaimedPostgreSQLFromReopenedSQLite() async throws {
        guard let package = ProcessInfo.processInfo.environment["VAELEN_TEST_POSTGRESQL_PACKAGE_ROOT"] else { throw XCTSkip("Run the Core recovery acceptance script with the verified local PostgreSQL package.") }
        let port = try PostgreSQLServiceModule.availableLoopbackPort()
        try await exercise(kind: .postgresql, packageIdentifier: PostgreSQLServiceModule.packageIdentifier, port: port) { layout, repository in
            let id = ServiceInstanceID(kind: .postgresql, name: try ProjectInstanceName("primary"))
            let module = PostgreSQLServiceModule(layout: layout, repository: repository, packageRoot: URL(fileURLWithPath: package, isDirectory: true))
            _ = try module.create(id: id, port: port)
            return Runtime.postgresql(module, id)
        }
    }

    func testFreshCoreRecoversProjectClaimedValkeyFromReopenedSQLite() async throws {
        guard let package = ProcessInfo.processInfo.environment["VAELEN_TEST_VALKEY_PACKAGE_ROOT"] else { throw XCTSkip("Run the Core recovery acceptance script with the verified local Valkey package.") }
        let port = try ValkeyServiceModule.availableLoopbackPort()
        try await exercise(kind: .valkey, packageIdentifier: ValkeyServiceModule.packageIdentifier, port: port) { layout, repository in
            let id = ServiceInstanceID(kind: .valkey, name: try ProjectInstanceName("primary"))
            let module = ValkeyServiceModule(layout: layout, repository: repository, packageRoot: URL(fileURLWithPath: package, isDirectory: true))
            _ = try module.create(id: id, port: port)
            return Runtime.valkey(module, id)
        }
    }

    private func exercise(kind: ProjectServiceKind, packageIdentifier: String, port: Int, makeRuntime: (VaelenFilesystemLayout, ServiceInstanceRepository) throws -> Runtime) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/vcore-restart-\(UUID().uuidString)", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        try FileManager.default.createDirectory(at: layout.stateDirectoryURL, withIntermediateDirectories: true)
        let database = layout.databaseURL
        let instanceName = try ProjectInstanceName(kind == .mysql ? "default" : "primary")
        let id = ServiceInstanceID(kind: kind, name: instanceName)
        let project = LinkedProjectRecord(id: ProjectID(), name: "restart-fixture", canonicalPath: root.appendingPathComponent("project", isDirectory: true).path)
        let binding = try ProjectServiceBinding(alias: ProjectBindingAlias("service"), kind: kind, instance: instanceName, version: packageIdentifier)
        var preserveRoot = false
        defer { if !preserveRoot { try? FileManager.default.removeItem(at: root) } }
        do {
            let first = try await firstCoreScope(layout: layout, database: database, project: project, binding: binding, id: id, packageIdentifier: packageIdentifier, port: port, makeRuntime: makeRuntime)
            try ensureAssertionsPassed(after: "first Core scope")
            let restarted = try await reopenedCoreScope(layout: layout, database: database, project: project, binding: binding, id: id, packageIdentifier: packageIdentifier, port: port, makeRuntime: makeRuntime)
            try ensureAssertionsPassed(after: "reopened Core scope")
            XCTAssertEqual(restarted.record, first.record)
            XCTAssertEqual(restarted.record.id, id)
            XCTAssertEqual(restarted.record.packageIdentifier, packageIdentifier)
            XCTAssertEqual(restarted.record.endpoint.portNumbers.first, port)
            XCTAssertEqual(restarted.health, "healthy")
            XCTAssertNotNil(restarted.pid)
            XCTAssertNotEqual(restarted.pid, first.pid)
            XCTAssertEqual(restarted.claims, [binding])
            XCTAssertFalse(restarted.intents.contains("mysql"), "project-claimed MySQL recovery must not enable global MySQL intent")
            try ensureAssertionsPassed(after: "recovery assertions")
            try confirmStopped(restarted.runtime, pid: restarted.pid)
            try ensureAssertionsPassed(after: "runtime shutdown")
            try FileManager.default.removeItem(at: root)
            guard !FileManager.default.fileExists(atPath: root.path) else { throw FixtureError.rootDidNotDelete }
            preserveRoot = true
            let line = "CORE_PROJECT_SERVICE_RESTART kind=\(kind.rawValue) package=\(packageIdentifier) previousPID=\(first.pid) recoveredPID=\(restarted.pid ?? -1) port=\(port) health=healthy claims=1 globalMySQLIntent=off cleanup=confirmed stoppedPID=\(restarted.pid ?? -1)"
            print(line)
            if let path = ProcessInfo.processInfo.environment["VAELEN_SERVICE_RECOVERY_EVIDENCE"] {
                try Data((line + "\n").utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("\(kind.rawValue).record"), options: .atomic)
            }
        } catch {
            preserveRoot = true
            throw NSError(domain: "CoreProjectServiceRestartRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture root preserved at \(root.path): \(error)"])
        }
    }

    private func firstCoreScope(layout: VaelenFilesystemLayout, database: URL, project: LinkedProjectRecord, binding: ProjectServiceBinding, id: ServiceInstanceID, packageIdentifier: String, port: Int, makeRuntime: (VaelenFilesystemLayout, ServiceInstanceRepository) throws -> Runtime) async throws -> (record: ServiceInstanceRecord, pid: Int32) {
        let store = try SQLiteStateStore(databaseURL: database)
        let repository = ServiceInstanceRepository(store: store)
        let runtime = try makeRuntime(layout, repository)
        defer {
            if let status = try? runtime.health(), status.0 != "stopped" {
                try? confirmStopped(runtime, pid: status.1)
            }
        }
        if case .mysql(let module) = runtime { try module.initialize() }
        let record = try runtime.record()
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.packageIdentifier, packageIdentifier)
        XCTAssertEqual(record.endpoint.portNumbers.first, port)
        try ProjectRepository(store: store).upsert(project)
        try repository.replaceProjectClaims([binding], materializing: [record], for: project.id)
        let intents = ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json"))
        let dispatcher = try runtime.dispatcher(layout: layout, store: store, repository: repository, intents: intents)
        await dispatcher.restoreServicesOnStartup()
        let barrier = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        guard case .status = barrier.response.result else { throw FixtureError.missingRecord }
        let healthy = try runtime.health()
        XCTAssertEqual(healthy.0, "healthy")
        let previousPID = try XCTUnwrap(healthy.1)
        try confirmStopped(runtime, pid: previousPID)
        let shutdown = await dispatcher.shutdownForParentExit()
        XCTAssertTrue(shutdown.completed)
        XCTAssertTrue(shutdown.components.allSatisfy(\.succeeded))
        return (record, previousPID)
    }

    private func ensureAssertionsPassed(after scope: String) throws {
        if (testRun?.failureCount ?? 0) > 0 { throw FixtureError.assertionsFailed(scope) }
    }

    private func reopenedCoreScope(layout: VaelenFilesystemLayout, database: URL, project: LinkedProjectRecord, binding: ProjectServiceBinding, id: ServiceInstanceID, packageIdentifier: String, port: Int, makeRuntime: (VaelenFilesystemLayout, ServiceInstanceRepository) throws -> Runtime) async throws -> (record: ServiceInstanceRecord, claims: [ProjectServiceBinding], health: String, pid: Int32?, intents: Set<String>, runtime: Runtime) {
        let store = try SQLiteStateStore(databaseURL: database)
        let repository = ServiceInstanceRepository(store: store)
        let runtime = try makeRuntime(layout, repository)
        defer {
            if let status = try? runtime.health(), status.0 != "stopped" {
                try? confirmStopped(runtime, pid: status.1)
            }
        }
        let before = try XCTUnwrap(repository.instance(id))
        XCTAssertEqual(before.packageIdentifier, packageIdentifier)
        XCTAssertEqual(before.endpoint.portNumbers.first, port)
        XCTAssertEqual(try repository.projectClaims(for: project.id), [binding])
        let intents = ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json"))
        let dispatcher = try runtime.dispatcher(layout: layout, store: store, repository: repository, intents: intents)
        await dispatcher.restoreServicesOnStartup()
        let barrier = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        guard case .status = barrier.response.result else { throw FixtureError.missingRecord }
        let observed = try runtime.health()
        XCTAssertEqual(try repository.instance(id), before)
        XCTAssertEqual(try repository.projectClaims(for: project.id), [binding])
        let shutdown = await dispatcher.shutdownForParentExit()
        XCTAssertTrue(shutdown.completed)
        XCTAssertTrue(shutdown.components.allSatisfy(\.succeeded))
        return (before, try repository.projectClaims(for: project.id), observed.0, observed.1, try intents.enabledServices(), runtime)
    }

    private func confirmStopped(_ runtime: Runtime, pid: Int32?) throws {
        try runtime.stop()
        guard try runtime.health().0 == "stopped" else { throw FixtureError.runtimeDidNotStop }
        if let pid {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if kill(pid, 0) == -1 && errno == ESRCH { return }
                usleep(50_000)
            }
            throw FixtureError.processDidNotExit(pid)
        }
    }

    private func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.packageUnavailable }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw FixtureError.packageUnavailable }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &actual, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { throw FixtureError.packageUnavailable }
        return Int(UInt16(bigEndian: actual.sin_port))
    }
}
