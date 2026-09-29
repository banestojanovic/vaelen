import SwiftUI
import AppKit
import VaelenIPC
import VaelenCore

enum VaelenUI {
    static let spacing6: CGFloat = 6
    static let spacing8: CGFloat = 8
    static let spacing10: CGFloat = 10
    static let spacing12: CGFloat = 12
    static let popoverPadding: CGFloat = 14
    static let cornerRadius: CGFloat = 11
}

struct VaelenStatusLabel: View {
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

struct VaelenEmptyState: View {
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

struct VaelenLoadingIndicator: View {
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
    @Environment(\.openWindow) private var openWindow
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
        SettingsWindowActivation.openSettings { openWindow(id: "settings") }
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
enum SettingsWindowActivation {
    private static var closeObserver: NSObjectProtocol?

    static func openSettings(_ openSettings: () -> Void) {
        NSApplication.shared.setActivationPolicy(.regular)
        activateApplication()
        openSettings()
        DispatchQueue.main.async { bringForward() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { bringForward() }
    }

    static func activateApplication() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    static func restoreMenuBarOnlyActivation() {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
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
                Task { @MainActor in
                    restoreMenuBarOnlyActivation()
                }
            }
        }
        window.orderFrontRegardless()
        activateApplication()
        window.makeKeyAndOrderFront(nil)
        activateApplication()
    }
}

struct SettingsMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            SettingsWindowActivation.openSettings { openWindow(id: "settings") }
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

struct PopoverSectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.45)
    }
}
