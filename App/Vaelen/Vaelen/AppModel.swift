import SwiftUI
import AppKit
import Observation
import ServiceManagement
import UniformTypeIdentifiers
import os
import VaelenIPC
import VaelenCore

@MainActor
@Observable
final class AppModel {
    private static let startupLogger = Logger(subsystem: "dev.vaelen.app", category: "ProjectStartup")
    enum State {
        case connecting
        case running(CoreStatusResponse, [ProjectWire], PHPVersionsResult?, RouterStatus?, DNSStatus?, TLSStatus?, StandardPortsStatus?, MySQLStatus?, MailpitStatus?)
        case unavailable
        case incompatible(String)
    }

    private(set) var state: State = .connecting
    private(set) var serviceReadiness: CoreServiceReadiness = .checking
    private(set) var earlyProjectList: [ProjectWire]?
    private(set) var projectReports: [ProjectEnvironmentReport] = []
    private(set) var projectReportErrors: [String: String] = [:]
    private(set) var projectStartupMilestones: [String: TimeInterval] = [:]
    private(set) var phpCatalog: PHPRuntimeCatalog?
    private(set) var phpCatalogReadPending = false
    private(set) var phpConfiguration: PHPConfigurationResult?
    private(set) var phpConfigurationError: String?
    private(set) var phpConfigurationReadPending = false
    private(set) var phpConfigurationSaving = false
    private(set) var phpOperation: PHPOperationState?
    private(set) var phpError: String?
    private(set) var phpRequestInFlight = false
    private(set) var phpRequestTarget: String?
    private(set) var parkedFolders: [ParkedPathWire] = []
    private(set) var linkedProjects: [ProjectWire] = []
    private(set) var configuredRoutes: [RouteIntent]?
    private(set) var configuredRoutesError: String?
    private(set) var trustError: String?
    private(set) var serviceOperation: String?
    private(set) var serviceError: String?
    private var serviceErrorService: String?
    private(set) var startupServiceIssues: [String: String] = [:]
    private(set) var isQuitting = false
    private(set) var refreshError: String?
    private(set) var coreLaunchError: String?
    private(set) var relationshipError: String?
    private(set) var relationshipOperation: String?
    private(set) var relationshipMutationInFlight = false
    private var client: VaelenCoreClient?
    private var refreshGeneration = 0
    private var relationshipSnapshotGeneration = 0
    private var refreshInFlight = false
    private var refreshRequested = false
    private var monitorTask: Task<Void, Never>?
    private var serviceCheckTimeoutTask: Task<Void, Never>?
    private var serviceCheckStartedAt: ContinuousClock.Instant?
    private var pendingServiceReads = Set<String>()
    private var projectReportsTask: Task<Void, Never>?
    private var projectSettingsVisible = false
    private var projectRelationshipsRefreshInFlight = false
    private var projectRelationshipsRefreshRequested = false
    private(set) var projectRelationshipsRefreshError: String?
    private(set) var isSettingsFixture = false
    private(set) var settingsFixtureDark = false
    private(set) var settingsFixtureLight = false
    private(set) var settingsFixtureMode: String?
    private(set) var settingsFixturePage: SettingsPage?
    private(set) var settingsFixtureOperationFailure = false

    static func modelForApplicationLaunch(arguments: [String]) -> AppModel {
        #if VAELEN_SETTINGS_FIXTURES
        if let argument = arguments.first(where: { $0.hasPrefix("--settings-fixture=") }) {
            let mode = String(argument.dropFirst("--settings-fixture=".count))
            let model = AppModel()
            model.isSettingsFixture = true
            model.settingsFixtureMode = mode
            model.settingsFixtureDark = arguments.contains("--settings-fixture-dark")
            model.settingsFixtureLight = arguments.contains("--settings-fixture-light")
            if let pageArgument = arguments.first(where: { $0.hasPrefix("--settings-page=") }) {
                model.settingsFixturePage = SettingsPage(rawValue: String(pageArgument.dropFirst("--settings-page=".count)))
            }
            switch mode {
            case "pending":
                model.state = .connecting
                model.pendingServiceReads = ["PHP", "routing", "DNS", "TLS", "standard-ports", "MySQL", "Mailpit"]
                model.phpCatalogReadPending = true
                model.phpConfigurationReadPending = true
            case "unavailable":
                model.state = .unavailable
                model.coreLaunchError = "Fixture: Core observations are unavailable."
            case "partial", "empty", "installed", "all-installed", "install-failed", "remove-failed":
                model.settingsFixtureOperationFailure = mode == "install-failed" || mode == "remove-failed"
                let mysqlState: MySQLState = mode == "partial" ? .unhealthy : (mode == "installed" || mode == "all-installed" || mode == "remove-failed") ? .stopped : .notInstalled
                let mysqlVersion = (mode == "installed" || mode == "all-installed" || mode == "remove-failed") ? "8.4.11" : nil
                let mysql = MySQLStatus(
                    state: mysqlState,
                    health: mysqlState == .unhealthy ? "identity-unverified" : mysqlState == .stopped ? "stopped" : "not-installed",
                    installedVersion: mysqlVersion,
                    selectedVersion: nil,
                    pid: mysqlState == .unhealthy ? 4242 : nil,
                    port: 3306,
                    socket: "/fixture/mysql.sock",
                    datadir: "/fixture/mysql-data",
                    executablePath: "/fixture/mysqld"
                )
                let mailpitInstalled = mode == "all-installed"
                let mailpit = MailpitStatus(
                    state: mailpitInstalled ? .installed : .notInstalled,
                    health: mailpitInstalled ? "stopped" : "not-installed",
                    installedVersion: mailpitInstalled ? MailpitModule.defaultVersion : nil,
                    pid: nil,
                    smtpPort: 1025,
                    httpPort: 8025,
                    database: "/fixture/mailpit.db",
                    uiEndpoint: "http://127.0.0.1:8025",
                    executablePath: "/fixture/mailpit"
                )
                let status = CoreStatusResponse(core: CoreRuntime(version: "0.0.14-fixture", pid: 1).status, protocolVersion: 1, serviceIntents: [])
                model.state = .running(status, [], nil, RouterStatus(provider: "Caddy", providerVersion: "fixture", state: .stopped, health: .unknown, routeCount: 0), nil, nil, nil, mysql, mailpit)
                let runtime = PHPRuntimeVersion(version: "8.4.23", running: false, isDefault: true)
                model.phpCatalog = PHPRuntimeCatalog(
                    availableVersions: mode == "partial" || mode == "installed" || mode == "install-failed" || mode == "remove-failed" ? ["8.5.0"] : [],
                    installedVersions: mode == "partial" || mode == "installed" || mode == "install-failed" || mode == "remove-failed" ? [runtime] : [],
                    defaultVersion: mode == "partial" || mode == "installed" || mode == "install-failed" || mode == "remove-failed" ? "8.4.23" : nil,
                    runningVersions: [],
                    availableVersionsKnown: true
                )
                model.phpConfigurationReadPending = true
            default:
                model.isSettingsFixture = false
                model.settingsFixtureMode = nil
            }
            return model
        }
        #endif
        return AppModel()
    }

