import SwiftUI
import AppKit
import Observation
import ServiceManagement
import VaelenIPC
import VaelenCore

@main
struct VaelenApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StatusView(model: model)
        } label: {
            Label("Vaelen", systemImage: "wrench.and.screwdriver")
                .onAppear { model.startMonitoring() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
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
    private(set) var parkedFolders: [ParkedPathWire] = []
    private(set) var linkedProjects: [ProjectWire] = []
    private(set) var trustError: String?
    private(set) var refreshError: String?
    private(set) var relationshipError: String?
    private(set) var relationshipMutationInFlight = false
    private var client: VaelenCoreClient?
    private var refreshGeneration = 0
    private var refreshInFlight = false
    private var refreshRequested = false
    private var monitorTask: Task<Void, Never>?

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
            try await client.connect()
            let status = try await client.status()
            let projects = try await client.projectList()
            let linkedProjects = try await client.linkedProjects()
            let parkedFolders = try await client.parkedPaths()
            var reports = [ProjectEnvironmentReport]()
            for project in projects {
                if let report = try? await client.projectStatus(selector: project.id?.uuidString, workingDirectory: project.path) {
                    reports.append(report)
                }
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
            self.linkedProjects = linkedProjects
            self.parkedFolders = parkedFolders
            state = .running(status, projects, php, routing, dns, tls, ports, mysql, mailpit)
            refreshError = nil
        } catch let error as CoreClientError {
            guard generation == refreshGeneration else { return }
            await client.disconnect()
            if hasRunningSnapshot {
                refreshError = refreshMessage(for: error)
                return
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

    func installMySQL() async { trustError = nil; guard let client else { return }; do { _ = try await client.mysqlInstall(MySQLModule.defaultVersion); _ = try await client.mysqlUse(MySQLModule.defaultVersion); await refresh() } catch { trustError = error.localizedDescription } }
    func startMySQL() async { trustError = nil; guard let client else { return }; do { let status = try await client.mysqlStatus(); if status.health == "not-initialized" { _ = try await client.mysqlInitialize() }; _ = try await client.mysqlStart(); await refresh() } catch { trustError = error.localizedDescription } }
    func stopMySQL() async { trustError = nil; guard let client else { return }; do { _ = try await client.mysqlStop(); await refresh() } catch { trustError = error.localizedDescription } }
    func installMailpit() async { trustError = nil; guard let client else { return }; do { _ = try await client.mailpitInstall(MailpitModule.defaultVersion); await refresh() } catch { trustError = error.localizedDescription } }
    func startMailpit() async { trustError = nil; guard let client else { return }; do { _ = try await client.mailpitStart(); await refresh() } catch { trustError = error.localizedDescription } }
    func stopMailpit() async { trustError = nil; guard let client else { return }; do { _ = try await client.mailpitStop(); await refresh() } catch { trustError = error.localizedDescription } }
    func openMailpit() async { trustError = nil; guard let client else { return }; do { let status = try await client.mailpitStatus(); guard status.state == .running else { throw NSError(domain: "Vaelen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mailpit is not healthy; start it before opening the UI."]) }; NSWorkspace.shared.open(URL(string: status.uiEndpoint)!); } catch { trustError = error.localizedDescription } }

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
        let route = report.observed.route
        guard route.intentExists,
              route.associationState == .durable,
              route.routerState == .running,
              route.routerHealth == .healthy,
              let hostname = route.hostname,
              !hostname.isEmpty,
              report.observed.dns.state == .installed,
              report.observed.dns.ownership == .vaelen,
              report.observed.dns.health == "healthy",
              report.observed.standardPorts.state == .healthy else { return nil }
        if route.tls == .local {
            guard report.observed.tls.state == .trusted,
                  report.observed.tls.trustObserved,
                  report.observed.tls.ownership == .owned else { return nil }
        }
        return URL(string: "\(route.tls == .local ? "https" : "http")://\(hostname)")
    }

    func openProjectSite(_ report: ProjectEnvironmentReport) {
        guard let url = projectSiteURL(report) else { return }
        NSWorkspace.shared.open(url)
    }

    func parkFolder(at path: String) async {
        guard beginRelationshipMutation(), let client else { return }
        do {
            _ = try await client.park(path: path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            finishRelationshipMutation()
            await refresh()
        } catch {
            finishRelationshipMutation(error: error)
        }
    }

    func removeParkedFolder(_ folder: ParkedPathWire) async {
        guard beginRelationshipMutation(), let client else { return }
        do {
            try await client.unpark(path: folder.path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            finishRelationshipMutation()
            await refresh()
        } catch {
            finishRelationshipMutation(error: error)
        }
    }

    func linkProject(at path: String) async {
        guard beginRelationshipMutation(), let client else { return }
        do {
            _ = try await client.link(path: path, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path, name: nil)
            finishRelationshipMutation()
            await refresh()
        } catch {
            finishRelationshipMutation(error: error)
        }
    }

    func unlinkProject(_ project: ProjectWire) async {
        guard beginRelationshipMutation(), let client else { return }
        do {
            try await client.unlink(path: project.path, name: nil, workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            finishRelationshipMutation()
            await refresh()
        } catch {
            finishRelationshipMutation(error: error)
        }
    }

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in await self?.monitor() }
    }

    private func monitor() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(5))
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

    private func beginRelationshipMutation() -> Bool {
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
        relationshipMutationInFlight = true
        return true
    }

    private func finishRelationshipMutation(error: Error? = nil) {
        relationshipMutationInFlight = false
        relationshipError = error?.localizedDescription
    }
}

struct StatusView: View {
    let model: AppModel
    @State private var selectedSection = Section.projects

    private enum Section: Hashable {
        case projects
        case services
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Vaelen").font(.headline)
                Spacer()
                coreStatus
            }
            switch model.state {
            case .connecting:
                Text("Connecting to Core…").foregroundStyle(.secondary)
            case .unavailable:
                Text("Vaelen Core is unavailable.").foregroundStyle(.secondary)
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

                switch selectedSection {
                case .projects:
                    ProjectsView(projects: projects, reports: model.projectReports, model: model)
                case .services:
                    ServicesView(status: status, php: php, routing: routing, dns: dns, tls: tls, ports: ports, mysql: mysql, mailpit: mailpit, model: model)
                }
            }
            Divider()
            HStack {
                Button("Refresh") { Task { await model.refresh() } }
                Spacer()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 380)
        .frame(minHeight: 280)
        .onAppear { model.startMonitoring() }
    }

    @ViewBuilder
    private var coreStatus: some View {
        switch model.state {
        case .connecting:
            Label("Connecting", systemImage: "circle.dotted")
        case .running:
            Label("Core Running", systemImage: "circle.fill").foregroundStyle(.green)
        case .unavailable:
            Label("Core Unavailable", systemImage: "circle")
        case .incompatible:
            Label("Core Incompatible", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }
}

struct ProjectsView: View {
    let projects: [ProjectWire]
    let reports: [ProjectEnvironmentReport]
    let model: AppModel

    var body: some View {
        if projects.isEmpty {
            ContentUnavailableView("No Projects", systemImage: "folder", description: Text("Known Core projects will appear here."))
                .frame(minHeight: 180)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(projects, id: \.path) { project in
                        ProjectCard(project: project, report: reports.first { $0.identity.path == project.path }, model: model)
                    }
                }
            }
            .frame(maxHeight: 390)
        }
    }
}

