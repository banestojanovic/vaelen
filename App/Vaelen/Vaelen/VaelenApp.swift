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
        image.size = NSSize(width: 21, height: 16.8)
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
            model.setProjectSettingsVisible(true)
            DispatchQueue.main.async {
                SettingsWindowActivation.bringForward()
            }
        }
        .onDisappear {
            model.setProjectSettingsVisible(false)
        }
    }
}

struct GeneralSettingsView: View {
    let model: AppModel
    @State private var editorStatus: String?

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
            SettingsGroup(title: "Code Editor", footer: "Used by ‘val edit’ and each project’s Open in Editor action. Vaelen opens the selected folder directly in this exact installed application.") {
                let selected = try? EditorPreferenceStore().load()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected?.bundleIdentifier ?? "No editor selected")
                            .font(.subheadline)
                        if let path = selected?.applicationPath {
                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(selected == nil ? "Choose…" : "Change…", systemImage: "app.badge") { chooseEditor() }
                    if selected != nil {
                        Button("Clear") { clearEditor() }
                    }
                }
                if let editorStatus { Text(editorStatus).font(.caption).foregroundStyle(.secondary) }
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

                SettingsGroup(title: "PHP Configuration", footer: "These settings are stored under Vaelen’s Application Support folder. Upload and POST size affect web requests; memory and input-variable limits apply to both web and CLI PHP. Execution time controls web requests; managed CLI PHP remains unlimited.") {
                    if let configuration = model.phpConfiguration {
                        VStack(alignment: .leading, spacing: VaelenUI.spacing12) {
                            PHPSettingsEditor(settings: configuration.defaultSettings, title: "Shared Default", saveTitle: "Save Shared Default", saving: model.phpConfigurationSaving) { settings in
                                Task { await model.savePHPConfiguration(version: nil, settings: settings) }
                            }
                            ForEach(configuration.versions, id: \.version) { version in
                                Divider().opacity(0.5)
                                VStack(alignment: .leading, spacing: VaelenUI.spacing8) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("PHP \(version.version)").font(.subheadline.weight(.medium))
                                            Text(version.inheritsDefault ? "Inherits the shared default" : "Version-specific override")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if !version.inheritsDefault {
                                            Button("Use Shared Default") {
                                                Task { await model.savePHPConfiguration(version: version.version, settings: nil) }
                                            }
                                            .disabled(model.phpConfigurationSaving)
                                        }
                                    }
                                    PHPSettingsEditor(settings: version.settings, title: "PHP \(version.version)", saveTitle: "Save PHP \(version.version)", saving: model.phpConfigurationSaving) { settings in
                                        Task { await model.savePHPConfiguration(version: version.version, settings: settings) }
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("FPM uses \(version.fpmIniPath)")
                                        Text("Managed CLI uses \(version.cliIniPath)")
                                        Text("FPM pool config (generated): \(version.fpmConfigurationPath)")
                                    }
                                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    if version.fpmRunning {
                                        Label("PHP-FPM is running with these settings.", systemImage: "checkmark.circle.fill")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Label("Settings will be used the next time PHP-FPM starts.", systemImage: "info.circle")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Button("Open Configuration Files…", systemImage: "folder") {
                                Task { await model.openPHPConfigurationFiles() }
                            }
                            .padding(.top, VaelenUI.spacing6)
                        }
                    } else {
                        HStack(spacing: VaelenUI.spacing8) {
                            ProgressView().controlSize(.small)
                            Text(model.phpConfigurationError ?? "Loading managed PHP configuration…")
                                .font(.caption).foregroundStyle(model.phpConfigurationError == nil ? Color.secondary : Color.red)
                            if model.phpConfigurationError != nil {
                                Button("Retry") { Task { await model.refreshPHPConfiguration() } }
                            }
                        }
                    }
                    if let error = model.phpConfigurationError, model.phpConfiguration != nil {
                        VaelenStatusLabel(error, systemImage: "exclamationmark.triangle", tint: .red)
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
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
        .task { if model.phpConfiguration == nil { await model.refreshPHPConfiguration() } }
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
            if let error = model.projectRelationshipsRefreshError {
                VaelenStatusLabel("Workspace and linked project state may be stale: \(error)", systemImage: "arrow.clockwise.circle", tint: .orange)
                    .font(.caption)
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

func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