    var savedServiceIntents: Set<String>? {
        guard case .running(let status, _, _, _, _, _, _, _, _) = state else { return nil }
        return status.serviceIntents
    }

    func startupIssue(for service: String) -> String? { startupServiceIssues[service] }
    func isServiceReadPending(_ service: String) -> Bool { pendingServiceReads.contains(service) }

    private func updateFixturePackages(mysql: MySQLStatus? = nil, mailpit: MailpitStatus? = nil) {
        guard isSettingsFixture,
              case .running(let status, let projects, let php, let routing, let dns, let tls, let ports, let oldMySQL, let oldMailpit) = state else { return }
        state = .running(status, projects, php, routing, dns, tls, ports, mysql ?? oldMySQL, mailpit ?? oldMailpit)
    }

    func notePopoverPresented() {
        let count = earlyProjectList?.count ?? {
            if case .running(_, let projects, _, _, _, _, _, _, _) = state { return projects.count }
            return 0
        }()
        let connection = self.earlyProjectList == nil ? "connecting" : "connected"
        Self.startupLogger.info("startup milestone=popover-view-presented known-projects=\(count) connection=\(connection, privacy: .public)")
    }

    func refresh() async {
        guard !isSettingsFixture else { return }
        guard !relationshipMutationInFlight else {
            refreshRequested = true
            return
        }
        guard !refreshInFlight else {
            refreshRequested = true
            return
        }
        refreshInFlight = true
        defer {
            refreshInFlight = false
            phpCatalogReadPending = false
            if refreshRequested {
                refreshRequested = false
                Task { @MainActor [weak self] in await self?.refresh() }
            }
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        projectReportsTask?.cancel()
        projectReportsTask = nil
        let refreshStarted = ContinuousClock.now
        projectStartupMilestones = [:]
        relationshipSnapshotGeneration += 1
        let relationshipGeneration = relationshipSnapshotGeneration
        let hasRunningSnapshot: Bool
        if case .running = state { hasRunningSnapshot = true } else { hasRunningSnapshot = false }
        if let client { await client.disconnect() }
        let paths = CoreEndpointPaths()
        let client = VaelenCoreClient(
            transport: UnixSocketTransport(path: paths.socketPath),
            identity: ClientIdentity(name: "Vaelen.app", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
        )
        self.client = client
        if !hasRunningSnapshot { state = .connecting }
        if !hasRunningSnapshot { earlyProjectList = nil }
        do {
            let handshakeStarted = ContinuousClock.now
            do {
                try await client.connect()
            } catch let error as CoreClientError {
                guard case .coreUnavailable = error else { throw error }
                let coreStarted = try await CoreStartupHelperGate.run(
                    reconcileHelper: { try await self.registerCurrentPrivilegedHelper() },
                    startCore: { try CoreProcessManager.shared.start() }
                )
                guard coreStarted else { throw HelperRegistrationError.failed(Self.helperApprovalGuidance) }
                var connected = false
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(100))
                    do {
                        try await client.connect()
                        connected = true
                        break
                    } catch let retryError as CoreClientError {
                        guard case .coreUnavailable = retryError else { throw retryError }
                    }
                }
                guard connected else { throw CoreClientError.coreUnavailable }
            }
            Self.startupLogger.info("startup phase=initial-ipc-handshake elapsed_ms=\(Self.elapsedMilliseconds(since: handshakeStarted))")
            // Core's status response waits for startup service restoration.
            // Discover over an independent connection so known names/paths
            // render while that work continues.
            let discoveryStarted = ContinuousClock.now
            let projects = try await discoverProjects()
            let discoveryElapsed = Self.elapsedMilliseconds(since: discoveryStarted)
            let identitiesReadyAt = Self.elapsedMilliseconds(since: refreshStarted)
            earlyProjectList = projects
            projectStartupMilestones["allCardIdentities"] = Double(identitiesReadyAt) / 1_000
            Self.startupLogger.info("startup phase=project-discovery-ipc count=\(projects.count) elapsed_ms=\(discoveryElapsed)")
            guard generation == refreshGeneration else { await client.disconnect(); return }
            if case .running(let oldStatus, _, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit) = state {
                state = .running(oldStatus, projects, php, routing, dns, tls, ports, mysql, mailpit)
            }
            Self.startupLogger.info("startup milestone=all-card-identities-ui-model count=\(projects.count) elapsed_ms=\(Self.elapsedMilliseconds(since: refreshStarted))")
            projectReports = []
            projectReportErrors = [:]
            beginServiceReadinessCheck(generation: generation)

            let statusStarted = ContinuousClock.now
            let status = try await trackedServiceOperation("Core status") { try await client.status() }
            Self.startupLogger.info("startup phase=core-status-ipc elapsed_ms=\(Self.elapsedMilliseconds(since: statusStarted))")
            // Core status waits for startup restoration. Take the shared report
            // snapshot only after that barrier, or PHP/MySQL/DNS observations
            // can be captured mid-restore and surfaced as false project errors.
            startProjectReports(projects, generation: generation, refreshStarted: refreshStarted)
            startupServiceIssues = status.serviceIssues ?? [:]
            if !startupServiceIssues.isEmpty {
                finishServiceReadinessCheck(.attention)
            }
            if !VaelenActivitySignal.markActive() {
                serviceError = "Vaelen is running, but its shell activity signal could not be saved. PHP will refuse to fall back until this is repaired."
            }
            coreLaunchError = nil
            let cachedPHP: PHPVersionsResult?
            let cachedRouting: RouterStatus?
            let cachedDNS: DNSStatus?
            let cachedTLS: TLSStatus?
            let cachedPorts: StandardPortsStatus?
            let cachedMySQL: MySQLStatus?
            let cachedMailpit: MailpitStatus?
            if case .running(_, _, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit) = state {
                cachedPHP = php; cachedRouting = routing; cachedDNS = dns; cachedTLS = tls
                cachedPorts = ports; cachedMySQL = mysql; cachedMailpit = mailpit
            } else {
                cachedPHP = nil; cachedRouting = nil; cachedDNS = nil; cachedTLS = nil
                cachedPorts = nil; cachedMySQL = nil; cachedMailpit = nil
            }
            // Core connectivity itself is enough to leave Connecting. Service
            // probes and all project/catalog work may finish afterward.
            pendingServiceReads.formUnion(["PHP", "routing", "DNS", "TLS", "standard-ports", "MySQL", "Mailpit"])
            phpCatalogReadPending = true
            state = .running(status, projects, cachedPHP, cachedRouting, cachedDNS, cachedTLS, cachedPorts, cachedMySQL, cachedMailpit)

            // Service reads use independent IPC connections; each connection
            // retains strict request/response serialization without one slow
            // service read blocking the other six.
            let serviceReadsStarted = ContinuousClock.now
            async let phpTask = trackedIndependentCoreRead("PHP") { try await $0.phpVersions() }
            async let routingTask = trackedIndependentCoreRead("routing") { try await $0.routingStatus() }
            async let dnsTask = trackedIndependentCoreRead("DNS") { try await $0.dnsStatus() }
            async let tlsTask = trackedIndependentCoreRead("TLS") { try await $0.tlsStatus() }
            async let portsTask = trackedIndependentCoreRead("standard-ports") { try await $0.portsStatus() }
            async let mysqlTask = trackedIndependentCoreRead("MySQL") { try await $0.mysqlStatus() }
            async let mailpitTask = trackedIndependentCoreRead("Mailpit") { try await $0.mailpitStatus() }
            let (php, routing, dns, tls, ports, mysql, mailpit) = await (phpTask, routingTask, dnsTask, tlsTask, portsTask, mysqlTask, mailpitTask)
            Self.startupLogger.info("startup phase=seven-service-reads elapsed_ms=\(Self.elapsedMilliseconds(since: serviceReadsStarted))")
            guard generation == refreshGeneration else { await client.disconnect(); return }
            if startupServiceIssues.isEmpty {
                let successCount = [php != nil, routing != nil, dns != nil, tls != nil, ports != nil, mysql != nil, mailpit != nil].filter { $0 }.count
                finishServiceReadinessCheck(CoreServiceReadiness.resolve(serviceIssues: startupServiceIssues, requiredReadCount: 7, completedReadCount: 7, successfulReadCount: successCount))
            }
            state = .running(status, projects, php, routing, dns, tls, ports, mysql, mailpit)

            let linkedProjects = try await client.linkedProjects()
            let parkedFolders = try await client.parkedPaths()
            let configuredRoutes: [RouteIntent]?
            let configuredRoutesError: String?
            do {
                configuredRoutes = try await client.routeList()
                configuredRoutesError = nil
            } catch {
                configuredRoutes = nil
                configuredRoutesError = error.localizedDescription
            }
            let phpCatalog = try? await client.phpCatalog()
            phpCatalogReadPending = false
            let phpOperation = try? await client.phpOperation()
            guard generation == refreshGeneration else { await client.disconnect(); return }
            self.configuredRoutes = configuredRoutes
            self.configuredRoutesError = configuredRoutesError
            if relationshipGeneration == relationshipSnapshotGeneration {
                self.linkedProjects = linkedProjects
                self.parkedFolders = parkedFolders
                projectRelationshipsRefreshError = nil
            }
            self.phpCatalog = phpCatalog
            self.phpOperation = phpOperation
            state = .running(status, projects, php, routing, dns, tls, ports, mysql, mailpit)
            refreshError = nil
            if self.phpConfiguration == nil { await refreshPHPConfiguration() }
        } catch let error as CoreClientError {
            guard generation == refreshGeneration else { return }
            await client.disconnect()
            if hasRunningSnapshot || isShowingRunningSnapshot {
                refreshError = refreshMessage(for: error)
                if serviceReadiness == .checking { finishServiceReadinessCheck(.unavailable) }
                return
            }
            if case .coreUnavailable = error {
                coreLaunchError = "Vaelen Core did not become ready within 2 seconds. Try Refresh or relaunch Vaelen."
            }
            switch error {
            case .coreUnavailable: state = .unavailable; finishServiceReadinessCheck(.unavailable)
            case .protocolIncompatible(let client, let core): state = .incompatible("Protocol mismatch: client \(client), Core \(core). Restart Vaelen Core and try again."); finishServiceReadinessCheck(.attention)
            case .coreIncompatible(let reason): state = .incompatible("\(reason) Restart Vaelen Core and try again."); finishServiceReadinessCheck(.attention)
            default: state = .unavailable
            }
            if !hasRunningSnapshot { finishServiceReadinessCheck(.unavailable) }
            markPendingProjectReportsUnavailable()
        } catch {
            guard generation == refreshGeneration else { return }
            await client.disconnect()
            if hasRunningSnapshot {
                refreshError = error.localizedDescription
                if serviceReadiness == .checking { finishServiceReadinessCheck(.unavailable) }
                return
            }
            coreLaunchError = error.localizedDescription
            state = .unavailable
            if !hasRunningSnapshot { finishServiceReadinessCheck(.unavailable) }
            markPendingProjectReportsUnavailable()
        }
    }

