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
enum VaelenBrand {
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
        image.size = NSSize(width: 15.5, height: 12.5)
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

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct GeneralSettingsView: View {
    let model: AppModel
    @Binding var selection: SettingsPage
    @State private var editorStatus: String?

    var body: some View {
        let editor = try? EditorPreferenceStore().load()
        VStack(spacing: 0) {
            SettingsPageHeader("General", subtitle: "Preferences for Vaelen on this Mac.") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsInsetCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Vaelen Core").font(.headline)
                                    Text("Core is the source of truth for managed services, projects, and local network state.").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                switch model.state {
                                case .running:
                                    SettingsStateBadge(title: model.refreshError == nil ? "Connected" : "Showing last confirmed state", tone: model.refreshError == nil ? .healthy : .attention)
                                case .connecting:
                                    SettingsStateBadge(title: "Checking", tone: .pending)
                                case .unavailable:
                                    SettingsStateBadge(title: "Unavailable", tone: .attention)
                                case .incompatible:
                                    SettingsStateBadge(title: "Needs attention", tone: .attention)
                                }
                            }
                            HStack(spacing: 8) {
                                Text("Version \(VaelenBuildInfo.version)").font(.caption).foregroundStyle(.secondary)
                                if let refreshError = model.refreshError { Text("· \(refreshError)").font(.caption).foregroundStyle(.orange).lineLimit(2) }
                                Spacer()
                                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.buttonStyle(.borderless)
                            }
                            if model.phpCatalog?.installedVersions.isEmpty != false {
                                Divider()
                                HStack(alignment: .top, spacing: 9) {
                            Image(systemName: model.phpCatalog == nil ? (model.phpCatalogReadPending || model.isServiceReadPending("PHP") ? "clock" : "exclamationmark.circle") : "info.circle").foregroundStyle(model.phpCatalog == nil && !model.phpCatalogReadPending && !model.isServiceReadPending("PHP") ? Color.orange : Color.accentColor)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.phpCatalog == nil ? (model.phpCatalogReadPending || model.isServiceReadPending("PHP") ? "Checking optional PHP setup" : "PHP setup unavailable") : "No managed PHP runtime is installed").font(.subheadline.weight(.medium))
                                        Text("PHP is optional. Install it when a project needs a managed runtime; other Vaelen features remain available.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 6)
                                    Button("Choose PHP") { selection = .php }.controlSize(.small)
                                }
                            }
                        }
                    }
                    SettingsInsetCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Code editor").font(.headline)
                            HStack(spacing: 10) {
                                Image(systemName: "curlybraces").font(.title3).foregroundStyle(Color.accentColor).frame(width: 36, height: 36).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(editor?.bundleIdentifier ?? "No editor selected").font(.subheadline.weight(.medium))
                                    if let path = editor?.applicationPath { Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled) }
                                }
                                Spacer(minLength: 8)
                                Button(editor == nil ? "Choose…" : "Change…", systemImage: "app.badge") { chooseEditor() }
                                if editor != nil { Button("Clear") { clearEditor() }.buttonStyle(.borderless) }
                            }
                            Text("Used by val edit and each project’s Open in Editor action. Vaelen opens the selected folder directly in this installed application.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let editorStatus { Label(editorStatus, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Text("Appearance follows macOS Light or Dark mode. Service and project state is shared with the menu bar and CLI.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 2)
                }
                .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
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
    @State private var selectedItem = "shared"
    @State private var removalVersion: String?
    @State private var didSelectInitialRuntime = false

    private var catalog: PHPRuntimeCatalog? { model.phpCatalog }
    private var installed: [PHPRuntimeVersion] { catalog?.installedVersions ?? [] }
    private var available: [String] {
        guard let catalog else { return [] }
        let installedVersions = Set(catalog.installedVersions.map(\.version))
        return catalog.availableVersions.filter { !installedVersions.contains($0) }
    }
    private var coreConnected: Bool {
        if case .running = model.state { return model.refreshError == nil }
        return false
    }
    private var selectedVersion: String? {
        guard !selectedItem.hasPrefix("available:") else { return String(selectedItem.dropFirst("available:".count)) }
        return selectedItem == "shared" ? nil : selectedItem
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader("PHP", subtitle: "Choose runtimes and tune the values your projects use.") {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh PHP runtime status")
            }
            HStack(spacing: 0) {
                runtimeList.frame(width: 238).background(Color(nsColor: .controlBackgroundColor).opacity(0.32))
                Divider()
                ScrollView { runtimeDetail.frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading).padding(22) }
            }
        }
        .task {
            if model.phpConfiguration == nil { await model.refreshPHPConfiguration() }
            selectInitialRuntime()
        }
        .onChange(of: model.phpCatalog?.defaultVersion) { _, _ in selectInitialRuntime() }
        .onChange(of: model.phpCatalog?.installedVersions.map(\.version)) { _, _ in
            if selectedItem != "shared", !selectedItem.hasPrefix("available:"), !installed.contains(where: { $0.version == selectedItem }) { selectedItem = "shared" }
        }
        .confirmationDialog("Remove PHP \(removalVersion ?? "runtime")?", isPresented: Binding(get: { removalVersion != nil }, set: { if !$0 { removalVersion = nil } }), titleVisibility: .visible) {
            if let removalVersion {
                Button("Remove", role: .destructive) { Task { await model.removePHP(removalVersion) }; self.removalVersion = nil }
                Button("Cancel", role: .cancel) { self.removalVersion = nil }
            }
        } message: { Text("This removes the Vaelen-managed PHP runtime from this Mac. Project files are not changed.") }
    }

    private var runtimeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                Text("INSTALLED").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, 14).padding(.bottom, 5)
                runtimeRow("shared", title: "Shared defaults", subtitle: catalog?.defaultVersion.map { "PHP \($0) · new projects" } ?? "Default unavailable", state: !coreConnected ? (phpChecking ? .pending : .neutral) : catalog?.defaultVersion == nil ? .attention : .healthy)
                if installed.isEmpty {
                    Text(catalog == nil ? "Waiting for a confirmed runtime catalog." : "No managed PHP runtimes installed.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
                }
                ForEach(installed, id: \.version) { runtime in
                    runtimeRow(runtime.version, title: "PHP \(runtime.version)", subtitle: runtimeSubtitle(runtime), state: runtimeTone(runtime))
                }
                Divider().padding(.horizontal, 12).padding(.vertical, 7)
                Text("AVAILABLE").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.bottom, 5)
                if catalog == nil {
                    Text(phpChecking ? "Checking available runtimes…" : "Available versions unavailable")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
                } else if !catalog!.availableVersionsKnown {
                    Text("Available versions could not be refreshed.").font(.caption).foregroundStyle(.orange).padding(.horizontal, 14).padding(.vertical, 9)
                } else if available.isEmpty {
                    Text("No additional versions available.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
                } else {
                    ForEach(available, id: \.self) { version in
                        runtimeRow("available:\(version)", title: "PHP \(version)", subtitle: PHPSeriesLabel.series(for: version), state: .pending)
                    }
                }
            }.padding(.bottom, 14)
        }
    }

    private var runtimeDetail: some View {
        VStack(alignment: .leading, spacing: 17) {
            if let error = model.refreshError {
                Label("Showing last confirmed PHP state · \(error)", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let operationTarget = model.phpRequestTarget {
                Label(phpOperationDescription(target: operationTarget, operation: model.phpOperation), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.phpError ?? model.phpConfigurationError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button("Retry", systemImage: "arrow.clockwise") { Task { await model.refreshPHPConfiguration(); await model.refresh() } }
            }
            if selectedItem == "shared" { sharedDefaultsDetail }
            else if selectedItem.hasPrefix("available:") { availableRuntimeDetail }
            else if let runtime = installed.first(where: { $0.version == selectedItem }) { installedRuntimeDetail(runtime) }
            else if catalog == nil { unavailableCatalogDetail }
            else { sharedDefaultsDetail }
        }
    }

    private var sharedDefaultsDetail: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shared defaults").font(.title2.weight(.semibold))
                    Text("Inherited only by projects without a PHP override.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if phpChecking { SettingsStateBadge(title: "Checking", tone: .pending) }
                else if !coreConnected { SettingsStateBadge(title: "Unavailable", tone: .attention) }
                else if let version = catalog?.defaultVersion { SettingsStateBadge(title: "PHP \(version) · Default", tone: .healthy) }
                else { SettingsStateBadge(title: "Default unavailable", tone: .attention) }
            }
            if let version = catalog?.defaultVersion {
                SettingsInsetCard {
                    HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("PHP \(version) is the shared default").font(.subheadline.weight(.medium)); Spacer(); Text("New projects").font(.caption).foregroundStyle(.secondary) }
                }
            }
            configurationEditor(version: nil)
            Text("Upload and POST size affect web requests. Memory and input-variable limits apply to web and CLI PHP. Execution time limits web requests; managed CLI PHP remains unlimited.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            configLocations
        }
    }

    @ViewBuilder private func installedRuntimeDetail(_ runtime: PHPRuntimeVersion) -> some View {
        let config = model.phpConfiguration?.versions.first { $0.version == runtime.version }
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "curlybraces").font(.title2).foregroundStyle(Color.accentColor).frame(width: 36, height: 36).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text("PHP \(runtime.version)").font(.title2.weight(.semibold))
                    Text(runtime.series.map { "\($0) series · Managed by Vaelen" } ?? "Managed by Vaelen").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SettingsStateBadge(title: runtimeStateTitle(runtime), tone: runtimeTone(runtime))
            }
            HStack(spacing: 8) {
                if runtime.isDefault { SettingsStateBadge(title: "Shared default", tone: coreConnected ? .healthy : .neutral) }
                if runtime.usedByProjectCount > 0 { Text("Used by \(runtime.usedByProjectCount) projects").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                PHPDefaultMenu(catalog: catalog!, model: model, canManage: coreConnected && !phpChecking)
            }
            if let config {
                SettingsInsetCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("PHP \(runtime.version) settings").font(.headline)
                                Text(config.inheritsDefault ? "Inherits shared values; edit only to create version-specific settings." : "These values override shared defaults for this version.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !config.inheritsDefault {
                                Button("Use Shared Default") { Task { await model.savePHPConfiguration(version: runtime.version, settings: nil) } }.disabled(model.phpConfigurationSaving || !coreConnected || phpChecking)
                            }
                        }
                        Divider()
                        PHPSettingsEditor(settings: config.settings, title: "PHP \(runtime.version)", saveTitle: "Save PHP \(runtime.version)", saving: model.phpConfigurationSaving || !coreConnected || phpChecking) { settings in
                            Task { await model.savePHPConfiguration(version: runtime.version, settings: settings) }
                        }
                        Text(config.fpmRunning ? "FPM is running; saved values apply on its next start." : "Settings will be used the next time PHP-FPM starts.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Label(model.phpConfigurationReadPending ? "Loading version-specific settings…" : "Version settings unavailable", systemImage: model.phpConfigurationReadPending ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(model.phpConfigurationReadPending ? Color.secondary : Color.orange)
            }
            configLocations
            runtimeActions(runtime)
        }
    }

    private var availableRuntimeDetail: some View {
        let version = selectedVersion ?? ""
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text("PHP \(version)").font(.title2.weight(.semibold)); Text(PHPSeriesLabel.series(for: version)).font(.caption).foregroundStyle(.secondary) }
                Spacer(); SettingsStateBadge(title: "Available", tone: .pending)
            }
            Text("Install this managed PHP runtime for projects that require it. Installing does not change the shared default.").font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsInsetCard { VStack(alignment: .leading, spacing: 8) { Text("Package").font(.headline); Text("Verified package · managed by Vaelen").font(.caption).foregroundStyle(.secondary); Text("Data and configuration are preserved independently of package installation.").font(.caption).foregroundStyle(.secondary) } }
            Button("Install PHP \(version)", systemImage: "arrow.down.circle.fill") { Task { await model.installPHP(version) } }
            .buttonStyle(.borderedProminent).disabled(model.phpRequestInFlight || !coreConnected || phpChecking)
            if !coreConnected || phpChecking { Text(phpChecking ? "Checking Core before enabling package actions…" : "Core must confirm current runtime state before installation.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var unavailableCatalogDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(phpChecking ? "Checking PHP runtime state…" : "PHP runtime state unavailable", systemImage: phpChecking ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                .font(.title3.weight(.semibold)).foregroundStyle(phpChecking ? Color.secondary : Color.orange)
            Text(phpChecking ? "Waiting for Core to confirm installed versions and running state." : "Core did not provide an authoritative PHP catalog. No runtime status is inferred.")
                .font(.subheadline).foregroundStyle(.secondary)
            if phpChecking { ProgressView().controlSize(.small) }
            else { Button("Retry PHP Status", systemImage: "arrow.clockwise") { Task { await model.refresh() } } }
        }.padding(.top, 8)
    }

    private var configLocations: some View {
        DisclosureGroup("Configuration locations") {
            if let config = model.phpConfiguration {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Directory: \(config.directory)")
                    ForEach(config.versions, id: \.version) { item in
                        Text("PHP \(item.version) · FPM \(item.fpmIniPath)")
                        Text("Managed CLI · \(item.cliIniPath)")
                    }
                    Button("Open Configuration Files…", systemImage: "folder") { Task { await model.openPHPConfigurationFiles() } }
                        .disabled(!coreConnected || phpChecking)
                }.font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 8)
            } else if model.phpConfigurationReadPending {
                HStack { ProgressView().controlSize(.small); Text("Checking configuration paths…").font(.caption).foregroundStyle(.secondary) }.padding(.top, 8)
            } else {
                HStack { Text("Configuration locations unavailable.").font(.caption).foregroundStyle(.secondary); Button("Retry") { Task { await model.refreshPHPConfiguration() } } }.padding(.top, 8)
            }
        }
        .font(.subheadline.weight(.semibold)).padding(13)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }

    private func configurationEditor(version: String?) -> some View {
        Group {
            if let configuration = model.phpConfiguration {
                SettingsInsetCard {
                    PHPSettingsEditor(
                        settings: version.flatMap { v in configuration.versions.first { $0.version == v }?.settings } ?? configuration.defaultSettings,
                        title: version.map { "PHP \($0) Settings" } ?? "Shared Default Settings",
                        saveTitle: version.map { "Save PHP \($0)" } ?? "Save Shared Default",
                        saving: model.phpConfigurationSaving || !coreConnected || phpChecking
                    ) { settings in Task { await model.savePHPConfiguration(version: version, settings: settings) } }
                }
            } else if model.phpConfigurationReadPending {
                SettingsInsetCard { HStack { ProgressView().controlSize(.small); Text("Checking PHP configuration…").font(.subheadline).foregroundStyle(.secondary) } }
            } else {
                SettingsInsetCard { VStack(alignment: .leading, spacing: 8) { Text("Shared PHP settings unavailable").font(.headline); Text(model.phpConfigurationError ?? "Core did not provide configuration values.").font(.caption).foregroundStyle(.secondary); Button("Retry Settings", systemImage: "arrow.clockwise") { Task { await model.refreshPHPConfiguration() } } } }
            }
        }
    }

    private func runtimeActions(_ runtime: PHPRuntimeVersion) -> some View {
        HStack {
            if runtime.updateAvailable == true, let latest = runtime.latestVersion {
                Button("Update to \(latest)", systemImage: "arrow.triangle.2.circlepath") { Task { await model.updatePHP(latest) } }.disabled(model.phpRequestInFlight || !coreConnected || phpChecking)
            }
            if runtime.running == false && !runtime.isDefault {
                Button("Remove Runtime…", systemImage: "trash", role: .destructive) { removalVersion = runtime.version }
                    .disabled(model.phpRequestInFlight || !coreConnected || phpChecking)
            }
            Spacer()
        }
    }

    private var phpChecking: Bool {
        if case .connecting = model.state { return true }
        return model.phpCatalogReadPending || model.isServiceReadPending("PHP") || model.phpConfigurationReadPending
    }

    private func selectInitialRuntime() {
        guard !didSelectInitialRuntime, let catalog else { return }
        selectedItem = catalog.defaultVersion ?? catalog.installedVersions.first?.version ?? "shared"
        didSelectInitialRuntime = true
    }

    private func runtimeRow(_ key: String, title: String, subtitle: String, state: SettingsStateBadge.Tone) -> some View {
        Button { selectedItem = key } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary); Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                Spacer(minLength: 2)
                SettingsStateDot(title: "", tone: state)
                if key == selectedItem { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
            .background(selectedItem == key ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 7)
            .accessibilityAddTraits(selectedItem == key ? .isSelected : [])
    }

    private func runtimeSubtitle(_ runtime: PHPRuntimeVersion) -> String {
        var parts: [String] = []
        if runtime.isDefault { parts.append("Shared default") }
        if runtime.usedByProjectCount > 0 { parts.append("\(runtime.usedByProjectCount) projects") }
        parts.append(runtimeStateTitle(runtime))
        return parts.joined(separator: " · ")
    }

    private func runtimeStateTitle(_ runtime: PHPRuntimeVersion) -> String {
        if phpChecking { return "Checking status…" }
        guard coreConnected else { return phpChecking ? "Checking status…" : "Last confirmed · unavailable" }
        if runtime.running == true { return "Running" }
        if runtime.running == false { return "Stopped" }
        return "Status unavailable"
    }

    private func runtimeTone(_ runtime: PHPRuntimeVersion) -> SettingsStateBadge.Tone {
        if phpChecking { return .pending }
        guard coreConnected else { return phpChecking ? .pending : .neutral }
        if runtime.running == true { return .healthy }
        if runtime.running == false { return .neutral }
        return .attention
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
    let canManage: Bool

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
        .disabled(model.phpRequestInFlight || !canManage)
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
                VaelenStatusLabel("Running", systemImage: "circle.fill", tint: .green)
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
    @State private var selectedPath: String?
    private var coreHasSnapshot: Bool { if case .running = model.state { true } else { false } }
    private var coreConnecting: Bool { if case .connecting = model.state { true } else { false } }
    private var selectedProject: ProjectWire? { model.linkedProjects.first { $0.path == selectedPath } }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader("Projects", subtitle: "Your workspaces, runtime choices, and local sites.") {
                Button("Add Folder…", systemImage: "plus") {
                    guard let path = chooseDirectory(title: "Choose a Workspace Folder", prompt: "Add Workspace Folder") else { return }
                    Task { await model.parkFolder(at: path) }
                }.disabled(model.relationshipMutationInFlight)
                Button("Link Project…", systemImage: "link") {
                    guard let path = chooseDirectory(title: "Choose a Project to Link", prompt: "Link Project") else { return }
                    Task { await model.linkProject(at: path) }
                }.buttonStyle(.borderedProminent).disabled(model.relationshipMutationInFlight)
            }
            HStack(spacing: 0) {
                projectList.frame(width: 250).background(Color(nsColor: .controlBackgroundColor).opacity(0.32))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !coreHasSnapshot {
                            SettingsInsetCard {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: coreConnecting ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill").foregroundStyle(coreConnecting ? Color.accentColor : Color.orange)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(coreConnecting ? "Checking project state…" : "Project state unavailable").font(.subheadline.weight(.semibold))
                                        Text("Workspace and linked-project state is not confirmed. Empty inventories are not inferred.").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                     Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh(); await model.refreshProjectRelationshipsIfVisible() } }
                                }
                            }
                        } else if let error = model.refreshError {
                            Label("Showing last confirmed project state · \(error)", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.orange)
                        }
                        if let selectedProject {
                            ProjectSelectedDetail(project: selectedProject, model: model)
                        } else if coreHasSnapshot {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Select a linked project").font(.title3.weight(.semibold))
                                Text("Choose a project from the list, or link a project folder to manage its local site and runtime.").font(.subheadline).foregroundStyle(.secondary)
                                VaelenEmptyState(title: "No Linked Projects", systemImage: "shippingbox", message: "Link a project to manage it directly.")
                            }
                            .padding(.top, 8)
                        } else {
                            Text(coreConnecting ? "Waiting for the first project inventory…" : "Reconnect to Core to load projects.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let operation = model.relationshipOperation { HStack { ProgressView().controlSize(.small); Text(operation).font(.caption).foregroundStyle(.secondary) } }
                        if let error = model.relationshipError { VaelenStatusLabel(error, systemImage: "exclamationmark.triangle", tint: .red).font(.caption) }
                        if let error = model.projectRelationshipsRefreshError { VaelenStatusLabel("Workspace and linked project state may be stale: \(error)", systemImage: "arrow.clockwise.circle", tint: .orange).font(.caption) }
                    }
                    .frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
                }
            }
        }
        .task { selectFirstProjectIfNeeded() }
        .onChange(of: model.linkedProjects.map(\.path)) { _, _ in selectFirstProjectIfNeeded() }
    }

    private var projectList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("WORKSPACE FOLDERS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, 14).padding(.bottom, 4)
                if model.parkedFolders.isEmpty {
                    Text(coreHasSnapshot ? "No folders added" : "Checking folders…").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 13).padding(.vertical, 8)
                }
                ForEach(model.parkedFolders, id: \.id) { folder in
                    HStack(spacing: 7) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayPath(folder.path)).font(.caption.weight(.medium)).lineLimit(1)
                            Text("\(discoveredCount(in: folder, from: model.projects)) discovered projects").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button("Remove Workspace Folder…", systemImage: "minus.circle") { Task { await model.removeParkedFolder(folder) } }
                                .disabled(model.relationshipMutationInFlight)
                        } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }.menuStyle(.borderlessButton)
                            .accessibilityLabel("Actions for \(displayPath(folder.path))")
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                }
                Text("LINKED PROJECTS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, 14).padding(.bottom, 4)
                if model.linkedProjects.isEmpty {
                    Text(coreHasSnapshot ? "No linked projects" : "Waiting for Core").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 13).padding(.vertical, 8)
                }
                ForEach(model.linkedProjects, id: \.path) { project in
                    Button { selectedPath = project.path } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                            Text([project.detectedFramework, displayPath(project.path)].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(selectedPath == project.path ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 7)
                        .accessibilityAddTraits(selectedPath == project.path ? .isSelected : [])
                }
            }.padding(.bottom, 14)
        }
    }

    private func selectFirstProjectIfNeeded() {
        if !model.linkedProjects.contains(where: { $0.path == selectedPath }) { selectedPath = model.linkedProjects.first?.path }
    }
}

