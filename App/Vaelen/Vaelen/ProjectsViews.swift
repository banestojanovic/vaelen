import SwiftUI
import AppKit
import VaelenIPC
import VaelenCore

struct ProjectsView: View {
    let projects: [ProjectWire]
    let reports: [ProjectEnvironmentReport]
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedProjectPaths = Set<String>()

    var body: some View {
        if projects.isEmpty {
            VStack(spacing: VaelenUI.spacing10) {
                VaelenEmptyState(title: "No Projects", systemImage: "folder", message: "Link a project folder to see its site and services here.")
                Button("Link Project…", systemImage: "link") {
                    guard !model.relationshipMutationInFlight,
                          let path = chooseDirectory(title: "Choose a Project to Link", prompt: "Link Project") else { return }
                    Task { await model.linkProject(at: path) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.relationshipMutationInFlight)
                if let operation = model.relationshipOperation {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(operation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.relationshipError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(minHeight: 180)
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ProjectFrameworkGroup.allCases, id: \.self) { group in
                        let groupedProjects = projects.filter { ProjectFrameworkGroup(project: $0) == group }
                        if !groupedProjects.isEmpty {
                            let firstGroup = ProjectFrameworkGroup.allCases.first {
                                candidate in projects.contains { ProjectFrameworkGroup(project: $0) == candidate }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                PopoverSectionHeading(title: group.title)
                                    .padding(.horizontal, 9)
                                    .padding(.top, group == firstGroup ? 14 : 20)
                                    .padding(.bottom, 3)
                                ForEach(Array(groupedProjects.enumerated()), id: \.element.path) { index, project in
                                    let report = reports.first { $0.identity.path == project.path }
                                    let routes = routesForProject(project, report: report, configured: model.configuredRoutes)
                                    ProjectCard(
                                        project: project,
                                        report: report,
                                        reportError: model.projectReportErrors[project.path],
                                        routes: routes,
                                        model: model,
                                        isExpanded: expandedProjectPaths.contains(project.path),
                                        toggleExpansion: { toggleExpansion(for: project) }
                                    )
                                    Divider()
                                        .opacity(0.3)
                                        .padding(.horizontal, 9)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func toggleExpansion(for project: ProjectWire) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            if expandedProjectPaths.contains(project.path) {
                expandedProjectPaths.remove(project.path)
            } else {
                expandedProjectPaths.insert(project.path)
            }
        }
    }
}

private enum ProjectFrameworkGroup: CaseIterable {
    case expo, laravel, wordpress, other

    init(project: ProjectWire) {
        let framework = project.detectedFramework?.lowercased() ?? ""
        if framework.contains("expo") { self = .expo }
        else if framework.contains("laravel") { self = .laravel }
        else if framework.contains("wordpress") { self = .wordpress }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .expo: "Expo"
        case .laravel: "Laravel"
        case .wordpress: "WordPress"
        case .other: "Other"
        }
    }
}

func routesForProject(_ project: ProjectWire, report: ProjectEnvironmentReport?, configured: [RouteIntent]?) -> [RouteIntent]? {
    guard let configured else { return nil }
    let verifiedDocumentRoot = report?.derived.framework.suggestedDocumentRoot.map {
        URL(fileURLWithPath: project.path).appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath().path
    }
    return ProjectRouteAttribution.routes(for: project.id, verifiedDocumentRoot: verifiedDocumentRoot, from: configured)
}

struct ProjectCard: View {
    let project: ProjectWire
    let report: ProjectEnvironmentReport?
    let reportError: String?
    let routes: [RouteIntent]?
    let model: AppModel
    let isExpanded: Bool
    let toggleExpansion: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private enum FocusedControl: Hashable { case site, database, expansion }
    @FocusState private var focusedControl: FocusedControl?
    @State private var hoveredControl: FocusedControl?
    @State private var rowHovered = false

    private var warnings: [ProjectDiagnostic] {
        guard let report, report.identity.registration == .linked else { return [] }
        return report.diagnostics.filter { $0.severity == .warning || $0.severity == .error }
    }

    private var headerAlertMessages: [String] {
        var messages = warnings.map(\.message)
        if project.availability != PathAvailability.available.rawValue {
            messages.append("Project folder unavailable")
        }
        if let routeError = model.configuredRoutesError {
            messages.append(routeError)
        }
        return messages
    }

    private var databaseAction: ProjectDatabaseViewerAction? {
        guard let report else { return nil }
        return ProjectDatabaseViewerAction.tablePlus(report: report, tablePlusInstalled: model.isTablePlusInstalled)
    }

    private var canOpenDatabase: Bool { databaseAction?.isEnabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 7) {
                FrameworkMark(framework: project.detectedFramework)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(project.name)
                    .font(.system(.headline, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(project.name)
                Spacer(minLength: 3)
                HStack(spacing: 1) {
                    Group {
                        if let warning = warnings.first {
                            Image(systemName: warning.severity == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(warning.severity == .error ? Color.red : Color.orange)
                        } else if !headerAlertMessages.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(width: 25, height: 25)
                    .help(headerAlertMessages.joined(separator: "\n"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(headerAlertMessages.joined(separator: ". "))
                    Group {
                        if let route = routes?.first, routes?.count == 1 {
                            Button { model.openProjectRoute(route) } label: {
                                Image(systemName: "safari")
                                    .frame(width: 25, height: 25)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusedControl, equals: .site)
                            .onHover { hoveredControl = $0 ? .site : nil }
                            .background { actionBackground(for: .site) }
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(focusedControl == .site ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                            }
                            .help("Open \(route.route.hostname)")
                            .accessibilityLabel("Open site \(route.route.hostname)")
                        } else if let routes, routes.count > 1 {
                            Menu {
                                ForEach(Array(routes.enumerated()), id: \.element.route.id) { _, route in
                                    Button(route.route.hostname, systemImage: route.route.tls == .local ? "lock.fill" : "globe") { model.openProjectRoute(route) }
                                }
                            } label: {
                                Image(systemName: "safari").frame(width: 25, height: 25).contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .focused($focusedControl, equals: .site)
                            .onHover { hoveredControl = $0 ? .site : nil }
                            .background { actionBackground(for: .site) }
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(focusedControl == .site ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                            }
                            .help("Open a project site")
                            .accessibilityLabel("Open site; \(routes.count) hosts available")
                        }
                    }
                    .frame(width: 25, height: 25)
                    Group {
                        if canOpenDatabase {
                            Button { model.openProjectDatabaseInTablePlus(report!) } label: {
                                Image(systemName: "cylinder.split.1x2")
                                    .frame(width: 25, height: 25)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusedControl, equals: .database)
                            .onHover { hoveredControl = $0 ? .database : nil }
                            .background { actionBackground(for: .database) }
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(focusedControl == .database ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                            }
                            .help(databaseAction?.reason ?? "Open project database in TablePlus")
                            .accessibilityLabel("Open project database in TablePlus")
                        }
                    }
                    .frame(width: 25, height: 25)
                    Button(action: toggleExpansion) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 25, height: 25)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedControl, equals: .expansion)
                    .onHover { hoveredControl = $0 ? .expansion : nil }
                    .background { actionBackground(for: .expansion) }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(focusedControl == .expansion ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5)
                    }
                    .frame(width: 25, height: 25)
                    .help(isExpanded ? "Collapse project details" : "Expand project details")
                    .accessibilityLabel(isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)")
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                }
                .font(.system(size: 11, weight: .medium))
            }

            runtimeSummary
            if isExpanded { expandedDetails }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowHovered || focusedControl != nil
                      ? Color.primary.opacity(colorScheme == .light ? 0.045 : 0.10)
                      : .clear)
        }
        .onHover { rowHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project \(project.name)")
    }

    private func actionBackground(for control: FocusedControl) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(hoveredControl == control || focusedControl == control
                  ? Color.primary.opacity(colorScheme == .light ? 0.075 : 0.16)
                  : .clear)
    }

    @ViewBuilder private var runtimeSummary: some View {
        if let report {
            HStack(spacing: 7) {
                if let version = report.observed.php.resolvedVersion {
                    runtimeBadge("PHP", version: version, state: report.observed.php.fpmHealth)
                }
                if report.desired.mysql == true, let mysql = report.observed.mysql {
                    runtimeBadge("MySQL", version: mysql.selectedVersion ?? mysql.installedVersion, state: "\(mysql.state.rawValue) \(mysql.health)")
                }
                if report.desired.mailpit == true, let mailpit = report.observed.mailpit {
                    runtimeBadge("Mailpit", version: mailpit.installedVersion, state: "\(mailpit.state.rawValue) \(mailpit.health)")
                }
            }
            .padding(.leading, 25)
        } else if let reportError {
            Label(reportError, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.leading, 25)
        } else {
            HStack(spacing: 5) {
                VaelenLoadingIndicator()
                Text("Loading project details…").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.leading, 25)
        }
    }

    private func runtimeBadge(_ name: String, version: String?, state: String) -> some View {
        let healthy = state.split(separator: " ").last?.caseInsensitiveCompare("healthy") == .orderedSame
        return HStack(spacing: 3) {
            Image(systemName: healthy ? "circle.fill" : "circle")
                .font(.system(size: 6, weight: .semibold))
                .foregroundStyle(healthy ? Color.green : Color.secondary)
            Text(name)
            if let version { Text(version).foregroundStyle(.secondary) }
        }
        .font(.system(size: 10, weight: .medium))
        .help("\(name) \(version ?? "") · \(state)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(version ?? "version unavailable"), \(state)")
    }

    @ViewBuilder private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(displayPath(project.path))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(project.path)
            if let routes {
                ForEach(routes, id: \.route.id) { route in
                    HStack(spacing: 6) {
                        Image(systemName: route.route.tls == .local ? "lock.fill" : "globe")
                            .foregroundStyle(route.route.tls == .local ? Color.green : Color.secondary)
                        Text(route.route.hostname).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Open") { model.openProjectRoute(route) }
                            .buttonStyle(.bordered).controlSize(.mini)
                        Button("Copy URL") { model.copyProjectRouteURL(route) }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
            }
            if routes == nil {
                Label(model.configuredRoutesError ?? "Site route state unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if project.availability != PathAvailability.available.rawValue {
                Label("Project folder unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !warnings.isEmpty {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: warning.severity == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(warning.severity == .error ? Color.red : Color.orange)
                            .frame(width: 14, alignment: .leading)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.message)
                                .font(.caption)
                                .foregroundStyle(warning.severity == .error ? Color.red : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            if let suggestion = warning.suggestion {
                                Text(suggestion)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            HStack(spacing: 12) {
                Button {
                    model.openProjectFolder(project)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                        Text("Open Folder")
                    }
                }
                    .accessibilityLabel("Open Folder")
                    .disabled(!model.canOpenProjectFolder(project))
                Button {
                    model.openProjectInEditor(project)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "curlybraces")
                        Text("Open in Editor")
                    }
                }
                    .accessibilityLabel("Open in Editor")
                    .disabled(!model.canOpenProjectFolder(project))
                Button {
                    model.copyProjectPath(project)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy Path")
                    }
                }
                    .accessibilityLabel("Copy Path")
            }
            .buttonStyle(.borderless).controlSize(.small)
        }
        .font(.caption)
            .padding(.leading, 25)
        .padding(.top, 3)
        .transition(.identity)
    }

    private func environmentSummary(_ report: ProjectEnvironmentReport) -> String? {
        var values = [String]()
            if let version = report.observed.php.resolvedVersion {
                values.append("PHP \(version.split(separator: ".").prefix(2).joined(separator: "."))" + (report.observed.php.overrideVersion == nil ? "" : " · Project Override"))
            } else if let override = report.observed.php.overrideVersion {
                values.append("PHP \(override) · Unavailable")
        }
        if report.desired.mysql == true, let mysql = report.observed.mysql, let version = mysql.selectedVersion ?? mysql.installedVersion {
            values.append("MySQL \(version)")
        }
        if model.projectSiteURL(report)?.scheme == "https" { values.append("HTTPS ✓") }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

}

private struct FrameworkLogo {
    let asset: String
    let color: Color
    let needsDarkModeBacking: Bool
}

private struct FrameworkMark: View {
    let framework: String?
    @Environment(\.colorScheme) private var colorScheme

    private var logo: FrameworkLogo? {
        guard let framework = framework?.lowercased() else { return nil }
        if framework.contains("expo") { return .init(asset: "Framework-expo", color: Color(hex: 0x1C2024), needsDarkModeBacking: true) }
        if framework.contains("react") { return .init(asset: "Framework-react", color: Color(hex: 0x61DAFB), needsDarkModeBacking: false) }
        if framework.contains("laravel") { return .init(asset: "Framework-laravel", color: Color(hex: 0xFF2D20), needsDarkModeBacking: false) }
        if framework.contains("next") { return .init(asset: "Framework-nextdotjs", color: Color(hex: 0x000000), needsDarkModeBacking: true) }
        if framework.contains("wordpress") { return .init(asset: "Framework-wordpress", color: Color(hex: 0x21759B), needsDarkModeBacking: false) }
        if framework.contains("symfony") { return .init(asset: "Framework-symfony", color: Color(hex: 0x000000), needsDarkModeBacking: true) }
        if framework.contains("drupal") { return .init(asset: "Framework-drupal", color: Color(hex: 0x0678BE), needsDarkModeBacking: false) }
        if framework.contains("magento") { return nil }
        if framework.contains("nuxt") { return .init(asset: "Framework-nuxt", color: Color(hex: 0x00DC82), needsDarkModeBacking: false) }
        if framework.contains("svelte") { return .init(asset: "Framework-svelte", color: Color(hex: 0xFF3E00), needsDarkModeBacking: false) }
        if framework.contains("astro") { return .init(asset: "Framework-astro", color: Color(hex: 0xBC52EE), needsDarkModeBacking: false) }
        if framework.contains("vue") { return .init(asset: "Framework-vuedotjs", color: Color(hex: 0x4FC08D), needsDarkModeBacking: false) }
        if framework.contains("angular") { return .init(asset: "Framework-angular", color: Color(hex: 0x0F0F11), needsDarkModeBacking: true) }
        return nil
    }

    var body: some View {
        if let logo, NSImage(named: logo.asset) != nil {
            Image(logo.asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(colorScheme == .dark && logo.needsDarkModeBacking ? Color(hex: 0xF2F3F5) : logo.color)
                .background {
                    if colorScheme == .dark && logo.needsDarkModeBacking {
                        Circle().fill(Color.white.opacity(0.10))
                    }
                }
        } else {
            Image(systemName: "globe.desk")
                .resizable().scaledToFit().padding(3)
                .foregroundStyle(.secondary)
        }
    }
}
