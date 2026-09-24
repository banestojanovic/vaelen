import XCTest
import Darwin
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

private final class DispatcherTrustFake: @unchecked Sendable, TLSTrustBoundary {
    var trusted = false
    func observe(certificateData: Data) throws -> LocalCATrustService.Observation {
        trusted ? .init(trusted: true, canonical: "trust:empty-array", fingerprint: "empty-fingerprint") : .init(trusted: false, canonical: "trust:nil", fingerprint: nil)
    }
    func trust(certificateData: Data) throws { trusted = true }
    func removeTrust(certificateData: Data) throws { trusted = false }
}

private actor ShutdownTestRouter: Router {
    private var running = false
    private var stopFailures = 0
    private var starts = 0
    init(stopFailures: Int = 0) { self.stopFailures = stopFailures }
    func start() async throws { starts += 1; running = true }
    func stop() async throws {
        if stopFailures > 0 { stopFailures -= 1; throw RouterError.notRunning }
        running = false
    }
    func status() async -> RouterStatus { .init(provider: "shutdown-test", state: running ? .running : .stopped, health: running ? .healthy : .unknown, routeCount: 0) }
    func health() async -> RouterHealth { running ? .healthy : .unhealthy }
    func reconcile(routes: [Route]) async throws {}
    func addRoute(_ route: Route) async throws {}
    func updateRoute(_ route: Route) async throws {}
    func removeRoute(id: RouteID) async throws {}
    func observedRoutes() async throws -> [Route] { [] }
    func startCount() -> Int { starts }
}

private actor BlockedRestoreRouter: Router {
    private var attempts = 0
    private var running = false
    func start() async throws { attempts += 1; if attempts == 1 { try await Task.sleep(for: .milliseconds(250)); throw RouterError.notRunning }; running = true }
    func stop() async throws { running = false }
    func status() async -> RouterStatus { .init(provider: "blocked-restore", state: running ? .running : .stopped, health: running ? .healthy : .unknown, routeCount: 0) }
    func health() async -> RouterHealth { running ? .healthy : .unhealthy }
    func reconcile(routes: [Route]) async throws {}
    func addRoute(_ route: Route) async throws {}
    func updateRoute(_ route: Route) async throws {}
    func removeRoute(id: RouteID) async throws {}
    func observedRoutes() async throws -> [Route] { [] }
    func attemptCount() -> Int { attempts }
}

private struct ShutdownPortsFake: StandardPortsPrivileged {
    let inspection: StandardPortsInspection
    let removals: ShutdownRemovalCounter
    func inspectForwarding() async throws -> StandardPortsInspection {
        await removals.count() > 0 ? .init(anchorContent: nil, pfConfContent: "# original PF fixture\n") : inspection
    }
    func installForwarding() async throws -> StandardPortsAcquisition { throw StandardPortsPrivilegeError.unavailable }
    func removeForwarding(acquisition: StandardPortsAcquisition) async throws { await removals.increment() }
}

private struct BlockedShutdownPortsFake: StandardPortsPrivileged {
    func inspectForwarding() async throws -> StandardPortsInspection { .init(anchorContent: nil, pfConfContent: "# isolated PF fixture\n") }
    func installForwarding() async throws -> StandardPortsAcquisition { throw StandardPortsPrivilegeError.unavailable }
    func removeForwarding(acquisition: StandardPortsAcquisition) async throws {}
}

private actor ShutdownRemovalCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

private struct ShutdownTestDNSHelper: PrivilegedDNSHelper {
    let path: String
    func inspectTestResolver() async throws -> ResolverInspection {
        let snapshot = try ResolverFileSnapshot.read(path)
        return .init(exists: snapshot.exists, content: snapshot.bytes.map { String(decoding: $0, as: UTF8.self) }, ownership: snapshot.exists ? .unknown : .none, snapshot: snapshot)
    }
    func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot { throw DNSCapabilityError.privilegeUnavailable }
    func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws { throw DNSCapabilityError.privilegeUnavailable }
}

private actor ShutdownTestResponder: DNSResponderControlling {
    private var running = false
    private var stops = 0
    private let identity = DNSResponderIdentity(pid: 4242, executablePath: "/fixture/vaelendns", arguments: ["--port", "49173"], startedAt: "fixture")
    func status() async -> DNSResponderStatus { .init(state: running ? .ownedRunning : .stopped, pid: running ? identity.pid : nil, listenerResponding: running, listenerPresent: running, identity: running ? identity : nil) }
    func start() async throws -> DNSResponderIdentity { running = true; return identity }
    func stop(expected: DNSResponderIdentity, timeout: TimeInterval) async throws -> DNSResponderStatus { guard expected == identity else { throw DNSCapabilityError.responderUnverified("identity mismatch") }; stops += 1; running = false; return .init(state: .exited, pid: identity.pid, identity: identity) }
    func stopCount() -> Int { stops }
}

