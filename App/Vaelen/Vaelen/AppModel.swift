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
    let managedLogViewer = ManagedLogViewerModel(client: CoreManagedLogsClient())
    private(set) var serviceReadiness: CoreServiceReadiness = .checking
    private(set) var earlyProjectList: [ProjectWire]?
    private(set) var projectReports: [ProjectEnvironmentReport] = []
    private(set) var projectReportErrors: [String: String] = [:]
    private(set) var projectStartupMilestones: [String: TimeInterval] = [:]
    private(set) var phpCatalog: PHPRuntimeCatalog?
    private(set) var phpCatalogReadPending = false
    let phpSettings = PHPConfigurationEditor()
    private(set) var phpConfiguration: PHPConfigurationResult? {
        get { phpSettings.snapshot }
        set { phpSettings.snapshot = newValue }
    }
    private(set) var phpConfigurationError: String? {
        get { phpSettings.readError }
        set { phpSettings.readError = newValue }
    }
    private(set) var phpConfigurationReadPending: Bool {
        get { phpSettings.readPending }
        set { phpSettings.readPending = newValue }
    }
    private(set) var phpConfigurationSaving = false
    private(set) var phpOperation: PHPOperationState?
    /// What the most recent update actually achieved, including any step that
    /// did not converge.
    private(set) var phpUpdateOutcome: PHPUpdateResult?

    /// Set after an update so the interface immediately shows the replacement's
    /// exact version, settings, paths, running state, and default role. The
    /// replacement keeps its own settings draft; nothing is carried over from an
    /// unrelated version's unsaved draft.
    private(set) var phpSelectionRequest: String?
    func clearPHPSelectionRequest() { phpSelectionRequest = nil }

    /// Installed runtimes whose family has an installable newer patch.
    ///
    /// This is a per-family claim, not a per-patch one: once the newest patch of
    /// a line is installed, that line no longer needs an update. It follows the
    /// authoritative catalog, so it clears when the update completes and never
    /// appears from a failed or unconfirmed check.
    var phpInstallableUpdates: [(from: PHPRuntimeVersion, to: String)] {
        guard let catalog = phpCatalog, catalog.availableVersionsKnown else { return [] }
        var newestInstalledByFamily: [String: String] = [:]
        var runtimeByVersion: [String: PHPRuntimeVersion] = [:]
        for runtime in catalog.installedVersions {
            runtimeByVersion[runtime.version] = runtime
            let family = runtime.series ?? PHPVersion(runtime.version)?.family ?? runtime.version
            if let existing = newestInstalledByFamily[family] {
                if phpIsNewer(runtime.version, existing) { newestInstalledByFamily[family] = runtime.version }
            } else {
                newestInstalledByFamily[family] = runtime.version
            }
        }
        var updates: [(from: PHPRuntimeVersion, to: String)] = []
        for family in Set(newestInstalledByFamily.keys) {
            let newestInstalled = newestInstalledByFamily[family] ?? ""
            let newestAvailable = catalog.availableVersions
                .filter { (PHPVersion($0)?.family ?? "") == family }
                .max(by: { phpIsNewer($1, $0) })
            guard let newestAvailable, phpIsNewer(newestAvailable, newestInstalled) else { continue }
            // Report against the runtime the list shows for this family, which is
            // the user's active runtime rather than necessarily the highest patch.
            guard let representative = catalog.installedVersions
                .filter({ ($0.series ?? "") == family })
                .sorted(by: { phpIsNewer($1.version, $0.version) })
                .first else { continue }
            updates.append((representative, newestAvailable))
        }
        return updates.sorted { phpIsNewer($0.to, $1.to) }
    }

    private func phpIsNewer(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = PHPVersion(lhs), let right = PHPVersion(rhs) else { return false }
        return left > right
    }

    var phpReleaseNotices: [PHPUpdateReport] { phpCatalog?.updateReports?.filter { $0.upstreamRelease != nil } ?? [] }
    var hasPHPUpdateNotice: Bool { hasInstallablePHPUpdate || !phpReleaseNotices.isEmpty }

    var hasInstallablePHPUpdate: Bool { !phpInstallableUpdates.isEmpty }

    var phpUpdateIndicatorHelp: String {
        let updates = phpInstallableUpdates
        guard let first = updates.first else { return phpReleaseNotices.map { "Official PHP \($0.upstreamRelease?.version ?? $0.family) release available" }.joined(separator: ", ") }
        if updates.count == 1 {
            return "Update available: PHP \(first.from.version) → \(first.to)"
        }
        return "\(updates.count) PHP runtimes have updates available: " + updates.map { "\($0.from.version) → \($0.to)" }.joined(separator: ", ")
    }
    private(set) var phpCompletionMessage: String?
    private(set) var phpCatalogCheckPending = false
    private(set) var phpCatalogCheckError: String?
    private(set) var phpError: String?
    private(set) var phpDefaultProjectIssues: [PHPDefaultProjectIssue] = []
    private(set) var phpDefaultRoutingIssues: [String] = []
    private(set) var phpRequestInFlight = false
    private(set) var phpRequestTarget: String?
    private(set) var parkedFolders: [ParkedPathWire] = []
    private(set) var linkedProjects: [ProjectWire] = []
    private(set) var nodeSnapshot: NodeCommandSnapshot?
    private(set) var nodeError: String?
    private(set) var configuredRoutes: [RouteIntent]?
    private(set) var configuredRoutesError: String?
    private(set) var localProxies: [LocalProxyWire]?
    private(set) var localProxiesError: String?
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
    private var nodeSnapshotGeneration = 0
    private var nodeSelectionRefreshInFlight = false
    private var refreshInFlight = false
    private var refreshRequested = false
    private var monitorTask: Task<Void, Never>?
    private var phpOperationPollTask: Task<Void, Never>?
    private var phpOperationWatchTask: Task<Void, Never>?
    private var lastAutomaticPHPCheckRequestAt: Date?
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
    private(set) var settingsFixturePHPSelection: String?
    private(set) var settingsFixturePage: SettingsPage?
    private(set) var settingsFixtureOperationFailure = false
    private(set) var verificationOpenSettingsPage: SettingsPage?

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
                let page = String(pageArgument.dropFirst("--settings-page=".count))
                model.settingsFixturePage = SettingsPage(rawValue: page)
                if model.settingsFixturePage == nil {
                    model.state = .unavailable
                    model.coreLaunchError = "Fixture: unsupported Settings page \(page)."
                    return model
                }
            }
            if let selectionArgument = arguments.first(where: { $0.hasPrefix("--settings-fixture-php-selection=") }) {
                model.settingsFixturePHPSelection = String(selectionArgument.dropFirst("--settings-fixture-php-selection=".count))
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
            case "partial", "empty", "installed", "all-installed", "install-failed", "remove-failed", "php-settings", "php-settings-no-default", "php-settings-error", "php-settings-invalid", "php-settings-saving", "php-update-review", "php-update-progress", "php-update-unknown-total", "php-update-success", "php-update-failed", "php-update-checking", "php-update-check-failed", "php-release-security", "php-release-coexist", "php-release-stale", "node-settings-selected", "node-settings-unpinned", "node-settings-unavailable":
                model.settingsFixtureOperationFailure = mode == "install-failed" || mode == "remove-failed"
                let mysqlState: MySQLState = mode == "node-settings-selected" ? .running : mode == "partial" ? .unhealthy : (mode == "installed" || mode == "all-installed" || mode == "remove-failed") ? .stopped : .notInstalled
                let mysqlVersion = (mode == "node-settings-selected" || mode == "installed" || mode == "all-installed" || mode == "remove-failed") ? "8.4.11" : nil
                let mysql = MySQLStatus(
                    state: mysqlState,
                    health: mysqlState == .unhealthy ? "identity-unverified" : mysqlState == .stopped ? "stopped" : mysqlState == .running ? "healthy" : "not-installed",
                    installedVersion: mysqlVersion,
                    selectedVersion: mysqlState == .running ? mysqlVersion : nil,
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
                if mode.hasPrefix("node-settings-") {
                    let projectID = UUID(uuidString: "C0B8DF3A-310A-4F20-9FC5-F7F4B01CC407")!
                    let project = ProjectWire(id: projectID, name: "Storefront", path: "/fixture/projects/storefront", registration: "linked", availability: "available", detectedFramework: "Next.js")
                    let version = try! NodeVersion("24.22.1")
                    let pin = mode == "node-settings-selected" ? version : mode == "node-settings-unavailable" ? try! NodeVersion("26.12.1") : nil
                    let packageJSON = Data(#"{"version":"24.22.1","platform":"darwin","architecture":"arm64","artifactSHA256":"fixture","receiptVersion":1}"#.utf8)
                    let package = try? JSONDecoder().decode(NodePackageIdentity.self, from: packageJSON)
                    model.linkedProjects = [project]
                    if mode == "node-settings-selected" {
                        let projectDomain = Project(
                            id: ProjectID(rawValue: projectID),
                            name: project.name,
                            rootPath: CanonicalPath(url: URL(fileURLWithPath: project.path, isDirectory: true)),
                            registrationKind: .linked,
                            availability: .available,
                            detectedFramework: project.detectedFramework
                        )
                        let php = ProjectObservedPHP(
                            installedVersions: ["8.3.22", "8.4.24"],
                            runningVersions: [],
                            resolvedVersion: "8.3.22",
                            resolvedState: "not-running",
                            defaultVersion: "8.4.24",
                            overrideVersion: "8.3.22"
                        )
                        let observed = ProjectObservedEnvironment(
                            php: php,
                            mysql: mysql,
                            mailpit: nil,
                            route: ProjectObservedRoute(intentExists: false, routerState: .stopped, routerHealth: .unknown),
                            dns: DNSStatus(state: .notInstalled, ownership: .none, health: "not-installed"),
                            tls: TLSStatus(state: .absent),
                            standardPorts: StandardPortsStatus(state: .absent)
                        )
                        let derived = ProjectDerivedEnvironment(
                            framework: ProjectFrameworkInspection(framework: "Next.js", confidence: .unknown, evidence: []),
                            phpResolution: "resolved",
                            dbEndpoint: ProjectEndpointObservation(configuredHost: nil, configuredPort: nil, expectedHost: nil, expectedPort: nil, matches: nil),
                            mailEndpoint: ProjectEndpointObservation(configuredHost: nil, configuredPort: nil, expectedHost: nil, expectedPort: nil, matches: nil),
                            mailAuthentication: ProjectMailAuthentication(requirement: .unknown),
                            routeDocumentRootMatches: nil,
                            configCache: ProjectConfigCacheObservation(state: "unknown", cachePath: "/fixture/projects/storefront/bootstrap/cache/config.php")
                        )
                        model.projectReports = [ProjectEnvironmentReport(
                            identity: ProjectEnvironmentIdentity(project: projectDomain),
                            desired: ProjectDesiredEnvironment(file: .valid, mysql: false),
                            configured: ProjectConfiguredEnvironment(envFile: "/fixture/projects/storefront/.env", envFilePresent: true, dbConnection: "sqlite"),
                            observed: observed,
                            derived: derived,
                            secret: ProjectSecretEnvironment(databasePassword: .unknown, mailPassword: .unknown),
                            diagnostics: []
                        )]
                    }
                    let record = NodeProjectRecord(id: ProjectID(rawValue: projectID), name: project.name, path: project.path, pin: pin)
                    model.nodeSnapshot = NodeCommandSnapshot(
                        releases: NodeRelease.reviewed,
                        selections: [ProjectNodeSelection(record: record, runtimeAvailable: mode != "node-settings-unavailable", detail: mode == "node-settings-unavailable" ? "The pinned Node package is missing." : nil)],
                        installedPackages: package.map { [$0] } ?? []
                    )
                }
                let phpUpdateFixture = mode.hasPrefix("php-update")
                let phpUpdateSuccess = mode == "php-update-success"
                let phpProjectOverrideFixture = mode == "node-settings-selected"
                let phpReleaseFixture = mode.hasPrefix("php-release")
                let phpUpdateReview = mode == "php-update-review" || phpReleaseFixture
                let phpPackageUpdateFixture = phpUpdateFixture || mode == "php-release-coexist"
                let phpFixtureSourceVersion = phpUpdateReview ? "8.4.24" : "8.4.23"
                let phpFixtureTargetVersion = mode == "php-release-coexist" ? "8.4.26" : phpUpdateReview ? "8.4.27" : "8.4.25"
                let phpSettingsFixture = mode.hasPrefix("php-settings") || phpUpdateFixture || phpReleaseFixture
                let fixtureVersions = phpSettingsFixture
                    ? [PHPRuntimeVersion(version: "8.3.22", running: false, isDefault: false), PHPRuntimeVersion(version: phpFixtureSourceVersion, running: true, isDefault: mode != "php-settings-no-default" && !phpUpdateSuccess, updateAvailable: phpPackageUpdateFixture && !phpUpdateSuccess ? true : nil, latestVersion: phpPackageUpdateFixture && !phpUpdateSuccess ? phpFixtureTargetVersion : nil), PHPRuntimeVersion(version: "8.5.0", running: false, isDefault: false)] + (phpUpdateFixture ? [PHPRuntimeVersion(version: "8.4.9", running: false), PHPRuntimeVersion(version: "8.3.29", running: false)] : []) + (phpUpdateSuccess ? [PHPRuntimeVersion(version: "8.4.25", running: false, isDefault: true)] : [])
                    : phpProjectOverrideFixture
                        ? [PHPRuntimeVersion(version: "8.3.22", running: false, isDefault: false), PHPRuntimeVersion(version: "8.4.24", running: false, isDefault: true)]
                        : [PHPRuntimeVersion(version: "8.4.23", running: false, isDefault: true)]
                model.phpCatalog = PHPRuntimeCatalog(
                    availableVersions: phpReleaseFixture ? (mode == "php-release-coexist" ? ["8.4.26"] : []) : phpUpdateFixture ? (phpUpdateSuccess ? ["8.5.1"] : [phpFixtureTargetVersion, "8.5.1"]) : mode == "partial" || mode == "installed" || mode == "install-failed" || mode == "remove-failed" ? ["8.5.0"] : [],
                    installedVersions: phpSettingsFixture || phpProjectOverrideFixture ? fixtureVersions : mode == "partial" || mode == "installed" || mode == "install-failed" || mode == "remove-failed" ? fixtureVersions : [],
                    defaultVersion: phpUpdateSuccess ? "8.4.25" : phpSettingsFixture && mode != "php-settings-no-default" ? phpFixtureSourceVersion : phpProjectOverrideFixture ? "8.4.24" : mode == "partial" || mode == "installed" || mode == "install-failed" || mode == "remove-failed" ? "8.4.23" : nil,
                    runningVersions: phpSettingsFixture ? [phpFixtureSourceVersion] : [],
                    availableVersionsKnown: true,
                    catalogCheckedAt: phpUpdateFixture ? Date(timeIntervalSinceNow: -3_600) : nil,
                    catalogCheckError: mode == "php-update-check-failed" ? "The catalog could not be reached; showing the last verified versions." : nil
                )
                if phpReleaseFixture {
                    let payload = Data(#"{"version":"8.4.27","date":"21 Oct 2026","tags":["security"]}"#.utf8)
                    let release = try? PHPReleaseAdvisory.parse(payload, family: "8.4")
                    let source = PHPReleaseSourceStatus(family: "8.4", release: release, lastAttemptAt: Date(), lastSuccessfulAt: Date(), error: mode == "php-release-stale" ? "Official PHP release check failed." : nil)
                    let availableVersions = model.phpCatalog?.availableVersions ?? []
                    let reports = PHPUpdateReport.project(installed: fixtureVersions, available: availableVersions, sources: [source])
                    model.phpCatalog?.updateReports = reports
                }
                if mode == "php-update-progress" {
                    model.phpRequestInFlight = true
                    model.phpRequestTarget = "8.4.25"
                    model.phpOperation = PHPOperationState(kind: .update, targetVersion: "8.4.25", phase: .downloading, bytesTransferred: 760_000, totalBytes: 2_500_000, artifactName: "FPM", artifactIndex: 2, artifactCount: 2)
                }
                if mode == "php-update-unknown-total" {
                    model.phpRequestInFlight = true
                    model.phpRequestTarget = "8.4.25"
                    model.phpOperation = PHPOperationState(kind: .update, targetVersion: "8.4.25", phase: .downloading, bytesTransferred: 760_000, totalBytes: nil, artifactName: "FPM", artifactIndex: 2, artifactCount: 2)
                }
                if mode == "php-update-success" {
                    model.phpRequestInFlight = true
                    model.phpRequestTarget = "8.4.25"
                    model.phpOperation = PHPOperationState(kind: .update, targetVersion: "8.4.25", phase: .ready)
                }
                if mode == "php-update-checking" { model.phpCatalogCheckPending = true }
                if mode == "php-update-failed" { model.phpError = "Fixture update failed while verifying PHP 8.4.25. Your existing PHP 8.4.23 package and settings remain unchanged. Retry the update when the catalog or network is available." }
                if phpSettingsFixture {
                    let shared = PHPSettingsValues(uploadLimitMB: 64, memoryLimitMB: 256, maxExecutionTimeSeconds: 30, maxInputVariables: 2_000, postLimitMB: 65)
                    let overridden = PHPSettingsValues(uploadLimitMB: 128, memoryLimitMB: 512, maxExecutionTimeSeconds: 0, maxInputVariables: 4_000, postLimitMB: 129)
                    model.phpConfiguration = PHPConfigurationResult(defaultSettings: shared, versions: [
                        PHPVersionConfiguration(version: "8.3.22", settings: shared, inheritsDefault: true, cliIniPath: "/fixture/php/8.3.22/cli.ini", fpmIniPath: "/fixture/php/8.3.22/fpm.ini", fpmConfigurationPath: "/fixture/php/8.3.22/php-fpm.conf", fpmRunning: false),
                        PHPVersionConfiguration(version: phpFixtureSourceVersion, settings: overridden, inheritsDefault: false, cliIniPath: "/fixture/php/\(phpFixtureSourceVersion)/cli.ini", fpmIniPath: "/fixture/php/\(phpFixtureSourceVersion)/fpm.ini", fpmConfigurationPath: "/fixture/php/\(phpFixtureSourceVersion)/php-fpm.conf", fpmRunning: true),
                        PHPVersionConfiguration(version: "8.5.0", settings: shared, inheritsDefault: true, cliIniPath: "/fixture/php/8.5.0/cli.ini", fpmIniPath: "/fixture/php/8.5.0/fpm.ini", fpmConfigurationPath: "/fixture/php/8.5.0/php-fpm.conf", fpmRunning: false)
                    ], directory: "/fixture/php")
                    model.phpConfigurationError = mode == "php-settings-error" ? "Fixture: configuration save failed." : nil
                    model.phpConfigurationSaving = mode == "php-settings-saving"
                } else { model.phpConfigurationReadPending = true }
            default:
                model.state = .unavailable
                model.coreLaunchError = "Fixture: unsupported Settings fixture \(mode)."
                return model
            }
            return model
        }
        #endif
        let model = AppModel()
        if let argument = arguments.first(where: { $0.hasPrefix("--verification-open-settings=") }) {
            model.verificationOpenSettingsPage = SettingsPage(rawValue: String(argument.dropFirst("--verification-open-settings=".count)))
        }
        return model
    }

    var savedServiceIntents: Set<String>? {
        guard case .running(let status, _, _, _, _, _, _, _, _) = state else { return nil }
        return status.serviceIntents
    }

    func startupIssue(for service: String) -> String? { startupServiceIssues[service] }
    func isServiceReadPending(_ service: String) -> Bool {
        guard pendingServiceReads.contains(service) else { return false }
        guard case .running(_, _, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit) = state else { return true }
        switch service {
        case "PHP": return php == nil
        case "routing": return routing == nil
        case "DNS": return dns == nil
        case "TLS": return tls == nil
        case "standard-ports": return ports == nil
        case "MySQL": return mysql == nil
        case "Mailpit": return mailpit == nil
        default: return true
        }
    }

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
                if VaelenTestRuntimePaths.isolatedSupportRoot() != nil { throw error }
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
            let localProxies: [LocalProxyWire]?
            let localProxiesError: String?
            do {
                localProxies = try await client.localProxyList()
                localProxiesError = nil
            } catch {
                localProxies = nil
                localProxiesError = error.localizedDescription
            }
            let phpCatalog = try? await client.phpCatalog()
            phpCatalogReadPending = false
            let phpOperation = try? await client.phpOperation()
            guard generation == refreshGeneration else { await client.disconnect(); return }
            self.configuredRoutes = configuredRoutes
            self.configuredRoutesError = configuredRoutesError
            self.localProxies = localProxies
            self.localProxiesError = localProxiesError
            if relationshipGeneration == relationshipSnapshotGeneration {
                self.linkedProjects = linkedProjects
                self.parkedFolders = parkedFolders
                projectRelationshipsRefreshError = nil
            }
            self.phpCatalog = phpCatalog
            if let phpCatalog {
                lastAutomaticPHPCheckRequestAt = phpCatalog.catalogCheckedAt ?? Date()
                phpCatalogCheckError = phpCatalog.catalogCheckError
            }
            self.phpOperation = phpOperation
            state = .running(status, projects, php, routing, dns, tls, ports, mysql, mailpit)
            refreshError = nil
            await refreshPHPConfiguration()
            if !hasRunningSnapshot, projectSettingsVisible, generation == refreshGeneration {
                await refreshNodeSelections()
            }
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
        let preserveReadinessOnTimeout = isShowingRunningSnapshot && serviceReadiness != .checking
        if !preserveReadinessOnTimeout { serviceReadiness = .checking }
        serviceCheckStartedAt = .now
        pendingServiceReads = []
        serviceCheckTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.refreshGeneration == generation, self.serviceCheckStartedAt != nil else { return }
            let outstanding = self.pendingServiceReads.sorted().joined(separator: ",")
            let elapsed = self.serviceCheckStartedAt.map(Self.elapsedMilliseconds(since:)) ?? 12_000
            Self.startupLogger.error("startup milestone=service-state-timeout elapsed_ms=\(elapsed) outstanding=\(outstanding, privacy: .public)")
            let unavailable = CoreServiceReadiness.resolve(serviceIssues: self.startupServiceIssues, requiredReadCount: 7, completedReadCount: 0, successfulReadCount: 0, timedOut: true)
            if !preserveReadinessOnTimeout { self.finishServiceReadinessCheck(unavailable) }
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
        await performPHPCommand(version, kind: .install) { _ = try await $0.phpInstall(version) }
    }

    /// Update a runtime. `source` names the runtime being replaced so its saved
    /// settings are the ones carried over when several patches coexist.
    func updatePHP(_ version: String, replacing source: String? = nil) async {
        if isSettingsFixture, settingsFixtureMode?.hasPrefix("php-update") == true {
            await performPHPUpdateFixture(version)
            return
        }
        // A previous outcome must not survive into this operation, whether the
        // new one succeeds, partially succeeds, or fails.
        phpUpdateOutcome = nil
        var updateResult: PHPUpdateResult?
        await performPHPCommand(version, kind: .update) { updateResult = try await $0.phpUpdate(version, sourceVersion: source) }
        guard let updateResult else { return }
        phpUpdateOutcome = updateResult
        // Show the replacement rather than leaving the user on the superseded row.
        phpSelectionRequest = updateResult.version
        // Describe what actually happened. "Installed and ready" is only truthful
        // when startup, default handover, and routing all completed.
        if let failure = updateResult.convergenceError {
            phpError = "PHP \(updateResult.version) installed, but some work did not finish: \(failure)"
            phpCompletionMessage = nil
        } else if let replaced = updateResult.replacedVersion {
            phpCompletionMessage = "PHP \(updateResult.version) is installed and ready. PHP \(replaced) was removed; its saved settings are kept and return if you reinstall it."
        } else {
            phpCompletionMessage = "PHP \(updateResult.version) is installed and ready."
        }
    }

    private func performPHPUpdateFixture(_ version: String) async {
        guard !phpRequestInFlight else { return }
        phpError = nil
        phpRequestInFlight = true
        phpRequestTarget = version
        for bytes in [Int64(180_000), 760_000, 1_250_000] {
            phpOperation = PHPOperationState(kind: .update, targetVersion: version, phase: .downloading, bytesTransferred: bytes, totalBytes: 2_500_000, artifactName: "FPM", artifactIndex: 2, artifactCount: 2)
            try? await Task.sleep(for: .milliseconds(650))
        }
        for phase in [PHPOperationPhase.verifying, .installing] {
            phpOperation = PHPOperationState(kind: .update, targetVersion: version, phase: phase)
            try? await Task.sleep(for: .milliseconds(700))
        }
        if settingsFixtureMode == "php-update-failed" {
            let message = "Fixture update failed while verifying PHP \(version). The existing package and settings remain unchanged. Retry the update when the catalog or network is available."
            phpOperation = PHPOperationState(kind: .update, targetVersion: version, phase: .failed, message: message)
            phpError = message
        } else if let catalog = phpCatalog,
                  let old = catalog.installedVersions.first(where: { $0.isDefault && PHPVersion($0.version)?.family == PHPVersion(version)?.family }) {
            let upgraded = PHPRuntimeVersion(version: version, running: false, isDefault: true, updateAvailable: false, latestVersion: version, usedByProjectCount: old.usedByProjectCount, explicitProjectCount: old.explicitProjectCount, inheritedProjectCount: old.inheritedProjectCount)
            let versions = catalog.installedVersions.map { runtime in
                runtime.version == old.version ? PHPRuntimeVersion(version: runtime.version, running: runtime.running, isDefault: false, updateAvailable: false, latestVersion: version, usedByProjectCount: runtime.usedByProjectCount, explicitProjectCount: runtime.explicitProjectCount, inheritedProjectCount: runtime.inheritedProjectCount) : runtime
            } + [upgraded]
            phpCatalog = PHPRuntimeCatalog(availableVersions: catalog.availableVersions.filter { $0 != version }, installedVersions: versions, defaultVersion: version, runningVersions: catalog.runningVersions, availableVersionsKnown: catalog.availableVersionsKnown, catalogCheckedAt: catalog.catalogCheckedAt)
            phpOperation = PHPOperationState(kind: .update, targetVersion: version, phase: .ready)
        }
        phpRequestInFlight = false
        phpRequestTarget = nil
    }

    /// Retry only the convergence work for an update that already installed its
    /// replacement. The package is not downloaded or installed again.
    func retryPHPUpdateConvergence(_ version: String) async {
        var updateResult: PHPUpdateResult?
        await performPHPCommand(version, kind: .update) { updateResult = try await $0.phpUpdate(version) }
        guard let updateResult else { return }
        phpUpdateOutcome = updateResult
        if let failure = updateResult.convergenceError {
            phpError = "PHP \(version) is installed, but some work did not finish: \(failure)"
        } else {
            phpError = nil
            phpCompletionMessage = "PHP \(version) is installed and fully converged."
        }
    }

    func checkPHPUpdates() async {
        guard !isSettingsFixture, !phpCatalogCheckPending else {
            if isSettingsFixture { phpCatalogCheckError = "Update checks are disabled in isolated Settings fixtures." }
            return
        }
        phpCatalogCheckPending = true
        phpCatalogCheckError = nil
        defer { phpCatalogCheckPending = false }
        do {
            let checkClient = makeCoreClient()
            try await checkClient.connect()
            defer { Task { await checkClient.disconnect() } }
            do {
                phpCatalog = try await checkClient.checkPHPUpdates()
                lastAutomaticPHPCheckRequestAt = phpCatalog?.catalogCheckedAt
                phpCatalogCheckError = nil
            } catch {
                phpCatalogCheckError = phpErrorMessage(error)
                if let snapshot = try? await checkClient.phpCatalogSnapshot() { phpCatalog = snapshot }
            }
        } catch {
            phpCatalogCheckError = phpErrorMessage(error)
        }
    }

    func removePHP(_ version: String) async {
        await performPHPCommand(version, kind: .remove) { _ = try await $0.phpRemove(version) }
    }

    func startPHPRuntime(_ version: String) async {
        await performPHPCommand(version, kind: .start) { _ = try await $0.phpStart(version) }
    }

    func stopPHPRuntime(_ version: String) async {
        await performPHPCommand(version, kind: .stop) { _ = try await $0.phpStop(version) }
    }

    func retryPHPProjectReconciliation(_ projectName: String) async {
        guard !phpRequestInFlight, !phpConfigurationSaving else { return }
        phpRequestInFlight = true
        phpRequestTarget = "project:\(projectName)"
        defer {
            phpRequestInFlight = false
            if phpRequestTarget == "project:\(projectName)" { phpRequestTarget = nil }
        }
        let retryClient = makeCoreClient()
        do {
            try await retryClient.connect()
            let execution = try await retryClient.projectActivate(selector: projectName, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            await retryClient.disconnect()
            if execution.state == .succeeded || execution.state == .partial {
                let verificationClient = makeCoreClient()
                let report: ProjectEnvironmentReport
                do {
                    try await verificationClient.connect()
                    report = try await verificationClient.projectInspect(selector: projectName, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
                    await verificationClient.disconnect()
                } catch {
                    await verificationClient.disconnect()
                    throw error
                }
                guard report.routeTargets.allSatisfy({ $0.disposition == .satisfied }) else {
                    throw NSError(domain: "Vaelen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Project routing has not yet passed authoritative verification."])
                }
                phpDefaultProjectIssues.removeAll { $0.projectName == projectName }
                projectReportErrors[projectName] = nil
            } else {
                let explanation = execution.operations.compactMap(\.message).joined(separator: "; ")
                if let index = phpDefaultProjectIssues.firstIndex(where: { $0.projectName == projectName }) {
                    phpDefaultProjectIssues[index] = PHPDefaultProjectIssue(projectName: projectName, message: explanation.isEmpty ? "The project still needs attention." : explanation)
                }
            }
            await refreshAuthoritativeServiceState()
        } catch {
            await retryClient.disconnect()
            if let index = phpDefaultProjectIssues.firstIndex(where: { $0.projectName == projectName }) {
                phpDefaultProjectIssues[index] = PHPDefaultProjectIssue(projectName: projectName, message: phpErrorMessage(error))
            }
        }
    }

    func setDefaultPHP(_ version: String) async {
        if isSettingsFixture, let catalog = phpCatalog, catalog.installedVersions.contains(where: { $0.version == version }) {
            let versions = catalog.installedVersions.map { runtime in
                PHPRuntimeVersion(version: runtime.version, series: runtime.series, running: runtime.running, isDefault: runtime.version == version, updateAvailable: runtime.updateAvailable, latestVersion: runtime.latestVersion, usedByProjectCount: runtime.usedByProjectCount)
            }
            phpCatalog = PHPRuntimeCatalog(availableVersions: catalog.availableVersions, installedVersions: versions, defaultVersion: version, runningVersions: catalog.runningVersions, availableVersionsKnown: catalog.availableVersionsKnown)
            return
        }
        phpDefaultProjectIssues = []
        phpDefaultRoutingIssues = []
        await performPHPCommand(version, kind: .defaultSelection) { [weak self] client in
            let response = try await client.phpDefaultSelect(version)
            self?.phpDefaultProjectIssues = response.projectIssues
            self?.phpDefaultRoutingIssues = response.routingIssues
        }
    }

    func refreshPHPConfiguration() async {
        guard !isSettingsFixture, !phpRequestInFlight else { return }
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
        await phpSettings.refresh { try await client.phpConfiguration() }
    }

    func savePHPConfiguration(version: String?, settings: PHPSettingsValues?) async {
        if isSettingsFixture {
            phpConfigurationSaving = true
            defer { phpConfigurationSaving = false }
            if settingsFixtureMode == "php-settings-error" {
                phpConfigurationError = "Fixture: could not save PHP configuration."
                return
            }
            guard let current = phpConfiguration else { phpConfigurationError = "Fixture: configuration unavailable."; return }
            if let version {
                let values = settings ?? current.defaultSettings
                let versions = current.versions.map { item in
                    item.version == version ? PHPVersionConfiguration(version: item.version, settings: values, inheritsDefault: settings == nil, cliIniPath: item.cliIniPath, fpmIniPath: item.fpmIniPath, fpmConfigurationPath: item.fpmConfigurationPath, fpmRunning: item.fpmRunning) : item
                }
                phpConfiguration = PHPConfigurationResult(defaultSettings: current.defaultSettings, versions: versions, directory: current.directory)
            } else if let settings {
                let versions = current.versions.map { item in
                    item.inheritsDefault ? PHPVersionConfiguration(version: item.version, settings: settings, inheritsDefault: true, cliIniPath: item.cliIniPath, fpmIniPath: item.fpmIniPath, fpmConfigurationPath: item.fpmConfigurationPath, fpmRunning: item.fpmRunning) : item
                }
                phpConfiguration = PHPConfigurationResult(defaultSettings: settings, versions: versions, directory: current.directory)
            }
            phpConfigurationError = nil
            return
        }
        guard !phpConfigurationSaving, !phpRequestInFlight else { return }
        let context = PHPSettingsContext(version: version)
        phpConfigurationSaving = true
        defer { phpConfigurationSaving = false }
        await phpSettings.save(context: context, settings: settings) {
            guard let client = self.client else { throw CoreClientError.coreUnavailable }
            return try await client.updatePHPConfiguration(version: version, settings: settings)
        }
        await refreshPHPConfiguration()
        await refreshAuthoritativeServiceState()
    }

    func openPHPConfigurationFiles(version: String? = nil) async {
        guard !isSettingsFixture else { return }
        do {
            guard let configuration = phpConfiguration else { throw CoreClientError.invalidResponse }
            let url: URL
            if let version {
                guard let item = configuration.versions.first(where: { $0.version == version }) else { throw CoreClientError.invalidResponse }
                url = URL(fileURLWithPath: item.fpmIniPath).deletingLastPathComponent()
            } else { url = URL(fileURLWithPath: configuration.directory, isDirectory: true) }
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
        guard let url = projectRouteURL(route) else { return }
        NSWorkspace.shared.open(url)
    }

    private func projectRouteURL(_ route: RouteIntent) -> URL? {
        let scheme = route.route.tls == .local ? "https" : "http"
        return URL(string: "\(scheme)://\(route.route.hostname)")
    }

    func copyProjectRouteURL(_ route: RouteIntent) {
        guard let url = projectRouteURL(route) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func localProxyRoute(_ proxy: LocalProxyWire) -> RouteIntent? {
        configuredRoutes?.first { $0.route.id.description == proxy.routeID }
    }

    func addLocalProxy(hostname: String, upstreamURL: String) async {
        do {
            guard let client else { throw CoreClientError.coreUnavailable }
            _ = try await client.localProxyAdd(hostname: hostname, upstreamURL: upstreamURL)
            await refresh()
        } catch {
            localProxiesError = error.localizedDescription
        }
    }

    func removeLocalProxy(hostname: String) async {
        do {
            guard let client else { throw CoreClientError.coreUnavailable }
            _ = try await client.localProxyRemove(hostname: hostname)
            await refresh()
        } catch {
            localProxiesError = error.localizedDescription
        }
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
            Task { await refresh(); await refreshNodeSelections() }
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
            Task { await refresh(); await refreshNodeSelections() }
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

    func refreshNodeSelections() async {
        guard !isSettingsFixture, !relationshipMutationInFlight, !nodeSelectionRefreshInFlight else { return }
        nodeSelectionRefreshInFlight = true
        defer { nodeSelectionRefreshInFlight = false }
        nodeSnapshotGeneration += 1
        let generation = nodeSnapshotGeneration
        let commandClient = makeCoreClient()
        do {
            try await commandClient.connect()
            let snapshot = try await commandClient.nodeCommand(NodeCommandRequest(action: .list, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path))
            if generation == nodeSnapshotGeneration, !relationshipMutationInFlight {
                nodeSnapshot = snapshot
                nodeError = nil
            }
            await commandClient.disconnect()
        } catch {
            await commandClient.disconnect()
            if generation == nodeSnapshotGeneration, !relationshipMutationInFlight {
                nodeError = error.localizedDescription
            }
        }
    }

    func setProjectNode(_ project: ProjectWire, version: NodeVersion?) async {
        guard !isSettingsFixture else {
            nodeError = "Node operations are disabled in isolated Settings fixtures."
            return
        }
        let operation = version.map { "Selecting Node \($0) for \(project.name)…" } ?? "Using invocation PATH for \(project.name)…"
        guard beginRelationshipMutation(operation) else { return }
        nodeSnapshotGeneration += 1
        nodeError = nil
        let commandClient = makeCoreClient()
        let selector = project.id?.uuidString ?? project.path
        do {
            try await commandClient.connect()
            if let version, !(nodeSnapshot?.installedPackages.contains(where: { $0.version == version }) ?? false) {
                nodeSnapshot = try await commandClient.nodeCommand(NodeCommandRequest(action: .install, version: version, workingDirectory: project.path))
            }
            let action: NodeCommandAction = version == nil ? .useDefault : .isolate
            nodeSnapshot = try await commandClient.nodeCommand(NodeCommandRequest(action: action, version: version, selector: selector, workingDirectory: project.path))
            await commandClient.disconnect()
            finishRelationshipMutation()
            nodeError = nil
        } catch {
            let message = error.localizedDescription
            if let snapshot = try? await commandClient.nodeCommand(NodeCommandRequest(action: .list, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)) {
                nodeSnapshot = snapshot
            }
            await commandClient.disconnect()
            nodeError = message
            finishRelationshipMutation(error: error)
        }
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
        if visible {
            Task {
                await refreshProjectRelationships()
                await refreshNodeSelections()
            }
        }
        else {
            relationshipSnapshotGeneration += 1
            projectRelationshipsRefreshRequested = false
        }
    }

    func refreshProjectRelationshipsIfVisible() async {
        guard projectSettingsVisible else { return }
        await refreshProjectRelationships()
        await refreshNodeSelections()
    }

    private func refreshProjectRelationships() async {
        guard !isSettingsFixture else { return }
        guard !relationshipMutationInFlight else { return }
        // The main refresh owns the authoritative project relationship snapshot
        // while it is connecting. Starting a second snapshot here can advance
        // relationshipSnapshotGeneration and discard that startup result.
        guard !refreshInFlight else { return }
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
        guard !serviceOperationIsBusy, !relationshipMutationInFlight else {
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
            await checkPHPUpdatesIfDue()
            // Background reconciliation catches changes Vaelen did not
            // initiate. Explicit commands use request/reply plus an immediate
            // authoritative service snapshot and never wait for this timer.
            // Keep projects and the remote PHP catalog out of the periodic
            // path so those diagnostics cannot queue behind lifecycle calls.
        }
    }

    private func checkPHPUpdatesIfDue() async {
        guard !isQuitting, !isSettingsFixture, !phpCatalogCheckPending,
              Date().timeIntervalSince(lastAutomaticPHPCheckRequestAt ?? .distantPast) >= 12 * 60 * 60 else { return }
        phpCatalogCheckPending = true
        defer { phpCatalogCheckPending = false }
        do {
            let checkClient = makeCoreClient()
            try await checkClient.connect()
            defer { Task { await checkClient.disconnect() } }
            phpCatalog = try await checkClient.phpCatalog()
            lastAutomaticPHPCheckRequestAt = Date()
            phpCatalogCheckError = phpCatalog?.catalogCheckError
        } catch {
            phpCatalogCheckError = phpErrorMessage(error)
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
        let reportsStarted = ContinuousClock.now
        // Cancelling here must be paired with rescheduling below: waiting for
        // the next tick would otherwise never refresh project PHP labels after
        // a mutation cancelled the in-flight report work.
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
            // Service-only polling refreshes the same project reports the full
            // path does, so a tick that cancelled report work still leaves fresh
            // project PHP labels behind instead of nothing.
            guard generation == refreshGeneration else { return }
            if case .running(_, let refreshedProjects, _, _, _, _, _, _, _) = state {
                startProjectReports(refreshedProjects, generation: generation, refreshStarted: reportsStarted)
            }
        } catch {
            await refreshClient.disconnect()
            refreshError = error.localizedDescription
            finishServiceReadinessCheck(.unavailable)
        }
    }

    private func beginPHPRequest(version: String) -> Bool {
        guard !isSettingsFixture else { phpError = "This isolated Settings fixture cannot operate Vaelen Core."; return false }
        guard !phpRequestInFlight, !phpConfigurationSaving else { return false }
        guard client != nil else { phpError = "Vaelen Core is unavailable."; return false }
        // A newer command owns the outcome now; a stale interruption watcher
        // must not overwrite it later.
        phpOperationWatchTask?.cancel()
        phpOperationWatchTask = nil
        phpError = nil
        phpCompletionMessage = nil
        phpRequestInFlight = true
        phpRequestTarget = version
        return true
    }

    private func finishPHPRequest(error: String? = nil) async {
        refreshGeneration += 1 // an older full snapshot must not overwrite this completion
        phpRequestInFlight = false
        phpRequestTarget = nil
        phpError = error
        // Settings inventory and configuration first: fast, and what the
        // completion message describes.
        await refreshPHPSettings()
        // Then the shared snapshot the menu-bar popover reads, plus fresh
        // project reports and route presentation — asynchronously, so slower
        // read-only work never keeps installation activity running after the
        // operation itself completed. Generation guards reject stale responses,
        // and refresh coalesces with any refresh already in flight.
        Task { @MainActor [weak self] in await self?.refresh() }
    }

    func refreshPHPSettings() async {
        guard !isSettingsFixture, !phpRequestInFlight else { return }
        let readClient = makeCoreClient()
        phpCatalogReadPending = true
        defer { phpCatalogReadPending = false }
        do {
            try await readClient.connect()
            phpCatalog = try await readClient.phpCatalogSnapshot()
            await phpSettings.refresh { try await readClient.phpConfiguration() }
            for issue in phpDefaultProjectIssues {
                if let report = try? await readClient.projectInspect(selector: issue.projectName, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path),
                   report.routeTargets.allSatisfy({ $0.disposition == .satisfied }) {
                    phpDefaultProjectIssues.removeAll { $0.projectName == issue.projectName }
                }
            }
            await readClient.disconnect()
        } catch {
            await readClient.disconnect()
            phpConfigurationError = "Could not refresh PHP runtime inventory: \(phpErrorMessage(error)). Showing last confirmed values."
        }
    }

    private func performPHPCommand(_ version: String, kind: PHPOperationKind, command: @MainActor (VaelenCoreClient) async throws -> Void) async {
        guard beginPHPRequest(version: version) else { return }
        let initialPhase: PHPOperationPhase = switch kind {
        case .defaultSelection, .start: .starting
        case .stop, .remove: .removing
        default: .downloading
        }
        phpOperation = PHPOperationState(kind: kind, targetVersion: version, phase: initialPhase)
        phpSettings.invalidateReads()
        let commandClient = makeCoreClient()
        do {
            try await commandClient.connect()
            let progressClient = makeCoreClient()
            try? await progressClient.connect()
            phpOperationPollTask?.cancel()
            phpOperationPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    if let operation = try? await progressClient.phpOperation(), !Task.isCancelled,
                       operation.kind == kind, operation.targetVersion == version,
                       operation.phase != .ready && operation.phase != .failed { self?.phpOperation = operation }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                }
                await progressClient.disconnect()
            }
            try await command(commandClient)
            await commandClient.disconnect()
            phpOperationPollTask?.cancel()
            phpOperationPollTask = nil
            phpOperation = PHPOperationState(kind: kind, targetVersion: version, phase: .ready)
            phpCompletionMessage = switch kind {
            case .install: "PHP \(version) installed. It remains stopped until you choose Start."
            // An update's message describes what actually happened. `updatePHP`
            // refines this with the convergence outcome.
            case .update: "PHP \(version) update completed."
            case .remove: "PHP \(version) removed. Saved settings and verified downloads are kept."
            case .defaultSelection: "PHP \(version) is now the default."
            case .start: "PHP \(version) started; saved default unchanged."
            case .stop: "PHP \(version) stopped; saved default unchanged."
            case .configurationUpdate: "PHP settings updated."
            }
            await finishPHPRequest()
        } catch {
            await commandClient.disconnect()
            phpOperationPollTask?.cancel()
            phpOperationPollTask = nil
            // A genuine Core rejection is reported as-is. A lost connection
            // proves nothing about the work itself, so reconcile against what
            // Core actually recorded before calling it a failure.
            if case CoreClientError.remote = error {
                phpOperation = PHPOperationState(kind: kind, targetVersion: version, phase: .failed, message: phpErrorMessage(error))
                phpCompletionMessage = nil
                await finishPHPRequest(error: phpErrorMessage(error))
            } else if let reconciled = await reconcileUncertainPHPOutcome(version: version, kind: kind) {
                phpOperation = reconciled.operation
                phpError = reconciled.errorMessage
                phpCompletionMessage = reconciled.completionMessage
                if reconciled.confirmedUpdate, kind == .update { phpSelectionRequest = version }
                await finishPHPRequest(error: reconciled.errorMessage)
            } else {
                phpOperation = PHPOperationState(kind: kind, targetVersion: version, phase: .failed, message: phpErrorMessage(error))
                phpCompletionMessage = nil
                await finishPHPRequest(error: phpErrorMessage(error))
            }
        }
    }

    /// Reconcile an interrupted command against Core's own records.
    ///
    /// The reply was lost, so the outcome is unknown — but Core keeps the
    /// operation's terminal state and the authoritative inventory. Use both:
    /// never declare success from a package directory alone, and never call an
    /// interrupted request a proven failure. Returns nil only when Core cannot
    /// be reached at all, in which case the caller reports the original error.
    private func reconcileUncertainPHPOutcome(version: String, kind: PHPOperationKind) async -> (operation: PHPOperationState, errorMessage: String?, completionMessage: String?, confirmedUpdate: Bool)? {
        let readClient = makeCoreClient()
        do {
            try await readClient.connect()
            let recorded = try await readClient.phpOperation()
            let catalog = try? await readClient.phpCatalogSnapshot()
            await readClient.disconnect()
            guard let recorded, recorded.kind == kind, recorded.targetVersion == version else {
                return (PHPOperationState(kind: kind, targetVersion: version, phase: .failed, message: nil),
                        "PHP \(version) could not be confirmed: the request was interrupted and Core holds no record of it. Check the inventory, then retry if needed.", nil, false)
            }
            switch recorded.phase {
            case .ready:
                // Core's own terminal record says the whole operation — package
                // work and convergence — finished. Confirm against inventory
                // rather than trusting the reply alone.
                let installed = catalog?.installedVersions.contains { $0.version == version } ?? false
                if installed {
                    return (recorded, nil, "PHP \(version) finished successfully. The reply was lost when the connection dropped, so this was verified against Core afterwards.", kind == .update)
                }
                return (recorded, "PHP \(version) needs checking: Core reports the operation finished, but the runtime is not in the inventory. Refresh and verify before retrying.", nil, false)
            case .failed:
                let detail = recorded.message ?? "The operation did not complete."
                return (recorded, "PHP \(version) did not complete: \(detail)", nil, false)
            case .starting, .downloading, .verifying, .installing, .startingRuntime, .converging, .removing:
                // Core is still working. Keep watching its operation to a
                // terminal state rather than freezing the strip mid-stage.
                watchInterruptedPHPOperation(version: version, kind: kind)
                return (recorded, nil, "PHP \(version) is still \(Self.plainStageName(recorded.phase)). The request was interrupted, but Core kept working; watching for its outcome.", false)
            case .removed:
                return (recorded, nil, "PHP \(version) was removed. The reply was lost when the connection dropped, so this was verified against Core afterwards.", false)
            }
        } catch {
            await readClient.disconnect()
            return nil
        }
    }

    /// Watch an operation Core is still running after our request was
    /// interrupted, until it reaches a terminal state. Cancelled as soon as a
    /// newer command starts, so it can never overwrite a newer outcome.
    private func watchInterruptedPHPOperation(version: String, kind: PHPOperationKind) {
        phpOperationWatchTask?.cancel()
        phpOperationWatchTask = Task { [weak self] in
            let watchClient = self?.makeCoreClient()
            try? await watchClient?.connect()
            defer { Task { await watchClient?.disconnect() } }
            for _ in 0..<600 {
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                guard let self, !self.phpRequestInFlight else { break }
                guard let observed = try? await watchClient?.phpOperation(),
                      observed.kind == kind, observed.targetVersion == version
                else { continue }
                switch observed.phase {
                case .ready, .removed:
                    self.phpOperation = observed
                    self.phpError = nil
                    self.phpCompletionMessage = "PHP \(version) finished after the interruption. Verified against Core."
                    if kind == .update { self.phpSelectionRequest = version }
                    await self.refreshPHPSettings()
                    break
                case .failed:
                    self.phpOperation = observed
                    self.phpCompletionMessage = nil
                    self.phpError = "PHP \(version) did not complete: \(observed.message ?? "The operation did not complete.")"
                    await self.refreshPHPSettings()
                    break
                default:
                    self.phpOperation = observed
                    continue
                }
                break
            }
            self?.phpOperationWatchTask = nil
        }
    }

    private static func plainStageName(_ phase: PHPOperationPhase) -> String {
        switch phase {
        case .starting: return "preparing"
        case .downloading: return "downloading"
        case .verifying: return "verifying"
        case .installing: return "installing"
        case .startingRuntime: return "starting"
        case .converging: return "finishing project routing"
        case .removing: return "removing"
        case .ready: return "finishing"
        case .removed: return "finishing removal"
        case .failed: return "finishing"
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
