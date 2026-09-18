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
        case running(CoreStatusResponse, [ProjectWire], PHPVersionsResult?, RouterStatus?, DNSStatus?, TLSStatus?, StandardPortsStatus?, MySQLStatus?)
        case unavailable
        case incompatible(Int, Int)
    }

    private(set) var state: State = .connecting
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
            identity: ClientIdentity(name: "Vaelen.app", version: VaelenBuildInfo.version)
        )
        self.client = client
        state = .connecting
        do {
            try await client.connect()
            let status = try await client.status()
            let projects = try await client.projectList()
            let php = try? await client.phpVersions()
            let routing = try? await client.routingStatus()
            let dns = try? await client.dnsStatus()
            let tls = try? await client.tlsStatus()
            let ports = try? await client.portsStatus()
            let mysql = try? await client.mysqlStatus()
            guard generation == refreshGeneration else { await client.disconnect(); return }
            state = .running(status, projects, php, routing, dns, tls, ports, mysql)
        } catch let error as CoreClientError {
            guard generation == refreshGeneration else { return }
            await client.disconnect()
            switch error {
            case .coreUnavailable: state = .unavailable
            case .protocolIncompatible(let client, let core): state = .incompatible(client, core)
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
        guard case .running(_, _, _, _, _, let tls, _, _) = state, let path = tls?.caCertificatePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        do { try LocalCATrustService().trust(certificateData: data); await refresh() } catch { trustError = error.localizedDescription }
    }

    func removeLocalCATrust() async {
        trustError = nil
        guard case .running(_, _, _, _, _, let tls, _, _) = state, let path = tls?.caCertificatePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        do { try LocalCATrustService().removeTrust(certificateData: data); await refresh() } catch { trustError = error.localizedDescription }
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
            case .incompatible(let client, let core):
                Label("Protocol Incompatible", systemImage: "exclamationmark.circle")
                Text("Client \(client), Core \(core)").font(.caption)
            case .running(let status, let projects, let php, let routing, let dns, let tls, let ports, let mysql):
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
                ForEach(projects.prefix(5), id: \.path) { project in
                    Text("\(project.name) (\(project.registration))")
                        .font(.caption)
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
