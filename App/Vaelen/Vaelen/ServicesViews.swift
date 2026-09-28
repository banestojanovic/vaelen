import SwiftUI
import AppKit
import VaelenIPC
import VaelenCore

private struct ServicePresentation {
    let title: String
    let symbol: String
    let tint: Color

    init(_ title: String, _ symbol: String, _ tint: Color) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }
}

private struct ServiceIconButton: View {
    enum Emphasis { case start, stop }

    let label: String
    let systemImage: String
    var emphasis: Emphasis? = nil
    var disabled = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var emphasisTint: Color? {
        switch emphasis {
        case .start: return colorScheme == .light ? Color(hex: 0x398258) : Color(hex: 0x79C895)
        case .stop: return colorScheme == .light ? Color(hex: 0xB44F46) : Color(hex: 0xE98578)
        case nil: return nil
        }
    }

    private var feedbackVisible: Bool { hovered || focused }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(disabled ? Color.primary.opacity(0.38) : (emphasisTint ?? Color.primary.opacity(0.78)))
        .disabled(disabled)
        .focused($focused)
        .focusable()
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(feedbackVisible ? (emphasisTint ?? Color.accentColor).opacity(0.12) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(feedbackVisible ? (emphasisTint ?? Color.accentColor).opacity(0.38) : .clear, lineWidth: 1)
        }
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ServiceRow<Actions: View>: View {
    let icon: String
    let title: String
    let version: String?
    let state: String
    let stateSymbol: String
    let stateTint: Color
    let pending: Bool
    let busy: Bool
    let actions: Actions

    init(
        icon: String,
        title: String,
        version: String?,
        state: String,
        stateSymbol: String,
        stateTint: Color,
        pending: Bool = false,
        busy: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.version = version
        self.state = state
        self.stateSymbol = stateSymbol
        self.stateTint = stateTint
        self.pending = pending
        self.busy = busy
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: VaelenUI.spacing8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.72))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .regular))
                    .lineLimit(1)
                if let version, !version.isEmpty {
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(version)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: 3) {
                HStack(spacing: 3) {
                    if pending {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Checking \(title) status")
                        Text("Checking")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: stateSymbol)
                            .foregroundStyle(stateTint)
                        Text(state)
                            .foregroundStyle(stateTint)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("\(title) operation in progress")
                }
                actions
                    .disabled(busy || pending)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(.trailing, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(pending ? "Checking" : state)")
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
    @State private var showingTrustGuidance = false

    var body: some View {
        Group {
            if showingTrustGuidance, let tls {
                let trustControl = TLSTrustControlPresentation(tls)
                if trustControl.canManageTrust {
                    let details = trustControl.manageTrustDetails(caFingerprint: tls.caFingerprint, certificatePath: tls.caCertificatePath)
                    LocalCATrustDetailsView(
                        fingerprint: details?.fingerprint,
                        certificatePath: details?.certificatePath,
                        explanation: details?.explanation ?? "Trust details are unavailable. Do not change any Keychain trust setting.",
                        manualSteps: details?.manualSteps
                    ) {
                        showingTrustGuidance = false
                    }
                } else {
                    servicesList
                }
            } else {
                servicesList
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var servicesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Runtimes", first: true)
                phpRow

                sectionTitle("Services")
                mysqlRow
                caddyRow
                mailpitRow

                sectionTitle("Networking")
                dnsRow
                tlsRow
                portsRow

                if let operation = model.serviceOperation {
                    VaelenStatusLabel(operation, systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
                        .font(.caption)
                        .padding(.top, VaelenUI.spacing8)
                }
                if let error = model.serviceError ?? model.trustError ?? model.startupServiceIssueMessage {
                    VaelenStatusLabel(error, systemImage: "exclamationmark.triangle", tint: .red)
                        .font(.caption)
                        .padding(.top, VaelenUI.spacing8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func sectionTitle(_ title: String, first: Bool = false) -> some View {
        PopoverSectionHeading(title: title)
            .padding(.top, first ? VaelenUI.spacing12 : 18)
            .padding(.bottom, 4)
    }

    private func resolved(_ value: ServicePresentation?, readLabel: String, present: Bool) -> (ServicePresentation, Bool) {
        let pending = !present && model.isServiceReadPending(readLabel)
        if let value { return (value, false) }
        if pending { return (.init("Checking", "circle.dotted", .secondary), true) }
        return (.init("Unavailable", "exclamationmark.triangle", .orange), false)
    }

    private var phpRow: some View {
        let isPending = model.isServiceReadPending("PHP") && php == nil
        let state: ServicePresentation
        if let php {
            state = php.default != nil
                ? .init("Default", "checkmark.circle", .secondary)
                : (php.installed.isEmpty ? .init("Not installed", "circle", .secondary) : .init("Ready", "checkmark.circle", .secondary))
        } else {
            state = isPending ? .init("Checking", "circle.dotted", .secondary) : .init("Unavailable", "exclamationmark.triangle", .orange)
        }
        return ServiceRow(icon: "chevron.left.forwardslash.chevron.right", title: "PHP", version: php.map { $0.installed.map(\.version).joined(separator: " · ") }, state: state.title, stateSymbol: state.symbol, stateTint: state.tint, pending: isPending) {
            HStack(spacing: 3) {
                if php != nil {
                    ServiceIconButton(label: "Open PHP Configuration Files", systemImage: "doc.text.magnifyingglass") {
                        Task { await model.openPHPConfigurationFiles() }
                    }
                } else if !isPending {
                    ServiceIconButton(label: "Refresh PHP status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var mysqlRow: some View {
        let pending = model.isServiceReadPending("MySQL") && mysql == nil
        let state = resolved(mysql.map(mysqlState), readLabel: "MySQL", present: mysql != nil).0
        let busy = model.serviceOperationIs(for: "MySQL")
        return ServiceRow(icon: "cylinder.fill", title: "MySQL", version: mysql?.selectedVersion ?? mysql?.installedVersion, state: state.title, stateSymbol: state.symbol, stateTint: state.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                let tablePlus = MySQLDatabaseViewerAction.tablePlus(mysql: mysql, tablePlusInstalled: model.isTablePlusInstalled)
                ServiceIconButton(
                    label: pending ? "Checking MySQL and TablePlus availability" : tablePlus.reason,
                    systemImage: "cylinder.split.1x2",
                    disabled: pending || !tablePlus.isEnabled
                ) {
                    if let mysql { model.openMySQLInTablePlus(mysql) }
                }
                if let mysql {
                    if mysql.state == .notInstalled {
                        ServiceIconButton(label: "Install MySQL", systemImage: "arrow.down.to.line") { Task { await model.installMySQL() } }
                    } else if mysql.state == .stopped || mysql.state == .installed || mysql.state == .unhealthy {
                        ServiceIconButton(label: mysql.health == "not-initialized" ? "Initialize and Start MySQL" : "Start MySQL", systemImage: "play.circle", emphasis: .start) { Task { await model.startMySQL() } }
                    }
                    if mysql.state == .running {
                        ServiceIconButton(label: "Stop MySQL", systemImage: "stop.circle", emphasis: .stop) { Task { await model.stopMySQL() } }
                    }
                    if mysql.state != .notInstalled {
                        ServiceIconButton(label: "Reveal MySQL Data Files", systemImage: "folder", disabled: !FileManager.default.fileExists(atPath: mysql.datadir)) { model.revealMySQLDataFiles(mysql) }
                        ServiceIconButton(label: "Reveal MySQL Binaries", systemImage: "shippingbox", disabled: !FileManager.default.fileExists(atPath: mysql.executablePath)) { model.revealMySQLBinaries(mysql) }
                    }
                } else if !pending {
                    ServiceIconButton(label: "Refresh MySQL status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var caddyRow: some View {
        let pending = model.isServiceReadPending("routing") && routing == nil
        let state = resolved(routing.map(routingState), readLabel: "routing", present: routing != nil).0
        let busy = model.serviceOperationIs(for: "Caddy")
        return ServiceRow(icon: "globe", title: "Caddy", version: routing?.providerVersion, state: state.title, stateSymbol: state.symbol, stateTint: state.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let routing {
                    if routing.state == .running {
                        ServiceIconButton(label: "Stop Caddy", systemImage: "stop.circle", emphasis: .stop) { Task { await model.stopRouting() } }
                    } else {
                        ServiceIconButton(label: "Start Caddy", systemImage: "play.circle", emphasis: .start) { Task { await model.startRouting() } }
                    }
                } else if !pending {
                    ServiceIconButton(label: "Refresh Caddy status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var mailpitRow: some View {
        let pending = model.isServiceReadPending("Mailpit") && mailpit == nil
        let state = resolved(mailpit.map(mailpitState), readLabel: "Mailpit", present: mailpit != nil).0
        let busy = model.serviceOperationIs(for: "Mailpit")
        return ServiceRow(icon: "envelope.fill", title: "Mailpit", version: mailpit?.installedVersion, state: state.title, stateSymbol: state.symbol, stateTint: state.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let mailpit {
                    if mailpit.state == .notInstalled {
                        ServiceIconButton(label: "Install Mailpit", systemImage: "arrow.down.to.line") { Task { await model.installMailpit() } }
                    } else if mailpit.state == .installed || mailpit.state == .stopped || mailpit.state == .unhealthy || mailpit.state == .conflict {
                        ServiceIconButton(label: "Start Mailpit", systemImage: "play.circle", emphasis: .start) { Task { await model.startMailpit() } }
                    }
                    if mailpit.state == .running {
                        ServiceIconButton(label: "Stop Mailpit", systemImage: "stop.circle", emphasis: .stop) { Task { await model.stopMailpit() } }
                        ServiceIconButton(label: "Open Mailpit", systemImage: "arrow.up.right.square") { Task { await model.openMailpit() } }
                    }
                } else if !pending {
                    ServiceIconButton(label: "Refresh Mailpit status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var dnsRow: some View {
        let pending = model.isServiceReadPending("DNS") && dns == nil
        let control = dns.map { ServiceControlPresentation.dns(status: $0, savedOn: model.savedServiceIntents?.contains("dns"), blockedReason: model.startupIssue(for: "dns")) }
        let state = control.map { ServicePresentation($0.title, serviceSymbol($0.title), serviceTint($0.title)) }
        let resolvedState = resolved(state, readLabel: "DNS", present: dns != nil).0
        let busy = model.serviceOperationIs(for: "DNS")
        return ServiceRow(icon: "network", title: "DNS", version: dns.map { "Port \($0.port)" }, state: resolvedState.title, stateSymbol: resolvedState.symbol, stateTint: resolvedState.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let control {
                    if control.action == .enable { ServiceIconButton(label: "Enable DNS", systemImage: "power") { Task { await model.startDNS() } } }
                    if control.action == .retry { ServiceIconButton(label: "Retry DNS Start", systemImage: "arrow.clockwise") { Task { await model.startDNS() } } }
                    if control.action == .stop || control.action == .disable { ServiceIconButton(label: "Stop DNS", systemImage: "stop.circle", emphasis: .stop) { Task { await model.stopDNS() } } }
                    if control.canDisable && control.action == .retry { ServiceIconButton(label: "Disable DNS", systemImage: "power") { Task { await model.stopDNS() } } }
                } else if !pending {
                    ServiceIconButton(label: "Refresh DNS status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var tlsRow: some View {
        let pending = model.isServiceReadPending("TLS") && tls == nil
        let trust = tls.map(TLSTrustControlPresentation.init)
        let state: ServicePresentation?
        if let tls, let trust {
            state = .init(trust.title, tls.trustObserved ? "checkmark.circle.fill" : "exclamationmark.triangle", tls.trustObserved ? .green : .orange)
        } else {
            state = nil
        }
        let resolvedState = resolved(state, readLabel: "TLS", present: tls != nil).0
        let busy = model.serviceOperationIs(for: "Local HTTPS")
        return ServiceRow(icon: "lock.fill", title: "Local HTTPS", version: tls.map { "Port \($0.tlsPort)" }, state: resolvedState.title, stateSymbol: resolvedState.symbol, stateTint: resolvedState.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let trust {
                    if trust.canTrust { ServiceIconButton(label: "Trust Local CA", systemImage: "lock.open.fill") { Task { await model.trustLocalCA() } } }
                    if trust.canRemove { ServiceIconButton(label: "Remove Local CA Trust", systemImage: "lock.slash") { Task { await model.removeLocalCATrust() } } }
                    if trust.canManageTrust { ServiceIconButton(label: "Manage Local CA Trust", systemImage: "info.circle") { showingTrustGuidance = true } }
                } else if !pending {
                    ServiceIconButton(label: "Refresh Local HTTPS status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private var portsRow: some View {
        let pending = model.isServiceReadPending("standard-ports") && ports == nil
        let control = ports.map { ServiceControlPresentation.standardPorts(status: $0, savedOn: model.savedServiceIntents?.contains("standard-ports"), blockedReason: model.startupIssue(for: "standard-ports")) }
        let state = control.map { ServicePresentation($0.title, serviceSymbol($0.title), serviceTint($0.title)) }
        let resolvedState = resolved(state, readLabel: "standard-ports", present: ports != nil).0
        let busy = model.serviceOperationIs(for: "standard ports")
        return ServiceRow(icon: "cable.connector", title: "Standard Ports", version: ports.map { "\($0.httpPort) · \($0.httpsPort)" }, state: resolvedState.title, stateSymbol: resolvedState.symbol, stateTint: resolvedState.tint, pending: pending, busy: busy) {
            HStack(spacing: 3) {
                if let control {
                    if control.action == .enable { ServiceIconButton(label: "Enable Standard Ports", systemImage: "power", emphasis: .start) { Task { await model.installStandardPorts() } } }
                    if control.action == .retry { ServiceIconButton(label: "Retry Standard Ports", systemImage: "arrow.clockwise") { Task { await model.installStandardPorts() } } }
                    if control.action == .disable { ServiceIconButton(label: "Disable Standard Ports", systemImage: "stop.circle", emphasis: .stop) { Task { await model.removeStandardPorts() } } }
                } else if !pending {
                    ServiceIconButton(label: "Refresh Standard Ports status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                }
            }
        }
    }

    private func mysqlState(_ mysql: MySQLStatus) -> ServicePresentation {
        switch mysql.state {
        case .running where mysql.health == "healthy": return .init("Running", "checkmark.circle.fill", .green)
        case .notInstalled: return .init("Not installed", "circle", .secondary)
        case .conflict, .unhealthy: return .init("Needs attention", "exclamationmark.triangle", .orange)
        case .stopped, .installed: return .init("Stopped", "pause.circle", .secondary)
        default: return .init(mysql.state.rawValue.capitalized, "arrow.triangle.2.circlepath", .secondary)
        }
    }

    private func mailpitState(_ mailpit: MailpitStatus) -> ServicePresentation {
        switch mailpit.state {
        case .running where mailpit.health == "healthy": return .init("Running", "checkmark.circle.fill", .green)
        case .notInstalled: return .init("Not installed", "circle", .secondary)
        case .conflict, .unhealthy: return .init("Needs attention", "exclamationmark.triangle", .orange)
        case .stopped, .installed: return .init("Stopped", "pause.circle", .secondary)
        default: return .init(mailpit.state.rawValue.capitalized, "arrow.triangle.2.circlepath", .secondary)
        }
    }

    private func routingState(_ routing: RouterStatus) -> ServicePresentation {
        routing.state == .running && routing.health == .healthy ? .init("Running", "checkmark.circle.fill", .green) : (routing.state == .stopped ? .init("Stopped", "pause.circle", .secondary) : .init("Needs attention", "exclamationmark.triangle", .orange))
    }

    private func serviceSymbol(_ title: String) -> String {
        if title == "Needs attention" || title == "State unavailable" { return "exclamationmark.triangle" }
        if title.localizedCaseInsensitiveContains("start") || title.localizedCaseInsensitiveContains("check") { return "arrow.triangle.2.circlepath" }
        if title.hasPrefix("On") || title == "Enabled" || title == "Ready" || title == "Trusted" { return "checkmark.circle.fill" }
        if title == "Off" || title == "Stopped" || title == "Disabled" { return "pause.circle" }
        return "circle"
    }

    private func serviceTint(_ title: String) -> Color {
        if title == "Needs attention" || title == "State unavailable" { return .orange }
        if title == "Running" || title.hasPrefix("On") || title == "Enabled" || title == "Trusted" { return .green }
        return .secondary
    }

}

private struct LocalCATrustDetailsView: View {
    let fingerprint: String?
    let certificatePath: String?
    let explanation: String
    let manualSteps: String?
    let onBack: () -> Void
    @State private var copiedFingerprint = false

    var body: some View {
        VStack(alignment: .leading, spacing: VaelenUI.spacing10) {
            HStack {
                Button("Back to Services", systemImage: "chevron.backward", action: onBack)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Returns to the Services list and keeps the Vaelen popover open.")
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: VaelenUI.spacing12) {
                    Text("Manage Local CA Trust")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    VStack(alignment: .leading, spacing: VaelenUI.spacing8) {
                        if let fingerprint, !fingerprint.isEmpty {
                            Text("CA certificate SHA-256")
                                .font(.subheadline.weight(.semibold))
                            Text(fingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("CA certificate SHA-256 fingerprint: \(fingerprint)")
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fingerprint, forType: .string)
                                copiedFingerprint = true
                            } label: {
                                Label(copiedFingerprint ? "Copied" : "Copy SHA-256", systemImage: copiedFingerprint ? "checkmark" : "doc.on.doc")
                            }
                            .accessibilityLabel(copiedFingerprint ? "Fingerprint copied" : "Copy CA SHA-256 fingerprint")
                            .accessibilityHint("Copies the full CA certificate fingerprint to the clipboard.")
                            .accessibilityIdentifier("localCATrust.copyFingerprint")
                        } else {
                            VaelenStatusLabel("CA fingerprint unavailable. Do not change any Keychain trust setting.", systemImage: "exclamationmark.triangle", tint: .orange)
                                .font(.caption)
                        }

                        if let certificatePath, !certificatePath.isEmpty {
                            Text("Certificate file: \(certificatePath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(VaelenUI.spacing8)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: VaelenUI.cornerRadius))

                    Text(explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel("Why automatic trust removal is unavailable and safe manual Keychain instructions")
                    if let manualSteps {
                        Text(manualSteps)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, VaelenUI.spacing6)
            }
            .accessibilityLabel("Local CA trust details")
        }
        .padding(VaelenUI.spacing12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}
