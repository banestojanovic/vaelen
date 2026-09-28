import SwiftUI
import AppKit
import Observation
import ServiceManagement
import UniformTypeIdentifiers
import os
import VaelenIPC
import VaelenCore

@main
struct VaelenApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(VaelenAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusView(model: model)
        } label: {
            Image(nsImage: VaelenBrand.menuBarImage)
                .accessibilityLabel("Vaelen")
                .onAppear {
                    model.startMonitoring()
                    appDelegate.requestQuit = { Task { await model.quitVaelen() } }
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsMenuCommand()
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Vaelen") { Task { await model.quitVaelen() } }
                    .keyboardShortcut("q")
            }
        }
    }
}

/// Supplied scalable brand variants are kept in the app bundle. The tiny
/// menu-bar artwork is an AppKit template so macOS controls light, dark, and
/// highlighted tinting. Settings uses the supplied icon-only vector as a
/// template beside native text, which stays crisp in both appearances.
@MainActor
private enum VaelenBrand {
    private struct BluePalette {
        let light: Color
        let dark: Color

        func foreground(for scheme: ColorScheme) -> Color {
            scheme == .dark ? dark : light
        }
    }

    // Both endpoints are from the official #38B2F6 → #1B64E9 brand gradient.
    // The brighter endpoint stays legible against dark popover material; the
    // deeper endpoint provides readable contrast on light surfaces.
    private static let blue = BluePalette(
        light: Color(red: 27.0 / 255, green: 100.0 / 255, blue: 233.0 / 255),
        dark: Color(red: 56.0 / 255, green: 178.0 / 255, blue: 246.0 / 255)
    )
    static let accentColor = blue.light
    static func selectedBlue(for scheme: ColorScheme) -> Color { blue.foreground(for: scheme) }
    static let menuBarImage: NSImage = {
        guard let url = Bundle.main.url(forResource: "vaelen-mark-currentcolor", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Vaelen") ?? NSImage()
        }
        image.size = NSSize(width: 21, height: 16.8)
        image.isTemplate = true
        return image
    }()

    static var settingsImage: NSImage {
        guard let url = Bundle.main.url(forResource: "vaelen-mark-dark", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return menuBarImage }
        image.size = NSSize(width: 36, height: 25)
        image.isTemplate = true
        return image
    }

    static let headerMarkDark = loadHeaderMark(resource: "vaelen-mark-dark")
    static let headerMarkWhite = loadHeaderMark(resource: "vaelen-mark-white")
    static let headerMarkBlue: NSImage = {
        guard let url = Bundle.main.url(forResource: "vaelen-mark-blue", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return settingsImage }
        image.isTemplate = false
        return image
    }()

    private static func loadHeaderMark(resource: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return settingsImage }
        // Keep the SVG's intrinsic vector representation and viewBox size. The
        // SwiftUI image below fits it into a 22×16-point frame, allowing AppKit
        // to resolve the vector at the destination's 1×/Retina backing scale.
        image.isTemplate = false
        return image
    }
}

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
    private(set) var phpConfiguration: PHPConfigurationResult?
    private(set) var phpConfigurationError: String?
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
    private var projectSettingsRefreshTask: Task<Void, Never>?
    private var projectRelationshipsRefreshInFlight = false
    private(set) var projectRelationshipsRefreshError: String?

    var savedServiceIntents: Set<String>? {
        guard case .running(let status, _, _, _, _, _, _, _, _) = state else { return nil }
        return status.serviceIntents
    }

    func startupIssue(for service: String) -> String? { startupServiceIssues[service] }
    func isServiceReadPending(_ service: String) -> Bool { pendingServiceReads.contains(service) }

    func notePopoverPresented() {
        let count = earlyProjectList?.count ?? {
            if case .running(_, let projects, _, _, _, _, _, _, _) = state { return projects.count }
            return 0
        }()
        let connection = self.earlyProjectList == nil ? "connecting" : "connected"
        Self.startupLogger.info("startup milestone=popover-view-presented known-projects=\(count) connection=\(connection, privacy: .public)")
    }

    func refresh() async {
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

    func installMySQL() async { await performServiceCommand("Installing MySQL…") { client in _ = try await client.mysqlInstall(MySQLModule.defaultVersion); _ = try await client.mysqlUse(MySQLModule.defaultVersion) } }
    func startMySQL() async { await performServiceCommand("Starting MySQL…") { client in let status = try await client.mysqlStatus(); if status.health == "not-initialized" { _ = try await client.mysqlInitialize() }; _ = try await client.mysqlStart() } }
    func stopMySQL() async { await performServiceCommand("Stopping MySQL…") { client in _ = try await client.mysqlStop() } }
    func installMailpit() async { await performServiceCommand("Installing Mailpit…") { client in _ = try await client.mailpitInstall(MailpitModule.defaultVersion) } }
    func startMailpit() async { await performServiceCommand("Starting Mailpit…") { client in _ = try await client.mailpitStart() } }
    func stopMailpit() async { await performServiceCommand("Stopping Mailpit…") { client in _ = try await client.mailpitStop() } }
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
        guard let client else { phpConfigurationError = "Vaelen Core is not connected."; return }
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
        guard beginRelationshipMutation("Adding workspace folder…"), let client else { return }
        do {
            _ = try await client.park(path: path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            finishRelationshipMutation()
            await refresh()
        } catch {
            finishRelationshipMutation(error: error)
        }
    }

    func removeParkedFolder(_ folder: ParkedPathWire) async {
        guard beginRelationshipMutation("Removing workspace folder…"), let client else { return }
        do {
            try await client.unpark(path: folder.path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            finishRelationshipMutation()
            await refresh()
        } catch {
            finishRelationshipMutation(error: error)
        }
    }

    func linkProject(at path: String) async {
        guard beginRelationshipMutation("Linking project…"), let client else { return }
        do {
            _ = try await client.link(path: path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path, name: nil)
            finishRelationshipMutation()
            await refresh()
        } catch {
            finishRelationshipMutation(error: error)
        }
    }

    func unlinkProject(_ project: ProjectWire) async {
        guard beginRelationshipMutation("Unlinking project…"), let client else { return }
        do {
            try await client.unlink(path: project.path, name: nil, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            finishRelationshipMutation()
            await refresh()
        } catch {
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
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in await self?.monitor() }
    }

    func setProjectSettingsVisible(_ visible: Bool) {
        guard projectSettingsVisible != visible else { return }
        projectSettingsVisible = visible
        if !visible {
            relationshipSnapshotGeneration += 1
            projectSettingsRefreshTask?.cancel()
            projectSettingsRefreshTask = nil
            return
        }

        projectSettingsRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.projectSettingsVisible {
                await self.refreshProjectRelationships()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
    }

    private func refreshProjectRelationships() async {
        guard projectSettingsVisible, !relationshipMutationInFlight,
              !projectRelationshipsRefreshInFlight else { return }
        projectRelationshipsRefreshInFlight = true
        relationshipSnapshotGeneration += 1
        let generation = relationshipSnapshotGeneration
        let refreshClient = makeCoreClient()
        do {
            try await refreshClient.connect()
            let linked = try await refreshClient.linkedProjects()
            let parked = try await refreshClient.parkedPaths()
            guard generation == relationshipSnapshotGeneration,
                  projectSettingsVisible, !relationshipMutationInFlight else {
                await refreshClient.disconnect()
                projectRelationshipsRefreshInFlight = false
                return
            }
            linkedProjects = linked
            parkedFolders = parked
            projectRelationshipsRefreshError = nil
            await refreshClient.disconnect()
        } catch {
            await refreshClient.disconnect()
            if generation == relationshipSnapshotGeneration && projectSettingsVisible {
                projectRelationshipsRefreshError = error.localizedDescription
            }
        }
        projectRelationshipsRefreshInFlight = false
    }

    func quitVaelen() async {
        guard !isQuitting else { return }
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
        guard !refreshInFlight else {
            relationshipError = "Please wait for Vaelen to finish refreshing."
            return false
        }
        guard client != nil else {
            relationshipError = "Vaelen Core is unavailable."
            return false
        }
        relationshipError = nil
        relationshipSnapshotGeneration += 1
        relationshipOperation = operation
        relationshipMutationInFlight = true
        return true
    }

    private func beginServiceOperation(_ operation: String) -> Bool {
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
private enum VaelenUI {
    static let spacing6: CGFloat = 6
    static let spacing8: CGFloat = 8
    static let spacing10: CGFloat = 10
    static let spacing12: CGFloat = 12
    static let popoverPadding: CGFloat = 14
    static let cornerRadius: CGFloat = 11
}

private struct VaelenStatusLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    init(_ title: String, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)
    }
}

private struct VaelenEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: VaelenUI.spacing8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}

private struct ConnectionProgressPanel: View {
    let title: String
    let message: String
    let symbol: String
    var isConnecting = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: VaelenUI.spacing10) {
            if isConnecting && !reduceMotion {
                ProgressView().controlSize(.small).padding(.top, 2)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isConnecting ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 20)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(.subheadline, weight: .semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: VaelenUI.cornerRadius, style: .continuous)
                .fill(colorScheme == .light ? Color.white.opacity(0.72) : Color.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: VaelenUI.cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .light ? 0.07 : 0.10), lineWidth: 0.7)
                }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct VaelenLoadingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Loading")
        } else {
            ProgressView().controlSize(.mini).accessibilityLabel("Loading")
        }
    }
}