private struct ProjectSelectedDetail: View {
    let project: ProjectWire
    let model: AppModel
    @State private var confirmUnlink = false

    private var report: ProjectEnvironmentReport? { model.projectReports.first { $0.identity.path == project.path } }
    private var routes: [RouteIntent]? { routesForProject(project, report: report, configured: model.configuredRoutes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.title2.weight(.semibold))
                    Text(displayPath(project.path)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Menu {
                    Button("Unlink Project…", systemImage: "link.badge.minus", role: .destructive) { confirmUnlink = true }
                        .disabled(model.relationshipMutationInFlight)
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).accessibilityLabel("Project actions")
                Button("Open Folder", systemImage: "folder") { model.openProjectFolder(project) }.disabled(!model.canOpenProjectFolder(project))
            }
            HStack(spacing: 10) {
                projectMetric("Runtime", projectPHPText, report == nil ? "Checking with Core" : (model.phpCatalogReadPending ? "Checking runtime catalog" : projectPHPMode))
                projectMetric("Site", projectRouteValue, projectRouteDetail)
                projectMetric("Database", report?.observed.mysql?.selectedVersion.map { "MySQL \($0)" } ?? "MySQL", report?.observed.mysql?.state.rawValue ?? "Checking")
            }
            SettingsInsetCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Project actions").font(.headline)
                    HStack(spacing: 8) {
                        if let routes, routes.count == 1, let route = routes.first {
                            Button("Open Site", systemImage: "safari") { model.openProjectRoute(route) }.disabled(route.route.hostname.isEmpty)
                        } else if let routes, routes.count > 1 {
                            Menu {
                                ForEach(Array(routes.enumerated()), id: \.element.route.id) { _, item in
                                    Button(item.route.hostname, systemImage: item.route.tls == .local ? "lock.fill" : "globe") { model.openProjectRoute(item) }
                                }
                            } label: { Label("Open Site", systemImage: "safari") }
                        }
                        Button("Open in Editor", systemImage: "curlybraces") { model.openProjectInEditor(project) }.disabled(!model.canOpenProjectFolder(project))
                        if let report {
                            let action = model.tablePlusAction(report)
                            Button("Open Database", systemImage: "cylinder.split.1x2") { model.openProjectDatabaseInTablePlus(report) }.disabled(!action.isEnabled).help(action.reason)
                        }
                        Button("Copy Path", systemImage: "doc.on.doc") { model.copyProjectPath(project) }
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack { Text("Project PHP").font(.headline); Spacer(); ProjectPHPMenu(project: project, report: report, model: model) }
                Text("This runtime choice applies to this project only. Other projects keep their own override or inherit the shared default.").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 3)
            if let report {
                SettingsInsetCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Project environment").font(.headline)
                        projectFact("Framework", project.detectedFramework ?? "Not detected")
                        projectFact("Availability", project.availability)
                        projectFact("PHP", projectPHPText)
                        projectFact("MySQL", report.observed.mysql.map { "\($0.state.rawValue) · \($0.selectedVersion ?? "version unavailable")" } ?? "Status unavailable")
                        if let routeError = model.configuredRoutesError { projectFact("Routes", "Unavailable · \(routeError)") }
                        else { projectFact("Routes", routes?.map { $0.route.hostname }.joined(separator: ", ") ?? "No configured route") }
                    }
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.projectReportErrors[project.path] ?? "Checking project details with Core…").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("Unlink \(project.name)?", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("Unlink Project", role: .destructive) { Task { await model.unlinkProject(project) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes Vaelen’s link only. The project folder, files, databases, and services are not deleted.") }
    }

    private var projectPHPText: String {
        guard let php = report?.observed.php else { return "Checking" }
        if let version = php.resolvedVersion { return "PHP \(version)" }
        if let override = php.overrideVersion { return "PHP \(override) unavailable" }
        return "Unavailable"
    }
    private var projectPHPMode: String { report?.observed.php.overrideVersion == nil ? "Uses shared default" : "Project override" }
    private var projectRouteValue: String {
        guard let routes else { return model.configuredRoutesError == nil ? "Checking" : "Unavailable" }
        return routes.first?.route.hostname ?? "No route"
    }
    private var projectRouteDetail: String {
        guard let routes else { return model.configuredRoutesError == nil ? "Checking routes" : "Route state unavailable" }
        return routes.isEmpty ? "Not configured" : "Local route"
    }
    private func projectMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary); Text(value).font(.subheadline.weight(.medium)).lineLimit(1); Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
    private func projectFact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading); Text(value).font(.caption).textSelection(.enabled); Spacer(minLength: 0) }
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
            .padding(.top, 32)
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
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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
    @State private var showUnlinkConfirmation = false

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
                HStack(spacing: 12) {
                    if let routes, routes.count == 1, let route = routes.first {
                        Button("Open Site", systemImage: "safari") { model.openProjectRoute(route) }.buttonStyle(.borderless)
                    } else if let routes, routes.count > 1 {
                        Menu {
                            ForEach(Array(routes.enumerated()), id: \.element.route.id) { _, route in
                                Button(route.route.hostname, systemImage: route.route.tls == .local ? "lock.fill" : "globe") { model.openProjectRoute(route) }
                            }
                        } label: { Label("Open Site", systemImage: "safari") }.menuStyle(.borderlessButton)
                    }
                    Button("Open Folder", systemImage: "folder") { model.openProjectFolder(project) }
                        .disabled(!model.canOpenProjectFolder(project))
                    Button("Open in Editor", systemImage: "curlybraces") { model.openProjectInEditor(project) }
                        .disabled(!model.canOpenProjectFolder(project))
                    if let report {
                        let action = model.tablePlusAction(report)
                        Button("TablePlus", systemImage: "cylinder.split.1x2") { model.openProjectDatabaseInTablePlus(report) }
                            .disabled(!action.isEnabled).help(action.reason)
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") { model.copyProjectPath(project) }
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
            Spacer()
            ProjectPHPMenu(project: project, report: report, model: model)
            Menu {
                Button("Unlink Project…", systemImage: "link.badge.minus", role: .destructive) { showUnlinkConfirmation = true }
                    .disabled(model.relationshipMutationInFlight)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for project \(project.name)")
        }
        .padding(.vertical, VaelenUI.spacing6)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        .confirmationDialog("Unlink \(project.name)?", isPresented: $showUnlinkConfirmation, titleVisibility: .visible) {
            Button("Unlink Project", role: .destructive) { Task { await model.unlinkProject(project) } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes Vaelen’s link only. The project folder, files, databases, and services are not deleted.")
        }
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

func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