private struct MutableShutdownDNSHelper: PrivilegedDNSHelper {
    let path: String
    func inspectTestResolver() async throws -> ResolverInspection {
        let snapshot = try ResolverFileSnapshot.read(path)
        return .init(exists: snapshot.exists, content: snapshot.bytes.map { String(decoding: $0, as: UTF8.self) }, ownership: snapshot.exists ? .unknown : .none, snapshot: snapshot)
    }
    func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot {
        guard try ResolverFileSnapshot.read(path) == replacing else { throw DNSCapabilityError.ownershipMismatch }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("nameserver 127.0.0.1\nport \(port)\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return try ResolverFileSnapshot.read(path)
    }
    func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws {
        guard try ResolverFileSnapshot.read(path) == expected else { throw DNSCapabilityError.ownershipMismatch }
        if restore.exists, let bytes = restore.bytes { try bytes.write(to: URL(fileURLWithPath: path), options: .atomic) }
        else { try FileManager.default.removeItem(atPath: path) }
    }
}

private actor StartupRaceDNSHelper: PrivilegedDNSHelper {
    let path: String
    private var inspections = 0
    private var acquisitions = 0
    init(path: String) { self.path = path }
    func inspectCount() -> Int { inspections }
    func acquisitionCount() -> Int { acquisitions }
    func inspectTestResolver() async throws -> ResolverInspection {
        inspections += 1
        try await Task.sleep(for: .milliseconds(100))
        let snapshot = try ResolverFileSnapshot.read(path)
        return .init(exists: snapshot.exists, content: snapshot.bytes.map { String(decoding: $0, as: UTF8.self) }, ownership: snapshot.exists ? .unknown : .none, snapshot: snapshot)
    }
    func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot {
        acquisitions += 1
        guard try ResolverFileSnapshot.read(path) == replacing else { throw DNSCapabilityError.ownershipMismatch }
        try Data("nameserver 127.0.0.1\nport \(port)\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return try ResolverFileSnapshot.read(path)
    }
    func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws {
        guard try ResolverFileSnapshot.read(path) == expected else { throw DNSCapabilityError.ownershipMismatch }
        if restore.exists, let bytes = restore.bytes { try bytes.write(to: URL(fileURLWithPath: path), options: .atomic) }
        else { try FileManager.default.removeItem(atPath: path) }
    }
}

final class DispatcherTests: XCTestCase {
    func testCoreStatusWaitsForSavedDNSAutostartAndFirstSnapshotIsHealthy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("status-after-dns-autostart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = root.appendingPathComponent("resolver/test")
        try FileManager.default.createDirectory(at: resolver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nameserver 192.0.2.53\n".utf8).write(to: resolver)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let intents = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        try intents.set("dns", enabled: true)
        let responder = ShutdownTestResponder()
        let dns = DNSCapability(helper: StartupRaceDNSHelper(path: resolver.path), responder: responder, port: 49173, ledger: SystemModificationLedger(store: store))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: ProjectRegistry(store: store), dns: dns, serviceIntents: intents)

        await dispatcher.restoreServicesOnStartup()
        let began = Date()
        let coreReply = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        let elapsed = Date().timeIntervalSince(began)
        guard case .status(let coreStatus) = coreReply.response.result else { return XCTFail("expected Core status") }
        XCTAssertGreaterThanOrEqual(elapsed, 0.09, "bootstrap status must remain loading until the delayed saved DNS start settles")
        XCTAssertEqual(coreStatus.serviceIntents, ["dns"])
        XCTAssertNil(coreStatus.serviceIssues?["dns"])

        let dnsReply = await dispatcher.dispatch(IPCRequest(method: .dnsStatus), handshaken: true)
        guard case .dnsStatus(let dnsStatus) = dnsReply.response.result else { return XCTFail("expected authoritative DNS snapshot") }
        XCTAssertEqual(dnsStatus.dns.state, .installed)
        XCTAssertEqual(dnsStatus.dns.ownership, .vaelen)
        XCTAssertEqual(dnsStatus.dns.responderState, .ownedRunning)
        XCTAssertEqual(dnsStatus.dns.health, "healthy")
        XCTAssertEqual(try intents.failures()["dns"], nil)
    }

    func testSavedDNSOffRemainsOffAndFailedAutostartRemainsRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dns-off-and-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let offRoot = root.appendingPathComponent("off")
        try FileManager.default.createDirectory(at: offRoot, withIntermediateDirectories: true)
        let offStore = try SQLiteStateStore(databaseURL: offRoot.appendingPathComponent("state.sqlite"))
        let offIntents = ServiceIntentStore(url: offRoot.appendingPathComponent("service-intents.json"))
        let offResolver = offRoot.appendingPathComponent("resolver/test")
        let offDNS = DNSCapability(helper: ShutdownTestDNSHelper(path: offResolver.path), responder: ShutdownTestResponder(), ledger: SystemModificationLedger(store: offStore))
        let offDispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: ProjectRegistry(store: offStore), dns: offDNS, serviceIntents: offIntents)
        await offDispatcher.restoreServicesOnStartup()
        let offStatus = await offDispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        guard case .status(let offCore) = offStatus.response.result else { return XCTFail("expected OFF Core status") }
        XCTAssertFalse(offCore.serviceIntents?.contains("dns") ?? true)
        let offDNSReply = await offDispatcher.dispatch(IPCRequest(method: .dnsStatus), handshaken: true)
        guard case .dnsStatus(let offDNSStatus) = offDNSReply.response.result else { return XCTFail("expected OFF DNS status") }
        XCTAssertEqual(offDNSStatus.dns.state, .notInstalled)
        XCTAssertEqual(offDNSStatus.dns.responderState, .stopped)

        let failedRoot = root.appendingPathComponent("failed")
        try FileManager.default.createDirectory(at: failedRoot.appendingPathComponent("resolver"), withIntermediateDirectories: true)
        let failedResolver = failedRoot.appendingPathComponent("resolver/test")
        let failedStore = try SQLiteStateStore(databaseURL: failedRoot.appendingPathComponent("state.sqlite"))
        let failedIntents = ServiceIntentStore(url: failedRoot.appendingPathComponent("service-intents.json"))
        try failedIntents.set("dns", enabled: true)
        let failedDNS = DNSCapability(helper: ShutdownTestDNSHelper(path: failedResolver.path), responder: ShutdownTestResponder(), port: 49174, ledger: SystemModificationLedger(store: failedStore))
        let failedDispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: ProjectRegistry(store: failedStore), dns: failedDNS, serviceIntents: failedIntents)
        await failedDispatcher.restoreServicesOnStartup()
        let failedReply = await failedDispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        guard case .status(let failedStatus) = failedReply.response.result else { return XCTFail("expected failed-start status") }
        XCTAssertEqual(failedStatus.serviceIssues?["dns"], "macOS authorization for resolver changes is unavailable.")
    }

    func testSavedDNSAutostartAndConcurrentRetryAcquireOnceAndRecoverOnQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-dns-startup-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = root.appendingPathComponent("resolver/test")
        try FileManager.default.createDirectory(at: resolver.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preimage = Data("nameserver 192.0.2.53\nsearch local\n".utf8)
        try preimage.write(to: resolver)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let intents = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        try intents.set("dns", enabled: true)
        let helper = StartupRaceDNSHelper(path: resolver.path)
        let ledger = SystemModificationLedger(store: store)
        let dns = DNSCapability(helper: helper, responder: ShutdownTestResponder(), port: 49173, ledger: ledger)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: ProjectRegistry(store: store), dns: dns, serviceIntents: intents)

        await dispatcher.restoreServicesOnStartup()
        for _ in 0..<100 {
            if await helper.inspectCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let retry = Task { await dispatcher.dispatch(IPCRequest(method: .dnsInstall), handshaken: true) }
        let response = await retry.value
        XCTAssertNil(response.response.error)
        guard case .dnsStatus(let result) = response.response.result else { return XCTFail("saved startup/retry did not return DNS state") }
        XCTAssertEqual(result.dns.health, "healthy")
        let acquisitionCount = await helper.acquisitionCount()
        XCTAssertEqual(acquisitionCount, 1)

        let quit = await dispatcher.shutdownForParentExit()
        XCTAssertTrue(quit.completed)
        XCTAssertEqual(try Data(contentsOf: resolver), preimage)
        XCTAssertEqual(try ledger.resolverOwnershipRecord()?.phase, .resolverRestored)
        XCTAssertEqual(try ledger.dnsRecord()?.active, false)
        XCTAssertEqual(try intents.enabledServices(), ["dns"])
    }

    func testExplicitRouterIntentPersistsAcrossQuitAndStopClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-intent-dispatcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let intents = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        let registry = ProjectRegistry(store: store)
        let firstRouter = ShutdownTestRouter()
        let first = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, router: firstRouter, serviceIntents: intents)

        _ = await first.dispatch(IPCRequest(method: .routingStart), handshaken: true)
        XCTAssertEqual(try intents.enabledServices(), ["caddy"])
        let quit = await first.shutdownForParentExit()
        XCTAssertTrue(quit.completed)

        let relaunchedRouter = ShutdownTestRouter()
        let relaunched = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 2), registry: registry, router: relaunchedRouter, serviceIntents: ServiceIntentStore(url: root.appendingPathComponent("service-intents.json")))
        await relaunched.restoreServicesOnStartup()
        for _ in 0..<100 {
            if await relaunchedRouter.startCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restoredStarts = await relaunchedRouter.startCount()
        XCTAssertEqual(restoredStarts, 1)

        _ = await relaunched.dispatch(IPCRequest(method: .routingStop), handshaken: true)
        XCTAssertTrue(try intents.enabledServices().isEmpty)
        let stoppedRouter = ShutdownTestRouter()
        let stoppedLaunch = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 3), registry: registry, router: stoppedRouter, serviceIntents: intents)
        await stoppedLaunch.restoreServicesOnStartup()
        try await Task.sleep(for: .milliseconds(50))
        let stoppedStarts = await stoppedRouter.startCount()
        XCTAssertEqual(stoppedStarts, 0)
    }

    func testBlockedRestoreKeepsEnabledChoiceAndAttemptsOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-intent-blocked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let intentStore = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        try intentStore.set("caddy", enabled: true)
        let router = BlockedRestoreRouter()
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: ProjectRegistry(store: store), router: router, serviceIntents: intentStore)

        await dispatcher.restoreServicesOnStartup()
        let statusStartedAt = Date()
        let lightweightStatus = await dispatcher.dispatch(IPCRequest(method: .routingStatus), handshaken: true)
        XCTAssertLessThan(Date().timeIntervalSince(statusStartedAt), 0.2, "a blocked restore must not hold up status IPC")
        XCTAssertNil(lightweightStatus.response.error)
        for _ in 0..<100 {
            if await router.attemptCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            if !intentStore.failures().isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let attempts = await router.attemptCount()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(try intentStore.enabledServices(), ["caddy"])
        let observed = await router.status()
        XCTAssertEqual(observed.state, .stopped)
        let coreStatus = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        guard case .status(let status) = coreStatus.response.result else { return XCTFail("missing Core status") }
        XCTAssertEqual(status.serviceIssues?["caddy"], "notRunning")

        // The ordinary explicit Start remains a retry path after a block.
        let retry = await dispatcher.dispatch(IPCRequest(method: .routingStart), handshaken: true)
        XCTAssertNil(retry.response.error)
        let attemptsAfterRetry = await router.attemptCount()
        XCTAssertEqual(attemptsAfterRetry, 2)
    }

    func testInstalledPHPWithoutSavedStartChoiceStaysStoppedOnLaunch() async throws {
        let installedURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vaelen/packages/php/8.4.23/.vaelen-package.json")
        guard let data = try? Data(contentsOf: installedURL), let installed = try? JSONDecoder().decode(PHPPackage.self, from: data) else {
            throw XCTSkip("Installed managed PHP package prerequisite unavailable")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-intent-never-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support"), logsDirectoryURL: root.appendingPathComponent("logs"))
        let packageDirectory = layout.phpPackagesDirectoryURL.appendingPathComponent(installed.version)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let isolatedPackage = PHPPackage(version: installed.version, architecture: installed.architecture, packagePath: packageDirectory.path, cliPath: installed.cliPath, fpmPath: installed.fpmPath, source: installed.source, cliSHA256: installed.cliSHA256, fpmSHA256: installed.fpmSHA256, installedAt: installed.installedAt)
        try JSONEncoder().encode(isolatedPackage).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: installed.version, platform: "macos", architecture: installed.architecture, artifacts: [:], verification: .init(algorithm: "sha256", authenticity: "isolated-installed-runtime"))
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: manifestURL))
        let intents = ServiceIntentStore(url: root.appendingPathComponent("state/service-intents.json"))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: ProjectRegistry(store: SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))), php: module, serviceIntents: intents)

        XCTAssertTrue(try intents.enabledServices().isEmpty)
        await dispatcher.restoreServicesOnStartup()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try module.status(requestedVersion: installed.version).state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpInstancesDirectoryURL.appendingPathComponent("\(installed.version)/process.json").path))
        XCTAssertTrue(try intents.enabledServices().isEmpty)
    }

    func testSavedDNSBlockedByExternalResolverKeepsFileChoiceAndExposesReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-intent-dns-conflict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = root.appendingPathComponent("resolver/test")
        let herd = Data("# Herd resolver\nnameserver 127.0.0.1\nsearch test\n".utf8)
        try FileManager.default.createDirectory(at: resolver.deletingLastPathComponent(), withIntermediateDirectories: true)
        try herd.write(to: resolver)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let intents = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        try intents.set("dns", enabled: true)
        let dns = DNSCapability(helper: ShutdownTestDNSHelper(path: resolver.path), ledger: SystemModificationLedger(store: store))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: ProjectRegistry(store: store), dns: dns, serviceIntents: intents)

        await dispatcher.restoreServicesOnStartup()
        try await Task.sleep(for: .milliseconds(100))
        let response = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        guard case .status(let status) = response.response.result else { return XCTFail("missing Core status") }
        XCTAssertEqual(status.serviceIssues?["dns"], "DNS responder executable is unavailable")
        XCTAssertEqual(try Data(contentsOf: resolver), herd)
        XCTAssertEqual(try intents.enabledServices(), ["dns"])

        let quit = await dispatcher.shutdownForParentExit()
        XCTAssertTrue(quit.completed, "external resolver with no Vaelen ownership is a no-op: \(quit.components)")
        XCTAssertEqual(try Data(contentsOf: resolver), herd)
        XCTAssertEqual(try intents.enabledServices(), ["dns"])
    }

    func testSavedDNSBlockedByChangedOwnedPreimageReportsSpecificReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-intent-dns-preimage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = root.appendingPathComponent("resolver/test")
        try FileManager.default.createDirectory(at: resolver.deletingLastPathComponent(), withIntermediateDirectories: true)
        let baselineBytes = Data("# prior resolver\nnameserver 192.0.2.1\n".utf8)
        try baselineBytes.write(to: resolver)
        let baseline = try ResolverFileSnapshot.read(resolver.path)
        let replacementBytes = Data("# changed externally\nnameserver 192.0.2.99\n".utf8)
        try replacementBytes.write(to: resolver)
        let changed = try ResolverFileSnapshot.read(resolver.path)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let ledger = SystemModificationLedger(store: store)
        try ledger.saveResolverOwnershipRecord(.init(phase: .resolverRestored, previous: baseline, intendedBytes: Data("nameserver 127.0.0.1\nport 53535\n".utf8), written: nil))
        let intents = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        try intents.set("dns", enabled: true)
        let dns = DNSCapability(helper: ShutdownTestDNSHelper(path: resolver.path), ledger: ledger)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: ProjectRegistry(store: store), dns: dns, serviceIntents: intents)

        await dispatcher.restoreServicesOnStartup()
        try await Task.sleep(for: .milliseconds(100))
        let response = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        guard case .status(let status) = response.response.result else { return XCTFail("missing Core status") }
        XCTAssertEqual(status.serviceIssues?["dns"], "The resolver no longer matches Vaelen's saved preimage; it was left unchanged.")
        XCTAssertEqual(try ResolverFileSnapshot.read(resolver.path), changed)
        XCTAssertEqual(try Data(contentsOf: resolver), replacementBytes)
        XCTAssertEqual(try intents.enabledServices(), ["dns"])

        let quit = await dispatcher.shutdownForParentExit()
        XCTAssertTrue(quit.completed)
        XCTAssertEqual(try ResolverFileSnapshot.read(resolver.path), changed)
        XCTAssertEqual(try intents.enabledServices(), ["dns"])
    }

    func testSavedStandardPortsAuthorizationBlockIsVisibleAndChoiceRemainsOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-intent-ports-blocked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StandardPortsPaths(anchorPath: root.appendingPathComponent("anchor").path, pfConfPath: root.appendingPathComponent("pf.conf").path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# isolated PF fixture\n".write(toFile: paths.pfConfPath, atomically: true, encoding: .utf8)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let intents = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        try intents.set("standard-ports", enabled: true)
        let ports = StandardPortsCapability(privileged: BlockedShutdownPortsFake(), paths: paths, ledger: SystemModificationLedger(store: store), portOccupied: { _ in false }, backendHealthy: { true })
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: ProjectRegistry(store: store), ports: ports, serviceIntents: intents)

        await dispatcher.restoreServicesOnStartup()
        try await Task.sleep(for: .milliseconds(100))
        let response = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: true)
        guard case .status(let status) = response.response.result else { return XCTFail("missing Core status") }
        XCTAssertEqual(status.serviceIssues?["standard-ports"], "Standard Ports require approval in Vaelen.app.")
        XCTAssertEqual(try intents.enabledServices(), ["standard-ports"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.anchorPath))
    }

    func testPortsInstallHelperFailureReturnsIPCErrorPayloadAndPreservesDesiredOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ports-install-ipc-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let intents = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        let paths = StandardPortsPaths(anchorPath: root.appendingPathComponent("anchor").path, pfConfPath: root.appendingPathComponent("pf.conf").path)
        try "# isolated PF fixture\n".write(toFile: paths.pfConfPath, atomically: true, encoding: .utf8)
        let capability = StandardPortsCapability(
            privileged: BlockedShutdownPortsFake(),
            paths: paths,
            ledger: SystemModificationLedger(store: store),
            portOccupied: { _ in false },
            backendHealthy: { true }
        )
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: "test", pid: getpid()),
            registry: ProjectRegistry(store: store),
            ports: capability,
            serviceIntents: intents
        )

        let result = await dispatcher.dispatch(IPCRequest(method: .portsInstall), handshaken: true)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
        XCTAssertNotNil(result.response.error?.message)
        XCTAssertEqual(try intents.enabledServices(), ["standard-ports"])
    }

    func testQuitReleasesProvenPFForwardingWithoutChangingSavedOnIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("service-intent-pf-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = StandardPortsPaths(anchorPath: root.appendingPathComponent("anchor").path, pfConfPath: root.appendingPathComponent("pf.conf").path)
        let anchor = StandardPortsForwardingPolicy.anchorRules()
        let references = StandardPortsForwardingPolicy.pfConfReferenceLines(anchorPath: paths.anchorPath).joined(separator: "\n") + "\n"
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let ledger = SystemModificationLedger(store: store)
        let preConf = StandardPortsFileSnapshot(exists: true, bytes: Data("# original PF fixture\n".utf8), owner: 501, group: 20, mode: 0o644)
        let preAnchor = StandardPortsFileSnapshot(exists: false, bytes: nil, owner: nil, group: nil, mode: nil)
        let writtenConf = StandardPortsFileSnapshot(exists: true, bytes: Data(references.utf8), owner: 501, group: 20, mode: 0o644)
        let writtenAnchor = StandardPortsFileSnapshot(exists: true, bytes: Data(anchor.utf8), owner: 501, group: 20, mode: 0o644)
        let acquisition = StandardPortsAcquisition(preimagePFConf: preConf, preimageAnchor: preAnchor, writtenPFConf: writtenConf, writtenAnchor: writtenAnchor, changedPFConf: true, changedAnchor: true, forwardingWasActive: false, pfToken: "fixture-authorization")
        try ledger.recordStandardPorts(anchorRules: anchor, acquisition: acquisition)
        let intents = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        try intents.set("standard-ports", enabled: true)
        let removals = ShutdownRemovalCounter()
        let privileged = ShutdownPortsFake(inspection: .init(anchorContent: anchor, pfConfContent: references), removals: removals)
        let ports = StandardPortsCapability(privileged: privileged, paths: paths, ledger: ledger, portOccupied: { _ in false }, backendHealthy: { false })
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: ProjectRegistry(store: store), ports: ports, serviceIntents: intents)

        let shutdown = await dispatcher.shutdownForParentExit()
        XCTAssertTrue(shutdown.completed, "Quit must release recorded PF state: \(shutdown.components)")
        let removalCount = await removals.count()
        XCTAssertEqual(removalCount, 1)
        XCTAssertEqual(try ledger.standardPortsRecord()?.active, false)
        XCTAssertEqual(try intents.enabledServices(), ["standard-ports"])
        let externalAfter = try await privileged.inspectForwarding()
        XCTAssertNil(externalAfter.anchorContent)
        XCTAssertEqual(externalAfter.pfConfContent, "# original PF fixture\n")
    }

    func testCoreShutdownAllStoppedIsTypedIdempotentAndStopsCoreOnlyOnSuccess() async throws {
        let fixture = try makeShutdownDispatcher()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = await fixture.dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true)
        guard case .shutdown(let result) = first.response.result else { return XCTFail("Core shutdown did not return typed outcome") }
        XCTAssertTrue(result.completed, "\(result.components)")
        XCTAssertTrue(result.components.contains { $0.component == "caddy" && $0.succeeded })
        XCTAssertTrue(result.components.contains { $0.component == "dns" && $0.succeeded })
        XCTAssertTrue(result.components.contains { $0.component == "standard-ports-pf" && $0.succeeded })
        let mayExit = await fixture.dispatcher.shouldExitAfterShutdownResponse()
        XCTAssertTrue(mayExit)

        let repeated = await fixture.dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true)
        guard case .shutdown(let repeatedResult) = repeated.response.result else { return XCTFail("repeated shutdown missing typed response") }
        XCTAssertEqual(repeatedResult, result)
    }

    func testSuccessfulShutdownResponsePrecedesCoreSocketRemoval() async throws {
        let root = URL(fileURLWithPath: "/private/var/tmp/vq-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let ports = StandardPortsCapability(privileged: ShutdownPortsFake(inspection: .init(anchorContent: nil, pfConfContent: nil), removals: ShutdownRemovalCounter()), paths: .init(anchorPath: root.appendingPathComponent("anchor").path, pfConfPath: root.appendingPathComponent("pf.conf").path), ledger: SystemModificationLedger(store: store), portOccupied: { _ in false }, backendHealthy: { false })
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: getpid()), registry: ProjectRegistry(store: store), dns: DNSCapability(helper: ShutdownTestDNSHelper(path: root.appendingPathComponent("resolver/test").path), ledger: SystemModificationLedger(store: store)), ports: ports)
        let paths = CoreEndpointPaths(root: root.appendingPathComponent("core-runtime", isDirectory: true))
        let server = DaemonServer(paths: paths, dispatcher: dispatcher)
        let serverTask = Task.detached { try server.run() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: paths.socketPath) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socketPath))
        let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "quit-acceptance", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
        try await client.connect()
        let result = try await client.shutdown()
        XCTAssertTrue(result.completed, "\(result.components)")
        await client.disconnect()
        try await serverTask.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socketPath), "Core socket must disappear after the successful response")
    }

    func testShutdownFailureIsReportedButDoesNotHoldCoreOpen() async throws {
        let router = ShutdownTestRouter(stopFailures: 1)
        let fixture = try makeShutdownDispatcher(router: router)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = await fixture.dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true)
        guard case .shutdown(let firstResult) = first.response.result else { return XCTFail("missing shutdown outcome") }
        XCTAssertFalse(firstResult.completed)
        XCTAssertFalse(firstResult.components.first { $0.component == "caddy" }?.succeeded ?? true)
        XCTAssertTrue(firstResult.components.first { $0.component == "dns" }?.succeeded ?? false, "DNS cleanup still runs after Caddy cleanup fails")
        let mayExitAfterFailure = await fixture.dispatcher.shouldExitAfterShutdownResponse()
        XCTAssertTrue(mayExitAfterFailure)
        let blockedStart = await fixture.dispatcher.dispatch(IPCRequest(method: .routingStart), handshaken: true)
        XCTAssertNotNil(blockedStart.response.error, "new service starts must be rejected once shutdown begins")
    }

    func testCoreShutdownStopsOwnedMailpitAndLeavesUnrelatedSameExecutableAlive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-mailpit-\(UUID().uuidString)")
        defer { removeShutdownRoot(root) }
        let fixture = try makeMailpitFixture(root: root, resistant: false)
        let started = try fixture.module.start()
        let pid = try XCTUnwrap(started.pid)
        let unrelatedPorts = try (ephemeralTCPPort(), ephemeralTCPPort())
        let unrelatedDatabase = root.appendingPathComponent("unrelated/messages.db")
        try FileManager.default.createDirectory(at: unrelatedDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: fixture.executable.path)
        unrelated.arguments = ["--smtp", "127.0.0.1:\(unrelatedPorts.0)", "--listen", "127.0.0.1:\(unrelatedPorts.1)", "--database", unrelatedDatabase.path, "--log-file", root.appendingPathComponent("unrelated/log").path, "--allowed-hosts", "127.0.0.1,localhost"]
        unrelated.standardOutput = FileHandle.nullDevice; unrelated.standardError = FileHandle.nullDevice; try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        XCTAssertTrue(waitForTCP(unrelatedPorts.0)); XCTAssertTrue(waitForTCP(unrelatedPorts.1))

        let core = try makeShutdownDispatcher(root: root, mailpit: fixture.module)
        let reply = await core.dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true)
        guard case .shutdown(let result) = reply.response.result else { return XCTFail("missing typed shutdown result") }
        XCTAssertTrue(result.completed, "\(result.components)")
        XCTAssertFalse(processIsLive(pid))
        XCTAssertFalse(waitForTCP(started.smtpPort)); XCTAssertFalse(waitForTCP(started.httpPort))
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertTrue(waitForTCP(unrelatedPorts.0)); XCTAssertTrue(waitForTCP(unrelatedPorts.1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.module.instanceDatabasePath()))
    }

    func testParentExitCleanupUsesTheSameOwnedMailpitStopRoutine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parent-exit-mailpit-\(UUID().uuidString)")
        defer { removeShutdownRoot(root) }
        let fixture = try makeMailpitFixture(root: root, resistant: false)
        let started = try fixture.module.start()
        let pid = try XCTUnwrap(started.pid)
        let core = try makeShutdownDispatcher(root: root, mailpit: fixture.module)

        let result = await core.dispatcher.shutdownForParentExit()

        XCTAssertTrue(result.completed, "\(result.components)")
        XCTAssertFalse(processIsLive(pid))
        XCTAssertFalse(waitForTCP(started.smtpPort)); XCTAssertFalse(waitForTCP(started.httpPort))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.module.instanceDatabasePath()))
        let mayExit = await core.dispatcher.shouldExitAfterShutdownResponse()
        XCTAssertTrue(mayExit)
    }

    func testResistantMailpitDoesNotKeepCoreAliveAfterBestEffortQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-mailpit-retry-\(UUID().uuidString)")
        defer { removeShutdownRoot(root) }
        let fixture = try makeMailpitFixture(root: root, resistant: true)
        let started = try fixture.module.start()
        let pid = try XCTUnwrap(started.pid)
        let core = try makeShutdownDispatcher(root: root, mailpit: fixture.module)
        let first = await core.dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true)
        guard case .shutdown(let partial) = first.response.result else { return XCTFail("missing partial shutdown result") }
        XCTAssertFalse(partial.completed)
        XCTAssertFalse(partial.components.first { $0.component == "mailpit" }?.succeeded ?? true)
        XCTAssertTrue(processIsLive(pid))
        XCTAssertTrue(waitForTCP(started.smtpPort)); XCTAssertTrue(waitForTCP(started.httpPort))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.processFile.path))
        let mayExit = await core.dispatcher.shouldExitAfterShutdownResponse()
        XCTAssertTrue(mayExit)
        XCTAssertTrue(processIsLive(pid), "a resistant process is not signaled beyond its provider's best effort")
        try FileManager.default.removeItem(at: fixture.resistFile)
        _ = try fixture.module.stop()
        XCTAssertFalse(processIsLive(pid))
        XCTAssertFalse(waitForTCP(started.smtpPort)); XCTAssertFalse(waitForTCP(started.httpPort))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.processFile.path))
    }

    func testShutdownFencesNewStartsAndStopsAlreadyAdmittedProviderStart() async throws {
        let router = ShutdownTestRouter()
        let fixture = try makeShutdownDispatcher(router: router)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let startTask = Task { await fixture.dispatcher.dispatch(IPCRequest(method: .routingStart), handshaken: true) }
        for _ in 0..<100 {
            if await router.startCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let starts = await router.startCount()
        let admittedStart = await startTask.value
        XCTAssertEqual(starts, 1, "start response: \(String(describing: admittedStart.response.error))")
        let shutdownTask = Task { await fixture.dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true) }
        for _ in 0..<100 {
            if await fixture.dispatcher.isShutdownInProgress() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let lateStart = await fixture.dispatcher.dispatch(IPCRequest(method: .routingStart), handshaken: true)
        XCTAssertNotNil(lateStart.response.error)
        _ = await startTask.value
        let shutdown = await shutdownTask.value
        guard case .shutdown(let result) = shutdown.response.result else { return XCTFail("missing shutdown response") }
        XCTAssertTrue(result.completed, "\(result.components)")
        let routerStatus = await router.status()
        XCTAssertEqual(routerStatus.state, .stopped)
    }

    func testQuitLeavesHistoricalPFFilesAloneWithoutProvenanceAndCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-pf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let removals = ShutdownRemovalCounter()
        let observed = StandardPortsInspection(anchorContent: StandardPortsForwardingPolicy.anchorRules(), pfConfContent: StandardPortsForwardingPolicy.pfConfReferenceLines().joined(separator: "\n"))
        let ports = StandardPortsCapability(privileged: ShutdownPortsFake(inspection: observed, removals: removals), paths: .init(anchorPath: root.appendingPathComponent("anchor").path, pfConfPath: root.appendingPathComponent("pf.conf").path), ledger: SystemModificationLedger(store: store), portOccupied: { _ in false }, backendHealthy: { false })
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: ProjectRegistry(store: store), ports: ports)
        let resultResponse = await dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true)
        guard case .shutdown(let result) = resultResponse.response.result else { return XCTFail("missing shutdown response") }
        XCTAssertTrue(result.completed, "unowned historical PF files are not a cleanup obligation: \(result.components)")
        XCTAssertTrue(result.components.first { $0.component == "standard-ports-pf" }?.succeeded ?? false)
        XCTAssertTrue(result.components.first { $0.component == "standard-ports-pf" }?.detail.contains("left unchanged") ?? false)
        let removeCount = await removals.count()
        XCTAssertEqual(removeCount, 0)
        let mayExit = await dispatcher.shouldExitAfterShutdownResponse()
        XCTAssertTrue(mayExit)
    }

    func testResolverEditPreservesExternalResolverAndQuitStopsVaelenResponder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-dns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let resolver = root.appendingPathComponent("resolver/test")
        let responder = ShutdownTestResponder()
        let dns = DNSCapability(helper: MutableShutdownDNSHelper(path: resolver.path), responder: responder, port: 49173, ledger: SystemModificationLedger(store: store))
        _ = try await dns.install()
        let independent = Data("nameserver 192.0.2.99\n# independent\n".utf8)
        try independent.write(to: resolver, options: .atomic)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: ProjectRegistry(store: store), dns: dns)
        let reply = await dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true)
        guard case .shutdown(let result) = reply.response.result else { return XCTFail("missing shutdown result") }
        XCTAssertTrue(result.completed, "external resolver drift is preserved while Vaelen releases its resources")
        let dnsResult = try XCTUnwrap(result.components.first { $0.component == "dns" })
        XCTAssertTrue(dnsResult.succeeded)
        XCTAssertEqual(try Data(contentsOf: resolver), independent)
        XCTAssertNil(try SystemModificationLedger(store: store).resolverOwnershipRecord())
        let stops = await responder.stopCount()
        XCTAssertEqual(stops, 1, "independent resolver edit must not prevent responder shutdown")
        let status = await dns.status()
        XCTAssertEqual(status.health, "stopped")
    }

    func testShutdownTreatsUnownedExternalResolverAsHarmlessAndLeavesItByteForByteAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-dns-external-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = root.appendingPathComponent("resolver/test")
        try FileManager.default.createDirectory(at: resolver.deletingLastPathComponent(), withIntermediateDirectories: true)
        let herdCompatibleContents = Data("nameserver 127.0.0.1\n".utf8)
        try herdCompatibleContents.write(to: resolver)
        let before = try ResolverFileSnapshot.read(resolver.path)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let responder = ShutdownTestResponder()
        let dns = DNSCapability(layout: VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support")), helper: ShutdownTestDNSHelper(path: resolver.path), responder: responder, port: 49174, ledger: SystemModificationLedger(store: store))
        let ports = StandardPortsCapability(privileged: ShutdownPortsFake(inspection: .init(anchorContent: nil, pfConfContent: nil), removals: ShutdownRemovalCounter()), paths: .init(anchorPath: root.appendingPathComponent("anchor").path, pfConfPath: root.appendingPathComponent("pf.conf").path), ledger: SystemModificationLedger(store: store), portOccupied: { _ in false }, backendHealthy: { false })
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: ProjectRegistry(store: store), dns: dns, ports: ports)

        let reply = await dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true)
        guard case .shutdown(let result) = reply.response.result else { return XCTFail("missing typed shutdown result") }
        XCTAssertTrue(result.completed, "an unowned external resolver is not a Vaelen cleanup obligation: \(result.components)")
        let dnsOutcome = try XCTUnwrap(result.components.first { $0.component == "dns" })
        XCTAssertTrue(dnsOutcome.succeeded)
        XCTAssertEqual(try ResolverFileSnapshot.read(resolver.path), before)
        XCTAssertEqual(try Data(contentsOf: resolver), herdCompatibleContents)
        XCTAssertNil(try SystemModificationLedger(store: store).resolverOwnershipRecord())
        XCTAssertNil(try SystemModificationLedger(store: store).dnsRecord())
        let responderStops = await responder.stopCount()
        XCTAssertEqual(responderStops, 0)
    }

    func testCoreShutdownStopsCaddyThenContinuesThroughDNSRestore() async throws {
        let root = URL(fileURLWithPath: "/tmp/vln-qcd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: support)
        let package = try CaddyModule(layout: VaelenFilesystemLayout()).resolveInstalled(requestedVersion: "2.11.4")
        let httpPort = try ephemeralTCPPort()
        var httpsPort = try ephemeralTCPPort()
        while httpsPort == httpPort { httpsPort = try ephemeralTCPPort() }
        let supervisor = CaddyProcessSupervisor(layout: layout, configuration: CaddyRuntimeConfiguration(httpPort: httpPort, httpsPort: httpsPort))
        await supervisor.installPackage(package)
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        try await router.start()

        let resolver = root.appendingPathComponent("resolver/test")
        try FileManager.default.createDirectory(at: resolver.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preimage = Data("nameserver 192.0.2.53\n".utf8)
        try preimage.write(to: resolver)
        let responder = ShutdownTestResponder()
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let dns = DNSCapability(
            layout: layout,
            helper: MutableShutdownDNSHelper(path: resolver.path),
            responder: responder,
            port: 49174,
            ledger: SystemModificationLedger(store: store)
        )
        _ = try await dns.install()
        let ports = StandardPortsCapability(
            privileged: ShutdownPortsFake(inspection: .init(anchorContent: nil, pfConfContent: nil), removals: ShutdownRemovalCounter()),
            paths: .init(anchorPath: root.appendingPathComponent("anchor").path, pfConfPath: root.appendingPathComponent("pf.conf").path),
            ledger: SystemModificationLedger(store: store),
            portOccupied: { _ in false },
            backendHealthy: { false }
        )
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: getpid()), registry: ProjectRegistry(store: store), router: router, dns: dns, ports: ports)

        let reply = await dispatcher.dispatch(IPCRequest(method: .shutdown), handshaken: true)
        guard case .shutdown(let result) = reply.response.result else { return XCTFail("missing typed shutdown result") }
        XCTAssertTrue(result.completed, "all shutdown work, including DNS, must complete: \(result.components)")
        let caddyIndex = try XCTUnwrap(result.components.firstIndex { $0.component == "caddy" })
        let dnsIndex = try XCTUnwrap(result.components.firstIndex { $0.component == "dns" })
        XCTAssertLessThan(caddyIndex, dnsIndex)
        let caddyStatus = await supervisor.status()
        let dnsStatus = await dns.status()
        let responderStops = await responder.stopCount()
        XCTAssertEqual(caddyStatus.state, .stopped)
        XCTAssertEqual(dnsStatus.state, .notInstalled)
        XCTAssertEqual(try Data(contentsOf: resolver), preimage)
        XCTAssertEqual(responderStops, 1)
    }

    private struct ShutdownFixture {
        let dispatcher: CoreRequestDispatcher
        let root: URL
    }

    private func makeShutdownDispatcher(root: URL? = nil, router: any Router = InMemoryRouter(), mailpit: MailpitModule? = nil) throws -> ShutdownFixture {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("quit-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let counter = ShutdownRemovalCounter()
        let ports = StandardPortsCapability(privileged: ShutdownPortsFake(inspection: .init(anchorContent: nil, pfConfContent: nil), removals: counter), paths: .init(anchorPath: root.appendingPathComponent("anchor").path, pfConfPath: root.appendingPathComponent("pf.conf").path), ledger: SystemModificationLedger(store: store), portOccupied: { _ in false }, backendHealthy: { false })
        let dnsPath = root.appendingPathComponent("resolver/test").path
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: ProjectRegistry(store: store), mailpit: mailpit, router: router, dns: DNSCapability(helper: ShutdownTestDNSHelper(path: dnsPath), ledger: SystemModificationLedger(store: store)), ports: ports)
        return ShutdownFixture(dispatcher: dispatcher, root: root)
    }

    private struct ShutdownMailpitFixture {
        let module: MailpitModule
        let executable: URL
        let configuration: MailpitRuntimeConfiguration
        let resistFile: URL
        let processFile: URL
    }

    private func makeMailpitFixture(root: URL, resistant: Bool) throws -> ShutdownMailpitFixture {
        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("mailpit-core", isDirectory: true))
        let packageDirectory = layout.mailpitPackagesDirectoryURL.appendingPathComponent(MailpitModule.defaultVersion, isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let executable = packageDirectory.appendingPathComponent("mailpit")
        let python = #"""
#!/usr/bin/python3
import os,signal,socket,sys,select
a=sys.argv[1:]
smtp=a[a.index('--smtp')+1]; http=a[a.index('--listen')+1]
def ep(v):
 h,p=v.rsplit(':',1); return h,int(p)
listeners=[]
for v in (smtp,http):
 s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(ep(v)); s.listen(8); s.setblocking(False); listeners.append(s)
db=a[a.index('--database')+1]; open(db,'a').close(); resist=os.path.join(os.path.dirname(db),'resist-term')
def term(sig,frame):
 if not os.path.exists(resist): raise SystemExit(0)
signal.signal(signal.SIGTERM,term)
while True:
 ready,_,_=select.select(listeners,[],[],.1)
 for listener in ready:
  client,_=listener.accept()
  try:
   if listener is listeners[0]: client.sendall(b'220 harmless fixture\\r\\n')
   else: client.recv(4096); client.sendall(b'HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nok')
  except Exception: pass
  client.close()
"""#
        try Data(python.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let package = MailpitPackage(version: MailpitModule.defaultVersion, architecture: "arm64", packagePath: packageDirectory.path, executablePath: executable.path, source: "fixture", artifactSHA256: MailpitManifest.official1_31_1.artifactSHA256, license: "MIT", installedAt: Date())
        try JSONEncoder().encode(package).write(to: packageDirectory.appendingPathComponent(".vaelen-package.json"))
        let configuration = MailpitRuntimeConfiguration(smtpPort: try ephemeralTCPPort(), httpPort: try ephemeralTCPPort())
        let module = MailpitModule(layout: layout, configuration: configuration)
        let resistFile = layout.mailpitInstancesDirectoryURL.appendingPathComponent("default/resist-term")
        try FileManager.default.createDirectory(at: resistFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if resistant { try Data("resist".utf8).write(to: resistFile) }
        return ShutdownMailpitFixture(module: module, executable: executable, configuration: configuration, resistFile: resistFile, processFile: layout.mailpitInstancesDirectoryURL.appendingPathComponent("default/process.json"))
    }

    private func ephemeralTCPPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw NSError(domain: "QuitTest", code: 1) }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw NSError(domain: "QuitTest", code: 2) }
        var result = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &result) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard queried == 0 else { throw NSError(domain: "QuitTest", code: 3) }
        return Int(UInt16(bigEndian: result.sin_port))
    }

    private func waitForTCP(_ port: Int) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd >= 0 {
                var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
                close(fd)
                if connected { return true }
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    private func processIsLive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func removeShutdownRoot(_ root: URL) { guard FileManager.default.fileExists(atPath: root.path) else { return }; let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod"); chmod.arguments = ["-R", "u+w", root.path]; try? chmod.run(); chmod.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
    func testProjectRelationshipsTraverseCoreAndRemainIndependentlyDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let project = workspace.appendingPathComponent("project", isDirectory: true)
        for path in ["bootstrap", "config", "public"] {
            try FileManager.default.createDirectory(at: project.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("marker".utf8).write(to: project.appendingPathComponent("artisan"))
        try Data("<?php".utf8).write(to: project.appendingPathComponent("public/index.php"))
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state/state.sqlite")
        let dispatcher = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1),
            registry: ProjectRegistry(store: try SQLiteStateStore(databaseURL: database))
        )

        let emptyParks = await dispatcher.dispatch(IPCRequest(method: .pathList, params: .listProjects(.init())), handshaken: true)
        guard case .parkedPathList(let emptyParkList) = emptyParks.response.result else { return XCTFail("missing parked-root list") }
        XCTAssertTrue(emptyParkList.paths.isEmpty)
        let emptyLinks = await dispatcher.dispatch(IPCRequest(method: .projectLinks, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let emptyLinkList) = emptyLinks.response.result else { return XCTFail("missing explicit-link list") }
        XCTAssertTrue(emptyLinkList.projects.isEmpty)

        let parked = await dispatcher.dispatch(IPCRequest(method: .pathPark, params: .park(.init(path: workspace.path, workingDirectory: root.path))), handshaken: true)
        guard case .parkedPathMutation(let parkedResult) = parked.response.result else { return XCTFail("park did not return a typed result") }
        XCTAssertTrue(parkedResult.created)
        let repeatedPark = await dispatcher.dispatch(IPCRequest(method: .pathPark, params: .park(.init(path: workspace.appendingPathComponent(".").path, workingDirectory: root.path))), handshaken: true)
        guard case .parkedPathMutation(let repeatedParkResult) = repeatedPark.response.result else { return XCTFail("repeated park did not return a typed result") }
        XCTAssertFalse(repeatedParkResult.created)
        XCTAssertEqual(repeatedParkResult.path?.id, parkedResult.path?.id)

        let linked = await dispatcher.dispatch(IPCRequest(method: .projectLink, params: .link(.init(path: project.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectMutation(let linkedResult) = linked.response.result else { return XCTFail("link did not return a typed result") }
        XCTAssertTrue(linkedResult.created)
        let repeatedLink = await dispatcher.dispatch(IPCRequest(method: .projectLink, params: .link(.init(path: project.appendingPathComponent(".").path, workingDirectory: root.path))), handshaken: true)
        guard case .projectMutation(let repeatedLinkResult) = repeatedLink.response.result else { return XCTFail("repeated link did not return a typed result") }
        XCTAssertFalse(repeatedLinkResult.created)
        XCTAssertEqual(repeatedLinkResult.project?.id, linkedResult.project?.id)

        let recreated = try CoreRequestDispatcher(
            runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 2),
            registry: ProjectRegistry(store: try SQLiteStateStore(databaseURL: database))
        )
        let persistedParks = await recreated.dispatch(IPCRequest(method: .pathList, params: .listProjects(.init())), handshaken: true)
        guard case .parkedPathList(let persistedParkList) = persistedParks.response.result else { return XCTFail("recreated Core lost parked roots") }
        XCTAssertEqual(persistedParkList.paths.map(\.path), [workspace.standardizedFileURL.path])
        let persistedLinks = await recreated.dispatch(IPCRequest(method: .projectLinks, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let persistedLinkList) = persistedLinks.response.result else { return XCTFail("recreated Core lost explicit links") }
        XCTAssertEqual(persistedLinkList.projects.map(\.path), [project.standardizedFileURL.path])
        let presented = await recreated.dispatch(IPCRequest(method: .projectList, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let presentedList) = presented.response.result else { return XCTFail("combined project list unavailable") }
        XCTAssertEqual(presentedList.projects.count, 1)
        XCTAssertEqual(presentedList.projects.first?.detectedFramework, "Laravel")
        XCTAssertEqual(presentedList.projects.first?.sources, ["explicitLink", "parkedFolder"])

        _ = await recreated.dispatch(IPCRequest(method: .pathUnpark, params: .unpark(.init(path: workspace.path, workingDirectory: root.path))), handshaken: true)
        let linksAfterUnpark = await recreated.dispatch(IPCRequest(method: .projectLinks, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let linksAfterUnparkResult) = linksAfterUnpark.response.result else { return XCTFail("explicit links unavailable after unpark") }
        XCTAssertEqual(linksAfterUnparkResult.projects.map(\.path), [project.standardizedFileURL.path])

        _ = await recreated.dispatch(IPCRequest(method: .pathPark, params: .park(.init(path: workspace.path, workingDirectory: root.path))), handshaken: true)
        _ = await recreated.dispatch(IPCRequest(method: .projectUnlink, params: .unlink(.init(path: project.path, workingDirectory: root.path))), handshaken: true)
        let parksAfterUnlink = await recreated.dispatch(IPCRequest(method: .pathList, params: .listProjects(.init())), handshaken: true)
        guard case .parkedPathList(let parksAfterUnlinkResult) = parksAfterUnlink.response.result else { return XCTFail("parked roots unavailable after unlink") }
        XCTAssertEqual(parksAfterUnlinkResult.paths.map(\.path), [workspace.standardizedFileURL.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
    }

    func testM13TrustAndUntrustTraverseDispatcherWithParameterlessRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let fake = DispatcherTrustFake()
        let keychain = LocalCAKeychain(tag: "dev.vaelen.ipc.\(UUID().uuidString)")
        defer { try? keychain.removeCAKey() }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let tls = TLSCapability(layout: layout, store: store, keychain: keychain, trustBoundary: fake)
        _ = try await tls.install()
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry, tls: tls)
        let handshake = await dispatcher.dispatch(IPCRequest(method: .handshake, params: .handshake(.init(client: .init(name: "test", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))), handshaken: false)
        XCTAssertTrue(handshake.handshaken)

        let trusted = await dispatcher.dispatch(IPCRequest(method: .tlsTrustLocalCA), handshaken: true)
        guard case .tlsTrust(let trust)? = trusted.response.result else { return XCTFail("missing typed trust response") }
        XCTAssertEqual(trust.result.operation, .confirmed)
        XCTAssertNil(IPCRequest(method: .tlsTrustLocalCA).params)

        let untrusted = await dispatcher.dispatch(IPCRequest(method: .tlsRemoveLocalCATrust), handshaken: true)
        guard case .tlsTrust(let remove)? = untrusted.response.result else { return XCTFail("missing typed untrust response") }
        XCTAssertEqual(remove.result.operation, .removed)
        XCTAssertNil(IPCRequest(method: .tlsRemoveLocalCATrust).params)
    }

    func testDispatcherHandshakeRequiresMatchingSchemaBeforeNormalDispatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry)

        let old = await dispatcher.dispatch(IPCRequest(method: .handshake, params: .handshake(.init(client: .init(name: "old", version: "0.0.10-dev")))), handshaken: false)
        XCTAssertEqual(old.response.error?.code, .coreIncompatible)
        XCTAssertFalse(old.handshaken)

        let current = await dispatcher.dispatch(IPCRequest(method: .handshake, params: .handshake(.init(client: .init(name: "current", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)))), handshaken: false)
        XCTAssertTrue(current.handshaken)
        guard case .handshake(let result) = current.response.result else { return XCTFail("handshake did not return compatibility identity") }
        XCTAssertEqual(result.schemaCompatibilityVersion, VaelenBuildInfo.schemaCompatibilityVersion)
        XCTAssertEqual(result.buildIdentity, VaelenBuildInfo.buildIdentity)
    }

    func testDispatcherRejectsNormalCommandBeforeHandshake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry)

        let result = await dispatcher.dispatch(IPCRequest(method: .status), handshaken: false)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
        XCTAssertEqual(result.response.error?.message, "Handshake is required before other requests.")
    }

    func testDispatcherRejectsUnknownMethodStructurally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry)

        let result = await dispatcher.dispatch(IPCRequest(rawMethod: "project.future"), handshaken: true)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
    }

    func testRouteMutationPersistsThroughCoreAndSurvivesDispatcherRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "persisted.test", target: .staticFiles(documentRoot: "/tmp/persisted"), tls: .disabled)
        let intent = RouteIntent(route: route)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry, routeRepository: repository)

        let added = await dispatcher.dispatch(IPCRequest(method: .routeAdd, params: .route(intent)), handshaken: true)
        guard case .routeMutation(let addedIntent) = added.response.result else { return XCTFail("route add did not return the route") }
        XCTAssertEqual(addedIntent, intent)

        let recreated = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 2), registry: registry, routeRepository: repository)
        let listed = await recreated.dispatch(IPCRequest(method: .routeList), handshaken: true)
        guard case .routeList(let result) = listed.response.result else { return XCTFail("route list did not return routes") }
        XCTAssertEqual(result.routes, [intent])

        let removed = await recreated.dispatch(IPCRequest(method: .routeRemove, params: .routeRemove(.init(id: route.id))), handshaken: true)
        guard case .routeList(let afterRemoval) = removed.response.result else { return XCTFail("route remove did not return routes") }
        XCTAssertTrue(afterRemoval.routes.isEmpty)
    }

    func testExplicitRouteAssociationChangesOnlyMetadataAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("public"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("bootstrap"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: projectRoot.appendingPathComponent("artisan"))
        try Data("<?php".utf8).write(to: projectRoot.appendingPathComponent("public/index.php"))
        try Data("{\"require\":{\"laravel/framework\":\"^11.0\",\"php\":\"^8.3\"}}".utf8).write(to: projectRoot.appendingPathComponent("composer.json"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let project = try await registry.link(path: projectRoot)
        guard let projectID = project.id else { return XCTFail("linked project did not receive an ID") }
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "project.test", target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: projectRoot.appendingPathComponent("public").path), tls: .local)
        let intent = RouteIntent(route: route)
        try repository.upsert(intent)
        let router = InMemoryRouter()
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry, router: router, routeRepository: repository)

        let request = IPCRequest(method: .routeProjectAssociationAttach, params: .routeAssociation(.init(routeID: route.id, projectID: projectID)))
        let response = await dispatcher.dispatch(request, handshaken: true)
        guard case .routeAssociation(let association) = response.response.result else { return XCTFail("association did not return typed result") }
        XCTAssertEqual(association.state, .associated)
        XCTAssertEqual(association.route.route, route)
        XCTAssertEqual(try repository.all().first?.projectID, projectID.rawValue)
        XCTAssertEqual(try repository.all().first?.projectPath, projectRoot.path)
        let routerStatus = await router.status()
        XCTAssertEqual(routerStatus.routeCount, 0)

        let second = await dispatcher.dispatch(request, handshaken: true)
        guard case .routeAssociation(let repeated) = second.response.result else { return XCTFail("repeated association did not return typed result") }
        XCTAssertEqual(repeated.state, .satisfied)
        XCTAssertEqual(try repository.all().first?.route, route)
    }

    func testRouteAssociationRejectsExistingDifferentProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let first = try await registry.link(path: firstRoot)
        let second = try await registry.link(path: secondRoot)
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "owned.test", target: .staticFiles(documentRoot: firstRoot.path), tls: .disabled)
        try repository.upsert(RouteIntent(route: route, projectID: first.id?.rawValue, projectPath: firstRoot.path))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version, pid: 1), registry: registry, routeRepository: repository)

        let response = await dispatcher.dispatch(IPCRequest(method: .routeProjectAssociationAttach, params: .routeAssociation(.init(routeID: route.id, projectID: second.id!))), handshaken: true)
        XCTAssertEqual(response.response.error?.code, .invalidRequest)
        XCTAssertEqual(try repository.all().first?.projectID, first.id?.rawValue)
    }

    func testUnlinkPreservesDurableRouteAssociationAsOrphanedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let registry = ProjectRegistry(store: store)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let project = try await registry.link(path: projectRoot)
        let repository = RouteIntentRepository(store: store)
        let route = Route(hostname: "orphan.test", target: .staticFiles(documentRoot: projectRoot.path), tls: .disabled)
        try repository.upsert(RouteIntent(route: route, projectID: project.id?.rawValue, projectPath: projectRoot.path))

        try await registry.unlink(path: projectRoot)

        let persisted = try repository.all().first
        XCTAssertEqual(persisted?.projectID, project.id?.rawValue)
        XCTAssertEqual(persisted?.projectPath, projectRoot.path)
    }

    func testDispatcherDoesNotConvertRepositoryFailureIntoEmptyRoutes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        try store.execute("DROP TABLE route_intents")
        let registry = ProjectRegistry(store: store)
        let repository = RouteIntentRepository(store: store)

        XCTAssertThrowsError(try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, routeRepository: repository)) { error in
            XCTAssertNotNil(error as? SQLiteStateError)
        }
    }

    func testDispatcherRejectsMalformedTransitionProvenanceAtStartup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        try store.execute("INSERT INTO route_target_transitions (route_id,project_id,previous_route_json,desired_route_json,previous_provider_json,desired_provider_json,previous_socket,desired_socket,state) VALUES ('bad','bad',X'00',X'00',X'00',X'00','a','b','providerPending')")
        let registry = ProjectRegistry(store: store)
        XCTAssertThrowsError(try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, routeRepository: RouteIntentRepository(store: store))) { error in
            XCTAssertEqual(error as? SQLiteStateError, .invalidRecord)
        }
    }

    func testProjectReconciliationRejectsDiscoveredProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("discovered")
        for path in ["bootstrap", "config", "public"] {
            try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("marker".utf8).write(to: projectRoot.appendingPathComponent("artisan"))
        try Data("<?php".utf8).write(to: projectRoot.appendingPathComponent("public/index.php"))
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite")))
        _ = try await registry.park(path: root)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry)

        // Precondition: Slice 4 discovery recognizes the parked folder as a discovered (unlinked) project.
        let listed = await dispatcher.dispatch(IPCRequest(method: .projectList, params: .listProjects(.init())), handshaken: true)
        guard case .projectList(let listedResult) = listed.response.result else { return XCTFail("combined project list unavailable") }
        XCTAssertEqual(listedResult.projects.first(where: { $0.name == "discovered" })?.registration, "discovered")

        // Read-only environment remains observable for discovered projects.
        let status = await dispatcher.dispatch(IPCRequest(method: .projectStatus, params: .projectEnvironment(.init(selector: "discovered", workingDirectory: root.path))), handshaken: true)
        XCTAssertNil(status.response.error)

        // Reconciliation stays gated to explicitly linked projects.
        let result = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: "discovered", workingDirectory: root.path))), handshaken: true)

        XCTAssertEqual(result.response.error?.code, .invalidRequest)
        XCTAssertEqual(result.response.error?.message, "Project reconciliation requires a registered linked project.")

        let plan = await dispatcher.dispatch(IPCRequest(method: .projectPlan, params: .projectEnvironment(.init(selector: "discovered", workingDirectory: root.path))), handshaken: true)
        XCTAssertEqual(plan.response.error?.code, .invalidRequest)
        XCTAssertEqual(plan.response.error?.message, "Project reconciliation requires a registered linked project.")
    }

    func testProjectActivationStartsAndThenReusesAnIsolatedMailpit() async throws {
        guard let package = MailpitModule().installedVersions().first else { throw XCTSkip("Mailpit package prerequisite unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { removeTestRoot(root) }
        let configuration = MailpitRuntimeConfiguration(smtpPort: try availablePort(), httpPort: try availablePort())
        try Data("version: 1\nservices:\n  mailpit: true\n".utf8).write(to: projectRoot.appendingPathComponent("vaelen.yml"))
        try Data("MAIL_MAILER=smtp\nMAIL_HOST=127.0.0.1\nMAIL_PORT=\(configuration.smtpPort)\nMAIL_PASSWORD=null\n".utf8).write(to: projectRoot.appendingPathComponent(".env"))

        let layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("vaelen"))
        let finalPackage = layout.mailpitPackagesDirectoryURL.appendingPathComponent(package.version, isDirectory: true)
        try FileManager.default.createDirectory(at: layout.mailpitPackagesDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: package.packagePath), to: finalPackage)
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod"); chmod.arguments = ["-R", "u+w", finalPackage.path]; try chmod.run(); chmod.waitUntilExit()
        let copiedPackage = MailpitPackage(version: package.version, architecture: package.architecture, packagePath: finalPackage.path, executablePath: finalPackage.appendingPathComponent("mailpit").path, source: package.source, artifactSHA256: package.artifactSHA256, license: package.license, installedAt: package.installedAt)
        try JSONEncoder().encode(copiedPackage).write(to: finalPackage.appendingPathComponent(".vaelen-package.json"), options: .atomic)
        let mailpit = MailpitModule(layout: layout, configuration: configuration)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: mailpit.instanceDatabasePath()).deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mailpit.instanceDatabasePath(), contents: Data())
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        _ = try await registry.link(path: projectRoot)
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "0.0.1-dev", pid: 1), registry: registry, mailpit: mailpit, router: InMemoryRouter(), routeRepository: RouteIntentRepository(store: try SQLiteStateStore(databaseURL: layout.databaseURL.appendingPathExtension("routes"))))

        let planResponse = await dispatcher.dispatch(IPCRequest(method: .projectPlan, params: .projectEnvironment(.init(selector: projectRoot.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectPlan(let planResult) = planResponse.response.result else { return XCTFail("project plan did not return a plan") }
        XCTAssertEqual(planResult.plan.state, .actionable)
        XCTAssertEqual(planResult.plan.operations.first?.id, "mailpit.start")

        let activationResponse = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: projectRoot.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectActivation(let activationResult) = activationResponse.response.result else { return XCTFail("project activation did not return an execution result") }
        XCTAssertEqual(activationResult.execution.state, .succeeded)
        let firstPID = mailpit.status().pid
        XCTAssertEqual(mailpit.status().state, .running)

        let secondResponse = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: projectRoot.path, workingDirectory: root.path))), handshaken: true)
        guard case .projectActivation(let secondResult) = secondResponse.response.result else { return XCTFail("second activation did not return an execution result") }
        XCTAssertEqual(secondResult.execution.state, .succeeded)
        XCTAssertEqual(mailpit.status().pid, firstPID)
        _ = try mailpit.stop()
    }

    private func removeTestRoot(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod"); process.arguments = ["-R", "u+w", root.path]; try? process.run(); process.waitUntilExit(); try? FileManager.default.removeItem(at: root)
    }

    private func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MailpitModuleError.processFailed("socket") }
        defer { close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw MailpitModuleError.processFailed("bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard result == 0 else { throw MailpitModuleError.processFailed("getsockname") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