struct ProjectCard: View {
    let project: ProjectWire
    let report: ProjectEnvironmentReport?
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name).font(.headline)
                Spacer()
                Text(project.registration).font(.caption).foregroundStyle(.secondary)
            }
            Text(displayPath(project.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let report {
                if let url = model.projectSiteURL(report) {
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(report.diagnostics.count) diagnostics")
                    .font(.caption2)
                    .foregroundStyle(report.diagnostics.contains { $0.severity == .error } ? .red : .secondary)
            } else {
                Text("Project status unavailable").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Folder") { model.openProjectFolder(project) }
                    .disabled(!model.canOpenProjectFolder(project))
                if let report {
                    Button("Open Site") { model.openProjectSite(report) }
                        .disabled(model.projectSiteURL(report) == nil)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Version  \(status.core.version)")
                Text("PID       \(status.core.pid)")
                Text("Protocol  \(status.protocolVersion)")
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
            }
        }
        .frame(maxHeight: 390)
    }
}

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProjectSettingsView(model: model)
                .tabItem { Label("Projects", systemImage: "folder") }
        }
        .frame(width: 560, height: 400)
        .onAppear { model.startMonitoring() }
    }
}

struct GeneralSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("General") {
                Text("Vaelen keeps its Core connection and project state available from the menu bar.")
                    .foregroundStyle(.secondary)
                switch model.state {
                case .running:
                    Label("Core Running", systemImage: "circle.fill").foregroundStyle(.green)
                case .connecting:
                    Label("Core Connecting", systemImage: "circle.dotted")
                case .unavailable:
                    Label("Core Unavailable", systemImage: "circle")
                case .incompatible:
                    Label("Core Incompatible", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ProjectSettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Parked Folders") {
                if model.parkedFolders.isEmpty {
                    Text("No parked folders.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.parkedFolders, id: \.id) { folder in
                        relationshipRow(title: displayPath(folder.path), detail: folder.availability) {
                            Task { await model.removeParkedFolder(folder) }
                        } actionLabel: {
                            Text("Remove")
                        }
                    }
                }
                Button("Add Folder…") {
                    guard let path = chooseDirectory(title: "Choose a Folder to Park", prompt: "Add Folder") else { return }
                    Task { await model.parkFolder(at: path) }
                }
                .disabled(model.relationshipMutationInFlight)
            }

            Section("Linked Projects") {
                if model.linkedProjects.isEmpty {
                    Text("No linked projects.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.linkedProjects, id: \.path) { project in
                        relationshipRow(title: project.name, detail: displayPath(project.path)) {
                            Task { await model.unlinkProject(project) }
                        } actionLabel: {
                            Text("Unlink")
                        }
                    }
                }
                Button("Link Project…") {
                    guard let path = chooseDirectory(title: "Choose a Project to Link", prompt: "Link Project") else { return }
                    Task { await model.linkProject(at: path) }
                }
                .disabled(model.relationshipMutationInFlight)
            }

            if let error = model.relationshipError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func relationshipRow<ActionLabel: View>(
        title: String,
        detail: String,
        action: @escaping () -> Void,
        @ViewBuilder actionLabel: () -> ActionLabel
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(title)
            Spacer()
            Button(action: action, label: actionLabel)
                .disabled(model.relationshipMutationInFlight)
        }
    }
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
