import SwiftUI
import AppKit
import Observation
import ServiceManagement
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

/// Official Vaelen marks are kept in the app bundle. The current-color SVG is
/// used as an AppKit template in the menu bar so macOS controls tinting in light,
/// dark, and highlighted states. Settings uses the supplied appearance-specific
/// monochrome artwork rather than recoloring or approximating the mark.
private enum VaelenBrand {
    static let menuBarImage: NSImage = {
        guard let url = Bundle.main.url(forResource: "vaelen-mark-currentcolor", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Vaelen") ?? NSImage()
        }
        image.size = NSSize(width: 18, height: 18 * 145 / 214)
        image.isTemplate = true
        return image
    }()

    static var settingsImage: NSImage {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let asset = isDark ? "vaelen-mark-white" : "vaelen-mark-dark"
        guard let url = Bundle.main.url(forResource: asset, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return menuBarImage }
        image.size = NSSize(width: 36, height: 36 * 145 / 214)
        return image
    }
}

@MainActor
@Observable
final class AppModel {
    enum State {
        case connecting
        case running(CoreStatusResponse, [ProjectWire], PHPVersionsResult?, RouterStatus?, DNSStatus?, TLSStatus?, StandardPortsStatus?, MySQLStatus?, MailpitStatus?)
        case unavailable
        case incompatible(String)
    }

    private(set) var state: State = .connecting
    private(set) var projectReports: [ProjectEnvironmentReport] = []
    private(set) var phpCatalog: PHPRuntimeCatalog?
    private(set) var phpOperation: PHPOperationState?
    private(set) var phpError: String?
    private(set) var phpRequestInFlight = false
    private(set) var phpRequestTarget: String?
    private(set) var parkedFolders: [ParkedPathWire] = []
    private(set) var linkedProjects: [ProjectWire] = []
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
    private var refreshInFlight = false
    private var refreshRequested = false
    private var monitorTask: Task<Void, Never>?

    var savedServiceIntents: Set<String>? {
        guard case .running(let status, _, _, _, _, _, _, _, _) = state else { return nil }
        return status.serviceIntents
    }

