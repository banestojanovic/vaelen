import SwiftUI
import AppKit
import Observation
import ServiceManagement
import VaelenIPC
import VaelenCore
import Darwin

@main
struct VaelenApp: App {
    @NSApplicationDelegateAdaptor(VaelenApplicationDelegate.self) private var applicationDelegate
    @State private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--vaelen-observe-registration") {
            // This is a one-shot, read-only controller witness.  It accepts
            // no identity or operation choice from the caller: Core supplies
            // the bound envelope and the signed canonical app echoes it.
            do {
                let request = try JSONDecoder().decode(
                    LifecycleControllerObservationRequest.self,
                    from: FileHandle.standardInput.readDataToEndOfFile())
                guard request.target == LifecycleCanonicalIdentity.target,
                      LifecycleCanonicalIdentity.isAllowedControllerURL(Bundle.main.bundleURL),
                      ArtifactPreflight.validate(appURL: Bundle.main.bundleURL) != nil else { throw CocoaError(.validationMissingMandatoryProperty) }
                let service = SMAppService.agent(plistName: "dev.vaelen.vaelend.agent.plist")
                let registration: ObservationValue
                switch service.status {
                case .enabled: registration = .true
                case .notRegistered: registration = .false
                default: registration = .unknown
                }
                let response = LifecycleControllerObservationResponse(
                    operationID: request.operationID, generation: request.generation,
                    target: request.target, nonce: request.nonce,
                    sessionBinding: request.sessionBinding,
                    registrationMatch: registration,
                    source: "signed-canonical-controller")
                FileHandle.standardOutput.write(try JSONEncoder().encode(response))
                exit(0)
            } catch {
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--vaelen-authorized-unregister") {
            Task { @MainActor in
                do {
                    let request = try JSONDecoder().decode(LifecycleControllerMutationRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
                    guard LifecycleControllerMutationValidator.validate(request, controllerPath: Bundle.main.bundleURL.path) else { throw CocoaError(.validationMissingMandatoryProperty) }
                    try await Self.awaitUnregisterCanonicalAgent()
                    let response = LifecycleControllerMutationResponse(operationID: request.operationID, generation: request.generation, nonce: request.nonce, sessionBinding: request.sessionBinding, success: true)
                    FileHandle.standardOutput.write(try JSONEncoder().encode(response)); exit(0)
                } catch { exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--vaelen-authorized-development-cleanup") {
            Task { @MainActor in
                do {
                    // Cleanup is itself a signed-product operation. Refuse to
                    // touch ServiceManagement unless this exact installed
                    // controller and nested daemon satisfy the canonical
                    // identity/layout contract.
                    guard LifecycleCanonicalIdentity.isAllowedControllerURL(Bundle.main.bundleURL),
                          ArtifactPreflight.validate(appURL: Bundle.main.bundleURL) != nil else {
                        throw CocoaError(.validationMissingMandatoryProperty)
                    }
                    let service = SMAppService.agent(plistName: "dev.vaelen.vaelend.agent.plist")
                    if service.status == .enabled { try await service.unregister() }
                    try Self.verifyDevelopmentCleanupExternalAbsence()
                    let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout().databaseURL)
                     do {
                         try store.performAuthorizedDevelopmentCleanup()
                         // The lifecycle fence and its promoted bootstrap
                         // handoff are one exact development residue.
                         if try store.bootstrapReceiptEvidence() != nil {
                             try store.archiveAuthorizedPromotedReceipt()
                         }
                     } catch AuthorizedDevelopmentCleanupError.residueMismatch {
                         // A prior signed cleanup may already have cleared the
                         // lifecycle fence while leaving the exact receipt.
                         try store.archiveAuthorizedPromotedReceiptWithRejectedMACForDevelopment()
                     }
                    NSLog("MANUAL DEVELOPMENT ACCEPTANCE CLEANUP: canonical agent unregistered and exact residue archived")
                } catch { NSLog("Vaelen development cleanup failed: %@", String(describing: error)) }
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--vaelen-authorized-off-recovery") {
            Task.detached {
                do {
                    guard LifecycleCanonicalIdentity.isAllowedControllerURL(Bundle.main.bundleURL),
                          ArtifactPreflight.validate(appURL: Bundle.main.bundleURL) != nil else {
                        throw CocoaError(.validationMissingMandatoryProperty)
                    }
                    let daemon = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/vaelend")
                    let process = Process(); process.executableURL = daemon
                    process.arguments = ["--vaelen-authorized-off-recovery"]
                    try process.run(); process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw BootstrapError.recoveryRequired("Exact Off recovery refused by Core.") }
                } catch { NSLog("Vaelen Off recovery failed: %@", String(describing: error)) }
                exit(0)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--vaelen-start-token"),
           index + 1 < CommandLine.arguments.count {
            let token = CommandLine.arguments[index + 1]
            Task.detached {
                do {
                    let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout().databaseURL)
                    let executor = CoreAbsentBootstrapExecutor(store: store, authenticator: KeychainBootstrapReceiptAuthenticator.shared)
                    _ = try await executor.execute(explicitInvocationToken: token,
                                                    controllerPath: Bundle.main.bundleURL.standardizedFileURL.path,
                                                    user: NSUserName())
                } catch { NSLog("Vaelen explicit start failed: %@", String(describing: error)) }
            }
        }
        if CommandLine.arguments.contains("--vaelen-authorized-legacy-recovery") {
            Task.detached {
                do {
                    let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout().databaseURL)
                    let executor = CoreAbsentBootstrapExecutor(store: store, authenticator: KeychainBootstrapReceiptAuthenticator.shared)
                    _ = try await executor.recoverLegacyPreInvocationOrphan()
                } catch { NSLog("Vaelen legacy recovery failed: %@", String(describing: error)) }
            }
        }
        if CommandLine.arguments.contains("--vaelen-authorized-modern-recovery") {
            Task.detached {
                do {
                    let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout().databaseURL)
                    let executor = CoreAbsentBootstrapExecutor(store: store, authenticator: KeychainBootstrapReceiptAuthenticator.shared)
                    _ = try await executor.recoverRegisteredOrphan()
                } catch { NSLog("Vaelen modern recovery failed: %@", String(describing: error)) }
            }
        }
        if CommandLine.arguments.contains("--vaelen-authorized-known-bootstrap-recovery") {
            Task.detached {
                do {
                    let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout().databaseURL)
                    let executor = CoreAbsentBootstrapExecutor(store: store, authenticator: KeychainBootstrapReceiptAuthenticator.shared)
                    try await executor.recoverKnownSucceededReceipt()
                    NSLog("Vaelen known bootstrap receipt recovery: archived exact receipt")
                } catch { NSLog("Vaelen known bootstrap receipt recovery failed: %@", String(describing: error)) }
            }
        }
    }

    private nonisolated static func awaitUnregisterCanonicalAgent() async throws {
        let service = SMAppService.agent(plistName: "dev.vaelen.vaelend.agent.plist")
        // The controller is the sole ServiceManagement mutation context for
        // unregister; Core remains the authority through the envelope.
        try await service.unregister()
    }

    private nonisolated static func verifyDevelopmentCleanupExternalAbsence() throws {
        let paths = CoreEndpointPaths()
        let fm = FileManager.default
        guard !fm.fileExists(atPath: paths.socket.path) else { throw CocoaError(.fileNoSuchFile) }
        for path in [paths.lock.path, paths.bootstrapLock.path] {
            let fd = open(path, O_RDWR | O_NOFOLLOW)
            if fd >= 0 {
                defer { close(fd) }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: "VaelenDevelopmentCleanup", code: 1) }
                _ = flock(fd, LOCK_UN)
            } else if errno != ENOENT {
                throw NSError(domain: "VaelenDevelopmentCleanup", code: 1)
            }
        }
        let pipe = Pipe(); let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "uid=,command="]
        ps.standardOutput = pipe
        try ps.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        guard ps.terminationStatus == 0,
              !output.split(separator: "\n").contains(where: { $0.contains("Contents/Resources/vaelend") }) else {
            throw NSError(domain: "VaelenDevelopmentCleanup", code: 1)
        }
    }

    var body: some Scene {
        MenuBarExtra("Vaelen", systemImage: "wrench.and.screwdriver") {
            StatusView(model: model)
                .task { await model.consumePendingExternalURL(); await model.monitor() }
                .onOpenURL { url in Task { await model.handleExternalURL(url) } }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class VaelenApplicationDelegate: NSObject, NSApplicationDelegate {
    private static var pendingURL: URL?
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Self.pendingURL = url
        if let model = AppModel.shared {
            Self.pendingURL = nil
            Task { await model.handleExternalURL(url) }
        }
    }
    func application(_ application: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first, let url = URL(string: first) {
            Self.pendingURL = url
            if let model = AppModel.shared {
                Self.pendingURL = nil
                Task { await model.handleExternalURL(url) }
            }
        }
    }
    static func takePendingURL() -> URL? { defer { pendingURL = nil }; return pendingURL }
}

@MainActor
@Observable
final class AppModel {
    static weak var shared: AppModel?
    enum State {
        case connecting
        case running(CoreStatusResponse, [ProjectWire], PHPVersionsResult?, RouterStatus?, DNSStatus?, TLSStatus?, StandardPortsStatus?, MySQLStatus?, MailpitStatus?, LifecycleStatusResult?)
        case unavailable
        case incompatible(String)
    }

    private(set) var state: State = .connecting
    private(set) var projectReports: [ProjectEnvironmentReport] = []
    private(set) var trustError: String?
    private var client: VaelenCoreClient?
    private var refreshGeneration = 0

    init() {
        Self.shared = self
        // Bounded signed-controller recovery entrypoint for environments
        // where LaunchServices cannot deliver a URL to a disposable archive
        // copy. The flag is not a public selector: it carries no IDs and
        // always invokes the fixed authorization above.
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        if let client { await client.disconnect() }
        let paths = CoreEndpointPaths()
        let client = VaelenCoreClient(
            transport: UnixSocketTransport(path: paths.socketPath),
            identity: ClientIdentity(name: "Vaelen.app", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
        )
        self.client = client
        state = .connecting
        do {
            try await client.connect()
            let status = try await client.status()
            let lifecycle = try? await client.lifecycleStatus()
            let projects = try await client.projectList()
            let reports = await withTaskGroup(of: ProjectEnvironmentReport?.self, returning: [ProjectEnvironmentReport].self) { group in
                for project in projects {
                    group.addTask { try? await client.projectStatus(selector: project.id?.uuidString, workingDirectory: project.path) }
                }
                var reports = [ProjectEnvironmentReport]()
                while let report = await group.next() {
                    if let report { reports.append(report) }
                }
                return reports
            }
            let php = try? await client.phpVersions()
            let routing = try? await client.routingStatus()
            let dns = try? await client.dnsStatus()
            let tls = try? await client.tlsStatus()
            let ports = try? await client.portsStatus()
            let mysql = try? await client.mysqlStatus()
            let mailpit = try? await client.mailpitStatus()
            guard generation == refreshGeneration else { await client.disconnect(); return }
            projectReports = reports
            state = .running(status, projects, php, routing, dns, tls, ports, mysql, mailpit, lifecycle)
        } catch let error as CoreClientError {
            guard generation == refreshGeneration else { return }
            await client.disconnect()
            switch error {
            case .coreUnavailable: state = .unavailable
            case .protocolIncompatible(let client, let core): state = .incompatible("Protocol mismatch: client \(client), Core \(core). Restart Vaelen Core and try again.")
            case .coreIncompatible(let reason): state = .incompatible("\(reason) Restart Vaelen Core and try again.")
            default: state = .unavailable
            }
        } catch {
            guard generation == refreshGeneration else { return }
            await client.disconnect()
            state = .unavailable
        }
    }

    func trustLocalCA() async {
        trustError = nil
        guard let client else { return }
        do { _ = try await client.tlsTrustLocalCA(); await refresh() } catch { trustError = error.localizedDescription }
    }

    func removeLocalCATrust() async {
        trustError = nil
        guard let client else { return }
        do { _ = try await client.tlsRemoveLocalCATrust(); await refresh() } catch { trustError = error.localizedDescription }
    }

    func installStandardPorts() async {
        trustError = nil
        guard let client else { return }
        do {
            // Production path: register the signed helper through macOS; the
            // system owns authentication and Vaelen never sees credentials.
            // Ad-hoc development builds cannot register (this is expected);
            // use Scripts/dev-standard-ports-install.sh for development.
            if #available(macOS 13, *) {
                let service = SMAppService.daemon(plistName: "dev.vaelen.privileged-helper.plist")
                if service.status != .enabled { try service.register() }
            }
            _ = try await client.portsInstall(); await refresh()
        } catch { trustError = error.localizedDescription }
    }

    func removeStandardPorts() async {
        trustError = nil
        guard let client else { return }
        do { _ = try await client.portsRemove(); await refresh() } catch { trustError = error.localizedDescription }
    }

    func lifecycleOn() async {
        trustError = nil
        guard let client else { return }
        do { _ = try await client.lifecycleOn(actor: "Vaelen.app", target: LifecycleCanonicalIdentity.target); await refresh() }
        catch { trustError = error.localizedDescription }
    }

    func lifecycleOff() async {
        trustError = nil
        guard let client else { return }
        do { _ = try await client.lifecycleOff(actor: "Vaelen.app", target: LifecycleCanonicalIdentity.target); await refresh() }
        catch { trustError = error.localizedDescription }
    }

    /// The app is the signed controller. The URL is only an explicit
    /// user-invocation signal; the executor still fixes identity, layout,
    /// receipt, lock, and the single ServiceManagement operation.
    func bootstrapForExplicitStart(token: String, controllerPath: String) async {
        do {
            let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout().databaseURL)
            let executor = CoreAbsentBootstrapExecutor(store: store, authenticator: KeychainBootstrapReceiptAuthenticator.shared)
            _ = try await executor.execute(explicitInvocationToken: token, controllerPath: controllerPath, user: NSUserName())
        } catch {
            trustError = error.localizedDescription
        }
    }

    func consumePendingExternalURL() async {
        if let url = VaelenApplicationDelegate.takePendingURL() { await handleExternalURL(url) }
    }

    func handleExternalURL(_ url: URL) async {
        if url.scheme == "vaelen", url.host == "recover-legacy", url.path == "" {
            // This host is not a general recovery API. It is the single,
            // source-bound M14 authorization for the fixed pre-invocation
            // orphan; no caller-supplied IDs or invocation provenance enter.
            do {
                let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout().databaseURL)
                let executor = CoreAbsentBootstrapExecutor(store: store)
                _ = try await executor.recoverLegacyPreInvocationOrphan()
            } catch { trustError = error.localizedDescription }
            return
        }
        guard url.scheme == "vaelen", url.host == "start",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            await recordBootstrapURLDiagnostic(url: url, detail: "malformed or missing start token")
            return
        }
        await bootstrapForExplicitStart(token: token, controllerPath: Bundle.main.bundleURL.standardizedFileURL.path)
    }

    func recordBootstrapURLDiagnostic(url: URL, detail: String) async {
        guard let store = try? SQLiteStateStore(databaseURL: VaelenFilesystemLayout().databaseURL) else { return }
        let id = UUID()
        try? store.recordDiagnostic(.init(correlationID: id, phase: .urlReceipt, outcome: "rejected", detail: detail + " scheme=" + (url.scheme ?? "none"), databasePath: store.databaseURL.path, user: NSUserName()))
    }

    func installMySQL() async { trustError = nil; guard let client else { return }; do { _ = try await client.mysqlInstall(MySQLModule.defaultVersion); _ = try await client.mysqlUse(MySQLModule.defaultVersion); await refresh() } catch { trustError = error.localizedDescription } }
    func startMySQL() async { trustError = nil; guard let client else { return }; do { let status = try await client.mysqlStatus(); if status.health == "not-initialized" { _ = try await client.mysqlInitialize() }; _ = try await client.mysqlStart(); await refresh() } catch { trustError = error.localizedDescription } }
    func stopMySQL() async { trustError = nil; guard let client else { return }; do { _ = try await client.mysqlStop(); await refresh() } catch { trustError = error.localizedDescription } }
    func installMailpit() async { trustError = nil; guard let client else { return }; do { _ = try await client.mailpitInstall(MailpitModule.defaultVersion); await refresh() } catch { trustError = error.localizedDescription } }
    func startMailpit() async { trustError = nil; guard let client else { return }; do { _ = try await client.mailpitStart(); await refresh() } catch { trustError = error.localizedDescription } }
    func stopMailpit() async { trustError = nil; guard let client else { return }; do { _ = try await client.mailpitStop(); await refresh() } catch { trustError = error.localizedDescription } }
    func openMailpit() async { trustError = nil; guard let client else { return }; do { let status = try await client.mailpitStatus(); guard status.state == .running else { throw NSError(domain: "Vaelen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mailpit is not healthy; start it before opening the UI."]) }; NSWorkspace.shared.open(URL(string: status.uiEndpoint)!); } catch { trustError = error.localizedDescription } }

    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