    private func beginServiceReadinessCheck(generation: Int) {
        serviceCheckTimeoutTask?.cancel()
        serviceReadiness = .checking
        serviceCheckStartedAt = .now
        pendingServiceReads = []
        serviceCheckTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.refreshGeneration == generation, self.serviceReadiness == .checking else { return }
            let outstanding = self.pendingServiceReads.sorted().joined(separator: ",")
            let elapsed = self.serviceCheckStartedAt.map(Self.elapsedMilliseconds(since:)) ?? 12_000
            Self.startupLogger.error("startup milestone=service-state-timeout elapsed_ms=\(elapsed) outstanding=\(outstanding, privacy: .public)")
            let unavailable = CoreServiceReadiness.resolve(serviceIssues: self.startupServiceIssues, requiredReadCount: 7, completedReadCount: 0, successfulReadCount: 0, timedOut: true)
            self.finishServiceReadinessCheck(unavailable)
        }
    }

    private func finishServiceReadinessCheck(_ readiness: CoreServiceReadiness) {
        serviceCheckTimeoutTask?.cancel()
        serviceCheckTimeoutTask = nil
        serviceReadiness = readiness
        if let started = serviceCheckStartedAt {
            let result: String
            switch readiness {
            case .checking: result = "checking"
            case .ready: result = "ready"
            case .attention: result = "attention"
            case .unavailable: result = "unavailable"
            }
            Self.startupLogger.info("startup milestone=service-state-completion result=\(result, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: started))")
            serviceCheckStartedAt = nil
        }
    }

    private func trackedServiceOperation<Value>(_ label: String, operation: () async throws -> Value) async throws -> Value {
        pendingServiceReads.insert(label)
        defer { pendingServiceReads.remove(label) }
        return try await operation()
    }

    private func trackedIndependentCoreRead<Value: Sendable>(_ label: String, operation: @escaping @Sendable (VaelenCoreClient) async throws -> Value) async -> Value? {
        pendingServiceReads.insert(label)
        defer { pendingServiceReads.remove(label) }
        return await independentCoreRead(label, operation: operation)
    }

    private func startProjectReports(_ projects: [ProjectWire], generation: Int, refreshStarted: ContinuousClock.Instant) {
        Self.startupLogger.info("startup milestone=project-reports-started count=\(projects.count) elapsed_ms=\(Self.elapsedMilliseconds(since: refreshStarted))")
        if projects.isEmpty {
            projectStartupMilestones["allFreshDetails"] = Double(Self.elapsedMilliseconds(since: refreshStarted)) / 1_000
            Self.startupLogger.info("startup milestone=all-fresh-details count=0 elapsed_ms=\(Self.elapsedMilliseconds(since: refreshStarted))")
            return
        }
        projectReportsTask = Task { @MainActor [weak self] in
            await self?.refreshProjectReports(projects, generation: generation, refreshStarted: refreshStarted)
        }
    }

    private func refreshProjectReports(_ projects: [ProjectWire], generation: Int, refreshStarted: ContinuousClock.Instant) async {
        let reportsStarted = ContinuousClock.now
        let snapshotID = await independentCoreRead("project-observation-snapshot") { try await $0.projectObservationSnapshot() }
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        Self.startupLogger.info("startup phase=report-snapshot elapsed_ms=\(Self.elapsedMilliseconds(since: reportsStarted)) available=\(snapshotID != nil)")
        await withTaskGroup(of: (String, ProjectEnvironmentReport?, String?).self) { group in
            var next = 0
            let concurrency = min(4, projects.count)
            func submit(_ project: ProjectWire) {
                group.addTask {
                    let report = await self.independentCoreRead("report-\(project.name)") { client in
                        try await client.projectStatus(selector: project.id?.uuidString, workingDirectory: project.path, snapshotID: snapshotID)
                    }
                    return (project.path, report, report == nil ? "Project diagnostics unavailable. Refresh to retry." : nil)
                }
            }
            while next < concurrency { submit(projects[next]); next += 1 }
            while let (path, report, reportError) = await group.next() {
                guard generation == refreshGeneration, !Task.isCancelled else { group.cancelAll(); return }
                if let report {
                    projectReports.removeAll { $0.identity.path == path }
                    projectReports.append(report)
                    projectReportErrors.removeValue(forKey: path)
                    if projectStartupMilestones["firstFreshDetail"] == nil {
                        let elapsed = Self.elapsedMilliseconds(since: refreshStarted)
                        projectStartupMilestones["firstFreshDetail"] = Double(elapsed) / 1_000
                        Self.startupLogger.info("startup milestone=first-fresh-detail elapsed_ms=\(elapsed)")
                    }
                } else if let reportError {
                    projectReportErrors[path] = reportError
                }
                if next < projects.count { submit(projects[next]); next += 1 }
            }
        }
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        let reportElapsed = Self.elapsedMilliseconds(since: reportsStarted)
        if projectReports.count == projects.count {
            let elapsed = Self.elapsedMilliseconds(since: refreshStarted)
            projectStartupMilestones["allFreshDetails"] = Double(elapsed) / 1_000
            Self.startupLogger.info("startup milestone=all-fresh-details count=\(projects.count) elapsed_ms=\(elapsed)")
        }
        Self.startupLogger.info("startup phase=reports count=\(projects.count) completed=\(self.projectReports.count) failed=\(self.projectReportErrors.count) elapsed_ms=\(reportElapsed)")
        projectReportsTask = nil
    }

    private func markPendingProjectReportsUnavailable() {
        guard let earlyProjectList else { return }
        for project in earlyProjectList where !projectReports.contains(where: { $0.identity.path == project.path }) {
            projectReportErrors[project.path] = "Core is unavailable; project diagnostics could not be refreshed."
        }
    }

    private func independentCoreRead<Value: Sendable>(_ label: String, operation: @escaping @Sendable (VaelenCoreClient) async throws -> Value) async -> Value? {
        let paths = CoreEndpointPaths()
        let worker = VaelenCoreClient(
            transport: UnixSocketTransport(path: paths.socketPath),
            identity: ClientIdentity(name: "Vaelen.app.project-refresh", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
        )
        do {
            let handshakeStarted = ContinuousClock.now
            try await worker.connect()
            Self.startupLogger.info("startup phase=ipc-handshake label=\(label, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: handshakeStarted))")
            let requestStarted = ContinuousClock.now
            let value = try await operation(worker)
            Self.startupLogger.info("startup phase=ipc-request label=\(label, privacy: .public) elapsed_ms=\(Self.elapsedMilliseconds(since: requestStarted))")
            await worker.disconnect()
            return value
        } catch {
            Self.startupLogger.warning("startup phase=ipc-request-failed label=\(label, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            await worker.disconnect()
            return nil
        }
    }

    private func discoverProjects() async throws -> [ProjectWire] {
        let paths = CoreEndpointPaths()
        let discoveryClient = VaelenCoreClient(
            transport: UnixSocketTransport(path: paths.socketPath),
            identity: ClientIdentity(name: "Vaelen.app.project-list", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
        )
        do {
            let handshakeStarted = ContinuousClock.now
            try await discoveryClient.connect()
            Self.startupLogger.info("startup phase=ipc-handshake label=project-list elapsed_ms=\(Self.elapsedMilliseconds(since: handshakeStarted))")
            let requestStarted = ContinuousClock.now
            let projects = try await discoveryClient.projectList()
            Self.startupLogger.info("startup phase=ipc-request label=project-list elapsed_ms=\(Self.elapsedMilliseconds(since: requestStarted))")
            await discoveryClient.disconnect()
            return projects
        } catch {
            await discoveryClient.disconnect()
            throw error
        }
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    func trustLocalCA() async {
        guard beginServiceOperation("Trusting Local HTTPS…"), let client else { return }
        do { _ = try await client.tlsTrustLocalCA(); await refresh() } catch { trustError = error.localizedDescription }
        finishServiceOperation(error: trustError)
    }

    func removeLocalCATrust() async {
        guard beginServiceOperation("Removing Local HTTPS trust…"), let client else { return }
        do { _ = try await client.tlsRemoveLocalCATrust(); await refresh(); finishServiceOperation() } catch { finishServiceOperation(error: error.localizedDescription) }
    }

    func installStandardPorts() async {
        await performServiceCommand("Enabling standard ports…", service: "standard-ports") { [self] client in
            try await preparePrivilegedHelper(using: client)
            _ = try await client.portsInstall()
        }
    }

    func removeStandardPorts() async {
        await performServiceCommand("Disabling standard ports…", service: "standard-ports") { client in
            _ = try await client.portsRemove()
        }
    }

    func startDNS() async {
        await performServiceCommand("Starting DNS…", service: "dns") { [self] client in
            try await preparePrivilegedHelper(using: client)
            _ = try await client.dnsInstall(takeover: false)
        }
    }

    private static let helperApprovalGuidance = "Approve Vaelen’s privileged daemon in System Settings → General → Login Items & Extensions → Allow in the Background, then retry."
    private static let registeredHelperDigestKey = "registeredPrivilegedHelperSHA256"
    private static let pendingHelperDigestKey = "pendingPrivilegedHelperSHA256"

    /// SMAppService requires re-registration when the bundled helper or plist
    /// changes. The build manifest hashes the helper payload before code
    /// signing plus the packaged plist, so local re-signing does not look like
    /// a functional update. A pending digest prevents a failed first XPC call
    /// from repeating the unregister/register cycle on the user's next retry.
    private func registerCurrentPrivilegedHelper() async throws -> Bool {
        guard #available(macOS 13, *) else { return true }
        let service = SMAppService.daemon(plistName: "dev.vaelen.privileged-helper.plist")
        let digest = try helperRegistrationDigest()
        let defaults = UserDefaults.standard
        let registeredDigest = defaults.string(forKey: Self.registeredHelperDigestKey)
        let pendingDigest = defaults.string(forKey: Self.pendingHelperDigestKey)

        switch HelperRegistrationDigestPolicy.resolve(
            serviceEnabled: service.status == .enabled,
            serviceRequiresApproval: service.status == .requiresApproval,
            packagedDigest: digest,
            registeredDigest: registeredDigest,
            pendingDigest: pendingDigest
        ) {
        case .useCurrentRegistration:
            // A normal launch must not churn a valid durable registration.
            return true
        case .approvalRequired:
            return false
        case .reconcile:
            break
        }

        if (service.status == .enabled || service.status == .requiresApproval), registeredDigest != digest {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    service.unregister { error in
                        if let error { continuation.resume(throwing: error) }
                        else {
                            // SMAppService can transiently reject immediate
                            // re-registration after unregister (Operation not
                            // permitted). Defer to the next main run-loop turn
                            // as recommended by Apple DTS:
                            // https://developer.apple.com/forums/thread/783539
                            DispatchQueue.main.async { continuation.resume() }
                        }
                    }
                }
            } catch {
                throw HelperRegistrationError.failed("macOS could not replace the registered helper: \(error.localizedDescription)")
            }
        }

        if service.status != .enabled && service.status != .requiresApproval {
            do { try service.register() }
            catch { throw HelperRegistrationError.failed(error.localizedDescription) }
        }

        switch service.status {
        case .enabled:
            defaults.set(digest, forKey: Self.pendingHelperDigestKey)
            return true
        case .requiresApproval:
            defaults.set(digest, forKey: Self.pendingHelperDigestKey)
            return false
        case .notRegistered:
            throw HelperRegistrationError.failed("macOS did not register Vaelen’s privileged daemon.")
        case .notFound:
            throw HelperRegistrationError.failed("macOS could not find Vaelen’s packaged privileged daemon.")
        @unknown default:
            throw HelperRegistrationError.failed("macOS could not find Vaelen’s packaged privileged daemon.")
        }
    }

    private func helperRegistrationDigest() throws -> String {
        let manifestURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/vaelen-privileged-helper.manifest")
        return try String(contentsOf: manifestURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reuses the accepted SMAppService digest reconciliation and read-only
    /// helper probe for every user-triggered operation requiring the helper.
    /// The digest is committed as registered only after Core successfully
    /// reaches the current helper through the supported XPC path.
    private func preparePrivilegedHelper(using client: VaelenCoreClient) async throws {
        guard try await registerCurrentPrivilegedHelper() else { throw HelperRegistrationError.failed(Self.helperApprovalGuidance) }
        let helperProbe = try await client.dnsStatus()
        guard helperProbe.health != "privilege-unavailable" else {
            throw HelperRegistrationError.failed("The registered privileged helper did not respond to Core’s XPC inspection.")
        }
        let digest = try helperRegistrationDigest()
        UserDefaults.standard.set(digest, forKey: Self.registeredHelperDigestKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingHelperDigestKey)
    }

    func stopDNS() async {
        await performServiceCommand("Stopping DNS…", service: "dns") { client in _ = try await client.dnsRemove() }
    }

    func installMySQL() async {
        if isSettingsFixture {
            if settingsFixtureOperationFailure { serviceError = "Fixture: install failed; Core inventory is unchanged."; return }
            serviceError = nil
            updateFixturePackages(mysql: MySQLStatus(state: .installed, health: "not-initialized", installedVersion: MySQLModule.defaultVersion, selectedVersion: nil, pid: nil, port: 3306, socket: "/fixture/mysql.sock", datadir: "/fixture/mysql-data", executablePath: "/fixture/mysqld"))
            return
        }
        await performServiceCommand("Installing MySQL…") { client in _ = try await client.mysqlInstall(MySQLModule.defaultVersion); _ = try await client.mysqlUse(MySQLModule.defaultVersion) }
    }
    func startMySQL() async { await performServiceCommand("Starting MySQL…") { client in let status = try await client.mysqlStatus(); if status.health == "not-initialized" { _ = try await client.mysqlInitialize() }; _ = try await client.mysqlStart() } }
    func stopMySQL() async { await performServiceCommand("Stopping MySQL…") { client in _ = try await client.mysqlStop() } }
    func removeMySQL(_ version: String) async {
        if isSettingsFixture {
            if settingsFixtureOperationFailure { serviceError = "Fixture: removal failed; Core inventory is unchanged."; return }
            serviceError = nil
            updateFixturePackages(mysql: MySQLStatus(state: .notInstalled, health: "not-installed", installedVersion: nil, selectedVersion: nil, pid: nil, port: 3306, socket: "/fixture/mysql.sock", datadir: "/fixture/mysql-data", executablePath: "/fixture/mysqld"))
            return
        }
        await performServiceCommand("Removing MySQL package…") { client in _ = try await client.mysqlRemove(version) }
    }
    func installMailpit() async {
        if isSettingsFixture {
            if settingsFixtureOperationFailure { serviceError = "Fixture: install failed; Core inventory is unchanged."; return }
            serviceError = nil
            updateFixturePackages(mailpit: MailpitStatus(state: .installed, health: "stopped", installedVersion: MailpitModule.defaultVersion, pid: nil, smtpPort: 1025, httpPort: 8025, database: "/fixture/mailpit.db", uiEndpoint: "http://127.0.0.1:8025", executablePath: "/fixture/mailpit"))
            return
        }
        await performServiceCommand("Installing Mailpit…") { client in _ = try await client.mailpitInstall(MailpitModule.defaultVersion) }
    }
    func startMailpit() async { await performServiceCommand("Starting Mailpit…") { client in _ = try await client.mailpitStart() } }
    func stopMailpit() async { await performServiceCommand("Stopping Mailpit…") { client in _ = try await client.mailpitStop() } }
    func removeMailpit(_ version: String) async {
        if isSettingsFixture {
            if settingsFixtureOperationFailure { serviceError = "Fixture: removal failed; Core inventory is unchanged."; return }
            serviceError = nil
            updateFixturePackages(mailpit: MailpitStatus(state: .notInstalled, health: "not-installed", installedVersion: nil, pid: nil, smtpPort: 1025, httpPort: 8025, database: "/fixture/mailpit.db", uiEndpoint: "http://127.0.0.1:8025", executablePath: "/fixture/mailpit"))
            return
        }
        await performServiceCommand("Removing Mailpit package…") { client in _ = try await client.mailpitRemove(version) }
    }
    func openMailpit() async { guard beginServiceOperation("Opening Mailpit…"), let client else { return }; do { let status = try await client.mailpitStatus(); guard status.state == .running else { throw NSError(domain: "Vaelen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mailpit is not healthy; start it before opening the UI."]) }; NSWorkspace.shared.open(URL(string: status.uiEndpoint)!); finishServiceOperation() } catch { finishServiceOperation(error: error.localizedDescription) } }
    func startRouting() async { await performServiceCommand("Starting Caddy…") { client in _ = try await client.routingStart() } }
    func stopRouting() async { await performServiceCommand("Stopping Caddy…") { client in _ = try await client.routingStop() } }

    func installPHP(_ version: String) async {
        await performPHPCommand(version) { _ = try await $0.phpInstall(version) }
    }

    func updatePHP(_ version: String) async {
        await performPHPCommand(version) { _ = try await $0.phpUpdate(version) }
    }

    func removePHP(_ version: String) async {
        await performPHPCommand(version) { _ = try await $0.phpRemove(version) }
    }

    func setDefaultPHP(_ version: String) async {
        await performPHPCommand(version) { _ = try await $0.phpDefaultSet(version) }
    }

    func refreshPHPConfiguration() async {
        guard let client else {
            if case .connecting = state {
                phpConfigurationReadPending = true
                phpConfigurationError = nil
            } else {
                phpConfigurationReadPending = false
                phpConfigurationError = "Vaelen Core is not connected."
            }
            return
        }
        phpConfigurationReadPending = true
        defer { phpConfigurationReadPending = false }
        do { phpConfiguration = try await client.phpConfiguration(); phpConfigurationError = nil }
        catch { phpConfigurationError = error.localizedDescription }
    }

    func savePHPConfiguration(version: String?, settings: PHPSettingsValues?) async {
        guard let client, !phpConfigurationSaving else { return }
        phpConfigurationSaving = true
        defer { phpConfigurationSaving = false }
        do {
            phpConfiguration = try await client.updatePHPConfiguration(version: version, settings: settings)
            phpConfigurationError = nil
            await refresh()
            await refreshPHPConfiguration()
        } catch {
            phpConfigurationError = error.localizedDescription
            await refreshPHPConfiguration()
        }
    }

    func openPHPConfigurationFiles() async {
        guard let client else { phpConfigurationError = "Vaelen Core is not connected."; return }
        do {
            let configuration = try await client.phpConfiguration()
            let url = URL(fileURLWithPath: configuration.directory, isDirectory: true)
            guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            phpConfigurationError = nil
        } catch { phpConfigurationError = "Could not open Vaelen PHP configuration files: \(error.localizedDescription)" }
    }

    func phpOperationIs(for version: String) -> Bool {
        phpRequestInFlight && phpOperation?.targetVersion == version
    }

    func serviceOperationIs(for title: String) -> Bool {
        guard let operation = serviceOperation else { return false }
        return operation.localizedCaseInsensitiveContains(title)
    }

    func openProjectFolder(_ project: ProjectWire) {
        guard canOpenProjectFolder(project) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path, isDirectory: true))
    }

    func openProjectInEditor(_ project: ProjectWire) {
        guard canOpenProjectFolder(project) else {
            serviceError = "Project folder is unavailable at \(project.path)."
            return
        }
        do {
            guard let preference = try EditorPreferenceStore().load() else {
                serviceError = "No editor is configured. Choose an installed editor in Vaelen Settings → General."
                return
            }
            let appURL = URL(fileURLWithPath: preference.applicationPath, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: appURL.path),
                  Bundle(url: appURL)?.bundleIdentifier == preference.bundleIdentifier else {
                serviceError = "Configured editor is unavailable. Choose it again in Vaelen Settings → General."
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: project.path, isDirectory: true)], withApplicationAt: appURL, configuration: configuration) { [weak self] _, error in
                if let error { Task { @MainActor in self?.serviceError = "Could not open project in editor: \(error.localizedDescription)" } }
            }
        } catch {
            serviceError = "Could not read the editor preference: \(error.localizedDescription)"
        }
    }

    func canOpenProjectFolder(_ project: ProjectWire) -> Bool {
        var isDirectory: ObjCBool = false
        return project.availability == PathAvailability.available.rawValue
            && FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func projectSiteURL(_ report: ProjectEnvironmentReport) -> URL? {
        report.usableSiteURL
    }

    func openProjectSite(_ report: ProjectEnvironmentReport) {
        guard let url = projectSiteURL(report) else { return }
        NSWorkspace.shared.open(url)
    }

    func openProjectRoute(_ route: RouteIntent) {
        let scheme = route.route.tls == .local ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(route.route.hostname)") else { return }
        NSWorkspace.shared.open(url)
    }

    func tablePlusAction(_ report: ProjectEnvironmentReport) -> ProjectDatabaseViewerAction {
        ProjectDatabaseViewerAction.tablePlus(report: report, tablePlusInstalled: isTablePlusInstalled)
    }

    var isTablePlusInstalled: Bool { tablePlusApplicationURL != nil }

    func openMySQLInTablePlus(_ mysql: MySQLStatus) {
        guard let applicationURL = tablePlusApplicationURL,
              let url = MySQLDatabaseViewerAction.tablePlus(mysql: mysql, tablePlusInstalled: true).url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration)
    }

    func openProjectDatabaseInTablePlus(_ report: ProjectEnvironmentReport) {
        let action = tablePlusAction(report)
        guard let url = action.url, let applicationURL = tablePlusApplicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration)
    }

    private var tablePlusApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tinyapp.TablePlus")
    }

    func revealMySQLDataFiles(_ mysql: MySQLStatus) {
        guard FileManager.default.fileExists(atPath: mysql.datadir) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mysql.datadir, isDirectory: true)])
    }

    func revealMySQLBinaries(_ mysql: MySQLStatus) {
        guard FileManager.default.fileExists(atPath: mysql.executablePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mysql.executablePath)])
    }

    func copyProjectPath(_ project: ProjectWire) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.path, forType: .string)
    }

    var projects: [ProjectWire] {
        guard case .running(_, let projects, _, _, _, _, _, _, _) = state else { return [] }
        return projects
    }

    func parkFolder(at path: String) async {
        guard beginRelationshipMutation("Adding workspace folder…") else { return }
        let commandClient = makeCoreClient()
        do {
            try await commandClient.connect()
            _ = try await commandClient.park(path: path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            try await reconcileProjectRelationships(using: commandClient)
            await commandClient.disconnect()
            finishRelationshipMutation()
            Task { await refresh() }
        } catch {
            await commandClient.disconnect()
            finishRelationshipMutation(error: error)
        }
    }

    func removeParkedFolder(_ folder: ParkedPathWire) async {
        guard beginRelationshipMutation("Removing workspace folder…") else { return }
        let commandClient = makeCoreClient()
        do {
            try await commandClient.connect()
            try await commandClient.unpark(path: folder.path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            try await reconcileProjectRelationships(using: commandClient)
            await commandClient.disconnect()
            finishRelationshipMutation()
            Task { await refresh() }
        } catch {
            await commandClient.disconnect()
            finishRelationshipMutation(error: error)
        }
    }

    func linkProject(at path: String) async {
        guard beginRelationshipMutation("Linking project…") else { return }
        let commandClient = makeCoreClient()
        do {
            try await commandClient.connect()
            _ = try await commandClient.link(path: path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path, name: nil)
            try await reconcileProjectRelationships(using: commandClient)
            await commandClient.disconnect()
            finishRelationshipMutation()
            Task { await refresh() }
        } catch {
            await commandClient.disconnect()
            finishRelationshipMutation(error: error)
        }
    }

    func unlinkProject(_ project: ProjectWire) async {
        guard beginRelationshipMutation("Unlinking project…") else { return }
        let commandClient = makeCoreClient()
        do {
            try await commandClient.connect()
            try await commandClient.unlink(path: project.path, name: nil, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            try await reconcileProjectRelationships(using: commandClient)
            await commandClient.disconnect()
            finishRelationshipMutation()
            Task { await refresh() }
        } catch {
            await commandClient.disconnect()
            finishRelationshipMutation(error: error)
        }
    }

    func setProjectPHP(_ project: ProjectWire, version: String?, useDefault: Bool = false) async {
        guard !relationshipMutationInFlight, let client else { return }
        relationshipMutationInFlight = true; relationshipOperation = "Updating PHP for \(project.name)…"; relationshipError = nil
        defer { relationshipMutationInFlight = false; relationshipOperation = nil }
        do { _ = try await client.setProjectPHP(selector: project.id?.uuidString ?? project.path, workingDirectory: project.path, version: version, useDefault: useDefault); await refresh() }
        catch { relationshipError = error.localizedDescription }
    }

    func startMonitoring() {
        guard !isSettingsFixture else { return }
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in await self?.monitor() }
    }

    func setProjectSettingsVisible(_ visible: Bool) {
        guard !isSettingsFixture else { return }
        guard projectSettingsVisible != visible else { return }
        projectSettingsVisible = visible
        if visible { Task { await refreshProjectRelationships() } }
        else {
            relationshipSnapshotGeneration += 1
            projectRelationshipsRefreshRequested = false
        }
    }

    func refreshProjectRelationshipsIfVisible() async {
        guard projectSettingsVisible else { return }
        await refreshProjectRelationships()
    }

    private func refreshProjectRelationships() async {
        guard !isSettingsFixture else { return }
        guard !relationshipMutationInFlight else { return }
        if projectRelationshipsRefreshInFlight {
            projectRelationshipsRefreshRequested = true
            return
        }
        projectRelationshipsRefreshInFlight = true
        defer {
            projectRelationshipsRefreshInFlight = false
            if projectRelationshipsRefreshRequested && projectSettingsVisible {
                projectRelationshipsRefreshRequested = false
                Task { await refreshProjectRelationships() }
            }
        }
        relationshipSnapshotGeneration += 1
        let generation = relationshipSnapshotGeneration
        let refreshClient = makeCoreClient()
        do {
            try await refreshClient.connect()
            let projects = try await refreshClient.projectList()
            let linked = try await refreshClient.linkedProjects()
            let parked = try await refreshClient.parkedPaths()
            guard generation == relationshipSnapshotGeneration, !relationshipMutationInFlight else {
                await refreshClient.disconnect()
                return
            }
            if case .running(let status, _, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit) = state {
                state = .running(status, projects, php, routing, dns, tls, ports, mysql, mailpit)
            }
            linkedProjects = linked
            parkedFolders = parked
            projectRelationshipsRefreshError = nil
            await refreshClient.disconnect()
        } catch {
            await refreshClient.disconnect()
            if generation == relationshipSnapshotGeneration {
                projectRelationshipsRefreshError = error.localizedDescription
            }
        }
    }

    private func reconcileProjectRelationships(using client: VaelenCoreClient) async throws {
        let projects = try await client.projectList()
        let linked = try await client.linkedProjects()
        let parked = try await client.parkedPaths()
        relationshipSnapshotGeneration += 1
        linkedProjects = linked
        parkedFolders = parked
        projectRelationshipsRefreshError = nil
        if case .running(let status, _, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit) = state {
            state = .running(status, projects, php, routing, dns, tls, ports, mysql, mailpit)
        }
    }

    func quitVaelen() async {
        guard !isQuitting else { return }
        if isSettingsFixture {
            isQuitting = true
            VaelenAppDelegate.shared?.terminateAfterCleanQuit()
            return
        }
        // These flags cover only live request/reply operations now; the slow
        // project/catalog reconciliation is not part of their lifetime.
        guard !serviceOperationIsBusy, !phpRequestInFlight, !relationshipMutationInFlight else {
            serviceError = "Vaelen is finishing the current operation. Try Quit again when it completes."
            return
        }
        isQuitting = true
        NSLog("SHUTDOWN_TIMING GUI quit begin epoch=%.3f", Date().timeIntervalSince1970)
        serviceError = nil
        refreshGeneration += 1
        monitorTask?.cancel(); monitorTask = nil
        // Use a private IPC connection so an in-flight background refresh
        // cannot serialize or disconnect the user's explicit Quit request.
        let shutdownClient = VaelenCoreClient(
            transport: UnixSocketTransport(path: CoreEndpointPaths().socketPath),
            identity: ClientIdentity(name: "Vaelen.app", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
        )
        do {
            try await shutdownClient.connect()
            let result = try await shutdownClient.shutdown()
            if !result.completed {
                let details = result.components.filter { !$0.succeeded }.map { "\($0.component): \($0.detail)" }.joined(separator: "\n")
                NSLog("Vaelen is quitting after best-effort cleanup; remaining issues: %@", details)
            }
        } catch {
            NSLog("Vaelen Core shutdown request failed; exiting app and relying on Core parent-exit cleanup: %@", error.localizedDescription)
        }
        _ = VaelenActivitySignal.markInactive()
        await shutdownClient.disconnect()
        NSLog("SHUTDOWN_TIMING GUI termination request epoch=%.3f", Date().timeIntervalSince1970)
        VaelenAppDelegate.shared?.terminateAfterCleanQuit()
    }

    private var serviceOperationIsBusy: Bool { serviceOperation != nil }

    var startupServiceIssueMessage: String? {
        guard !startupServiceIssues.isEmpty else { return nil }
        let details = startupServiceIssues.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        return "Saved services are blocked from starting. Resolve the issue and retry Start:\n\(details)"
    }

    private func monitor() async {
        // Bootstrap must run the Core discovery/start path. A lightweight
        // status refresh is only for an already-running Core; using it first
        // would leave the UI in Connecting forever when no Core exists yet.
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            if isShowingRunningSnapshot { await refreshAuthoritativeServiceState() }
            else { await refresh() }
            // Background reconciliation catches changes Vaelen did not
            // initiate. Explicit commands use request/reply plus an immediate
            // authoritative service snapshot and never wait for this timer.
            // Keep projects and the remote PHP catalog out of the periodic
            // path so those diagnostics cannot queue behind lifecycle calls.
        }
    }

    private func refreshMessage(for error: CoreClientError) -> String {
        switch error {
        case .coreUnavailable: return "Core is temporarily unavailable."
        case .protocolIncompatible(let client, let core): return "Protocol mismatch: client \(client), Core \(core)."
        case .coreIncompatible(let reason): return reason
        default: return "Core refresh failed."
        }
    }

    private var isShowingRunningSnapshot: Bool {
        if case .running = state { return true }
        return false
    }

    private func beginRelationshipMutation(_ operation: String) -> Bool {
        guard !relationshipMutationInFlight else { return false }
        relationshipError = nil
        relationshipSnapshotGeneration += 1
        relationshipOperation = operation
        relationshipMutationInFlight = true
        return true
    }

    private func beginServiceOperation(_ operation: String) -> Bool {
        guard !isSettingsFixture else {
            serviceError = "This isolated Settings fixture cannot operate Vaelen Core."
            trustError = serviceError
            return false
        }
        guard serviceOperation == nil else { return false }
        guard client != nil else {
            serviceError = "Vaelen Core is unavailable."
            trustError = serviceError
            return false
        }
        serviceError = nil
        serviceErrorService = nil
        trustError = nil
        serviceOperation = operation
        return true
    }

    /// Explicit commands own their request/reply and authoritative service
    /// refresh. The slower project/catalog refresh remains background
    /// reconciliation and never keeps a completed command's spinner alive.
    private func performServiceCommand(_ operation: String, service: String? = nil, command: @MainActor (VaelenCoreClient) async throws -> Void) async {
        guard beginServiceOperation(operation) else { return }
        let commandClient = makeCoreClient()
        do {
            try await commandClient.connect()
            try await command(commandClient)
            await commandClient.disconnect()
            await refreshAuthoritativeServiceState()
            finishServiceOperation()
        } catch {
            await commandClient.disconnect()
            await refreshAuthoritativeServiceState()
            let reconciledError = service == "dns" && operation == "Starting DNS…"
                ? ServiceControlPresentation.dnsStartFailure(error.localizedDescription, authoritativeStatus: currentDNSStatus)
                : error.localizedDescription
            finishServiceOperation(error: reconciledError, service: service)
        }
    }

    private func makeCoreClient() -> VaelenCoreClient {
        VaelenCoreClient(
            transport: UnixSocketTransport(path: CoreEndpointPaths().socketPath),
            identity: ClientIdentity(name: "Vaelen.app", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
        )
    }

    private func refreshAuthoritativeServiceState() async {
        refreshGeneration += 1 // invalidate any older, slower reconciliation snapshot
        let generation = refreshGeneration
        projectReportsTask?.cancel()
        projectReportsTask = nil
        beginServiceReadinessCheck(generation: generation)
        let refreshClient = makeCoreClient()
        do {
            try await trackedServiceOperation("Core handshake") { try await refreshClient.connect() }
            let status = try await trackedServiceOperation("Core status") { try await refreshClient.status() }
            async let phpTask = trackedIndependentCoreRead("PHP") { try await $0.phpVersions() }
            async let routingTask = trackedIndependentCoreRead("routing") { try await $0.routingStatus() }
            async let dnsTask = trackedIndependentCoreRead("DNS") { try await $0.dnsStatus() }
            async let mysqlTask = trackedIndependentCoreRead("MySQL") { try await $0.mysqlStatus() }
            async let mailpitTask = trackedIndependentCoreRead("Mailpit") { try await $0.mailpitStatus() }
            async let portsTask = trackedIndependentCoreRead("standard-ports") { try await $0.portsStatus() }
            let (php, routing, dns, mysql, mailpit, observedPorts) = await (phpTask, routingTask, dnsTask, mysqlTask, mailpitTask, portsTask)
            guard generation == refreshGeneration else {
                await refreshClient.disconnect()
                return
            }

            let projects: [ProjectWire]
            let tls: TLSStatus?
            let currentPorts: StandardPortsStatus?
            if case .running(_, let currentProjects, _, _, _, let currentTLS, let cachedPorts, _, _) = state {
                projects = currentProjects; tls = currentTLS
                currentPorts = observedPorts ?? cachedPorts
            } else {
                projects = []; tls = nil; currentPorts = nil
            }
            state = .running(status, projects, php, routing, dns, tls, currentPorts, mysql, mailpit)
            startupServiceIssues = status.serviceIssues ?? [:]
            let successCount = [php != nil, routing != nil, dns != nil, mysql != nil, mailpit != nil, observedPorts != nil].filter { $0 }.count
            finishServiceReadinessCheck(CoreServiceReadiness.resolve(serviceIssues: startupServiceIssues, requiredReadCount: 6, completedReadCount: 6, successfulReadCount: successCount))
            if serviceErrorService == "dns", Self.isAuthoritativelyHealthyDNS(dns) {
                let supersededError = serviceError
                serviceError = nil
                serviceErrorService = nil
                if trustError == supersededError { trustError = nil }
            }
            refreshError = nil
            await refreshClient.disconnect()
        } catch {
            await refreshClient.disconnect()
            refreshError = error.localizedDescription
            finishServiceReadinessCheck(.unavailable)
        }
    }

    private func beginPHPRequest(version: String) -> Bool {
        guard !isSettingsFixture else { phpError = "This isolated Settings fixture cannot operate Vaelen Core."; return false }
        guard !phpRequestInFlight else { return false }
        guard client != nil else { phpError = "Vaelen Core is unavailable."; return false }
        phpError = nil
        phpRequestInFlight = true
        phpRequestTarget = version
        return true
    }

    private func finishPHPRequest(error: String? = nil) async {
        await refreshAuthoritativeServiceState()
        phpRequestInFlight = false
        phpRequestTarget = nil
        phpError = error
    }

    private func performPHPCommand(_ version: String, command: @MainActor (VaelenCoreClient) async throws -> Void) async {
        guard beginPHPRequest(version: version) else { return }
        let commandClient = makeCoreClient()
        do {
            try await commandClient.connect()
            try await command(commandClient)
            await commandClient.disconnect()
            await finishPHPRequest()
        } catch {
            await commandClient.disconnect()
            await finishPHPRequest(error: phpErrorMessage(error))
        }
    }

    private func phpErrorMessage(_ error: Error) -> String {
        if case CoreClientError.remote(let payload) = error {
            switch payload.code {
            case .invalidRequest: return payload.message
            default: return payload.message
            }
        }
        return error.localizedDescription
    }

    private func finishServiceOperation(error: String? = nil, service: String? = nil) {
        serviceOperation = nil
        serviceError = error
        trustError = error
        serviceErrorService = error == nil ? nil : service
    }

    private var currentDNSStatus: DNSStatus? {
        guard case .running(_, _, _, _, let dns, _, _, _, _) = state else { return nil }
        return dns
    }

    private static func isAuthoritativelyHealthyDNS(_ dns: DNSStatus?) -> Bool {
        guard let dns else { return false }
        return dns.state == .installed && dns.ownership == .vaelen && dns.responderState == .ownedRunning && dns.health == "healthy"
    }

    private func finishRelationshipMutation(error: Error? = nil) {
        relationshipMutationInFlight = false
        relationshipOperation = nil
        relationshipError = error?.localizedDescription
    }
}

private enum HelperRegistrationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let detail): return "Vaelen could not prepare its privileged DNS helper: \(detail)"
        }
    }
}

/// Small, product-facing presentation constants used by the current shell.
/// This is intentionally local to the app until repeated patterns justify more.
