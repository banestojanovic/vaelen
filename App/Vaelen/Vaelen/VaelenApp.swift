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
        MenuBarExtra("Vaelen", systemImage: "wrench.and.screwdriver") {
            StatusView(model: model)
                .task { await model.monitor() }
        }
        .menuBarExtraStyle(.window)
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
    private(set) var trustError: String?
    private var client: VaelenCoreClient?
    private var refreshGeneration = 0

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
            state = .running(status, projects, php, routing, dns, tls, ports, mysql, mailpit)
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
            case .running(let status, let projects, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit):
                Label("Core Running", systemImage: "circle.fill").foregroundStyle(.green)
                Text("Version  \(status.core.version)")
                Text("PID       \(status.core.pid)")
                Text("Protocol  \(status.protocolVersion)")
                Text("Projects  \(projects.count)")
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