struct StatusView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vaelen").font(.headline)
            switch model.state {
            case .connecting:
                Label("Core Connecting", systemImage: "circle.dotted")
            case .unavailable:
                Label("Core Unavailable", systemImage: "circle")
            case .incompatible(let reason):
                Label("Core Incompatible", systemImage: "exclamationmark.circle")
                Text(reason).font(.caption)
            case .running(let status, let projects, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit, let lifecycle):
                Label("Core Running", systemImage: "circle.fill").foregroundStyle(.green)
                Text("Version  \(status.core.version)")
                Text("PID       \(status.core.pid)")
                Text("Protocol  \(status.protocolVersion)")
                Text("Projects  \(projects.count)")
                if let lifecycle {
                    Text("Lifecycle  \(lifecycle.intent?.intent.rawValue ?? "unknown")")
                    Text("Readiness  \(lifecycle.readiness.rawValue)")
                    if lifecycle.operation?.state == .unknownRecoveryRequired {
                        Text("Recovery required").foregroundStyle(.red)
                    } else if lifecycle.intent?.intent == .on {
                        Button("Turn Off") { Task { await model.lifecycleOff() } }
                    } else {
                        Button("Turn On") { Task { await model.lifecycleOn() } }
                    }
                }
                if let php { Text("PHP       \(php.installed.map(\.version).joined(separator: ", "))") }
                if let routing { Text("Routing   \(routing.state.rawValue) (\(routing.routeCount))") }
                if let dns { Text("DNS       \(dns.state.rawValue)") }
                if let tls {
                    Text("Local CA  \(tls.state.rawValue)")
                    Text("Trust     \(tls.trustObserved ? "Trusted" : "Not Trusted")")
                    if let trustError = model.trustError { Text(trustError).font(.caption).foregroundStyle(.red) }
                    if tls.state == .createdButUntrusted { Button("Trust Local CA") { Task { await model.trustLocalCA() } } }
                    if tls.trustObserved { Button("Remove Local CA Trust") { Task { await model.removeLocalCATrust() } } }
                }
                if let ports {
                    Text("Std Ports \(ports.state.rawValue)")
                    if ports.state == .absent || ports.state == .unhealthy { Button("Enable Standard Ports") { Task { await model.installStandardPorts() } } }
                    if ports.state == .healthy || ports.state == .installed { Button("Disable Standard Ports") { Task { await model.removeStandardPorts() } } }
                }
                if let mysql {
                    Text("MySQL     \(mysql.state.rawValue)")
                    Text("Version   \(mysql.selectedVersion ?? "none")")
                    Text("Port      \(mysql.port)")
                    if let pid = mysql.pid { Text("PID       \(pid)") }
                    if mysql.state == .notInstalled { Button("Install MySQL") { Task { await model.installMySQL() } } }
                    else if mysql.state == .stopped || mysql.state == .installed || mysql.state == .unhealthy { Button(mysql.health == "not-initialized" ? "Initialize and Start MySQL" : "Start MySQL") { Task { await model.startMySQL() } } }
                    if mysql.state == .running { Button("Stop MySQL") { Task { await model.stopMySQL() } } }
                }
                if let mailpit {
                    Text("Mailpit    \(mailpit.state.rawValue)")
                    Text("Version    \(mailpit.installedVersion ?? "none")")
                    Text("SMTP       \(mailpit.smtpPort)")
                    Text("UI         \(mailpit.httpPort)")
                    if mailpit.state == .notInstalled { Button("Install Mailpit") { Task { await model.installMailpit() } } }
                    else if mailpit.state == .installed || mailpit.state == .stopped || mailpit.state == .unhealthy || mailpit.state == .conflict { Button("Start Mailpit") { Task { await model.startMailpit() } } }
                    if mailpit.state == .running { Button("Stop Mailpit") { Task { await model.stopMailpit() } }; Button("Open Mailpit") { Task { await model.openMailpit() } } }
                }
                ForEach(projects.prefix(5), id: \.path) { project in
                    Text("\(project.name) (\(project.registration))")
                        .font(.caption)
                    if let report = model.projectReports.first(where: { $0.identity.path == project.path }) {
                        Text("  \(report.diagnostics.count) diagnostics")
                            .font(.caption2)
                            .foregroundStyle(report.diagnostics.contains { $0.severity == .error } ? .red : .secondary)
                        if let diagnostic = report.diagnostics.first {
                            Text("  \(diagnostic.code)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            Button("Refresh") { Task { await model.refresh() } }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 240)
    }
}
