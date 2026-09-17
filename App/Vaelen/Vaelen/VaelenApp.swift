import SwiftUI
import AppKit
import Observation
import VaelenIPC

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
        case running(CoreStatusResponse)
        case unavailable
        case incompatible(Int, Int)
    }

    private(set) var state: State = .connecting
    private var client: VaelenCoreClient?

    func refresh() async {
        let paths = CoreEndpointPaths()
        let client = VaelenCoreClient(
            transport: UnixSocketTransport(path: paths.socketPath),
            identity: ClientIdentity(name: "Vaelen.app", version: VaelenBuildInfo.version)
        )
        self.client = client
        state = .connecting
        do {
            try await client.connect()
            state = .running(try await client.status())
        } catch let error as CoreClientError {
            switch error {
            case .coreUnavailable: state = .unavailable
            case .protocolIncompatible(let client, let core): state = .incompatible(client, core)
            default: state = .unavailable
            }
        } catch {
            state = .unavailable
        }
    }

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
            case .running(let status):
                Label("Core Running", systemImage: "circle.fill").foregroundStyle(.green)
                Text("Version  \(status.core.version)")
                Text("PID       \(status.core.pid)")
                Text("Protocol  \(status.protocolVersion.rawValue)")
            }
            Divider()
            Button("Refresh") { Task { await model.refresh() } }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 240)
    }
}