private struct HeaderServiceStatus: View {
    let readiness: CoreServiceReadiness
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch readiness {
            case .checking:
                HStack(spacing: 5) {
                    VaelenLoadingIndicator()
                    statusText("Checking services", color: .secondary)
                }
            case .ready:
                HStack(spacing: 5) {
                    Circle()
                        .fill(colorScheme == .light ? Color(hex: 0x168B50) : Color(hex: 0x55D98A))
                        .frame(width: 7, height: 7)
                    statusText("Ready", color: colorScheme == .light ? Color(hex: 0x168B50) : Color(hex: 0x55D98A))
                }
            case .attention:
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    statusText("Needs attention", color: .orange)
                }
            case .unavailable:
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle")
                    statusText("Unavailable", color: .secondary)
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(width: 132, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch readiness {
        case .checking: return "Checking services"
        case .ready: return "Ready"
        case .attention: return "Service needs attention"
        case .unavailable: return "Service status unavailable"
        }
    }

    private func statusText(_ title: String, color: Color) -> some View {
        Text(title).foregroundStyle(color)
    }
}

struct StatusView: View {
    let model: AppModel
    @State private var selectedSection = Section.projects
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focusedSection: Section?
    @FocusState private var focusedFooterControl: FooterControl?
    @State private var hoveredFooterControl: FooterControl?

    private enum Section: Hashable {
        case projects
        case services
    }

    private enum FooterControl: Hashable {
        case refresh
        case settings
        case quit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: VaelenBrand.headerMarkBlue)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Vaelen").font(.system(.headline, weight: .bold))
                    Text("The developer control center for macOS")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.15)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                coreStatus
            }
            switch model.state {
            case .connecting:
                if let projects = model.earlyProjectList {
                    if projects.isEmpty {
                        VaelenEmptyState(title: "No Projects", systemImage: "folder", message: "Core found no projects. Service status is still connecting.")
                            .frame(minHeight: 130)
                    } else {
                        ProjectsView(projects: projects, reports: model.projectReports, model: model)
                    }
                } else {
                    ConnectionProgressPanel(
                        title: "Connecting to Core",
                        message: "Your projects will appear as soon as Core responds.",
                        symbol: "cable.connector"
                    )
                }
            case .unavailable:
                VStack(alignment: .leading, spacing: VaelenUI.spacing8) {
                    ConnectionProgressPanel(
                        title: "Core Unavailable",
                        message: model.coreLaunchError ?? "Vaelen Core could not be reached. Retry or relaunch Vaelen.",
                        symbol: "exclamationmark.circle",
                        isConnecting: false
                    )
                    if let projects = model.earlyProjectList {
                        if projects.isEmpty {
                            VaelenEmptyState(title: "No Projects", systemImage: "folder", message: "Core was reached, but is now unavailable.")
                                .frame(minHeight: 100)
                        } else {
                            ProjectsView(projects: projects, reports: model.projectReports, model: model)
                        }
                    }
                }
            case .incompatible(let reason):
                ConnectionProgressPanel(title: "Core Incompatible", message: reason, symbol: "exclamationmark.triangle", isConnecting: false)
            case .running(let status, let projects, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit):
                if model.refreshError != nil {
                    Label("Refresh failed; showing last known Core state.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 2) {
                    sectionButton(.projects, title: "Projects", symbol: "folder.fill")
                    sectionButton(.services, title: "Services", symbol: "gearshape.2.fill")
                }
                .padding(2)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(colorScheme == .light ? Color(hex: 0xF4F6F8).opacity(0.86) : Color(hex: 0x45474D).opacity(0.92))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(colorScheme == .light ? Color.white.opacity(0.82) : Color.white.opacity(0.15), lineWidth: 0.7)
                        }
                        .shadow(color: Color.black.opacity(colorScheme == .light ? 0.035 : 0.09), radius: 2, x: 0, y: 1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Vaelen section")

                switch selectedSection {
                case .projects:
                    ProjectsView(projects: projects, reports: model.projectReports, model: model)
                case .services:
                    ServicesView(status: status, php: php, routing: routing, dns: dns, tls: tls, ports: ports, mysql: mysql, mailpit: mailpit, model: model)
                }
            }
            if let error = model.serviceError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if shouldSpacerBeforeFooter {
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .controlSize(.small)
                    .buttonStyle(PopoverFooterControlStyle(isEmphasized: footerControlIsHighlighted(.refresh)))
                    .focused($focusedFooterControl, equals: .refresh)
                    .onHover { hoveredFooterControl = $0 ? .refresh : nil }
                    .accessibilityHint("Refresh Vaelen state")
                Spacer()
                Button { presentSettings() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape")
                        Text("Settings")
                    }
                    .contentShape(Rectangle())
                }
                    .controlSize(.small)
                    .buttonStyle(PopoverFooterControlStyle(isEmphasized: footerControlIsHighlighted(.settings)))
                    .focused($focusedFooterControl, equals: .settings)
                    .onHover { hoveredFooterControl = $0 ? .settings : nil }
                Button {
                    Task { await model.quitVaelen() }
                } label: {
                    let isHighlighted = footerControlIsHighlighted(.quit)
                    HStack(spacing: 5) {
                        Image(systemName: "power")
                            .foregroundStyle(Color.red)
                        Text(model.isQuitting ? "Quitting Vaelen…" : "Quit Vaelen")
                            .foregroundStyle(isHighlighted ? Color.red : Color.primary.opacity(0.82))
                    }
                }
                .controlSize(.small)
                .buttonStyle(PopoverFooterControlStyle(isEmphasized: footerControlIsHighlighted(.quit), isDanger: true))
                .focused($focusedFooterControl, equals: .quit)
                .onHover { hoveredFooterControl = $0 ? .quit : nil }
                .accessibilityLabel(model.isQuitting ? "Quitting Vaelen" : "Quit Vaelen")
                .disabled(model.isQuitting)
            }
            .padding(.top, -3)
        }
        .padding(VaelenUI.popoverPadding)
        .frame(width: 420)
        .frame(height: popoverHeight)
        .background {
            if reduceTransparency {
                colorScheme == .light ? Color.white : Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    (colorScheme == .light ? Color(hex: 0xEDF1F5) : Color(hex: 0x45464B))
                        .opacity(colorScheme == .light ? 0.66 : 0.88)
                }
            }
        }
        .onAppear {
            model.notePopoverPresented()
            model.startMonitoring()
            VaelenAppDelegate.shared?.requestQuit = { Task { await model.quitVaelen() } }
        }
    }

    private var popoverHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        if needsCompactConnectionLayout {
            return min(340, max(245, visibleHeight * 0.46))
        }
        let preferred = min(500, visibleHeight * 0.56)
        let usefulMinimum = min(470, visibleHeight * 0.52)
        return max(usefulMinimum, preferred)
    }

    private var needsCompactConnectionLayout: Bool {
        switch model.state {
        case .connecting: return model.earlyProjectList?.isEmpty != false
        case .unavailable: return model.earlyProjectList?.isEmpty != false
        case .incompatible: return true
        case .running: return false
        }
    }

    private var shouldSpacerBeforeFooter: Bool {
        switch model.state {
        case .connecting: return model.earlyProjectList?.isEmpty != false
        case .unavailable: return model.earlyProjectList?.isEmpty != false
        case .incompatible: return true
        case .running(_, let projects, _, _, _, _, _, _, _):
            return selectedSection == .projects && projects.isEmpty
        }
    }

    private func presentSettings() {
        // Settings is an explicit user action from a menu-bar popover. Activate
        // Vaelen first, then make the SwiftUI-created window key once the scene
        // has had a chance to materialize. The window remains a normal window;
        // it is not made floating or repeatedly forced to the front.
        SettingsWindowActivation.activateApplication()
        openSettings()
        DispatchQueue.main.async {
            SettingsWindowActivation.bringForward()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            SettingsWindowActivation.bringForward()
        }
    }

    private func sectionButton(_ section: Section, title: String, symbol: String) -> some View {
        let isSelected = selectedSection == section
        let isFocused = focusedSection == section
        return Button { selectedSection = section } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? VaelenBrand.selectedBlue(for: colorScheme) : Color.primary.opacity(0.60))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(VaelenBrand.selectedBlue(for: colorScheme).opacity(colorScheme == .dark ? 0.23 : 0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(VaelenBrand.selectedBlue(for: colorScheme).opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 0.65)
                    }
            }
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(VaelenBrand.selectedBlue(for: colorScheme), lineWidth: 2)
            }
        }
        .focused($focusedSection, equals: section)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(section == .projects ? "Show projects and sites" : "Show runtime and service controls")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func footerControlIsHighlighted(_ control: FooterControl) -> Bool {
        focusedFooterControl == control || hoveredFooterControl == control
    }

    @ViewBuilder
    private var coreStatus: some View {
        switch model.state {
        case .connecting:
            if model.earlyProjectList == nil {
                VaelenStatusLabel("Connecting", systemImage: "circle.dotted", tint: .secondary)
                    .frame(width: 132, alignment: .trailing)
            } else {
                HeaderServiceStatus(readiness: model.serviceReadiness)
            }
        case .running:
            HeaderServiceStatus(readiness: model.serviceReadiness)
        case .unavailable:
            VaelenStatusLabel("Core Unavailable", systemImage: "circle", tint: .secondary)
                .frame(width: 132, alignment: .trailing)
        case .incompatible:
            VaelenStatusLabel("Core Incompatible", systemImage: "exclamationmark.circle", tint: .orange)
                .frame(width: 132, alignment: .trailing)
        }
    }
}

private struct PopoverFooterControlStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var isEmphasized = false
    var isDanger = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.68 : 0.80))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor(configuration: configuration))
            }
            .overlay {
                if isEmphasized {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isDanger
                                      ? Color.red.opacity(0.26)
                                      : Color.primary.opacity(colorScheme == .light ? 0.10 : 0.18), lineWidth: 0.6)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isEmphasized)
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        guard isEmphasized else { return .clear }
        if isDanger {
            return Color.red.opacity(configuration.isPressed
                                    ? (colorScheme == .light ? 0.15 : 0.23)
                                    : (colorScheme == .light ? 0.075 : 0.13))
        }
        return Color.primary.opacity(configuration.isPressed
                                     ? (colorScheme == .light ? 0.075 : 0.16)
                                     : (colorScheme == .light ? 0.045 : 0.10))
    }
}

