import SwiftUI
import AppKit

enum SettingsPage: String, Hashable { case services, projects, php, network, general }

struct SettingsView: View {
    let model: AppModel
    @State private var selection: SettingsPage

    init(model: AppModel, initialPage: SettingsPage = .services) {
        self.model = model
        _selection = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                    Section("WORKSPACE") {
                        Label("Services", systemImage: "server.rack").tag(SettingsPage.services)
                        Label("Projects", systemImage: "folder").tag(SettingsPage.projects)
                    }
                    Section("DEVELOPMENT") {
                        Label("PHP", systemImage: "curlybraces").tag(SettingsPage.php)
                        Label("Network & Security", systemImage: "lock.shield").tag(SettingsPage.network)
                    }
                    Section("PREFERENCES") {
                        Label("General", systemImage: "gearshape").tag(SettingsPage.general)
                    }
            }
            .listStyle(.sidebar)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
            .navigationTitle("Settings")
        } detail: {
            switch selection {
            case .services: ServicesSettingsView(model: model)
            case .general: GeneralSettingsView(model: model, selection: $selection)
            case .projects: ProjectSettingsView(model: model)
            case .php: PHPSettingsView(model: model)
            case .network: NetworkSecuritySettingsView(model: model)
            }
        }
        .frame(minWidth: 1_000, idealWidth: 1_060, minHeight: 640, idealHeight: 720)
        .onAppear {
            model.startMonitoring()
            model.setProjectSettingsVisible(true)
            DispatchQueue.main.async { SettingsWindowActivation.bringForward() }
        }
        .onDisappear {
            model.setProjectSettingsVisible(false)
            SettingsWindowActivation.restoreMenuBarOnlyActivation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.isVisible,
                  (window.title.localizedCaseInsensitiveContains("Settings") || window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true) else { return }
            Task { await model.refreshProjectRelationshipsIfVisible() }
        }
    }

}

struct SettingsPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 20).padding(.vertical, 13).padding(.top, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

struct SettingsStateBadge: View {
    enum Tone { case healthy, attention, pending, neutral }
    let title: String
    let tone: Tone

    var body: some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.11), in: Capsule())
            .accessibilityLabel("Status: \(title)")
    }

    private var color: Color {
        switch tone {
        case .healthy: .green
        case .attention: .orange
        case .pending: .accentColor
        case .neutral: .secondary
        }
    }
}

struct SettingsStateDot: View {
    let title: String
    let tone: SettingsStateBadge.Tone

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            if !title.isEmpty { Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .fixedSize()
        .accessibilityLabel(title)
    }

    private var color: Color {
        switch tone {
        case .healthy: .green
        case .attention: .orange
        case .pending: .accentColor
        case .neutral: Color.secondary.opacity(0.7)
        }
    }
}

struct SettingsInsetCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
    }
}