    func startupIssue(for service: String) -> String? { startupServiceIssues[service] }

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
        do {
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
            let status = try await client.status()
            startupServiceIssues = status.serviceIssues ?? [:]
            if !VaelenActivitySignal.markActive() {
                serviceError = "Vaelen is running, but its shell activity signal could not be saved. PHP will refuse to fall back until this is repaired."
            }
            coreLaunchError = nil
            let currentProjects: [ProjectWire]
            let cachedPHP: PHPVersionsResult?
            let cachedRouting: RouterStatus?
            let cachedDNS: DNSStatus?
            let cachedTLS: TLSStatus?
            let cachedPorts: StandardPortsStatus?
            let cachedMySQL: MySQLStatus?
            let cachedMailpit: MailpitStatus?
            if case .running(_, let projects, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit) = state {
                currentProjects = projects
                cachedPHP = php; cachedRouting = routing; cachedDNS = dns; cachedTLS = tls
                cachedPorts = ports; cachedMySQL = mysql; cachedMailpit = mailpit
            } else {
                currentProjects = []
                cachedPHP = nil; cachedRouting = nil; cachedDNS = nil; cachedTLS = nil
                cachedPorts = nil; cachedMySQL = nil; cachedMailpit = nil
            }
            // Core connectivity itself is enough to leave Connecting. Service
            // probes and all project/catalog work may finish afterward.
            state = .running(status, currentProjects, cachedPHP, cachedRouting, cachedDNS, cachedTLS, cachedPorts, cachedMySQL, cachedMailpit)

            // Publish a usable Services view before project diagnostics or
            // remote catalog enrichment. Core connectivity is established by
            // this point; those slower requests must never own the Connecting
            // presentation.
            let php = try? await client.phpVersions()
            let routing = try? await client.routingStatus()
            let dns = try? await client.dnsStatus()
            let tls = try? await client.tlsStatus()
            let ports = try? await client.portsStatus()
            let mysql = try? await client.mysqlStatus()
            let mailpit = try? await client.mailpitStatus()
            guard generation == refreshGeneration else { await client.disconnect(); return }
            state = .running(status, currentProjects, php, routing, dns, tls, ports, mysql, mailpit)

            // Project discovery, per-project reports, and catalog enrichment
            // are secondary startup work. They can update the view later, but
            // they no longer gate Core readiness or service controls.
            let projects = try await client.projectList()
            let linkedProjects = try await client.linkedProjects()
            let parkedFolders = try await client.parkedPaths()
            var reports = [ProjectEnvironmentReport]()
            for project in projects {
                if let report = try? await client.projectStatus(selector: project.id?.uuidString, workingDirectory: project.path) {
                    reports.append(report)
                }
            }
            let phpCatalog = try? await client.phpCatalog()
            let phpOperation = try? await client.phpOperation()
            guard generation == refreshGeneration else { await client.disconnect(); return }
            projectReports = reports
            self.linkedProjects = linkedProjects
            self.parkedFolders = parkedFolders
            self.phpCatalog = phpCatalog
            self.phpOperation = phpOperation
            state = .running(status, projects, php, routing, dns, tls, ports, mysql, mailpit)
            refreshError = nil
        } catch let error as CoreClientError {
            guard generation == refreshGeneration else { return }
            await client.disconnect()
            if hasRunningSnapshot || isShowingRunningSnapshot {
                refreshError = refreshMessage(for: error)
                return
            }
            if case .coreUnavailable = error {
                coreLaunchError = "Vaelen Core did not become ready within 2 seconds. Try Refresh or relaunch Vaelen."
            }
            switch error {
            case .coreUnavailable: state = .unavailable
            case .protocolIncompatible(let client, let core): state = .incompatible("Protocol mismatch: client \(client), Core \(core). Restart Vaelen Core and try again.")
            case .coreIncompatible(let reason): state = .incompatible("\(reason) Restart Vaelen Core and try again.")
            default: state = .unavailable
            }
        } catch {
            guard generation == refreshGeneration else { return }
            await client.disconnect()
            if hasRunningSnapshot {
                refreshError = error.localizedDescription
                return
            }
            coreLaunchError = error.localizedDescription
            state = .unavailable
        }
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
        let refreshClient = makeCoreClient()
        do {
            try await refreshClient.connect()
            let status = try await refreshClient.status()
            let php = try? await refreshClient.phpVersions()
            let routing = try? await refreshClient.routingStatus()
            let dns = try? await refreshClient.dnsStatus()
            let mysql = try? await refreshClient.mysqlStatus()
            let mailpit = try? await refreshClient.mailpitStatus()
            let observedPorts = try? await refreshClient.portsStatus()
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
    static let cornerRadius: CGFloat = 8
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

struct StatusView: View {
    let model: AppModel
    @State private var selectedSection = Section.projects
    @Environment(\.openSettings) private var openSettings

    private enum Section: Hashable {
        case projects
        case services
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VaelenUI.spacing12) {
            HStack {
                Text("Vaelen").font(.headline)
                Spacer()
                coreStatus
            }
            switch model.state {
            case .connecting:
                Text("Connecting to Core…").foregroundStyle(.secondary)
            case .unavailable:
                Text(model.coreLaunchError ?? "Vaelen Core is unavailable. Start Vaelen and retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .incompatible(let reason):
                Text(reason).font(.caption)
            case .running(let status, let projects, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit):
                if model.refreshError != nil {
                    Label("Refresh failed; showing last known Core state.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("View", selection: $selectedSection) {
                    Text("Projects").tag(Section.projects)
                    Text("Services").tag(Section.services)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Vaelen section")

                switch selectedSection {
                case .projects:
                    ProjectsView(projects: projects, reports: model.projectReports, model: model)
                case .services:
                    ServicesView(status: status, php: php, routing: routing, dns: dns, tls: tls, ports: ports, mysql: mysql, mailpit: mailpit, model: model)
                }
            }
            Divider().opacity(0.65)
            if let error = model.serviceError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.small)
                    .accessibilityHint("Refresh Vaelen state")
                Spacer()
                Button("Settings…") { presentSettings() }
                Button(model.isQuitting ? "Quitting Vaelen…" : "Quit Vaelen") {
                    Task { await model.quitVaelen() }
                }
                .disabled(model.isQuitting)
            }
        }
        .padding(VaelenUI.popoverPadding)
        .frame(width: 400)
        .frame(height: popoverHeight)
        .onAppear {
            model.startMonitoring()
            VaelenAppDelegate.shared?.requestQuit = { Task { await model.quitVaelen() } }
        }
    }

    private var popoverHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let preferred = min(660, visibleHeight * 0.72)
        let usefulMinimum = min(510, visibleHeight * 0.68)
        return max(usefulMinimum, preferred)
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

    @ViewBuilder
    private var coreStatus: some View {
        switch model.state {
        case .connecting:
            VaelenStatusLabel("Connecting", systemImage: "circle.dotted", tint: .secondary)
        case .running:
            VaelenStatusLabel("Ready", systemImage: "circle.fill", tint: .secondary)
        case .unavailable:
            VaelenStatusLabel("Core Unavailable", systemImage: "circle", tint: .secondary)
        case .incompatible:
            VaelenStatusLabel("Core Incompatible", systemImage: "exclamationmark.circle", tint: .orange)
        }
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

struct ProjectsView: View {
    let projects: [ProjectWire]
    let reports: [ProjectEnvironmentReport]
    let model: AppModel

    var body: some View {
        if projects.isEmpty {
            VaelenEmptyState(title: "No Projects", systemImage: "folder", message: "Known Core projects will appear here.")
                .frame(minHeight: 180)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VaelenUI.spacing8) {
                    ForEach(projects, id: \.path) { project in
                        ProjectCard(project: project, report: reports.first { $0.identity.path == project.path }, model: model)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct ProjectCard: View {
    let project: ProjectWire
    let report: ProjectEnvironmentReport?
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: VaelenUI.spacing10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: VaelenUI.spacing6) {
            HStack {
                Text(project.name).font(.headline)
                Spacer()
            }
            if let framework = project.detectedFramework, !framework.isEmpty {
                Text(framework)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(displayPath(project.path))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let report {
                if let url = model.projectSiteURL(report) {
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let summary = environmentSummary(report), !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let attention = attentionDiagnostic(report) {
                    VaelenStatusLabel(attention.message, systemImage: attention.severity == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle", tint: attention.severity == .error ? .red : .orange)
                        .font(.caption2)
                        .lineLimit(2)
                }
            } else {
                VaelenStatusLabel("Project status unavailable", systemImage: "clock", tint: .secondary)
                    .font(.caption2)
            }
            if project.availability != PathAvailability.available.rawValue {
                VaelenStatusLabel("Folder unavailable", systemImage: "exclamationmark.triangle", tint: .orange)
                    .font(.caption2)
            }
            HStack {
                if let report, model.projectSiteURL(report) != nil {
                    Button("Open Site", systemImage: "safari") { model.openProjectSite(report) }
                }
                Button("Open Folder", systemImage: "folder") { model.openProjectFolder(project) }
                    .disabled(!model.canOpenProjectFolder(project))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Copy Path", systemImage: "doc.on.doc") { model.copyProjectPath(project) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More actions for \(project.name)")
        }
        .padding(.vertical, VaelenUI.spacing6)
        .padding(.horizontal, VaelenUI.spacing8)
        .background(.quaternary.opacity(0.20), in: RoundedRectangle(cornerRadius: VaelenUI.cornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project \(project.name)")
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

    private func attentionDiagnostic(_ report: ProjectEnvironmentReport) -> ProjectDiagnostic? {
        // Discovery is intentionally read-only. Its normal lack of a route or
        // requested services is not an error in the Projects surface.
        guard report.identity.registration == .linked else { return nil }
        return report.diagnostics.first { diagnostic in
            guard diagnostic.severity == .error || diagnostic.severity == .warning else { return false }
            if diagnostic.code == "ROUTE_INTENT_MISSING" && report.desired.secureWeb != true { return false }
            return true
        }
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

private struct ServiceRow<Actions: View>: View {
    let title: String
    let subtitle: String?
    let state: String
    let stateSymbol: String
    let stateTint: Color
    let busy: Bool
    let actions: Actions

    init(title: String, subtitle: String?, state: String, stateSymbol: String, stateTint: Color, busy: Bool = false, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.stateSymbol = stateSymbol
        self.stateTint = stateTint
        self.busy = busy
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: VaelenUI.spacing8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(subtitle)
                }
            }
            Spacer(minLength: VaelenUI.spacing8)
            VaelenStatusLabel(state, systemImage: stateSymbol, tint: stateTint)
                .font(.caption)
                .lineLimit(1)
            if busy { ProgressView().controlSize(.small) }
            actions
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(busy)
        }
        .padding(.vertical, VaelenUI.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(state)")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Runtimes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.bottom, VaelenUI.spacing6)
                if let php {
                    ServiceRow(title: "PHP", subtitle: php.installed.isEmpty ? "Not installed" : php.installed.map(\.version).joined(separator: " · "), state: php.default.map { "Default \($0)" } ?? "Ready", stateSymbol: "circle.fill", stateTint: .secondary) {
                        EmptyView()
                    }
                }

                Text("Services")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, VaelenUI.spacing12)
                    .padding(.bottom, VaelenUI.spacing6)
                if let mysql {
                    ServiceRow(title: "MySQL", subtitle: mysqlSubtitle(mysql), state: mysqlState(mysql).title, stateSymbol: mysqlState(mysql).symbol, stateTint: mysqlState(mysql).tint, busy: model.serviceOperationIs(for: "MySQL")) {
                        mysqlActions(mysql)
                    }
                }
                if let routing {
                    ServiceRow(title: "Caddy", subtitle: caddySubtitle(routing), state: routingState(routing).title, stateSymbol: routingState(routing).symbol, stateTint: routingState(routing).tint, busy: model.serviceOperationIs(for: "Caddy")) {
                        if routing.state == .running { Button("Stop Caddy") { Task { await model.stopRouting() } } }
                        else { Button("Start Caddy") { Task { await model.startRouting() } } }
                    }
                }
                if let mailpit {
                    ServiceRow(title: "Mailpit", subtitle: mailpitSubtitle(mailpit), state: mailpitState(mailpit).title, stateSymbol: mailpitState(mailpit).symbol, stateTint: mailpitState(mailpit).tint, busy: model.serviceOperationIs(for: "Mailpit")) {
                        mailpitActions(mailpit)
                    }
                }

                Text("Networking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, VaelenUI.spacing12)
                    .padding(.bottom, VaelenUI.spacing6)
                if let dns {
                    let control = ServiceControlPresentation.dns(status: dns, savedOn: model.savedServiceIntents?.contains("dns"), blockedReason: model.startupIssue(for: "dns"))
                    ServiceRow(title: "DNS", subtitle: control.detail, state: control.title, stateSymbol: serviceSymbol(control.title), stateTint: serviceTint(control.title), busy: model.serviceOperationIs(for: "DNS")) {
                        if control.action == .enable { Button("Enable DNS") { Task { await model.startDNS() } } }
                        if control.action == .retry { Button("Retry DNS Start") { Task { await model.startDNS() } } }
                        if control.action == .stop || control.action == .disable { Button("Stop DNS") { Task { await model.stopDNS() } } }
                        if control.canDisable && control.action == .retry { Button("Disable DNS") { Task { await model.stopDNS() } } }
                    }
                }
                if let tls {
                    ServiceRow(title: "Local HTTPS", subtitle: nil, state: tls.trustObserved ? "Trusted" : "Needs attention", stateSymbol: tls.trustObserved ? "checkmark" : "exclamationmark.triangle", stateTint: tls.trustObserved ? .secondary : .orange, busy: model.serviceOperationIs(for: "Local HTTPS")) {
                        if tls.state == .createdButUntrusted { Button("Trust Local CA") { Task { await model.trustLocalCA() } } }
                        if tls.trustObserved { Button("Remove Local CA Trust") { Task { await model.removeLocalCATrust() } } }
                    }
                }
                if let ports {
                    let control = ServiceControlPresentation.standardPorts(status: ports, savedOn: model.savedServiceIntents?.contains("standard-ports"), blockedReason: model.startupIssue(for: "standard-ports"))
                    ServiceRow(title: "Standard Ports", subtitle: control.detail, state: control.title, stateSymbol: serviceSymbol(control.title), stateTint: serviceTint(control.title), busy: model.serviceOperationIs(for: "standard ports")) {
                        if control.action == .enable { Button("Enable Standard Ports") { Task { await model.installStandardPorts() } } }
                        if control.action == .retry { Button("Retry Standard Ports") { Task { await model.installStandardPorts() } } }
                        if control.action == .disable { Button("Disable Standard Ports") { Task { await model.removeStandardPorts() } } }
                    }
                }
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

    private func mysqlSubtitle(_ mysql: MySQLStatus) -> String {
        let version = mysql.selectedVersion ?? mysql.installedVersion
        return [version, mysql.state == .notInstalled ? nil : "Port \(mysql.port)"].compactMap { $0 }.joined(separator: " · ")
    }

    private func mailpitSubtitle(_ mailpit: MailpitStatus) -> String? {
        if mailpit.state == .notInstalled { return "Local mail testing" }
        return [mailpit.installedVersion, "SMTP \(mailpit.smtpPort)"].compactMap { $0 }.joined(separator: " · ")
    }

    private func caddySubtitle(_ routing: RouterStatus) -> String {
        [routing.providerVersion, routing.routeCount == 1 ? "1 routed project" : "\(routing.routeCount) routed projects"].compactMap { $0 }.joined(separator: " · ")
    }

    private func mysqlState(_ mysql: MySQLStatus) -> ServicePresentation {
        switch mysql.state {
        case .running where mysql.health == "healthy": return .init("Running", "circle.fill", .secondary)
        case .notInstalled: return .init("Not installed", "circle", .secondary)
        case .conflict, .unhealthy: return .init("Needs attention", "exclamationmark.triangle", .orange)
        default: return .init(mysql.state.rawValue.capitalized, "circle", .secondary)
        }
    }

    private func mailpitState(_ mailpit: MailpitStatus) -> ServicePresentation {
        switch mailpit.state {
        case .running where mailpit.health == "healthy": return .init("Running", "circle.fill", .secondary)
        case .notInstalled: return .init("Not installed", "circle", .secondary)
        case .conflict, .unhealthy: return .init("Needs attention", "exclamationmark.triangle", .orange)
        default: return .init(mailpit.state.rawValue.capitalized, "circle", .secondary)
        }
    }

    private func routingState(_ routing: RouterStatus) -> ServicePresentation {
        routing.state == .running && routing.health == .healthy ? .init("Running", "circle.fill", .secondary) : .init("Needs attention", "exclamationmark.triangle", .orange)
    }

    private func dnsState(_ dns: DNSStatus) -> ServicePresentation {
        dns.supportsLocalResolution ? .init("Ready", "checkmark", .secondary) : .init("Needs attention", "exclamationmark.triangle", .orange)
    }

    private func serviceSymbol(_ title: String) -> String {
        title == "Needs attention" || title == "State unavailable" ? "exclamationmark.triangle" : (title.hasPrefix("On") || title == "Enabled" ? "checkmark" : "circle")
    }

    private func serviceTint(_ title: String) -> Color {
        title == "Needs attention" || title == "State unavailable" ? .orange : .secondary
    }

    @ViewBuilder private func mysqlActions(_ mysql: MySQLStatus) -> some View {
        if mysql.state == .notInstalled { Button("Install MySQL") { Task { await model.installMySQL() } } }
        else if mysql.state == .stopped || mysql.state == .installed || mysql.state == .unhealthy { Button(mysql.health == "not-initialized" ? "Initialize and Start MySQL" : "Start MySQL") { Task { await model.startMySQL() } } }
        if mysql.state == .running { Button("Stop MySQL") { Task { await model.stopMySQL() } } }
    }

    @ViewBuilder private func mailpitActions(_ mailpit: MailpitStatus) -> some View {
        if mailpit.state == .notInstalled { Button("Install Mailpit") { Task { await model.installMailpit() } } }
        else if mailpit.state == .installed || mailpit.state == .stopped || mailpit.state == .unhealthy || mailpit.state == .conflict { Button("Start Mailpit") { Task { await model.startMailpit() } } }
        if mailpit.state == .running { Button("Stop Mailpit") { Task { await model.stopMailpit() } }; Button("Open Mailpit") { Task { await model.openMailpit() } } }
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
            DispatchQueue.main.async {
                SettingsWindowActivation.bringForward()
            }
        }
    }
}

struct GeneralSettingsView: View {
    let model: AppModel

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
        }
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
        HStack(spacing: VaelenUI.spacing8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).lineLimit(1)
                if let framework = project.detectedFramework, !framework.isEmpty {
                    Text("\(framework) · \(displayPath(project.path))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(displayPath(project.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