@MainActor
private enum SettingsWindowActivation {
    private static var closeObserver: NSObjectProtocol?

    static func activateApplication() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    static func bringForward() {
        guard let window = NSApplication.shared.windows.first(where: {
            $0.isVisible && $0.title.localizedCaseInsensitiveContains("Settings")
        }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // A menu-bar-only application has accessory activation policy, which
        // permits the window to order above another app but does not make it
        // the active application. Temporarily use normal application
        // activation while the user-owned Settings window is open, restoring
        // the menu-bar-only policy when that window closes.
        NSApplication.shared.setActivationPolicy(.regular)
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                NSApplication.shared.setActivationPolicy(.accessory)
                if let observer = closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    closeObserver = nil
                }
            }
        }
        window.orderFrontRegardless()
        activateApplication()
        window.makeKeyAndOrderFront(nil)
        activateApplication()
    }
}

private struct SettingsMenuCommand: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            SettingsWindowActivation.activateApplication()
            openSettings()
            DispatchQueue.main.async {
                SettingsWindowActivation.bringForward()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                SettingsWindowActivation.bringForward()
            }
        }
    }
}

private struct PopoverSectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.45)
    }
}

struct ProjectsView: View {
    let projects: [ProjectWire]
    let reports: [ProjectEnvironmentReport]
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedProjectPaths = Set<String>()

