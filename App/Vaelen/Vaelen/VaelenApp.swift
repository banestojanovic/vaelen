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
    @State private var model = AppModel.modelForApplicationLaunch(arguments: ProcessInfo.processInfo.arguments)
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(VaelenAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusView(model: model)
        } label: {
            Image(nsImage: VaelenBrand.menuBarImage)
                .accessibilityLabel("Vaelen")
                .onAppear {
                    if !model.isSettingsFixture { model.startMonitoring() }
                    appDelegate.requestQuit = { Task { await model.quitVaelen() } }
                    if model.isSettingsFixture { openWindow(id: "settings") }
                }
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView(model: model, initialPage: model.settingsFixturePage ?? .services)
                .preferredColorScheme(model.settingsFixtureDark ? .dark : model.settingsFixtureLight ? .light : nil)
        }
        .defaultSize(width: 1_060, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)

        Window("Service Logs", id: "service-logs") {
            ManagedLogsWindow(model: model.managedLogViewer)
        }
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
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
/// highlighted tinting across appearances.
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
    @State private var stopConfirmation: PHPRuntimeVersion?
    @State private var didSelectInitialRuntime = false

    private var catalog: PHPRuntimeCatalog? { model.phpCatalog }
    private var catalogCheckError: String? { model.phpCatalogCheckError ?? catalog?.catalogCheckError }
    private var availableSectionTitle: String { "Available" }
    private var availableEmptyMessage: String {
        if catalogCheckError != nil {
            return catalog?.catalogCheckedAt == nil
                ? "No additional versions are listed in local package metadata. Retry the catalog check."
                : "No additional versions are listed in the cached catalog. Retry to refresh."
        }
        if installed.isEmpty { return "No additional PHP versions are available." }
        return "Installed PHP runtimes are up to date."
    }
    private var installed: [PHPRuntimeVersion] { (catalog?.installedVersions ?? []).sorted { phpVersionDescending($0.version, $1.version) } }

    /// Versions offered for installation: families with nothing installed yet.
    ///
    /// An update to an already-installed family is shown on that family's row
    /// instead of appearing here as a second, unexplained installation option.
    private var available: [String] {
        guard let catalog, catalog.availableVersionsKnown else { return [] }
        let installedVersions = Set(installed.map(\.version))
        let installedFamilies = Set(installed.map { $0.series ?? $0.version })
        return catalog.availableVersions
            .filter { version in
                !installedVersions.contains(version)
                    && !installedFamilies.contains(PHPVersion(version)?.family ?? version)
            }
            .sorted(by: phpVersionDescending)
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
                Button { Task { await model.refreshPHPSettings() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh PHP runtimes and configuration")
                    .disabled(model.phpRequestInFlight || model.phpConfigurationSaving)
            }
            // Progress is shown next to the affected version's action and survives
            // switching panes or closing and reopening Settings, because it is
            // driven by the operation state rather than by pane-local state.
            PHPOperationProgressView(operation: model.phpOperation)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8)
                .background(model.phpOperation == nil ? Color.clear : Color.accentColor.opacity(0.06))
            if model.phpOperation == nil, let completion = model.phpCompletionMessage {
                HStack { Label(completion, systemImage: model.phpOperation?.phase == .failed ? "exclamationmark.triangle" : "checkmark.circle").font(.caption).foregroundStyle(model.phpOperation?.phase == .failed ? Color.orange : Color.secondary); Spacer() }.padding(.horizontal, 18).padding(.vertical, 8)
            }
            HStack(spacing: 0) {
                runtimeList.frame(width: 238).background(Color(nsColor: .controlBackgroundColor).opacity(0.32))
                Divider()
                ScrollView { runtimeDetail.frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading).padding(22) }
            }
        }
        .task {
            await model.refreshPHPConfiguration()
            selectInitialRuntime()
        }
        .task(id: selectedItem) {
            if let version = selectedVersion, !selectedItem.hasPrefix("available:"),
               installed.contains(where: { $0.version == version }),
               model.phpConfiguration?.versions.contains(where: { $0.version == version }) != true {
                await model.refreshPHPConfiguration()
            }
        }
        .onChange(of: model.phpCatalog) { _, _ in catalogDidChange() }
        .onChange(of: model.phpSelectionRequest) { _, request in
            // After an update, show the replacement's own version, settings, paths,
            // running state, and default role immediately.
            guard let request else { return }
            selectedItem = request
            model.clearPHPSelectionRequest()
        }
        .confirmationDialog("Remove PHP \(removalVersion ?? "runtime")?", isPresented: Binding(get: { removalVersion != nil }, set: { if !$0 { removalVersion = nil } }), titleVisibility: .visible) {
            if let removalVersion {
                Button("Remove", role: .destructive) { Task { await model.removePHP(removalVersion) }; self.removalVersion = nil }.settingsDestructiveTint()
                Button("Cancel", role: .cancel) { self.removalVersion = nil }
            }
        } message: { Text("This removes the Vaelen-managed PHP runtime from this Mac. Project files are not changed.") }
        .confirmationDialog("Stop PHP \(stopConfirmation?.version ?? "runtime")?", isPresented: Binding(get: { stopConfirmation != nil }, set: { if !$0 { stopConfirmation = nil } }), titleVisibility: .visible) {
            if let stopConfirmation {
                Button("Stop PHP \(stopConfirmation.version)", role: .destructive) { Task { await model.stopPHPRuntime(stopConfirmation.version) }; self.stopConfirmation = nil }.settingsDestructiveTint()
                Button("Cancel", role: .cancel) { self.stopConfirmation = nil }
            }
        } message: { Text("\(stopConfirmation?.usedByProjectCount ?? 0) project(s) use this runtime. Their PHP requests will fail until it is started again. The default selection will not change.") }
    }

    private var runtimeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                // A persistent, unobtrusive indicator on the installed group, so
                // an available update is visible without selecting anything.
                if !model.phpInstallableUpdates.isEmpty {
                    HStack(spacing: 6) {
                        updateIndicator(to: model.phpInstallableUpdates[0].to)
                        Text(model.phpInstallableUpdates.count == 1
                             ? "PHP \(model.phpInstallableUpdates[0].from.version) can update to \(model.phpInstallableUpdates[0].to)"
                             : "\(model.phpInstallableUpdates.count) PHP runtimes can update")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .help(model.phpUpdateIndicatorHelp)
                    .padding(.horizontal, 13).padding(.top, 6).padding(.bottom, 2)
                }
                phpSectionHeader("Configuration", top: 14)
                runtimeRow("shared", title: "Shared settings", subtitle: "Values inherited by PHP runtimes", state: model.phpConfiguration == nil ? .pending : .neutral)
                phpSectionHeader("Installed", count: catalog == nil ? nil : installed.count, top: 12)
                if installed.isEmpty {
                    Text(catalog == nil ? (phpChecking ? "Checking installed PHP runtimes…" : "Installed PHP runtimes unavailable.") : "No managed PHP runtimes installed.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
                }
                ForEach(installed, id: \.version) { runtime in
                    runtimeRow(runtime.version, title: "PHP \(runtime.version)", subtitle: runtimeSubtitle(runtime), state: runtimeTone(runtime), isDefault: runtime.isDefault, updateAvailable: runtime.updateAvailable == true ? runtime.latestVersion : nil)
                }
                Divider().padding(.horizontal, 12).padding(.vertical, 7)
                phpSectionHeader(availableSectionTitle, count: catalog?.availableVersionsKnown == true ? available.count : nil, top: 12) {
                    Button {
                        Task { await model.checkPHPUpdates() }
                    } label: {
                        HStack(spacing: 5) {
                            if model.phpCatalogCheckPending { ProgressView().controlSize(.small).frame(width: 12, height: 12) }
                            else { Image(systemName: "arrow.clockwise").frame(width: 12, height: 12) }
                            Text("Check for Updates")
                        }
                        .font(.system(size: 11))
                        .frame(minHeight: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Check Vaelen's trusted PHP sources for updates")
                    .accessibilityLabel("Check PHP for updates")
                    .disabled(model.phpCatalogCheckPending || !coreConnected || phpChecking)
                }
                if !model.phpCatalogCheckPending, let error = catalogCheckError {
                    Text("Update check failed: \(error)").font(.caption2).foregroundStyle(.orange).lineLimit(3).padding(.horizontal, 14).padding(.bottom, 5)
                } else if let checkedAt = catalog?.catalogCheckedAt {
                    Text("Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.bottom, 5)
                }
                if !model.phpCatalogCheckPending, catalog?.catalogAvailability == .cached || catalog?.catalogAvailability == .unconfirmed {
                    // Availability is retained, but never presented as current.
                    if let lastSuccess = catalog?.catalogCheckedAt {
                        Text("Showing cached availability; last successful check \(lastSuccess.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 5)
                    } else {
                        Text("Showing the versions shipped with Vaelen. No successful update check yet.")
                            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 5)
                    }
                }
                if catalog == nil {
                    Text(phpChecking ? "Checking available runtimes…" : "Available versions unavailable")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
                } else if !catalog!.availableVersionsKnown {
                    // Availability is retained, but it is never presented as
                    // confirmed, and the retry stays available.
                    Text("Available versions could not be refreshed. \(available.isEmpty ? "" : "Showing \(available.count) cached option\(available.count == 1 ? "" : "s").")")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 14).padding(.vertical, 9)
                } else if available.isEmpty {
                    Text(availableEmptyMessage)
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
                } else {
                    // Installation options: families with nothing installed yet.
                    ForEach(available, id: \.self) { version in
                        runtimeRow("available:\(version)", title: "PHP \(version)", subtitle: PHPSeriesLabel.series(for: version), state: .pending)
                    }
                }
                // Published but not yet recorded with verified package metadata.
                // Advertised honestly as not installable yet.
                let unverified = catalog?.advertisedUnverifiedVersions ?? []
                if !unverified.isEmpty {
                    Text("Newer patches are published but Vaelen has not verified their packages yet: \(unverified.joined(separator: ", ")). Run Check for Updates again shortly.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 5)
                }
            }.padding(.bottom, 14)
        }
    }

    private var runtimeDetail: some View {
        VStack(alignment: .leading, spacing: 17) {
            // An update that installed but did not finish converging is reported
            // as partial success, with a targeted recovery action.
            if let outcome = model.phpUpdateOutcome, let failure = outcome.convergenceError {
                SettingsInsetCard {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("PHP \(outcome.version) installed, but some work did not finish", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(.orange)
                        Text(failure).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let replaced = outcome.replacedVersion {
                            Text("PHP \(replaced) is still installed because the update did not finish. Nothing was lost — retry to finish routing.")
                                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Retry convergence", systemImage: "arrow.clockwise") { Task { await model.retryPHPUpdateConvergence(outcome.version) } }
                            .disabled(model.phpRequestInFlight || !coreConnected)
                    }.padding(11)
                }
            }
            if !model.phpDefaultProjectIssues.isEmpty {
                SettingsInsetCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("PHP default changed; some projects need attention", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                        ForEach(model.phpDefaultProjectIssues, id: \.projectName) { issue in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(issue.projectName): \(issue.message)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Button(model.phpRequestTarget == "project:\(issue.projectName)" ? "Retrying…" : "Retry \(issue.projectName) routing", systemImage: "arrow.clockwise") { Task { await model.retryPHPProjectReconciliation(issue.projectName) } }
                                    .disabled(model.phpRequestInFlight || !coreConnected)
                            }
                        }
                    }.padding(11)
                }
            }
            if !model.phpDefaultRoutingIssues.isEmpty {
                SettingsInsetCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("PHP default changed; routing needs attention", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                        ForEach(Array(model.phpDefaultRoutingIssues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.padding(11)
                }
            }
            if let error = model.refreshError {
                Label("Showing last confirmed PHP state · \(error)", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.phpConfigurationReadPending, model.phpConfiguration != nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Refreshing PHP settings…").font(.caption).foregroundStyle(.secondary) }
            }
            if let error = model.phpError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if let runtime = installed.first(where: { $0.version == selectedItem }), runtime.updateAvailable == true, let target = runtime.latestVersion {
                    Button("Retry Update to PHP \(target)", systemImage: "arrow.clockwise") { Task { await model.updatePHP(target, replacing: runtime.version) } }.disabled(model.phpRequestInFlight || !coreConnected || phpChecking)
                } else {
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await model.refreshPHPSettings() } }
                }
            }
            if selectedItem == "shared" { sharedDefaultsDetail }
            else if selectedItem.hasPrefix("available:"), available.contains(selectedVersion ?? "") { availableRuntimeDetail }
            else if selectedItem.hasPrefix("available:") { unavailableAvailableSelectionDetail }
            else if let runtime = installed.first(where: { $0.version == selectedItem }) { installedRuntimeDetail(runtime) }
            else if catalog == nil { unavailableCatalogDetail }
            else { sharedDefaultsDetail }
        }
    }

    private var sharedDefaultsDetail: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shared PHP settings").font(.title2.weight(.semibold))
                    Text("Configuration values inherited by runtimes without a version-specific override. These do not choose a project's PHP version.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if phpChecking { SettingsStateBadge(title: "Checking", tone: .pending) }
                else if !coreConnected { SettingsStateBadge(title: "Unavailable", tone: .attention) }
            }
            configurationEditor()
            configLocations(version: nil)
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
                if runtime.isDefault { Label("Default runtime", systemImage: "star.fill").font(.caption).foregroundStyle(.secondary) }
                if runtime.usedByProjectCount > 0 { Text("Used by \(runtime.usedByProjectCount) projects").font(.caption).foregroundStyle(.secondary) }
            }
            runtimeActionRow(runtime)
            runtimeStopWarning(runtime)
            Text("The default runtime is used by projects without a PHP version override. Making this runtime the default starts its PHP-FPM and refreshes those projects; other runtimes are not stopped.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let config {
                SettingsInsetCard {
                    PHPConfigurationForm(editor: model.phpSettings, context: .version(runtime.version), settings: config.settings, mode: config.inheritsDefault ? .inherited : .override,
                        saveTitle: "Save PHP \(runtime.version)", saving: model.phpSettings.savingContext == .version(runtime.version), disabled: model.phpConfigurationSaving || model.phpConfigurationReadPending || model.phpRequestInFlight || !coreConnected || phpChecking,
                        guidance: config.fpmRunning ? "Saving changed values restarts PHP \(runtime.version) FPM. CLI changes apply to the next command." : "PHP \(runtime.version) is stopped. Saved values apply on its next start; CLI changes apply to the next command.",
                        invalidDraftFixture: model.settingsFixtureMode == "php-settings-invalid",
                        reset: config.inheritsDefault ? nil : { Task { await model.savePHPConfiguration(version: runtime.version, settings: nil) } },
                        save: { settings in Task { await model.savePHPConfiguration(version: runtime.version, settings: settings) } })
                        .id(PHPSettingsContext.version(runtime.version))
                }
            } else {
                missingConfiguration(version: runtime.version)
            }
            if let error = model.phpConfigurationError, config != nil {
                Label("\(model.phpSettings.saveMessages[.version(runtime.version)] != nil ? "Settings were saved, but a later refresh failed" : "Could not refresh settings"): \(error). Showing last confirmed values.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Button("Retry Settings", systemImage: "arrow.clockwise") { Task { await model.refreshPHPConfiguration() } }
            }
            configLocations(version: runtime.version)
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
            SettingsInsetCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                        Text("Package").font(.headline)
                    }
                    Text("Verified package · managed by Vaelen").font(.caption).foregroundStyle(.secondary)
                    Text("Data and configuration are preserved independently of package installation.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Install PHP \(version)", systemImage: "arrow.down.circle.fill") { Task { await model.installPHP(version) } }
            .buttonStyle(.borderedProminent).tint(.accentColor).disabled(model.phpRequestInFlight || !coreConnected || phpChecking)
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

    /// One compact action row near the selected runtime's header: Start or Stop
    /// by confirmed state, Update when a newer patch is available, Make Default
    /// and Remove as icon controls. Unknown running state enables no
    /// start/stop/remove action.
    private func runtimeActionRow(_ runtime: PHPRuntimeVersion) -> some View {
        let busy = model.phpRequestTarget == runtime.version
        let blocked = model.phpRequestInFlight || model.phpConfigurationSaving || !coreConnected || phpChecking
        return HStack(spacing: 8) {
            if runtime.running == false {
                Button(busy && model.phpOperation?.kind == .start ? "Starting…" : "Start", systemImage: "play.fill") {
                    Task { await model.startPHPRuntime(runtime.version) }
                }
                .help("Start PHP \(runtime.version)")
                .accessibilityLabel("Start PHP \(runtime.version)")
                .disabled(blocked || model.serviceOperation != nil)
            } else if runtime.running == true {
                Button(busy && model.phpOperation?.kind == .stop ? "Stopping…" : "Stop", systemImage: "stop.fill",
                       role: runtime.usedByProjectCount > 0 ? .destructive : nil) {
                    if runtime.usedByProjectCount > 0 { stopConfirmation = runtime }
                    else { Task { await model.stopPHPRuntime(runtime.version) } }
                }
                .settingsDestructiveTint()
                .help("Stop PHP \(runtime.version)")
                .accessibilityLabel("Stop PHP \(runtime.version)")
                .disabled(blocked || model.serviceOperation != nil)
            }
            if runtime.updateAvailable == true, let latest = runtime.latestVersion {
                // The selected runtime is named as the source so its saved
                // settings are the ones carried over.
                Button(busy && model.phpOperation?.kind == .update ? "Updating…" : "Update", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await model.updatePHP(latest, replacing: runtime.version) }
                }
                .help("Update PHP \(runtime.version) to \(latest)")
                .accessibilityLabel("Update PHP \(runtime.version) to \(latest)")
                .disabled(blocked)
            }
            Spacer(minLength: 4)
            if !runtime.isDefault {
                Button {
                    Task { await model.setDefaultPHP(runtime.version) }
                } label: {
                    Image(systemName: busy && model.phpOperation?.kind == .defaultSelection ? "star.fill" : "star")
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(busy && model.phpOperation?.kind == .defaultSelection ? "Switching default to PHP \(runtime.version)…" : "Make PHP \(runtime.version) the default for projects without a version override")
                .accessibilityLabel("Make PHP \(runtime.version) the default")
                .disabled(blocked || runtime.running == nil)
            }
            if runtime.running == false && !runtime.isDefault {
                Button {
                    removalVersion = runtime.version
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove PHP \(runtime.version)")
                .accessibilityLabel("Remove PHP \(runtime.version)")
                .disabled(blocked)
            }
        }
    }

    private var unavailableAvailableSelectionDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(catalog?.availableVersionsKnown == false || phpChecking ? "Checking available PHP versions…" : "Available PHP versions unavailable", systemImage: phpChecking ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                .font(.title3.weight(.semibold)).foregroundStyle(phpChecking ? Color.secondary : Color.orange)
            Text("Core has not confirmed this version as installable. No package action is offered until the catalog is refreshed.")
                .font(.subheadline).foregroundStyle(.secondary)
            if phpChecking { ProgressView().controlSize(.small) }
            else { Button("Refresh PHP Status", systemImage: "arrow.clockwise") { Task { await model.refresh() } } }
        }.padding(.top, 8)
    }

    private func configLocations(version: String?) -> some View {
        DisclosureGroup("Configuration locations") {
            if let config = model.phpConfiguration {
                VStack(alignment: .leading, spacing: 6) {
                    if let version, let item = config.versions.first(where: { $0.version == version }) {
                        Text("PHP \(version) FPM INI: \(item.fpmIniPath)")
                        Text("PHP \(version) CLI INI: \(item.cliIniPath)")
                        Text("PHP \(version) FPM configuration: \(item.fpmConfigurationPath)")
                    } else if version == nil {
                        Text("Shared values: \(config.directory)/settings.json")
                    }
                    if version == nil || config.versions.contains(where: { $0.version == version }) {
                        Button(version.map { "Open PHP \($0) Configuration…" } ?? "Open Shared Configuration…", systemImage: "folder") { Task { await model.openPHPConfigurationFiles(version: version) } }
                            .disabled(!coreConnected || phpChecking)
                    }
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

    private func configurationEditor() -> some View {
        Group {
            if let configuration = model.phpConfiguration {
                SettingsInsetCard {
                    PHPConfigurationForm(editor: model.phpSettings, context: .shared, settings: configuration.defaultSettings, mode: .shared,
                        saveTitle: "Save Shared Settings", saving: model.phpSettings.savingContext == .shared, disabled: model.phpConfigurationSaving || model.phpConfigurationReadPending || model.phpRequestInFlight || !coreConnected || phpChecking,
                        guidance: "Saving changed values restarts affected running PHP-FPM instances. Stopped runtimes use them on their next start. Version overrides are preserved.",
                        invalidDraftFixture: model.settingsFixtureMode == "php-settings-invalid",
                        save: { settings in Task { await model.savePHPConfiguration(version: nil, settings: settings) } })
                        .id(PHPSettingsContext.shared)
                }
                if let error = model.phpConfigurationError {
                    Text("\(model.phpSettings.saveMessages[.shared] != nil ? "Shared settings were saved, but a later refresh failed" : "Could not refresh shared settings"): \(error). Showing last confirmed values.").font(.caption).foregroundStyle(.orange)
                    Button("Retry Settings") { Task { await model.refreshPHPConfiguration() } }
                }
            } else if model.phpConfigurationReadPending {
                SettingsInsetCard { HStack { ProgressView().controlSize(.small); Text("Checking PHP configuration…").font(.subheadline).foregroundStyle(.secondary) } }
            } else {
                SettingsInsetCard { VStack(alignment: .leading, spacing: 8) { Text("Shared PHP settings unavailable").font(.headline); Text(model.phpConfigurationError ?? "Core did not provide configuration values.").font(.caption).foregroundStyle(.secondary); Button("Retry Settings", systemImage: "arrow.clockwise") { Task { await model.refreshPHPConfiguration() } } } }
            }
        }
    }

    private func runtimeStopWarning(_ runtime: PHPRuntimeVersion) -> some View {
        Group {
            if runtime.running == true, runtime.usedByProjectCount > 0 {
                Text("Used by \(runtime.usedByProjectCount) project(s); stopping interrupts their PHP requests.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func missingConfiguration(version: String) -> some View {
        SettingsInsetCard {
            VStack(alignment: .leading, spacing: 8) {
                if model.phpConfigurationReadPending {
                    HStack { ProgressView().controlSize(.small); Text("Loading PHP \(version) settings…") }
                } else {
                    Label("PHP \(version) settings unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(model.phpConfigurationError ?? "Core has not returned configuration for this installed version. Refresh its settings to try again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Retry PHP \(version) Settings", systemImage: "arrow.clockwise") { Task { await model.refreshPHPConfiguration() } }
                        .disabled(!coreConnected || model.phpRequestInFlight)
                }
            }
        }
    }

    private var phpChecking: Bool {
        if case .connecting = model.state { return true }
        return model.phpCatalogReadPending || model.isServiceReadPending("PHP")
    }

    private func selectInitialRuntime() {
        guard !didSelectInitialRuntime, let catalog else { return }
        selectedItem = model.settingsFixturePHPSelection ?? catalog.defaultVersion ?? catalog.installedVersions.first?.version ?? "shared"
        didSelectInitialRuntime = true
    }

    private func catalogDidChange() {
        guard let catalog else { return }
        if !didSelectInitialRuntime {
            selectInitialRuntime()
            return
        }
        if selectedItem == "shared" { return }
        if selectedItem.hasPrefix("available:") {
            let version = String(selectedItem.dropFirst("available:".count))
            if installed.contains(where: { $0.version == version }) { selectedItem = version }
            else if catalog.availableVersionsKnown && !available.contains(version) { selectedItem = "shared" }
        } else if !installed.contains(where: { $0.version == selectedItem }) {
            if available.contains(selectedItem) { selectedItem = "available:\(selectedItem)" }
            else { selectedItem = "shared" }
        }
    }

    @ViewBuilder
    private func phpSectionHeader<Accessory: View>(_ title: String, count: Int? = nil, top: CGFloat = 0, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        HStack(alignment: .center, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.system(size: 10, weight: .regular)).foregroundStyle(.tertiary).monospacedDigit() }
            Spacer(minLength: 4)
            accessory()
        }
        .padding(.horizontal, 13).padding(.top, top).padding(.bottom, 5)
    }

    private var phpInventoryPending: Bool {
        if case .connecting = model.state { return true }
        return model.phpCatalogReadPending || model.isServiceReadPending("PHP")
    }

    /// The shared update indicator: the existing accent update icon, visually
    /// distinct from the default star and the running-state dot, with reserved
    /// width so every row stays aligned whether or not it is shown.
    private func updateIndicator(to target: String) -> some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)
            .frame(width: 14, height: 12)
            .help("Update available: PHP \(target)")
            .accessibilityLabel("Update available: PHP \(target)")
    }

    private static let updateIndicatorPlaceholder: some View = Color.clear.frame(width: 14, height: 12).accessibilityHidden(true)

    private func runtimeRow(_ key: String, title: String, subtitle: String, state: SettingsStateBadge.Tone, isDefault: Bool = false, updateAvailable: String? = nil) -> some View {
        Button { selectedItem = key } label: {
            HStack(spacing: 8) {
                // Default star, left-aligned and always in the same position.
                Image(systemName: "star.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange).frame(width: 12, height: 12).opacity(isDefault ? 1 : 0).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer(minLength: 2)
                if let updateAvailable { updateIndicator(to: updateAvailable) } else { Self.updateIndicatorPlaceholder }
                SettingsStateDot(title: "", tone: state)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 9)
            .background(selectedItem == key ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 7)
            .accessibilityAddTraits(selectedItem == key ? .isSelected : [])
    }

    private func phpVersionDescending(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = PHPVersion(lhs), let right = PHPVersion(rhs) else { return lhs > rhs }
        return left > right
    }

    /// Row subtitles stay short: project use and running state. An available
    /// update is communicated by the adjacent update symbol (with its tooltip),
    /// not by repeating it as prose.
    private func runtimeSubtitle(_ runtime: PHPRuntimeVersion) -> String {
        var parts: [String] = []
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

    /// Shared measured progress for PHP install and update operations.
///
/// Backed by the typed Core operation state. One horizontal determinate bar is
/// shown whenever the aggregate total is known, with a numeric percentage from
/// the first byte of the first archive. When the aggregate total genuinely
/// cannot be known, per-archive progress and transferred bytes are shown instead
/// of an invented percentage. Verification and installation stay visible after
/// the transfer reaches 100%, so "download complete" is never mistaken for a
/// finished update.
struct PHPOperationProgressView: View {
    let operation: PHPOperationState?

    private var determinate: (transferred: Double, total: Double)? {
        guard let bytes = operation?.bytesTransferred, let total = operation?.totalBytes, total > 0 else { return nil }
        return (Double(bytes), Double(total))
    }

    private var percentage: Int {
        guard let determinate, determinate.total > 0 else { return 0 }
        return min(100, max(0, Int((determinate.transferred / determinate.total * 100).rounded())))
    }

    /// Whether every expected byte has arrived. Past this point the determinate
    /// transfer bar is finished context, not the current activity.
    private var downloadComplete: Bool {
        guard let determinate else { return false }
        return determinate.total > 0 && determinate.transferred >= determinate.total
    }

    /// Phases where work is still in flight. These show a small native activity
    /// indicator in place of the leading icon; terminal phases restore the icon.
    private func isActive(_ operation: PHPOperationState) -> Bool {
        switch operation.phase {
        case .starting, .downloading, .verifying, .installing, .startingRuntime, .converging, .removing:
            return true
        case .ready, .removed, .failed:
            return false
        }
    }

    var body: some View {
        if let operation {
            VStack(alignment: .leading, spacing: 5) {
                // One stage message with one leading indicator: a spinner while
                // work is active, the outcome icon once it finishes. The fixed
                // frame keeps the row's alignment stable when the icon changes.
                HStack(spacing: 6) {
                    if isActive(operation) {
                        ProgressView().controlSize(.small).frame(width: 14)
                    } else {
                        Image(systemName: symbol(operation)).frame(width: 14)
                    }
                    Text(description(operation))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText(operation))
                switch operation.phase {
                case .downloading:
                    if let determinate {
                        // Determinate from the start; both archives contribute.
                        ProgressView(value: determinate.transferred, total: determinate.total)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 260)
                        Text(detail(operation, determinate: determinate))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        // Truthful fallback: transferred bytes, no invented total.
                        Text("\(ByteCountFormatter.string(fromByteCount: operation.bytesTransferred ?? 0, countStyle: .file)) transferred · total size unknown\(archiveSuffix(operation))")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                case .verifying, .installing, .startingRuntime, .converging, .removing:
                    // A completed download stays visible as finished context,
                    // clearly labelled so it never reads as overall completion.
                    if downloadComplete, let determinate {
                        Text("Download complete · \(ByteCountFormatter.string(fromByteCount: Int64(determinate.total), countStyle: .file)) received")
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                default:
                    EmptyView()
                }
            }
        }
    }

    private func accessibilityText(_ operation: PHPOperationState) -> String {
        if case .downloading = operation.phase, determinate != nil {
            return "\(description(operation)) \(percentage) percent"
        }
        return description(operation)
    }

    private func archiveSuffix(_ operation: PHPOperationState) -> String {
        guard let name = operation.artifactName else { return "" }
        if let index = operation.artifactIndex, let count = operation.artifactCount, count > 1 {
            return " · \(name) (\(index) of \(count))"
        }
        return " · \(name)"
    }

    private func detail(_ operation: PHPOperationState, determinate: (transferred: Double, total: Double)) -> String {
        let transferred = ByteCountFormatter.string(fromByteCount: Int64(determinate.transferred), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(determinate.total), countStyle: .file)
        // Verified cache reuse is stated plainly, and is allowed to finish quickly
        // rather than being slowed down to animate.
        if operation.usingVerifiedCachedDownloads == true {
            return "Using verified cached downloads · \(transferred) verified"
        }
        switch operation.phase {
        case .downloading:
            return "\(percentage)% · \(transferred) of \(total)\(archiveSuffix(operation))"
        case .verifying:
            return "Transfer complete · verifying \(transferred)\(archiveSuffix(operation))"
        case .installing:
            return "Verified · installing and validating PHP \(operation.targetVersion)"
        default:
            return "\(transferred) of \(total)"
        }
    }

    private func symbol(_ operation: PHPOperationState) -> String {
        switch operation.phase {
        case .failed: "exclamationmark.triangle"
        case .ready: "checkmark.circle"
        case .verifying: "checkmark.shield"
        case .installing: "shippingbox"
        case .startingRuntime: "play.circle"
        case .converging: "arrow.triangle.2.circlepath"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private func description(_ operation: PHPOperationState) -> String {
        let target = operation.targetVersion
        switch operation.phase {
        case .starting: return "Preparing PHP \(target)…"
        case .downloading: return "Downloading PHP \(target)…"
        case .verifying:
            return operation.usingVerifiedCachedDownloads == true
                ? "Using verified cached downloads"
                : "Verifying package…"
        case .installing: return "Installing PHP \(target)…"
        case .startingRuntime: return "Starting PHP \(target)…"
        case .converging: return "Updating project routing…"
        case .removing:
            // Update cleanup removes the replaced runtime through this phase.
            // The operation names the incoming version, so the stage names the
            // outgoing role instead of a wrong version number.
            return operation.kind == .update ? "Removing replaced runtime…" : "Removing PHP \(target)…"
        case .removed: return "PHP \(target) removed."
        case .ready: return readyDescription(operation)
        case .failed: return "PHP \(target) operation failed."
        }
    }

    /// Terminal messages name the action that finished. Start, Stop, Make
    /// Default, Remove, Install, and Update each read differently so a finished
    /// switch of defaults is never described as an installation.
    private func readyDescription(_ operation: PHPOperationState) -> String {
        let target = operation.targetVersion
        switch operation.kind {
        case .install: return "PHP \(target) installed."
        case .update: return "PHP \(target) updated."
        case .remove: return "PHP \(target) removed."
        case .defaultSelection: return "PHP \(target) is now the default."
        case .configurationUpdate: return "PHP \(target) settings saved."
        case .start: return "PHP \(target) started."
        case .stop: return "PHP \(target) stopped."
        }
    }
}

}

private struct PHPConfigurationForm: View {
    enum Mode { case shared, inherited, override }
    @Bindable var editor: PHPConfigurationEditor
    let context: PHPSettingsContext
    let settings: PHPSettingsValues
    let mode: Mode
    let saveTitle: String
    let saving: Bool
    let disabled: Bool
    let guidance: String
    var invalidDraftFixture = false
    var reset: (() -> Void)? = nil
    let save: (PHPSettingsValues) -> Void
    private var draft: PHPSettingsDraft { editor.draft(for: context, settings: settings) }
    private var conflict: Bool { draft.isDirty && draft.baseline != settings }
    private var postLimitMB: Int { draft.values?.postLimitMB ?? settings.postLimitMB }
    private func field(_ key: WritableKeyPath<PHPSettingsDraft, String>) -> Binding<String> {
        Binding(get: { draft[keyPath: key] }, set: { value in editor.edit(context, settings: settings) { $0[keyPath: key] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(mode == .shared ? "Shared values" : mode == .inherited ? "Using shared values" : "Version override")
                    .font(.subheadline.weight(.medium))
                if mode == .inherited { Text("Inherited").font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
                Spacer()
            }
            Text("Unsaved edits stay with this settings context while you switch runtimes.").font(.caption2).foregroundStyle(.secondary)
            if conflict {
                Text("Saved values changed during refresh. Your draft is preserved; reload saved values before saving.").font(.caption).foregroundStyle(.orange)
            }
            if draft.isDirty {
                Button("Discard Draft & Reload Saved Values") { editor.discardDraft(context, settings: settings) }.disabled(disabled)
            }
            PHPSettingsFormSection(title: "Uploads & requests") {
                PHPNumericFieldRow(label: "Maximum upload size", text: field(\.upload), unit: "MB", range: 1...2048, help: "Largest individual uploaded file.")
                HStack(spacing: 6) {
                    Text("POST body limit").foregroundStyle(.secondary)
                    Spacer()
                    Text(String(postLimitMB) + " MB").monospacedDigit()
                    Text("Managed automatically").font(.caption).foregroundStyle(.secondary)
                }.font(.callout).padding(.vertical, 5).accessibilityElement(children: .combine)
            }.disabled(disabled)
            PHPSettingsFormSection(title: "Resource limits") {
                PHPNumericFieldRow(label: "Memory limit", text: field(\.memory), unit: "MB", range: 16...4096, help: "Maximum memory available to a PHP script.")
                PHPNumericFieldRow(label: "Maximum execution time", text: field(\.execution), unit: "seconds", range: 0...86_400, help: "0 means unlimited for web requests. Managed CLI PHP remains unlimited.")
                PHPNumericFieldRow(label: "Maximum input variables", text: field(\.variables), unit: "variables", range: 100...1_000_000, help: "Applies to web and CLI PHP.")
            }.disabled(disabled)
            DisclosureGroup("PHP directive details") {
                Text("Vaelen keeps post_max_size at least 1 MB above upload_max_filesize to allow for multipart request overhead. memory_limit and max_input_vars apply to web and CLI PHP; max_execution_time applies to FPM/web requests, while managed CLI PHP is unlimited.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            }.font(.caption)
            PHPSettingsFormFooter(saveTitle: saveTitle, saving: saving, guidance: guidance,
                feedback: editor.saveErrors[context] ?? editor.saveMessages[context], feedbackIsError: editor.saveErrors[context] != nil,
                canSave: !disabled && !conflict && draft.isDirty && draft.values != nil, save: { if let values = draft.values { save(values) } })
            if let reset {
                Divider()
                Button("Reset to Shared Values", role: .destructive, action: reset).settingsDestructiveTint().disabled(disabled)
            }
        }
        .onAppear {
            if invalidDraftFixture { editor.edit(context, settings: settings) { $0.upload = "3000" } }
        }
    }
}

private struct PHPSettingsFormSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) { content }
        }.padding(.top, 2)
    }
}

private struct PHPNumericFieldRow: View {
    let label: String
    @Binding var text: String
    let unit: String
    let range: ClosedRange<Int>
    let help: String
    private var parsed: Int? { Int(text) }
    private var error: String? {
        guard let value = parsed else { return text.isEmpty ? "Enter a value." : "Enter a whole number." }
        guard range.contains(value) else { return "Use \(String(range.lowerBound))–\(String(range.upperBound))." }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(label).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                TextField(label, text: $text).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 92).monospacedDigit()
                    .accessibilityLabel(label).accessibilityHint(help)
                Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            }.frame(minHeight: 30)
            if let error { Text(error).font(.caption2).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .trailing) }
        }.help(help)
    }
}

private struct PHPSettingsFormFooter: View {
    let saveTitle: String
    let saving: Bool
    let guidance: String
    let feedback: String?
    let feedbackIsError: Bool
    let canSave: Bool
    let save: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(guidance).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(saveTitle, action: save).buttonStyle(.borderedProminent).disabled(saving || !canSave)
            }
            if let feedback { Label(feedback, systemImage: feedbackIsError ? "exclamationmark.circle" : "checkmark.circle").font(.caption).foregroundStyle(feedbackIsError ? Color.red : Color.secondary) }
        }.padding(.top, 8).overlay(alignment: .top) { Divider() }
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
                    Task { await model.updatePHP(latest, replacing: runtime.version) }
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
                    .settingsDestructiveTint()
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
            Button("Remove", role: .destructive) { Task { await model.removePHP(runtime.version) } }.settingsDestructiveTint()
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the Vaelen-managed PHP runtime from this Mac. Project files are not changed.")
        }
    }

    @State private var showRemovalConfirmation = false
}

private enum PHPSeriesLabel {
    static func series(for version: String) -> String {
        guard let parsed = PHPVersion(version) else { return "PHP series unavailable" }
        if let status = PHPPackageProvider.seriesLabels[parsed.family] { return "PHP \(parsed.family) · \(status)" }
        return "PHP \(parsed.family) series"
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
                    Text(coreHasSnapshot ? "No folders added" : coreConnecting ? "Checking folders…" : "Workspace folders unavailable")
                        .font(.caption).foregroundStyle(coreHasSnapshot || coreConnecting ? Color.secondary : Color.orange).padding(.horizontal, 13).padding(.vertical, 8)
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
                            Button("Remove Workspace Folder…", systemImage: "minus.circle", role: .destructive) { Task { await model.removeParkedFolder(folder) } }
                                .settingsDestructiveTint().disabled(model.relationshipMutationInFlight)
                        } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }.menuStyle(.borderlessButton)
                            .accessibilityLabel("Actions for \(displayPath(folder.path))")
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                }
                Text("LINKED PROJECTS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.top, 14).padding(.bottom, 4)
                if model.linkedProjects.isEmpty {
                    Text(coreHasSnapshot ? "No linked projects" : coreConnecting ? "Waiting for Core…" : "Linked project state unavailable")
                        .font(.caption).foregroundStyle(coreHasSnapshot || coreConnecting ? Color.secondary : Color.orange).padding(.horizontal, 13).padding(.vertical, 8)
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
                    Button("Unlink Project…", systemImage: "link.badge.minus", role: .destructive) { confirmUnlink = true }.settingsDestructiveTint()
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
            Button("Unlink Project", role: .destructive) { Task { await model.unlinkProject(project) } }.settingsDestructiveTint()
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
                Button("Remove Workspace Folder", systemImage: "minus.circle", role: .destructive) { Task { await model.removeParkedFolder(folder) } }
                    .settingsDestructiveTint().disabled(model.relationshipMutationInFlight)
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
                Button("Unlink Project…", systemImage: "link.badge.minus", role: .destructive) { showUnlinkConfirmation = true }.settingsDestructiveTint()
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
            Button("Unlink Project", role: .destructive) { Task { await model.unlinkProject(project) } }.settingsDestructiveTint()
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