    var body: some View {
        if projects.isEmpty {
            VaelenEmptyState(title: "No Projects", systemImage: "folder", message: "Known Core projects will appear here.")
                .frame(minHeight: 180)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ProjectFrameworkGroup.allCases, id: \.self) { group in
                        let groupedProjects = projects.filter { ProjectFrameworkGroup(project: $0) == group }
                        if !groupedProjects.isEmpty {
                            let firstGroup = ProjectFrameworkGroup.allCases.first {
                                candidate in projects.contains { ProjectFrameworkGroup(project: $0) == candidate }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                PopoverSectionHeading(title: group.title)
                                    .padding(.horizontal, 9)
                                    .padding(.top, group == firstGroup ? 14 : 20)
                                    .padding(.bottom, 3)
                                ForEach(Array(groupedProjects.enumerated()), id: \.element.path) { index, project in
                                    let report = reports.first { $0.identity.path == project.path }
                                    let routes = routesForProject(project, report: report, configured: model.configuredRoutes)
                                    ProjectCard(
                                        project: project,
                                        report: report,
                                        reportError: model.projectReportErrors[project.path],
                                        routes: routes,
                                        model: model,
                                        isExpanded: expandedProjectPaths.contains(project.path),
                                        toggleExpansion: { toggleExpansion(for: project) }
                                    )
                                    Divider()
                                        .opacity(0.3)
                                        .padding(.horizontal, 9)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func toggleExpansion(for project: ProjectWire) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            if expandedProjectPaths.contains(project.path) {
                expandedProjectPaths.remove(project.path)
            } else {
                expandedProjectPaths.insert(project.path)
            }
        }
    }
}

private enum ProjectFrameworkGroup: CaseIterable {
    case expo, laravel, wordpress, other

    init(project: ProjectWire) {
        let framework = project.detectedFramework?.lowercased() ?? ""
        if framework.contains("expo") { self = .expo }
        else if framework.contains("laravel") { self = .laravel }
        else if framework.contains("wordpress") { self = .wordpress }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .expo: "Expo"
        case .laravel: "Laravel"
        case .wordpress: "WordPress"
        case .other: "Other"
        }
    }
}

private func routesForProject(_ project: ProjectWire, report: ProjectEnvironmentReport?, configured: [RouteIntent]?) -> [RouteIntent]? {
    guard let configured else { return nil }
    let verifiedDocumentRoot = report?.derived.framework.suggestedDocumentRoot.map {
        URL(fileURLWithPath: project.path).appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath().path
    }
    return ProjectRouteAttribution.routes(for: project.id, verifiedDocumentRoot: verifiedDocumentRoot, from: configured)
}

struct ProjectCard: View {
    let project: ProjectWire
    let report: ProjectEnvironmentReport?
    let reportError: String?
    let routes: [RouteIntent]?
    let model: AppModel
    let isExpanded: Bool
    let toggleExpansion: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private enum FocusedControl: Hashable { case site, database, expansion }
    @FocusState private var focusedControl: FocusedControl?
    @State private var hoveredControl: FocusedControl?
    @State private var rowHovered = false

    private var warnings: [ProjectDiagnostic] {
        guard let report, report.identity.registration == .linked else { return [] }
        return report.diagnostics.filter { $0.severity == .warning || $0.severity == .error }
    }

    private var headerAlertMessages: [String] {
        var messages = warnings.map(\.message)
        if project.availability != PathAvailability.available.rawValue {
            messages.append("Project folder unavailable")
        }
        if let routeError = model.configuredRoutesError {
            messages.append(routeError)
        }
        return messages
    }

    private var databaseAction: ProjectDatabaseViewerAction? {
        guard let report else { return nil }
        return ProjectDatabaseViewerAction.tablePlus(report: report, tablePlusInstalled: model.isTablePlusInstalled)
    }

    private var canOpenDatabase: Bool { databaseAction?.isEnabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 7) {
                FrameworkMark(framework: project.detectedFramework)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(project.name)
                    .font(.system(.headline, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(project.name)
                Spacer(minLength: 3)
                HStack(spacing: 1) {
                    Group {
                        if let warning = warnings.first {
                            Image(systemName: warning.severity == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(warning.severity == .error ? Color.red : Color.orange)
                        } else if !headerAlertMessages.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(width: 25, height: 25)
                    .help(headerAlertMessages.joined(separator: "\n"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(headerAlertMessages.joined(separator: ". "))
                    Group {
                        if let route = routes?.first, routes?.count == 1 {
                            Button { model.openProjectRoute(route) } label: {
                                Image(systemName: "safari")
                                    .frame(width: 25, height: 25)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusedControl, equals: .site)
                            .onHover { hoveredControl = $0 ? .site : nil }
                            .background { actionBackground(for: .site) }
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(focusedControl == .site ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                            }
                            .help("Open \(route.route.hostname)")
                            .accessibilityLabel("Open site \(route.route.hostname)")
                        } else if let routes, routes.count > 1 {
                            Menu {
                                ForEach(Array(routes.enumerated()), id: \.element.route.id) { _, route in
                                    Button(route.route.hostname, systemImage: route.route.tls == .local ? "lock.fill" : "globe") { model.openProjectRoute(route) }
                                }
                            } label: {
                                Image(systemName: "safari").frame(width: 25, height: 25).contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .focused($focusedControl, equals: .site)
                            .onHover { hoveredControl = $0 ? .site : nil }
                            .background { actionBackground(for: .site) }
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(focusedControl == .site ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                            }
                            .help("Open a project site")
                            .accessibilityLabel("Open site; \(routes.count) hosts available")
                        }
                    }
                    .frame(width: 25, height: 25)
                    Group {
                        if canOpenDatabase {
                            Button { model.openProjectDatabaseInTablePlus(report!) } label: {
                                Image(systemName: "cylinder.split.1x2")
                                    .frame(width: 25, height: 25)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusedControl, equals: .database)
                            .onHover { hoveredControl = $0 ? .database : nil }
                            .background { actionBackground(for: .database) }
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(focusedControl == .database ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                            }
                            .help(databaseAction?.reason ?? "Open project database in TablePlus")
                            .accessibilityLabel("Open project database in TablePlus")
                        }
                    }
                    .frame(width: 25, height: 25)
                    Button(action: toggleExpansion) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 25, height: 25)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedControl, equals: .expansion)
                    .onHover { hoveredControl = $0 ? .expansion : nil }
                    .background { actionBackground(for: .expansion) }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(focusedControl == .expansion ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                    }
                    .frame(width: 25, height: 25)
                    .help(isExpanded ? "Collapse project details" : "Expand project details")
                    .accessibilityLabel(isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                }
                .font(.system(size: 11, weight: .medium))
            }

            runtimeSummary
            if isExpanded { expandedDetails }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowHovered || focusedControl != nil
                      ? Color.primary.opacity(colorScheme == .light ? 0.045 : 0.10)
                      : .clear)
        }
        .onHover { rowHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project \(project.name)")
    }

    private func actionBackground(for control: FocusedControl) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(hoveredControl == control || focusedControl == control
                  ? Color.primary.opacity(colorScheme == .light ? 0.075 : 0.16)
                  : .clear)
    }

    @ViewBuilder private var runtimeSummary: some View {
        if let report {
            HStack(spacing: 7) {
                if let version = report.observed.php.resolvedVersion {
                    runtimeBadge("PHP", version: version, state: report.observed.php.fpmHealth)
                }
                if report.desired.mysql == true, let mysql = report.observed.mysql {
                    runtimeBadge("MySQL", version: mysql.selectedVersion ?? mysql.installedVersion, state: "\(mysql.state.rawValue) \(mysql.health)")
                }
                if report.desired.mailpit == true, let mailpit = report.observed.mailpit {
                    runtimeBadge("Mailpit", version: mailpit.installedVersion, state: "\(mailpit.state.rawValue) \(mailpit.health)")
                }
            }
            .padding(.leading, 25)
        } else if let reportError {
            Label(reportError, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.leading, 25)
        } else {
            HStack(spacing: 5) {
                VaelenLoadingIndicator()
                Text("Loading project details…").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.leading, 25)
        }
    }

    private func runtimeBadge(_ name: String, version: String?, state: String) -> some View {
        let healthy = state.split(separator: " ").last?.caseInsensitiveCompare("healthy") == .orderedSame
        return HStack(spacing: 3) {
            Image(systemName: healthy ? "circle.fill" : "circle")
                .font(.system(size: 6, weight: .semibold))
                .foregroundStyle(healthy ? Color.green : Color.secondary)
            Text(name)
            if let version { Text(version).foregroundStyle(.secondary) }
        }
        .font(.system(size: 10, weight: .medium))
        .help("\(name) \(version ?? "") · \(state)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(version ?? "version unavailable"), \(state)")
    }

    @ViewBuilder private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(displayPath(project.path))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(project.path)
            if let routes, routes.count > 1 {
                ForEach(routes, id: \.route.id) { route in
                    HStack(spacing: 6) {
                        Image(systemName: route.route.tls == .local ? "lock.fill" : "globe")
                            .foregroundStyle(route.route.tls == .local ? Color.green : Color.secondary)
                        Text(route.route.hostname).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Open") { model.openProjectRoute(route) }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
            }
            if routes == nil {
                Label(model.configuredRoutesError ?? "Site route state unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if project.availability != PathAvailability.available.rawValue {
                Label("Project folder unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !warnings.isEmpty {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: warning.severity == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(warning.severity == .error ? Color.red : Color.orange)
                            .frame(width: 14, alignment: .leading)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.message)
                                .font(.caption)
                                .foregroundStyle(warning.severity == .error ? Color.red : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            if let suggestion = warning.suggestion {
                                Text(suggestion)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack(spacing: 12) {
                Button {
                    model.openProjectFolder(project)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                        Text("Open Folder")
                    }
                }
                    .accessibilityLabel("Open Folder")
                    .disabled(!model.canOpenProjectFolder(project))
                Button {
                    model.openProjectInEditor(project)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "curlybraces")
                        Text("Open in Editor")
                    }
                }
                    .accessibilityLabel("Open in Editor")
                    .disabled(!model.canOpenProjectFolder(project))
                Button {
                    model.copyProjectPath(project)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy Path")
                    }
                }
                    .accessibilityLabel("Copy Path")
            }
            .buttonStyle(.borderless).controlSize(.small)
        }
        .font(.caption)
            .padding(.leading, 25)
        .padding(.top, 3)
        .transition(.identity)
    }

    private func environmentSummary(_ report: ProjectEnvironmentReport) -> String? {
        var values = [String]()
            if let version = report.observed.php.resolvedVersion {
                values.append("PHP \(version.split(separator: ".").prefix(2).joined(separator: "."))" + (report.observed.php.overrideVersion == nil ? "" : " · Project Override"))
            } else if let override = report.observed.php.overrideVersion {
                values.append("PHP \(override) · Unavailable")
        }
        if report.desired.mysql == true, let mysql = report.observed.mysql, let version = mysql.selectedVersion ?? mysql.installedVersion {
            values.append("MySQL \(version)")
        }
        if model.projectSiteURL(report)?.scheme == "https" { values.append("HTTPS ✓") }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

}

private struct FrameworkLogo {
    let asset: String
    let color: Color
    let needsDarkModeBacking: Bool
}

private struct FrameworkMark: View {
    let framework: String?
    @Environment(\.colorScheme) private var colorScheme

    private var logo: FrameworkLogo? {
        guard let framework = framework?.lowercased() else { return nil }
        if framework.contains("expo") { return .init(asset: "Framework-expo", color: Color(hex: 0x1C2024), needsDarkModeBacking: true) }
        if framework.contains("react") { return .init(asset: "Framework-react", color: Color(hex: 0x61DAFB), needsDarkModeBacking: false) }
        if framework.contains("laravel") { return .init(asset: "Framework-laravel", color: Color(hex: 0xFF2D20), needsDarkModeBacking: false) }
        if framework.contains("next") { return .init(asset: "Framework-nextdotjs", color: Color(hex: 0x000000), needsDarkModeBacking: true) }
        if framework.contains("wordpress") { return .init(asset: "Framework-wordpress", color: Color(hex: 0x21759B), needsDarkModeBacking: false) }
        if framework.contains("symfony") { return .init(asset: "Framework-symfony", color: Color(hex: 0x000000), needsDarkModeBacking: true) }
        if framework.contains("drupal") { return .init(asset: "Framework-drupal", color: Color(hex: 0x0678BE), needsDarkModeBacking: false) }
        if framework.contains("magento") { return nil }
        if framework.contains("nuxt") { return .init(asset: "Framework-nuxt", color: Color(hex: 0x00DC82), needsDarkModeBacking: false) }
        if framework.contains("svelte") { return .init(asset: "Framework-svelte", color: Color(hex: 0xFF3E00), needsDarkModeBacking: false) }
        if framework.contains("astro") { return .init(asset: "Framework-astro", color: Color(hex: 0xBC52EE), needsDarkModeBacking: false) }
        if framework.contains("vue") { return .init(asset: "Framework-vuedotjs", color: Color(hex: 0x4FC08D), needsDarkModeBacking: false) }
        if framework.contains("angular") { return .init(asset: "Framework-angular", color: Color(hex: 0x0F0F11), needsDarkModeBacking: true) }
        return nil
    }

    var body: some View {
        if let logo, NSImage(named: logo.asset) != nil {
            Image(logo.asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(colorScheme == .dark && logo.needsDarkModeBacking ? Color(hex: 0xF2F3F5) : logo.color)
                .background {
                    if colorScheme == .dark && logo.needsDarkModeBacking {
                        Circle().fill(Color.white.opacity(0.10))
                    }
                }
        } else {
            Image(systemName: "globe.desk")
                .resizable().scaledToFit().padding(3)
                .foregroundStyle(.secondary)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private struct ServicePresentation {
    let title: String
    let symbol: String
    let tint: Color

    init(_ title: String, _ symbol: String, _ tint: Color) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }
}

private struct ServiceIconButton: View {
    enum Emphasis { case start, stop }

    let label: String
    let systemImage: String
    var emphasis: Emphasis? = nil
    var disabled = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var emphasisTint: Color? {
        switch emphasis {
        case .start: return colorScheme == .light ? Color(hex: 0x398258) : Color(hex: 0x79C895)
        case .stop: return colorScheme == .light ? Color(hex: 0xB44F46) : Color(hex: 0xE98578)
        case nil: return nil
        }
    }

    private var feedbackVisible: Bool { hovered || focused }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(disabled ? Color.primary.opacity(0.38) : (emphasisTint ?? Color.primary.opacity(0.78)))
        .disabled(disabled)
        .focused($focused)
        .focusable()
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(feedbackVisible ? (emphasisTint ?? Color.accentColor).opacity(0.12) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(feedbackVisible ? (emphasisTint ?? Color.accentColor).opacity(0.38) : .clear, lineWidth: 1)
        }
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ServiceRow<Actions: View>: View {
    let icon: String
    let title: String
    let version: String?
    let state: String
    let stateSymbol: String
    let stateTint: Color
    let pending: Bool
    let busy: Bool
    let actions: Actions

    init(
        icon: String,
        title: String,
        version: String?,
        state: String,
        stateSymbol: String,
        stateTint: Color,
        pending: Bool = false,
        busy: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.version = version
        self.state = state
        self.stateSymbol = stateSymbol
        self.stateTint = stateTint
        self.pending = pending
        self.busy = busy
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: VaelenUI.spacing8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.72))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .regular))
                    .lineLimit(1)
                if let version, !version.isEmpty {
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(version)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: 3) {
                HStack(spacing: 3) {
                    if pending {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Checking \(title) status")
                        Text("Checking")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: stateSymbol)
                            .foregroundStyle(stateTint)
                        Text(state)
                            .foregroundStyle(stateTint)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("\(title) operation in progress")
                }
                actions
                    .disabled(busy || pending)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(pending ? "Checking" : state)")
    }
}

struct ServicesView: View {
    let status: CoreStatusResponse
    let php: PHPVersionsResult?
    let routing: RouterStatus?
    let dns: DNSStatus?
    let tls: TLSStatus?
    let ports: StandardPortsStatus?
    let mysql: MySQLStatus?
    let mailpit: MailpitStatus?
    let model: AppModel
    @State private var showingTrustGuidance = false

    var body: some View {
        Group {
            if showingTrustGuidance, let tls {
                let trustControl = TLSTrustControlPresentation(tls)
                if trustControl.canManageTrust {
                    let details = trustControl.manageTrustDetails(caFingerprint: tls.caFingerprint, certificatePath: tls.caCertificatePath)
                    LocalCATrustDetailsView(
                        fingerprint: details?.fingerprint,
                        certificatePath: details?.certificatePath,
                        explanation: details?.explanation ?? "Trust details are unavailable. Do not change any Keychain trust setting.",
                        manualSteps: details?.manualSteps
                    ) {
                        showingTrustGuidance = false
                    }
                } else {
                    servicesList
                }
            } else {
                servicesList
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var servicesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Runtimes", first: true)
                phpRow

                sectionTitle("Services")
                mysqlRow
                caddyRow
                mailpitRow

                sectionTitle("Networking")
                dnsRow
                tlsRow
                portsRow

                if let operation = model.serviceOperation {
                    VaelenStatusLabel(operation, systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
                        .font(.caption)
                        .padding(.top, VaelenUI.spacing8)
                }
                if let error = model.serviceError ?? model.trustError ?? model.startupServiceIssueMessage {
                    VaelenStatusLabel(error, systemImage: "exclamationmark.triangle", tint: .red)
                        .font(.caption)
                        .padding(.top, VaelenUI.spacing8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func sectionTitle(_ title: String, first: Bool = false) -> some View {
        PopoverSectionHeading(title: title)
            .padding(.top, first ? VaelenUI.spacing12 : 18)
            .padding(.bottom, 4)
    }

    private func resolved(_ value: ServicePresentation?, readLabel: String, present: Bool) -> (ServicePresentation, Bool) {
        let pending = !present && model.isServiceReadPending(readLabel)
        if let value { return (value, false) }
        if pending { return (.init("Checking", "circle.dotted", .secondary), true) }
        return (.init("Unavailable", "exclamationmark.triangle", .orange), false)
    }

    private var phpRow: some View {
        let isPending = model.isServiceReadPending("PHP") && php == nil
        let state: ServicePresentation
        if let php {
            state = php.default != nil
                ? .init("Default", "checkmark.circle", .secondary)
                : (php.installed.isEmpty ? .init("Not installed", "circle", .secondary) : .init("Ready", "checkmark.circle", .secondary))
        } else {
            state = isPending ? .init("Checking", "circle.dotted", .secondary) : .init("Unavailable", "exclamationmark.triangle", .orange)
        }
        return ServiceRow(icon: "chevron.left.forwardslash.chevron.right", title: "PHP", version: php.map { $0.installed.map(\.version).joined(separator: " · ") }, state: state.title, stateSymbol: state.symbol, stateTint: state.tint, pending: isPending) {
            HStack(spacing: 3) {
                if php != nil {
                    ServiceIconButton(label: "Open PHP Configuration Files", systemImage: "doc.text.magnifyingglass") {
                        Task { await model.openPHPConfigurationFiles() }
                    }
                } else if !isPending {
                    ServiceIconButton(label: "Refresh PHP status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var mysqlRow: some View {
        let pending = model.isServiceReadPending("MySQL") && mysql == nil
        let state = resolved(mysql.map(mysqlState), readLabel: "MySQL", present: mysql != nil).0
        let busy = model.serviceOperationIs(for: "MySQL")
        return ServiceRow(icon: "cylinder.fill", title: "MySQL", version: mysql?.selectedVersion ?? mysql?.installedVersion, state: state.title, stateSymbol: state.symbol, stateTint: state.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                let tablePlus = MySQLDatabaseViewerAction.tablePlus(mysql: mysql, tablePlusInstalled: model.isTablePlusInstalled)
                ServiceIconButton(
                    label: pending ? "Checking MySQL and TablePlus availability" : tablePlus.reason,
                    systemImage: "cylinder.split.1x2",
                    disabled: pending || !tablePlus.isEnabled
                ) {
                    if let mysql { model.openMySQLInTablePlus(mysql) }
                }
                if let mysql {
                    if mysql.state == .notInstalled {
                        ServiceIconButton(label: "Install MySQL", systemImage: "arrow.down.to.line") { Task { await model.installMySQL() } }
                    } else if mysql.state == .stopped || mysql.state == .installed || mysql.state == .unhealthy {
                        ServiceIconButton(label: mysql.health == "not-initialized" ? "Initialize and Start MySQL" : "Start MySQL", systemImage: "play.circle", emphasis: .start) { Task { await model.startMySQL() } }
                    }
                    if mysql.state == .running {
                        ServiceIconButton(label: "Stop MySQL", systemImage: "stop.circle", emphasis: .stop) { Task { await model.stopMySQL() } }
                    }
                    if mysql.state != .notInstalled {
                        ServiceIconButton(label: "Reveal MySQL Data Files", systemImage: "folder", disabled: !FileManager.default.fileExists(atPath: mysql.datadir)) { model.revealMySQLDataFiles(mysql) }
                        ServiceIconButton(label: "Reveal MySQL Binaries", systemImage: "shippingbox", disabled: !FileManager.default.fileExists(atPath: mysql.executablePath)) { model.revealMySQLBinaries(mysql) }
                    }
                } else if !pending {
                    ServiceIconButton(label: "Refresh MySQL status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var caddyRow: some View {
        let pending = model.isServiceReadPending("routing") && routing == nil
        let state = resolved(routing.map(routingState), readLabel: "routing", present: routing != nil).0
        let busy = model.serviceOperationIs(for: "Caddy")
        return ServiceRow(icon: "globe", title: "Caddy", version: routing?.providerVersion, state: state.title, stateSymbol: state.symbol, stateTint: state.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let routing {
                    if routing.state == .running {
                        ServiceIconButton(label: "Stop Caddy", systemImage: "stop.circle", emphasis: .stop) { Task { await model.stopRouting() } }
                    } else {
                        ServiceIconButton(label: "Start Caddy", systemImage: "play.circle", emphasis: .start) { Task { await model.startRouting() } }
                    }
                } else if !pending {
                    ServiceIconButton(label: "Refresh Caddy status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var mailpitRow: some View {
        let pending = model.isServiceReadPending("Mailpit") && mailpit == nil
        let state = resolved(mailpit.map(mailpitState), readLabel: "Mailpit", present: mailpit != nil).0
        let busy = model.serviceOperationIs(for: "Mailpit")
        return ServiceRow(icon: "envelope.fill", title: "Mailpit", version: mailpit?.installedVersion, state: state.title, stateSymbol: state.symbol, stateTint: state.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let mailpit {
                    if mailpit.state == .notInstalled {
                        ServiceIconButton(label: "Install Mailpit", systemImage: "arrow.down.to.line") { Task { await model.installMailpit() } }
                    } else if mailpit.state == .installed || mailpit.state == .stopped || mailpit.state == .unhealthy || mailpit.state == .conflict {
                        ServiceIconButton(label: "Start Mailpit", systemImage: "play.circle", emphasis: .start) { Task { await model.startMailpit() } }
                    }
                    if mailpit.state == .running {
                        ServiceIconButton(label: "Stop Mailpit", systemImage: "stop.circle", emphasis: .stop) { Task { await model.stopMailpit() } }
                        ServiceIconButton(label: "Open Mailpit", systemImage: "arrow.up.right.square") { Task { await model.openMailpit() } }
                    }
                } else if !pending {
                    ServiceIconButton(label: "Refresh Mailpit status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var dnsRow: some View {
        let pending = model.isServiceReadPending("DNS") && dns == nil
        let control = dns.map { ServiceControlPresentation.dns(status: $0, savedOn: model.savedServiceIntents?.contains("dns"), blockedReason: model.startupIssue(for: "dns")) }
        let state = control.map { ServicePresentation($0.title, serviceSymbol($0.title), serviceTint($0.title)) }
        let resolvedState = resolved(state, readLabel: "DNS", present: dns != nil).0
        let busy = model.serviceOperationIs(for: "DNS")
        return ServiceRow(icon: "network", title: "DNS", version: dns.map { "Port \($0.port)" }, state: resolvedState.title, stateSymbol: resolvedState.symbol, stateTint: resolvedState.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let control {
                    if control.action == .enable { ServiceIconButton(label: "Enable DNS", systemImage: "power") { Task { await model.startDNS() } } }
                    if control.action == .retry { ServiceIconButton(label: "Retry DNS Start", systemImage: "arrow.clockwise") { Task { await model.startDNS() } } }
                    if control.action == .stop || control.action == .disable { ServiceIconButton(label: "Stop DNS", systemImage: "stop.circle", emphasis: .stop) { Task { await model.stopDNS() } } }
                    if control.canDisable && control.action == .retry { ServiceIconButton(label: "Disable DNS", systemImage: "power") { Task { await model.stopDNS() } } }
                } else if !pending {
                    ServiceIconButton(label: "Refresh DNS status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var tlsRow: some View {
        let pending = model.isServiceReadPending("TLS") && tls == nil
        let trust = tls.map(TLSTrustControlPresentation.init)
        let state: ServicePresentation?
        if let tls, let trust {
            state = .init(trust.title, tls.trustObserved ? "checkmark.circle.fill" : "exclamationmark.triangle", tls.trustObserved ? .green : .orange)
        } else {
            state = nil
        }
        let resolvedState = resolved(state, readLabel: "TLS", present: tls != nil).0
        let busy = model.serviceOperationIs(for: "Local HTTPS")
        return ServiceRow(icon: "lock.fill", title: "Local HTTPS", version: tls.map { "Port \($0.tlsPort)" }, state: resolvedState.title, stateSymbol: resolvedState.symbol, stateTint: resolvedState.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let trust {
                    if trust.canTrust { ServiceIconButton(label: "Trust Local CA", systemImage: "lock.open.fill") { Task { await model.trustLocalCA() } } }
                    if trust.canRemove { ServiceIconButton(label: "Remove Local CA Trust", systemImage: "lock.slash") { Task { await model.removeLocalCATrust() } } }
                    if trust.canManageTrust { ServiceIconButton(label: "Manage Local CA Trust", systemImage: "info.circle") { showingTrustGuidance = true } }
                } else if !pending {
                    ServiceIconButton(label: "Refresh Local HTTPS status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var portsRow: some View {
        let pending = model.isServiceReadPending("standard-ports") && ports == nil
        let control = ports.map { ServiceControlPresentation.standardPorts(status: $0, savedOn: model.savedServiceIntents?.contains("standard-ports"), blockedReason: model.startupIssue(for: "standard-ports")) }
        let state = control.map { ServicePresentation($0.title, serviceSymbol($0.title), serviceTint($0.title)) }
        let resolvedState = resolved(state, readLabel: "standard-ports", present: ports != nil).0
        let busy = model.serviceOperationIs(for: "standard ports")
        return ServiceRow(icon: "cable.connector", title: "Standard Ports", version: ports.map { "\($0.httpPort) · \($0.httpsPort)" }, state: resolvedState.title, stateSymbol: resolvedState.symbol, stateTint: resolvedState.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let control {
                    if control.action == .enable { ServiceIconButton(label: "Enable Standard Ports", systemImage: "power", emphasis: .start) { Task { await model.installStandardPorts() } } }
                    if control.action == .retry { ServiceIconButton(label: "Retry Standard Ports", systemImage: "arrow.clockwise") { Task { await model.installStandardPorts() } } }
                    if control.action == .disable { ServiceIconButton(label: "Disable Standard Ports", systemImage: "stop.circle", emphasis: .stop) { Task { await model.removeStandardPorts() } } }
                } else if !pending {
                    ServiceIconButton(label: "Refresh Standard Ports status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private func mysqlState(_ mysql: MySQLStatus) -> ServicePresentation {
        switch mysql.state {
        case .running where mysql.health == "healthy": return .init("Running", "checkmark.circle.fill", .green)
        case .notInstalled: return .init("Not installed", "circle", .secondary)
        case .conflict, .unhealthy: return .init("Needs attention", "exclamationmark.triangle", .orange)
        case .stopped, .installed: return .init("Stopped", "pause.circle", .secondary)
        default: return .init(mysql.state.rawValue.capitalized, "arrow.triangle.2.circlepath", .secondary)
        }
    }

    private func mailpitState(_ mailpit: MailpitStatus) -> ServicePresentation {
        switch mailpit.state {
        case .running where mailpit.health == "healthy": return .init("Running", "checkmark.circle.fill", .green)
        case .notInstalled: return .init("Not installed", "circle", .secondary)
        case .conflict, .unhealthy: return .init("Needs attention", "exclamationmark.triangle", .orange)
        case .stopped, .installed: return .init("Stopped", "pause.circle", .secondary)
        default: return .init(mailpit.state.rawValue.capitalized, "arrow.triangle.2.circlepath", .secondary)
        }
    }

    private func routingState(_ routing: RouterStatus) -> ServicePresentation {
        routing.state == .running && routing.health == .healthy ? .init("Running", "checkmark.circle.fill", .green) : (routing.state == .stopped ? .init("Stopped", "pause.circle", .secondary) : .init("Needs attention", "exclamationmark.triangle", .orange))
    }

    private func serviceSymbol(_ title: String) -> String {
        if title == "Needs attention" || title == "State unavailable" { return "exclamationmark.triangle" }
        if title.localizedCaseInsensitiveContains("start") || title.localizedCaseInsensitiveContains("check") { return "arrow.triangle.2.circlepath" }
        if title.hasPrefix("On") || title == "Enabled" || title == "Ready" || title == "Trusted" { return "checkmark.circle.fill" }
        if title == "Off" || title == "Stopped" || title == "Disabled" { return "pause.circle" }
        return "circle"
    }

    private func serviceTint(_ title: String) -> Color {
        if title == "Needs attention" || title == "State unavailable" { return .orange }
        if title == "Running" || title.hasPrefix("On") || title == "Enabled" || title == "Trusted" { return .green }
        return .secondary
    }

}

private struct LocalCATrustDetailsView: View {
    let fingerprint: String?
    let certificatePath: String?
    let explanation: String
    let manualSteps: String?
    let onBack: () -> Void
    @State private var copiedFingerprint = false

    var body: some View {
        VStack(alignment: .leading, spacing: VaelenUI.spacing10) {
            HStack {
                Button("Back to Services", systemImage: "chevron.backward", action: onBack)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Returns to the Services list and keeps the Vaelen popover open.")
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: VaelenUI.spacing12) {
                    Text("Manage Local CA Trust")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    VStack(alignment: .leading, spacing: VaelenUI.spacing8) {
                        if let fingerprint, !fingerprint.isEmpty {
                            Text("CA certificate SHA-256")
                                .font(.subheadline.weight(.semibold))
                            Text(fingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("CA certificate SHA-256 fingerprint: \(fingerprint)")
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fingerprint, forType: .string)
                                copiedFingerprint = true
                            } label: {
                                Label(copiedFingerprint ? "Copied" : "Copy SHA-256", systemImage: copiedFingerprint ? "checkmark" : "doc.on.doc")
                            }
                            .accessibilityLabel(copiedFingerprint ? "Fingerprint copied" : "Copy CA SHA-256 fingerprint")
                            .accessibilityHint("Copies the full CA certificate fingerprint to the clipboard.")
                            .accessibilityIdentifier("localCATrust.copyFingerprint")
                        } else {
                            VaelenStatusLabel("CA fingerprint unavailable. Do not change any Keychain trust setting.", systemImage: "exclamationmark.triangle", tint: .orange)
                                .font(.caption)
                        }

                        if let certificatePath, !certificatePath.isEmpty {
                            Text("Certificate file: \(certificatePath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(VaelenUI.spacing8)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: VaelenUI.cornerRadius))

                    Text(explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel("Why automatic trust removal is unavailable and safe manual Keychain instructions")
                    if let manualSteps {
                        Text(manualSteps)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, VaelenUI.spacing6)
            }
            .accessibilityLabel("Local CA trust details")
        }
        .padding(VaelenUI.spacing12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}

struct SettingsView: View {
    let model: AppModel
    @State private var selection = SettingsPage.general

    private enum SettingsPage: Hashable { case general, projects, php }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("GENERAL") {
                    Label("General", systemImage: "gearshape").tag(SettingsPage.general)
                    Label("Projects", systemImage: "folder").tag(SettingsPage.projects)
                }
                Section("DEVELOPMENT") {
                    Label("PHP", systemImage: "server.rack").tag(SettingsPage.php)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
        } detail: {
            switch selection {
            case .general: GeneralSettingsView(model: model)
            case .projects: ProjectSettingsView(model: model)
            case .php: PHPSettingsView(model: model)
            }
        }
        .frame(width: 760, height: 520)
        .onAppear {
            model.startMonitoring()
            model.setProjectSettingsVisible(true)
            DispatchQueue.main.async {
                SettingsWindowActivation.bringForward()
            }
        }
        .onDisappear {
            model.setProjectSettingsVisible(false)
        }
    }
}

struct GeneralSettingsView: View {
    let model: AppModel
    @State private var editorStatus: String?

    var body: some View {
        SettingsContent(title: "General", subtitle: "Vaelen keeps your local development environment ready from the menu bar.") {
            HStack(spacing: VaelenUI.spacing8) {
                Image(nsImage: VaelenBrand.settingsImage)
                    .accessibilityLabel("Vaelen mark")
                Text("Vaelen")
                    .font(.headline)
            }
            .padding(.bottom, VaelenUI.spacing6)
            SettingsGroup(title: "Status") {
                HStack {
                    switch model.state {
                    case .running: VaelenStatusLabel("Ready", systemImage: "circle.fill", tint: .secondary)
                    case .connecting: VaelenStatusLabel("Connecting", systemImage: "circle.dotted", tint: .secondary)
                    case .unavailable: VaelenStatusLabel("Unavailable", systemImage: "circle", tint: .secondary)
                    case .incompatible: VaelenStatusLabel("Needs attention", systemImage: "exclamationmark.circle", tint: .orange)
                    }
                    Spacer()
                    Text("Version \(VaelenBuildInfo.version)").font(.caption).foregroundStyle(.secondary)
                }
                if let refreshError = model.refreshError {
                    VaelenStatusLabel("Showing last known state", systemImage: "clock.arrow.circlepath", tint: .orange)
                        .font(.caption)
                        .padding(.top, VaelenUI.spacing6)
                        .help(refreshError)
                }
            }
            SettingsGroup(title: "Code Editor", footer: "Used by ‘val edit’ and each project’s Open in Editor action. Vaelen opens the selected folder directly in this exact installed application.") {
                let selected = try? EditorPreferenceStore().load()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected?.bundleIdentifier ?? "No editor selected")
                            .font(.subheadline)
                        if let path = selected?.applicationPath {
                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(selected == nil ? "Choose…" : "Change…", systemImage: "app.badge") { chooseEditor() }
                    if selected != nil {
                        Button("Clear") { clearEditor() }
                    }
                }
                if let editorStatus { Text(editorStatus).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.title = "Choose Code Editor"
        panel.message = "Select an installed macOS editor application."
        panel.prompt = "Use Editor"
        panel.allowedContentTypes = [.application]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            editorStatus = "Choose a valid installed application bundle."
            return
        }
        do {
            try EditorPreferenceStore().save(EditorPreference(bundleIdentifier: identifier, applicationPath: url.standardizedFileURL.path))
            editorStatus = "Editor selected: \(identifier)"
        } catch { editorStatus = "Could not save editor preference: \(error.localizedDescription)" }
    }

    private func clearEditor() {
        do { try EditorPreferenceStore().save(nil); editorStatus = "No editor is configured." }
        catch { editorStatus = "Could not clear editor preference: \(error.localizedDescription)" }
    }
}

struct PHPSettingsView: View {
    let model: AppModel

    var body: some View {
        SettingsContent(title: "PHP", subtitle: "Manage PHP runtimes installed by Vaelen.") {
            if let catalog = model.phpCatalog {
                SettingsGroup(title: "Default Runtime", footer: "Used when a project does not select another PHP runtime.") {
                    if let version = catalog.defaultVersion {
                        HStack(spacing: VaelenUI.spacing8) {
                            PHPDefaultMenu(catalog: catalog, model: model)
                            Spacer()
                            Text(PHPSeriesLabel.series(for: version))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VaelenStatusLabel("Default runtime unavailable", systemImage: "questionmark.circle", tint: .secondary)
                    }
                }

                SettingsGroup(title: "PHP Configuration", footer: "These settings are stored under Vaelen’s Application Support folder. Upload and POST size affect web requests; memory and input-variable limits apply to both web and CLI PHP. Execution time controls web requests; managed CLI PHP remains unlimited.") {
                    if let configuration = model.phpConfiguration {
                        VStack(alignment: .leading, spacing: VaelenUI.spacing12) {
                            PHPSettingsEditor(settings: configuration.defaultSettings, title: "Shared Default", saveTitle: "Save Shared Default", saving: model.phpConfigurationSaving) { settings in
                                Task { await model.savePHPConfiguration(version: nil, settings: settings) }
                            }
                            ForEach(configuration.versions, id: \.version) { version in
                                Divider().opacity(0.5)
                                VStack(alignment: .leading, spacing: VaelenUI.spacing8) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("PHP \(version.version)").font(.subheadline.weight(.medium))
                                            Text(version.inheritsDefault ? "Inherits the shared default" : "Version-specific override")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if !version.inheritsDefault {
                                            Button("Use Shared Default") {
                                                Task { await model.savePHPConfiguration(version: version.version, settings: nil) }
                                            }
                                            .disabled(model.phpConfigurationSaving)
                                        }
                                    }
                                    PHPSettingsEditor(settings: version.settings, title: "PHP \(version.version)", saveTitle: "Save PHP \(version.version)", saving: model.phpConfigurationSaving) { settings in
                                        Task { await model.savePHPConfiguration(version: version.version, settings: settings) }
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("FPM uses \(version.fpmIniPath)")
                                        Text("Managed CLI uses \(version.cliIniPath)")
                                        Text("FPM pool config (generated): \(version.fpmConfigurationPath)")
                                    }
                                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    if version.fpmRunning {
                                        Label("PHP-FPM is running with these settings.", systemImage: "checkmark.circle.fill")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Label("Settings will be used the next time PHP-FPM starts.", systemImage: "info.circle")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Button("Open Configuration Files…", systemImage: "folder") {
                                Task { await model.openPHPConfigurationFiles() }
                            }
                            .padding(.top, VaelenUI.spacing6)
                        }
                    } else {
                        HStack(spacing: VaelenUI.spacing8) {
                            ProgressView().controlSize(.small)
                            Text(model.phpConfigurationError ?? "Loading managed PHP configuration…")
                                .font(.caption).foregroundStyle(model.phpConfigurationError == nil ? Color.secondary : Color.red)
                            if model.phpConfigurationError != nil {
                                Button("Retry") { Task { await model.refreshPHPConfiguration() } }
                            }
                        }
                    }
                    if let error = model.phpConfigurationError, model.phpConfiguration != nil {
                        VaelenStatusLabel(error, systemImage: "exclamationmark.triangle", tint: .red)
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingsGroup(title: "Installed Versions") {
                    if catalog.installedVersions.isEmpty {
                        VaelenEmptyState(title: "No Installed PHP", systemImage: "shippingbox", message: "Vaelen has no managed PHP runtimes to show.")
                            .padding(.vertical, VaelenUI.spacing8)
                    } else {
                        ForEach(catalog.installedVersions, id: \.version) { runtime in
                            PHPVersionRow(runtime: runtime, model: model)
                        }
                    }
                }

                SettingsGroup(title: "Available Versions") {
                    let installed = Set(catalog.installedVersions.map(\.version))
                    let available = catalog.availableVersions.filter { !installed.contains($0) }
                    if !catalog.availableVersionsKnown {
                        Text("Available versions could not be refreshed. Installed runtimes remain available.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(.vertical, VaelenUI.spacing8)
                    } else if available.isEmpty {
                        Text("No additional PHP versions are currently available.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, VaelenUI.spacing8)
                    } else {
                        ForEach(available, id: \.self) { version in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("PHP \(version)")
                                    Text(PHPSeriesLabel.series(for: version))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Install", systemImage: "arrow.down.circle") {
                                    Task { await model.installPHP(version) }
                                }
                                .labelStyle(.titleAndIcon)
                                .accessibilityLabel("Install PHP \(version)")
                                .disabled(model.phpRequestInFlight)
                            }
                            .padding(.vertical, VaelenUI.spacing8)
                            .overlay(alignment: .bottom) { Divider().opacity(0.45) }
                        }
                    }
                }
            } else {
                HStack(spacing: VaelenUI.spacing8) {
                    ProgressView().controlSize(.small)
                    Text("Loading PHP runtime state…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, VaelenUI.spacing12)
            }

            if let target = model.phpRequestTarget {
                HStack(spacing: VaelenUI.spacing8) {
                    ProgressView().controlSize(.small)
                    Text(phpOperationDescription(target: target, operation: model.phpOperation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, VaelenUI.spacing6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("PHP operation in progress for \(target)")
            }
            if let error = model.phpError {
                VaelenStatusLabel(error, systemImage: "exclamationmark.triangle", tint: .red)
                    .font(.caption)
                    .padding(.top, VaelenUI.spacing6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if model.phpConfiguration == nil { await model.refreshPHPConfiguration() } }
    }

    private func phpOperationDescription(target: String, operation: PHPOperationState?) -> String {
        guard let operation, operation.targetVersion == target else { return "Working on PHP \(target)…" }
        switch operation.phase {
        case .starting: return "Starting PHP \(target)…"
        case .downloading: return "Downloading PHP \(target)…"
        case .verifying: return "Verifying PHP \(target)…"
        case .installing: return "Installing PHP \(target)…"
        case .removing: return "Removing PHP \(target)…"
        default: return "Working on PHP \(target)…"
        }
    }
}

private struct PHPSettingsEditor: View {
    let settings: PHPSettingsValues
    let title: String
    let saveTitle: String
    let saving: Bool
    let save: (PHPSettingsValues) -> Void
    @State private var uploadLimitMB: Int
    @State private var memoryLimitMB: Int
    @State private var maxExecutionTimeSeconds: Int
    @State private var maxInputVariables: Int

    init(settings: PHPSettingsValues, title: String, saveTitle: String, saving: Bool, save: @escaping (PHPSettingsValues) -> Void) {
        self.settings = settings; self.title = title; self.saveTitle = saveTitle; self.saving = saving; self.save = save
        _uploadLimitMB = State(initialValue: settings.uploadLimitMB)
        _memoryLimitMB = State(initialValue: settings.memoryLimitMB)
        _maxExecutionTimeSeconds = State(initialValue: settings.maxExecutionTimeSeconds)
        _maxInputVariables = State(initialValue: settings.maxInputVariables)
    }

    private var postLimitMB: Int { max(settings.postLimitMB, uploadLimitMB + 1) }
    private var valid: Bool { (1...2048).contains(uploadLimitMB) && (16...4096).contains(memoryLimitMB) && (0...86_400).contains(maxExecutionTimeSeconds) && (100...1_000_000).contains(maxInputVariables) && postLimitMB <= 2049 }
    private var unchanged: Bool {
        uploadLimitMB == settings.uploadLimitMB && memoryLimitMB == settings.memoryLimitMB && maxExecutionTimeSeconds == settings.maxExecutionTimeSeconds && maxInputVariables == settings.maxInputVariables && postLimitMB == settings.postLimitMB
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VaelenUI.spacing8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: VaelenUI.spacing8, verticalSpacing: VaelenUI.spacing8) {
                settingRow("Maximum upload size", value: $uploadLimitMB, unit: "MB", accessibility: "Maximum upload size for \(title)")
                GridRow {
                    Text("POST body limit").foregroundStyle(.secondary)
                    Text("\(postLimitMB) MB · managed automatically").gridCellColumns(2).foregroundStyle(.secondary)
                }
                settingRow("Memory limit", value: $memoryLimitMB, unit: "MB", accessibility: "PHP memory limit for \(title)")
                settingRow("Maximum execution time", value: $maxExecutionTimeSeconds, unit: "seconds", accessibility: "PHP maximum execution time for \(title)")
                settingRow("Maximum input variables", value: $maxInputVariables, unit: "variables", accessibility: "PHP maximum input variables for \(title)")
            }
            Text("Vaelen keeps post_max_size at least 1 MB above upload_max_filesize so multipart overhead cannot make the upload limit ineffective.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Upload and POST size affect web requests. Memory and maximum input variables apply to web and CLI PHP. Maximum execution time controls FPM/web requests; managed CLI PHP remains unlimited.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(saveTitle) {
                    save(PHPSettingsValues(uploadLimitMB: uploadLimitMB, memoryLimitMB: memoryLimitMB, maxExecutionTimeSeconds: maxExecutionTimeSeconds, maxInputVariables: maxInputVariables, postLimitMB: postLimitMB))
                }
                .disabled(saving || unchanged || !valid)
            }
        }
        .onChange(of: settings) { _, value in
            uploadLimitMB = value.uploadLimitMB; memoryLimitMB = value.memoryLimitMB; maxExecutionTimeSeconds = value.maxExecutionTimeSeconds; maxInputVariables = value.maxInputVariables
        }
    }

    private func settingRow(_ label: String, value: Binding<Int>, unit: String, accessibility: String) -> some View {
        GridRow {
            Text(label)
            TextField(label, value: value, format: .number)
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 78)
                .accessibilityLabel(accessibility)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PHPDefaultMenu: View {
    let catalog: PHPRuntimeCatalog
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(catalog.installedVersions, id: \.version) { runtime in
                Button {
                    guard runtime.version != catalog.defaultVersion else { return }
                    Task { await model.setDefaultPHP(runtime.version) }
                } label: {
                    if runtime.version == catalog.defaultVersion {
                        Label("PHP \(runtime.version)", systemImage: "checkmark")
                    } else {
                        Text("PHP \(runtime.version)")
                    }
                }
                .disabled(model.phpRequestInFlight || runtime.running == nil)
            }
        } label: {
            Label("PHP \(catalog.defaultVersion ?? "Unavailable")", systemImage: "checkmark.circle")
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Default PHP runtime")
        .accessibilityValue(catalog.defaultVersion.map { "PHP \($0)" } ?? "Unavailable")
        .disabled(model.phpRequestInFlight)
    }
}

private struct PHPVersionRow: View {
    let runtime: PHPRuntimeVersion
    let model: AppModel

    private var isWorking: Bool { model.phpRequestTarget == runtime.version }
    private var canRemove: Bool { runtime.running == false && !runtime.isDefault }

    var body: some View {
        HStack(alignment: .center, spacing: VaelenUI.spacing8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("PHP \(runtime.version)").font(.body)
                if let series = runtime.series {
                    Text("\(series) series")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if runtime.updateAvailable == true, let latest = runtime.latestVersion {
                    Text("Update available: \(latest)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if runtime.usedByProjectCount > 0 {
                    Text("Used by \(runtime.usedByProjectCount) project\(runtime.usedByProjectCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: VaelenUI.spacing8)
            if runtime.isDefault {
                VaelenStatusLabel("Default", systemImage: "checkmark.circle", tint: .secondary)
                    .font(.caption)
            }
            if runtime.running == true {
                VaelenStatusLabel("Running", systemImage: "circle.fill", tint: .secondary)
                    .font(.caption)
            }
            if isWorking {
                ProgressView().controlSize(.small)
            } else if runtime.updateAvailable == true, let latest = runtime.latestVersion {
                Button("Update", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.updatePHP(latest) }
                }
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Update PHP \(runtime.version) to \(latest)")
                .disabled(model.phpRequestInFlight)
            }
            if canRemove {
                Menu {
                    Button("Remove PHP \(runtime.version)", systemImage: "trash", role: .destructive) {
                        showRemovalConfirmation = true
                    }
                    .accessibilityLabel("Remove PHP \(runtime.version)")
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Actions for PHP \(runtime.version)")
                .disabled(model.phpRequestInFlight)
            }
        }
        .padding(.vertical, VaelenUI.spacing8)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PHP \(runtime.version)")
        .confirmationDialog("Remove PHP \(runtime.version)?", isPresented: $showRemovalConfirmation, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.removePHP(runtime.version) } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the Vaelen-managed PHP runtime from this Mac. Project files are not changed.")
        }
    }

    @State private var showRemovalConfirmation = false
}

private enum PHPSeriesLabel {
    static func series(for version: String) -> String {
        if let parsed = PHPVersion(version) { return "PHP \(parsed.family) series" }
        return "PHP series unavailable"
    }
}

struct ProjectSettingsView: View {
    let model: AppModel

    var body: some View {
        SettingsContent(title: "Projects", subtitle: "Choose which workspace folders Vaelen discovers and which projects you manage explicitly.") {
            if let refreshError = model.refreshError {
                VaelenStatusLabel("Showing last known project state", systemImage: "clock.arrow.circlepath", tint: .orange)
                    .font(.caption)
                    .help(refreshError)
            }
            SettingsGroup(title: "Workspace Folders", footer: "Projects found in these folders appear in the menu bar without changing their files.") {
                if model.parkedFolders.isEmpty {
                    VaelenEmptyState(title: "No Workspace Folders", systemImage: "folder", message: "Add a folder to discover projects.").padding(.vertical, VaelenUI.spacing8)
                } else {
                    ForEach(model.parkedFolders, id: \.id) { folder in
                        WorkspaceFolderRow(folder: folder, discoveredCount: discoveredCount(in: folder, from: model.projects), model: model)
                    }
                }
                Button("Add Workspace Folder…", systemImage: "plus") {
                    guard let path = chooseDirectory(title: "Choose a Workspace Folder", prompt: "Add Workspace Folder") else { return }
                    Task { await model.parkFolder(at: path) }
                }
                .disabled(model.relationshipMutationInFlight)
                .padding(.top, VaelenUI.spacing8)
            }
            SettingsGroup(title: "Linked Projects", footer: "Linked projects can receive project-specific configuration.") {
                if model.linkedProjects.isEmpty {
                    VaelenEmptyState(title: "No Linked Projects", systemImage: "shippingbox", message: "Link a project to manage it directly.").padding(.vertical, VaelenUI.spacing8)
                } else {
                    ForEach(model.linkedProjects, id: \.path) { project in
                        ExplicitProjectRow(project: project, model: model)
                    }
                }
                Button("Link Project…", systemImage: "link") {
                    guard let path = chooseDirectory(title: "Choose a Project to Link", prompt: "Link Project") else { return }
                    Task { await model.linkProject(at: path) }
                }
                .disabled(model.relationshipMutationInFlight)
                .padding(.top, VaelenUI.spacing8)
            }
            if let operation = model.relationshipOperation {
                HStack(spacing: VaelenUI.spacing8) { ProgressView().controlSize(.small); Text(operation).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = model.relationshipError {
                VaelenStatusLabel(error, systemImage: "exclamationmark.triangle", tint: .red).font(.caption)
            }
            if let error = model.projectRelationshipsRefreshError {
                VaelenStatusLabel("Workspace and linked project state may be stale: \(error)", systemImage: "arrow.clockwise.circle", tint: .orange)
                    .font(.caption)
            }
        }
    }
}

private struct SettingsContent<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VaelenUI.spacing12) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader).padding(.bottom, VaelenUI.spacing6)
            content
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.top, VaelenUI.spacing6) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkspaceFolderRow: View {
    let folder: ParkedPathWire
    let discoveredCount: Int
    let model: AppModel

    var body: some View {
        HStack(spacing: VaelenUI.spacing8) {
            Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayPath(folder.path)).lineLimit(1)
                Text(folderDetail(folder, discoveredCount: discoveredCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Remove Workspace Folder", systemImage: "minus.circle") { Task { await model.removeParkedFolder(folder) } }
                    .disabled(model.relationshipMutationInFlight)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for workspace folder \(displayPath(folder.path))")
        }
        .padding(.vertical, VaelenUI.spacing6)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }
}

private struct ExplicitProjectRow: View {
    let project: ProjectWire
    let model: AppModel

    var body: some View {
        let report = model.projectReports.first { $0.identity.path == project.path }
        let routes = routesForProject(project, report: report, configured: model.configuredRoutes)
        HStack(spacing: VaelenUI.spacing8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).lineLimit(1)
                if let framework = project.detectedFramework, !framework.isEmpty {
                    Text("\(framework) · \(displayPath(project.path))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(displayPath(project.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let routes, !routes.isEmpty {
                    Text(routes.map { "\($0.route.tls == .local ? "HTTPS" : "HTTP") · \($0.route.hostname)" }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityLabel("Site routes: " + routes.map(\.route.hostname).joined(separator: ", "))
                } else if routes == nil {
                    Label("Site routes unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                        .help(model.configuredRoutesError ?? "Vaelen could not read configured routes.")
                }
                projectPHPSummary(report)
            }
            Spacer()
            ProjectPHPMenu(project: project, report: report, model: model)
            Menu {
                Button("Unlink Project", systemImage: "link.badge.minus") { Task { await model.unlinkProject(project) } }
                    .disabled(model.relationshipMutationInFlight)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for project \(project.name)")
        }
        .padding(.vertical, VaelenUI.spacing6)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }

    @ViewBuilder
    private func projectPHPSummary(_ report: ProjectEnvironmentReport?) -> some View {
        if let report, let override = report.observed.php.overrideVersion, report.observed.php.resolvedVersion == nil {
            Label("PHP \(override) · Unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("PHP \(override), unavailable")
        } else if let report, let version = report.observed.php.resolvedVersion {
            Text("PHP \(version) · \(report.observed.php.overrideVersion == nil ? "Uses Default" : "Project Override")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("PHP \(version), \(report.observed.php.overrideVersion == nil ? "Uses Default" : "Project Override")")
        } else {
            Text("PHP unavailable")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct ProjectPHPMenu: View {
    let project: ProjectWire
    let report: ProjectEnvironmentReport?
    let model: AppModel

    var body: some View {
        Menu {
            Button("Use Default · PHP \(report?.observed.php.defaultVersion ?? "none")") {
                Task { await model.setProjectPHP(project, version: nil, useDefault: true) }
            }
            if let installed = model.phpCatalog?.installedVersions.map(\.version) {
                ForEach(installed, id: \.self) { version in
                    if version != report?.observed.php.defaultVersion {
                        Button("PHP \(version) · Project Override") { Task { await model.setProjectPHP(project, version: version) } }
                    }
                }
            }
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                Text(report?.observed.php.resolvedVersion.map { "PHP \($0)" } ?? "PHP unavailable")
                    .font(.caption)
                Text(projectPHPMode)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("PHP runtime for \(project.name)")
        .disabled(model.relationshipMutationInFlight || report == nil)
    }

    private var projectPHPMode: String {
        guard let report else { return "Unavailable" }
        if report.observed.php.resolvedVersion == nil { return "Unavailable" }
        return report.observed.php.overrideVersion == nil ? "Uses Default" : "Project Override"
    }
}

private func discoveredCount(in folder: ParkedPathWire, from projects: [ProjectWire] = []) -> Int {
    projects.filter { project in
        project.registration == "discovered" && (project.path == folder.path || project.path.hasPrefix(folder.path + "/"))
    }.count
}

private func folderDetail(_ folder: ParkedPathWire, discoveredCount: Int) -> String {
    let projects = "\(discoveredCount) discovered project\(discoveredCount == 1 ? "" : "s")"
    return folder.availability == PathAvailability.available.rawValue ? projects : "\(projects) · \(folder.availability)"
}

@MainActor
private func chooseDirectory(title: String, prompt: String) -> String? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = prompt
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    return panel.runModal() == .OK ? panel.url?.path : nil
}

private func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
