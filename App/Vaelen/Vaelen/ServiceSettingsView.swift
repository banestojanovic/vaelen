import SwiftUI
import AppKit
import VaelenCore
import VaelenIPC

private enum ManagedSettingsService: String, CaseIterable, Identifiable, Hashable {
    case mysql = "MySQL", mailpit = "Mailpit", caddy = "Caddy", dns = ".test Domains", https = "Local HTTPS", ports = "Standard Ports"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .mysql: "cylinder.split.1x2.fill"; case .mailpit: "envelope.fill"; case .caddy: "globe"; case .dns: "network"; case .https: "lock.shield"; case .ports: "cable.connector" }
    }
}

struct ServicesSettingsView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selected: ManagedSettingsService = .mysql
    @State private var available = false
    @State private var preserveSelectionOnTabChange = false
    @State private var confirmation: ServiceConfirmation?
    @State private var trustDetails: TLSTrustManagementDetails?
    @State private var showingTrustDetails = false

    private var observation: (CoreStatusResponse, PHPVersionsResult?, RouterStatus?, DNSStatus?, TLSStatus?, StandardPortsStatus?, MySQLStatus?, MailpitStatus?)? {
        if case .running(let status, _, let php, let routing, let dns, let tls, let ports, let mysql, let mailpit) = model.state {
            return (status, php, routing, dns, tls, ports, mysql, mailpit)
        }
        return nil
    }
    private var stateLine: String {
        if case .connecting = model.state { return "Connecting to Vaelen Core…" }
        if case .unavailable = model.state { return model.coreLaunchError ?? "Vaelen Core is unavailable." }
        if case .incompatible(let reason) = model.state { return reason }
        if let error = model.refreshError { return "Showing last confirmed state · \(error)" }
        return "State reported by Vaelen Core"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Services").font(.title2.weight(.semibold)).lineLimit(1)
                Text(available ? "Install supported Vaelen components." : "Installed includes built-in services and capabilities.").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                Spacer()
                Picker("Service view", selection: $available) {
                    Text("Installed (\(countLabel(for: false)))").tag(false)
                    Text("Available (\(countLabel(for: true)))").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    .accessibilityLabel("Service inventory")
                    .help("Installed includes confirmed installed packages and Vaelen built-in services and capabilities.")
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh service state")
                Button("View Logs", systemImage: "doc.text.magnifyingglass") {
                    openWindow(id: "service-logs")
                    DispatchQueue.main.async { SettingsWindowActivation.activateApplication() }
                }
                .controlSize(.small)
                .accessibilityLabel("View managed service logs")
            }.padding(.horizontal, 22).padding(.top, 44).padding(.bottom, 16)
            Divider()
            HStack(spacing: 0) {
                serviceList.frame(width: 270).background(.quaternary.opacity(0.12))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(stateLine).font(.caption).foregroundStyle(model.refreshError == nil ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if available { availableDetail } else { installedDetail }
                        if let operation = model.serviceOperation {
                            Label(operation, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = model.serviceError ?? model.trustError ?? model.startupServiceIssueMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }.frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
                }
            }
        }
        .confirmationDialog(confirmation?.title ?? "Confirm action", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let confirmation {
                Button(confirmation.button, role: confirmation.destructive ? .destructive : nil) { perform(confirmation) }
                    .tint(confirmation.destructive ? .red : .accentColor)
                Button("Cancel", role: .cancel) { self.confirmation = nil }
            }
        } message: { Text(confirmation?.message ?? "") }
        .sheet(isPresented: $showingTrustDetails) {
            if let details = trustDetails { LocalTrustDetailsSheet(details: details) }
        }
        .onAppear { reconcileSelectionAfterInventoryChange() }
        .onChange(of: available) { _, _ in
            if preserveSelectionOnTabChange { preserveSelectionOnTabChange = false; return }
            if let decision = SettingsInventorySelection.manualTabChange(
                currentItemID: selected.id,
                newTab: available ? .available : .installed,
                visibleItemIDs: listServices.map(\.id)
            ), let item = ManagedSettingsService(rawValue: decision.itemID) {
                selected = item
            }
        }
        .onChange(of: inventoryKey) { _, _ in reconcileSelectionAfterInventoryChange() }
    }

    private var serviceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if available {
                    sectionHeading("AVAILABLE PACKAGES")
                    if availablePackages.isEmpty {
                        Text(packageInventoryKnown ? "No additional supported packages are available." : packageInventoryPending ? "Checking package availability…" : "Available package state is unknown. Refresh to retry.")
                            .font(.caption).foregroundStyle(packageInventoryKnown || packageInventoryPending ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    ForEach(availablePackages, id: \.id) { serviceRow($0) }
                    if !packageInventoryKnown && !availablePackages.isEmpty { inventoryNote }
                    if !packageInventoryKnown && availablePackages.isEmpty { inventoryRefreshAction }
                } else {
                    sectionHeading("INSTALLED PACKAGES")
                    if installedPackages.isEmpty {
                        Text(packageInventoryKnown ? "No managed service packages are installed." : packageInventoryPending ? "Checking installed package state…" : "No confirmed package installs; some package states are unknown.")
                            .font(.caption).foregroundStyle(packageInventoryKnown || packageInventoryPending ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    ForEach(installedPackages, id: \.id) { serviceRow($0) }
                    if !packageInventoryKnown && !installedPackages.isEmpty { inventoryNote }
                    if !unknownPackages.isEmpty {
                        sectionHeading("PACKAGE STATE UNKNOWN")
                        Text("Core has not confirmed these packages as installed or available. No install or removal action is offered.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.bottom, 5)
                        ForEach(unknownPackages, id: \.id) { serviceRow($0) }
                    }
                    Divider().padding(.horizontal, 12).padding(.vertical, 8)
                    sectionHeading("BUILT-IN SERVICES & CAPABILITIES")
                    Text("Managed by Vaelen Core; enabling a capability is separate from installing a package.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.bottom, 5)
                    ForEach(builtInCapabilities, id: \.id) { serviceRow($0) }
                }
            }.padding(.bottom, 12)
        }
    }

    private var unknownPackages: [ManagedSettingsService] {
        [.mysql, .mailpit].filter { packageState($0) == .unknown || packageState($0) == .pending }
    }
    private var listServices: [ManagedSettingsService] {
        available ? availablePackages : installedPackages + unknownPackages + builtInCapabilities
    }

    private var installedPackages: [ManagedSettingsService] {
        [.mysql, .mailpit].filter { packageState($0) == .installed }
    }

    private var availablePackages: [ManagedSettingsService] {
        [.mysql, .mailpit].filter { packageState($0) == .available }
    }

    private var builtInCapabilities: [ManagedSettingsService] { [.caddy, .dns, .https, .ports] }
    private var packageCount: SettingsInventoryCount {
        let states = [packageState(.mysql), packageState(.mailpit)]
        return SettingsInventoryCount(
            confirmedInstalledPackages: states.filter { $0 == .installed }.count,
            confirmedAvailablePackages: states.filter { $0 == .available }.count,
            unknownPackages: states.filter { $0 == .unknown }.count,
            pendingPackages: states.filter { $0 == .pending }.count,
            builtInItems: builtInCapabilities.count
        )
    }
    private var packageInventoryKnown: Bool { packageCount.unknownPackages == 0 && packageCount.pendingPackages == 0 }
    private var packageInventoryPending: Bool {
        isConnecting || model.isServiceReadPending("MySQL") || model.isServiceReadPending("Mailpit")
    }
    private var inventoryKey: String {
        "\(packageState(.mysql)):\(packageState(.mailpit)):\(model.isServiceReadPending("MySQL")):\(model.isServiceReadPending("Mailpit"))"
    }
    private func countLabel(for availableTab: Bool) -> String {
        let label = packageCount.label(for: availableTab ? .available : .installed)
        return packageInventoryPending && !label.contains("checking") ? "\(label) · checking" : label
    }
    private func reconcileSelectionAfterInventoryChange() {
        guard selected == .mysql || selected == .mailpit else { return }
        guard !selectedPackageReadPending else { return }
        let state = packageState(selected)
        guard state == .installed || state == .available else { return }
        let decision = SettingsInventorySelection.reconcile(itemID: selected.id, currentTab: available ? .available : .installed, observedState: state)
        guard decision.tab != (available ? .available : .installed) else { return }
        preserveSelectionOnTabChange = true
        available = decision.tab == .available
    }
    private func packageState(_ service: ManagedSettingsService) -> ManagedPackageInventoryState {
        let pending = model.isServiceReadPending(service == .mysql ? "MySQL" : "Mailpit")
        guard let observed = observation else { return .classify(coreState: nil, installedVersion: nil, readPending: pending || isConnecting) }
        if service == .mysql {
            return .classify(coreState: observed.6?.state.rawValue, installedVersion: observed.6?.installedVersion, readPending: pending)
        }
        return .classify(coreState: observed.7?.state.rawValue, installedVersion: observed.7?.installedVersion, readPending: pending)
    }
    private var selectedPackageReadPending: Bool {
        (selected == .mysql || selected == .mailpit) &&
            (isConnecting || model.isServiceReadPending(readKey(selected)))
    }
    private var inventoryNote: some View {
        HStack(spacing: 6) {
            if packageInventoryPending { ProgressView().controlSize(.mini) }
            Image(systemName: packageInventoryPending ? "arrow.triangle.2.circlepath" : "questionmark.circle")
            Text(packageInventoryPending ? "Other package states are still being checked." : "Some package states are unavailable; only confirmed classifications are listed.")
        }.font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 5)
    }
    private var inventoryRefreshAction: some View {
        Group {
            if !packageInventoryPending {
                Button("Refresh Status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .buttonStyle(.borderless).padding(.horizontal, 14).padding(.top, 2)
            }
        }
    }
    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 5)
    }
    private func serviceRow(_ service: ManagedSettingsService) -> some View {
        let summary = rowSummary(service)
        return Button { selected = service } label: {
            HStack(spacing: 10) {
                Image(systemName: service.symbol).foregroundStyle(selected == service ? Color.accentColor : Color.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.rawValue).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                SettingsStateDot(title: "", tone: rowTone(summary))
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(selected == service ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 7)
            .accessibilityAddTraits(selected == service ? .isSelected : [])
    }

    private func rowSummary(_ service: ManagedSettingsService) -> String {
        if service == .mysql || service == .mailpit {
            switch packageState(service) {
            case .pending: return "Checking package state…"
            case .unknown: return "Package state unknown · no package action"
            case .installed, .available: break
            }
        }
        if model.isServiceReadPending(readKey(service)) || isConnecting { return "Checking status…" }
        guard let o = observation else {
            if model.isServiceReadPending(readKey(service)) || isConnecting { return "Checking status…" }
            return "State unavailable"
        }
        switch service {
        case .mysql: guard let s = o.6 else { return readPending("MySQL") }; return mysqlSummary(s)
        case .mailpit: guard let s = o.7 else { return readPending("Mailpit") }; return "\(s.installedVersion ?? "Mailpit") · \(s.state.rawValue)"
        case .caddy: guard let s = o.2 else { return readPending("routing") }; return "\(s.providerVersion ?? "Caddy") · \(s.state == .running && s.health == .healthy ? "Running" : s.state == .stopped ? "Stopped" : "Needs attention")"
        case .dns: guard let s = o.3 else { return readPending("DNS") }; return "Capability · \(dnsPresentation(s).title)"
        case .https: guard let s = o.4 else { return readPending("TLS") }; return "Capability · \(TLSTrustControlPresentation(s).title)"
        case .ports: guard let s = o.5 else { return readPending("standard-ports") }; return "Capability · \(portsPresentation(s).title)"
        }
    }
    private var isConnecting: Bool { ifConnecting(model.state) }
    private func ifConnecting(_ state: AppModel.State) -> Bool { if case .connecting = state { true } else { false } }
    private func readKey(_ service: ManagedSettingsService) -> String {
        switch service { case .mysql: "MySQL"; case .mailpit: "Mailpit"; case .caddy: "routing"; case .dns: "DNS"; case .https: "TLS"; case .ports: "standard-ports" }
    }
    private func readPending(_ key: String) -> String { model.isServiceReadPending(key) || isConnecting ? "Checking status…" : "State unavailable" }
    private func mysqlSummary(_ s: MySQLStatus) -> String {
        switch s.state { case .running where s.health == "healthy": return "\(s.selectedVersion ?? s.installedVersion ?? "MySQL") · Running"; case .running: return "Needs attention · \(s.health)"; case .notInstalled: return "Not installed"; case .stopped, .installed: return "\(s.selectedVersion ?? s.installedVersion ?? "MySQL") · Stopped"; default: return "Needs attention · \(s.health)" }
    }

    @ViewBuilder private var installedDetail: some View {
        if selectedPackageReadPending || ((selected == .mysql || selected == .mailpit) && packageState(selected) == .pending) {
            inventoryDetail(title: selected.rawValue, pending: true)
        } else if (selected == .mysql || selected == .mailpit), packageState(selected) == .unknown {
            inventoryDetail(title: selected.rawValue, pending: false)
        } else if let o = observation, !model.isServiceReadPending(readKey(selected)), !isConnecting {
            switch selected {
            case .mysql: if let s = o.6 { mysqlDetail(s) } else { unavailableDetail("MySQL") }
            case .mailpit: if let s = o.7 { mailpitDetail(s) } else { unavailableDetail("Mailpit") }
            case .caddy: if let s = o.2 { caddyDetail(s) } else { unavailableDetail("Caddy") }
            case .dns: if let s = o.3 { dnsDetail(s) } else { unavailableDetail("DNS") }
            case .https: if let s = o.4 { tlsDetail(s) } else { unavailableDetail("Local HTTPS") }
            case .ports: if let s = o.5 { portsDetail(s) } else { unavailableDetail("Standard Ports") }
            }
        } else {
            let pending = isConnecting || model.isServiceReadPending(readKey(selected))
            VStack(alignment: .leading, spacing: 10) {
                Label(pending ? "Checking \(selected.rawValue) status…" : "\(selected.rawValue) status unavailable", systemImage: pending ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                    .font(.headline).foregroundStyle(pending ? Color.secondary : Color.orange)
                if pending { ProgressView().controlSize(.small) }
                Text(pending ? "Waiting for Core to confirm observed package and service state." : "Core did not provide an authoritative report. No healthy or stopped state is inferred.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !pending { Button("Refresh Status", systemImage: "arrow.clockwise") { Task { await model.refresh() } } }
            }
        }
    }

    @ViewBuilder private var availableDetail: some View {
        if selectedPackageReadPending {
            inventoryDetail(title: selected.rawValue, pending: true)
        } else if !listServices.contains(selected) {
            if packageInventoryPending {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking Core package observations…").font(.subheadline).foregroundStyle(.secondary)
                }
            } else if !packageInventoryKnown {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Package state partially unavailable", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                    Text("Unknown packages are listed separately under Installed. Core must confirm a package as not installed before it is offered here.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Refresh Status") { Task { await model.refresh() } }
                }
            } else if availablePackages.isEmpty {
                Text("No additional supported packages are available. Built-in capabilities are managed under Installed.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Choose a supported component to install.").font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            serviceHeader(selected, state: "Available")
            Text(selected == .mysql ? "Install a managed MySQL server for local project databases." : "Capture local development email without sending it externally.")
                .foregroundStyle(.secondary)
            SettingsInsetCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install details").font(.headline)
                    detailRows(selected == .mysql
                        ? [("Package", observation?.6?.selectedVersion ?? observation?.6?.installedVersion ?? "Verified MySQL release"), ("Configuration", "Managed by Vaelen Core"), ("Data", "Created only by explicit initialization; preserved across updates")]
                        : [("Package", observation?.7?.installedVersion ?? "Verified Mailpit release"), ("License", "MIT"), ("Data", "Local message database; retained across restarts")])
                }
            }
            Button("Install \(selected.rawValue)", systemImage: "arrow.down.circle.fill") {
                if selected == .mysql { Task { await model.installMySQL() } } else { Task { await model.installMailpit() } }
            }.buttonStyle(.borderedProminent).tint(.accentColor).disabled(model.serviceOperation != nil)
            Text("Only the package is installed. Starting the service is a separate action; existing project data is preserved.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func inventoryDetail(title: String, pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(pending ? "Checking \(title) package state…" : "\(title) package state unknown", systemImage: pending ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                .font(.headline).foregroundStyle(pending ? Color.secondary : Color.orange)
            Text(pending ? "Showing the selected item while Core refreshes its package observation. No install or removal action is offered until the result is confirmed." : "The service observation does not prove that a package is installed or available. No package action is offered.")
                .font(.subheadline).foregroundStyle(.secondary)
            if pending { ProgressView().controlSize(.small) }
            else { Button("Refresh Status", systemImage: "arrow.clockwise") { Task { await model.refresh() } } }
        }
    }

    private func mysqlDetail(_ s: MySQLStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            serviceHeader(.mysql, state: mysqlSummary(s))
            HStack(spacing: 8) {
                if s.state == .notInstalled {
                    Button("Install MySQL", systemImage: "arrow.down.circle.fill") { Task { await model.installMySQL() } }.buttonStyle(.borderedProminent)
                } else if s.state == .running {
                    Button("Stop MySQL", systemImage: "stop.fill", role: .destructive) { confirmation = .stopMySQL }.buttonStyle(.bordered).settingsDestructiveTint()
                } else if s.state == .stopped || s.state == .installed || s.state == .unhealthy {
                    if s.health == "not-initialized" {
                        Button("Initialize & Start…", systemImage: "play.fill") { confirmation = .initializeMySQL }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Start MySQL", systemImage: "play.fill") { Task { await model.startMySQL() } }.buttonStyle(.borderedProminent)
                    }
                }
                if s.state == .running {
                    let action = MySQLDatabaseViewerAction.tablePlus(mysql: s, tablePlusInstalled: model.isTablePlusInstalled)
                    Button("Open in TablePlus", systemImage: "cylinder.split.1x2") { model.openMySQLInTablePlus(s) }.buttonStyle(.bordered).disabled(!action.isEnabled).help(action.reason)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.buttonStyle(.borderless)
            }
            if let version = s.installedVersion, [.running, .stopped, .installed].contains(s.state) {
                Button("Remove MySQL Package…", systemImage: "trash", role: .destructive) { confirmation = .removeMySQL(version) }
                    .buttonStyle(.bordered).settingsDestructiveTint()
                    .disabled(model.serviceOperation != nil)
            }
            if s.state == .conflict || s.state == .unhealthy || s.health != "healthy" && s.state == .running {
                attention("MySQL is \(s.health). Check its port and process state, then retry Start when safe.")
            }
            SettingsInsetCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connection").font(.headline)
                    detailRows([("Host", "127.0.0.1"), ("Port", String(s.port)), ("Socket", s.socket), ("Observed", "\(s.state.rawValue) · \(s.health)")])
                    Text("For a project-specific database, use the project’s Database action.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                locationCard("Data directory", path: s.datadir, symbol: "externaldrive") { model.revealMySQLDataFiles(s) }
                locationCard("Package binaries", path: s.executablePath, symbol: "shippingbox") { model.revealMySQLBinaries(s) }
            }
            detailRows([("Installed package", s.installedVersion ?? "Not installed"), ("Selected version", s.selectedVersion ?? "Unavailable"), ("Data policy", "Preserved across package updates")])
        }
    }

    private func mailpitDetail(_ s: MailpitStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            serviceHeader(.mailpit, state: "\(s.state.rawValue) · \(s.health)")
            HStack {
                if s.state == .notInstalled { Button("Install Mailpit", systemImage: "arrow.down.circle.fill") { Task { await model.installMailpit() } }.buttonStyle(.borderedProminent) }
                else if s.state == .running {
                    Button("Stop Mailpit", systemImage: "stop.fill", role: .destructive) { confirmation = .stopMailpit }.buttonStyle(.bordered).settingsDestructiveTint()
                    Button("Open Mailpit", systemImage: "arrow.up.right.square") { Task { await model.openMailpit() } }.buttonStyle(.borderedProminent)
                } else { Button("Start Mailpit", systemImage: "play.fill") { Task { await model.startMailpit() } }.buttonStyle(.borderedProminent) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.buttonStyle(.borderless)
            }
            if let version = s.installedVersion, [.running, .stopped, .installed].contains(s.state) {
                Button("Remove Mailpit Package…", systemImage: "trash", role: .destructive) { confirmation = .removeMailpit(version) }
                    .buttonStyle(.bordered).settingsDestructiveTint()
                    .disabled(model.serviceOperation != nil)
            }
            if s.state == .conflict || s.state == .unhealthy { attention("Mailpit health is \(s.health). Retry after reviewing the service status.") }
            SettingsInsetCard {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Package & local inbox").font(.headline)
                    detailRows([("Installed package", s.installedVersion ?? "Not installed"), ("Inbox URL", s.uiEndpoint), ("SMTP port", String(s.smtpPort)), ("Observed", "\(s.state.rawValue) · \(s.health)")])
                }
            }
        }
    }

    private func caddyDetail(_ s: RouterStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            serviceHeader(.caddy, state: "\(s.state) · \(s.health)")
            HStack {
                if s.state == .running { Button("Stop Caddy", systemImage: "stop.fill", role: .destructive) { confirmation = .stopCaddy }.buttonStyle(.bordered).settingsDestructiveTint() }
                else { Button("Start Caddy", systemImage: "play.fill") { Task { await model.startRouting() } }.buttonStyle(.borderedProminent) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.buttonStyle(.borderless)
            }
            if s.health != .healthy { attention("Caddy health is \(s.health). Routing actions are available through Core; external services are not adopted.") }
            detailRows([("Observed", "\(s.state) · \(s.health)"), ("Version", s.providerVersion ?? "Unavailable"), ("Routes", "\(s.routeCount) configured")])
        }
    }

    private func dnsDetail(_ s: DNSStatus) -> some View {
        let p = dnsPresentation(s)
        return VStack(alignment: .leading, spacing: 16) {
            serviceHeader(.dns, state: p.title)
            if let detail = p.detail { attention(detail) }
            HStack {
                switch p.action {
                case .enable: Button("Enable DNS…", systemImage: "power") { confirmation = .enableDNS }.buttonStyle(.borderedProminent)
                case .retry: Button("Retry DNS…", systemImage: "arrow.clockwise") { confirmation = .retryDNS }.buttonStyle(.borderedProminent)
                case .stop, .disable: Button("Stop DNS", systemImage: "stop.fill", role: .destructive) { confirmation = .stopDNS }.buttonStyle(.bordered).settingsDestructiveTint()
                case nil: EmptyView()
                }
                if p.canDisable && p.action == .retry { Button("Disable DNS…") { confirmation = .disableDNS }.buttonStyle(.borderless) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.buttonStyle(.borderless)
            }
            detailRows([("Observed", "\(s.state.rawValue) · \(s.responderState.rawValue) · \(s.health)"), ("Ownership", s.ownership.rawValue), ("Port", "\(s.port)"), ("Resolver", "/etc/resolver/test")])
        }
    }

    private func tlsDetail(_ s: TLSStatus) -> some View {
        let trust = TLSTrustControlPresentation(s)
        return VStack(alignment: .leading, spacing: 16) {
            serviceHeader(.https, state: trust.title)
            Text(s.trustObserved ? "Trust is observed in the user Keychain." : "Local HTTPS trust is not confirmed. Trust is a separate explicit Keychain operation.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                if trust.canTrust { Button("Trust Local CA…", systemImage: "lock.shield") { confirmation = .trustCA }.buttonStyle(.borderedProminent) }
                if trust.canRemove { Button("Remove Vaelen CA Trust…", systemImage: "lock.slash", role: .destructive) { confirmation = .removeTrust }.buttonStyle(.bordered).settingsDestructiveTint() }
                if trust.canManageTrust { Button("Manage Trust Details…", systemImage: "info.circle") { trustDetails = trust.manageTrustDetails(caFingerprint: s.caFingerprint, certificatePath: s.caCertificatePath); showingTrustDetails = trustDetails != nil }.buttonStyle(.bordered) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.buttonStyle(.borderless)
            }
            if let detail = s.detail { attention(detail) }
            detailRows([("Observed trust", s.trustObserved ? "Trusted" : "Not trusted"), ("Provenance", s.trustProvenance.rawValue), ("CA SHA-256", s.caFingerprint ?? "Unavailable"), ("Certificate", s.caCertificatePath ?? "Unavailable"), ("TLS port", "\(s.tlsPort)")])
        }
    }

    private func portsDetail(_ s: StandardPortsStatus) -> some View {
        let p = portsPresentation(s)
        return VStack(alignment: .leading, spacing: 16) {
            serviceHeader(.ports, state: p.title)
            if let detail = p.detail { attention(detail) }
            HStack {
                switch p.action {
                case .enable: Button("Enable Standard Ports…", systemImage: "power") { confirmation = .enablePorts }.buttonStyle(.borderedProminent)
                case .retry: Button("Retry Port Setup…", systemImage: "arrow.clockwise") { confirmation = .retryPorts }.buttonStyle(.borderedProminent)
                case .disable: Button("Disable Standard Ports…", systemImage: "stop.fill", role: .destructive) { confirmation = .disablePorts }.buttonStyle(.bordered).settingsDestructiveTint()
                case .stop: EmptyView()
                case nil: EmptyView()
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.buttonStyle(.borderless)
            }
            detailRows([("HTTP", "127.0.0.1:\(s.httpPort)"), ("HTTPS", "127.0.0.1:\(s.httpsPort)"), ("Observed", "\(s.state.rawValue) · \(s.ownership?.rawValue ?? "unknown")"), ("Details", s.detail ?? s.conflict ?? "No diagnostic reported")])
        }
    }

    private func dnsPresentation(_ s: DNSStatus) -> ServiceControlPresentation {
        ServiceControlPresentation.dns(status: s, savedOn: model.savedServiceIntents?.contains("dns"), blockedReason: model.startupIssue(for: "dns"))
    }
    private func portsPresentation(_ s: StandardPortsStatus) -> ServiceControlPresentation {
        ServiceControlPresentation.standardPorts(status: s, savedOn: model.savedServiceIntents?.contains("standard-ports"), blockedReason: model.startupIssue(for: "standard-ports"))
    }
    private func serviceHeader(_ service: ManagedSettingsService, state: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: service.symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) { Text(service.rawValue).font(.title2.weight(.semibold)); Text(serviceSubtitle(service, state: state)).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
            if model.refreshError != nil {
                SettingsStateBadge(title: "Last confirmed · \(serviceStateLabel(state))", tone: .neutral)
            } else {
                SettingsStateBadge(title: serviceStateLabel(state), tone: serviceTone(state))
            }
        }
    }
    private func serviceSubtitle(_ service: ManagedSettingsService, state: String) -> String {
        if service == .mysql, let version = state.split(separator: "·").first?.trimmingCharacters(in: .whitespaces), !version.isEmpty { return "MySQL \(version) · Managed by Vaelen" }
        return switch service {
        case .mysql, .mailpit: "Managed by Vaelen Core"
        case .caddy: "Local project site routing · Caddy"
        case .dns: "Owned responder · local .test domains"
        case .https: "Vaelen local certificate authority"
        case .ports: "Public local HTTP/HTTPS endpoints"
        }
    }
    private func serviceStateLabel(_ state: String) -> String {
        let lower = state.lowercased()
        if lower.contains("unavailable") { return "Unavailable" }
        if lower.contains("conflict") || lower.contains("unhealthy") || lower.contains("attention") || lower.contains("error") { return "Needs attention" }
        if lower.contains("checking") { return "Checking" }
        if lower.contains("running") { return "Running" }
        if lower.contains("stopped") { return "Stopped" }
        if lower.contains("trusted") { return "Trusted" }
        if lower.contains("enabled") || lower == "on" { return "Enabled" }
        return state
    }
    private func serviceTone(_ value: String) -> SettingsStateBadge.Tone {
        let lower = value.lowercased()
        if lower.contains("unavailable") || lower.contains("attention") || lower.contains("conflict") || lower.contains("error") || lower.contains("unhealthy") || lower.contains("not trusted") { return .attention }
        if lower.contains("checking") { return .pending }
        if lower.contains("running") || lower.contains("healthy") || lower.contains("trusted") || lower == "on" || lower == "enabled" { return .healthy }
        return .neutral
    }
    private func rowTone(_ value: String) -> SettingsStateBadge.Tone { serviceTone(value) }
    private func locationCard(_ title: String, path: String, symbol: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
            Text(path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            Button("Reveal", systemImage: "folder") { action() }.buttonStyle(.borderless).disabled(!FileManager.default.fileExists(atPath: path))
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
    }
    private func detailRows(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                    Text(row.1).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption).padding(.vertical, 8)
                if index < rows.count - 1 { Divider() }
            }
        }.padding(.vertical, 3).overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
    }
    private func attention(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }
    private func unavailableDetail(_ name: String) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            let pending = isConnecting || model.isServiceReadPending(name == "Caddy" ? "routing" : name)
            Label(pending ? "Checking \(name) status…" : "\(name) status unavailable", systemImage: pending ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle").font(.headline)
            if pending { ProgressView().controlSize(.small) }
            Text(pending ? "Core is checking this capability. The previous observed value is not presented as current." : "Core did not provide an authoritative status. No healthy or stopped state is inferred.").font(.subheadline).foregroundStyle(.secondary)
            if !pending { Button("Retry Status", systemImage: "arrow.clockwise") { Task { await model.refresh() } } }
        }
    }
    private func perform(_ action: ServiceConfirmation) {
        confirmation = nil
        switch action.id {
        case "mysql-stop": Task { await model.stopMySQL() }
        case "mysql-remove": if let version = action.version { Task { await model.removeMySQL(version) } }
        case "mysql-initialize": Task { await model.startMySQL() }
        case "mailpit-stop": Task { await model.stopMailpit() }
        case "mailpit-remove": if let version = action.version { Task { await model.removeMailpit(version) } }
        case "caddy-stop": Task { await model.stopRouting() }
        case "dns-stop", "dns-disable": Task { await model.stopDNS() }
        case "ports-disable": Task { await model.removeStandardPorts() }
        case "tls-trust": Task { await model.trustLocalCA() }
        case "tls-remove": Task { await model.removeLocalCATrust() }
        case "dns-enable", "dns-retry": Task { await model.startDNS() }
        case "ports-enable", "ports-retry": Task { await model.installStandardPorts() }
        default: break
        }
    }
}

private struct ServiceConfirmation: Identifiable {
    let id: String
    let title: String
    let button: String
    let message: String
    var version: String?
    var destructive = false
    static func removeMySQL(_ version: String) -> Self { Self(id: "mysql-remove", title: "Remove MySQL package?", button: "Remove Package", message: "Vaelen will disable MySQL’s saved start intent, stop it safely if running, then remove only the verified Vaelen MySQL package. Your databases, configuration, and credentials are preserved.", version: version, destructive: true) }
    static func removeMailpit(_ version: String) -> Self { Self(id: "mailpit-remove", title: "Remove Mailpit package?", button: "Remove Package", message: "Vaelen will disable Mailpit’s saved start intent, stop it safely if running, then remove only the verified Vaelen Mailpit package. Your local inbox database and logs are preserved.", version: version, destructive: true) }
    static let stopMySQL = Self(id: "mysql-stop", title: "Stop MySQL?", button: "Stop MySQL", message: "Projects depending on MySQL may lose their local database connection.", destructive: true)
    static let initializeMySQL = Self(id: "mysql-initialize", title: "Initialize MySQL data directory?", button: "Initialize & Start", message: "Core confirmed MySQL is not initialized. This creates Vaelen-managed database files at the reported data path; project files are not changed.")
    static let stopMailpit = Self(id: "mailpit-stop", title: "Stop Mailpit?", button: "Stop Mailpit", message: "The local inbox will be unavailable until Mailpit is started again.", destructive: true)
    static let stopCaddy = Self(id: "caddy-stop", title: "Stop Caddy?", button: "Stop Caddy", message: "Local project sites will not be routed until Caddy is started again.", destructive: true)
    static let stopDNS = Self(id: "dns-stop", title: "Stop Vaelen DNS?", button: "Stop DNS", message: ".test hostnames may stop resolving. Externally owned resolvers will not be changed.", destructive: true)
    static let disableDNS = Self(id: "dns-disable", title: "Disable Vaelen DNS?", button: "Disable DNS", message: "Only Vaelen-owned resolver configuration is removed; external DNS is preserved.", destructive: true)
    static let enableDNS = Self(id: "dns-enable", title: "Enable Vaelen DNS?", button: "Continue…", message: "Vaelen installs its .test resolver only if Core can safely preserve existing DNS. macOS may ask you to approve its background helper.")
    static let retryDNS = Self(id: "dns-retry", title: "Retry Vaelen DNS setup?", button: "Retry…", message: "Core re-checks ownership before retrying. External resolver configuration remains untouched; macOS may request helper approval.")
    static let disablePorts = Self(id: "ports-disable", title: "Disable Standard Ports?", button: "Disable Ports", message: "Local sites on ports 80 and 443 may be unavailable. Only Vaelen-owned PF configuration is removed.", destructive: true)
    static let enablePorts = Self(id: "ports-enable", title: "Enable Standard Ports?", button: "Continue…", message: "Vaelen installs fixed forwarding only after helper-confirmed ownership. macOS may request background-helper approval.")
    static let retryPorts = Self(id: "ports-retry", title: "Retry Standard Ports setup?", button: "Retry…", message: "The helper verifies current ownership before retrying. External PF configuration is not adopted or replaced.")
    static let trustCA = Self(id: "tls-trust", title: "Trust Vaelen Local CA?", button: "Continue to macOS…", message: "macOS will request approval to trust Vaelen’s local certificate authority in your user Keychain.")
    static let removeTrust = Self(id: "tls-remove", title: "Remove Vaelen Local CA trust?", button: "Remove Trust…", message: "This asks Core to remove trust only when Vaelen has confirmed ownership of the trust setting.", destructive: true)
    static let manageTrust = Self(id: "tls-manage", title: "Manage Local CA Trust", button: "OK", message: "Automatic trust removal is unavailable because Vaelen cannot prove that it created this Keychain setting.")
}

struct NetworkSecuritySettingsView: View {
    let model: AppModel
    @State private var action: NetworkAction?
    @State private var showingTrustDetails = false
    private var status: (DNSStatus?, TLSStatus?, StandardPortsStatus?) {
        if case .running(_, _, _, _, let dns, let tls, let ports, _, _) = model.state {
            return (model.isServiceReadPending("DNS") ? nil : dns,
                    model.isServiceReadPending("TLS") ? nil : tls,
                    model.isServiceReadPending("standard-ports") ? nil : ports)
        }
        return (nil, nil, nil)
    }
    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader("Network & Security", subtitle: "Local domains, web ports, and HTTPS trust on this Mac.") {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh network status")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.refreshError { Label("Showing last confirmed state · \(error)", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.orange) }
                    capability(title: ".test Domain Resolver", symbol: "network", readKey: "DNS", description: "Resolve local .test hostnames through Vaelen-owned DNS.", status: status.0.map(dnsPresentation) ?? readState("DNS"), detail: status.0.map { "\($0.conflict ?? $0.health) · ownership \($0.ownership.rawValue) · responder \($0.responderState.rawValue) · 127.0.0.1:\($0.port)" } ?? readDetail("DNS")) {
                    if let dns = status.0 {
                        let control = ServiceControlPresentation.dns(status: dns, savedOn: model.savedServiceIntents?.contains("dns"), blockedReason: model.startupIssue(for: "dns"))
                        switch control.action {
                        case .enable: Button("Enable DNS…") { action = .dnsEnable }.buttonStyle(.borderedProminent)
                        case .retry: Button("Retry DNS…") { action = .dnsRetry }.buttonStyle(.borderedProminent)
                        case .stop, .disable: Button("Stop DNS…", role: .destructive) { action = .dnsStop }.buttonStyle(.bordered).settingsDestructiveTint()
                        case nil: EmptyView()
                        }
                        if control.canDisable && control.action == .retry { Button("Disable DNS…", role: .destructive) { action = .dnsDisable }.buttonStyle(.borderless).settingsDestructiveTint() }
                    } else if !model.isServiceReadPending("DNS") { Button("Refresh DNS Status") { Task { await model.refresh() } } }
                }
                    capability(title: "Standard Ports", symbol: "cable.connector", readKey: "standard-ports", description: "Route local HTTP and HTTPS through ports 80 and 443.", status: status.2.map(portsPresentation) ?? readState("standard-ports"), detail: status.2.map { "HTTP :\($0.httpPort) · HTTPS :\($0.httpsPort) · ownership \($0.ownership?.rawValue ?? "unknown") · \($0.detail ?? $0.conflict ?? "No conflict reported.")" } ?? readDetail("standard-ports")) {
                    if let ports = status.2 {
                        let control = ServiceControlPresentation.standardPorts(status: ports, savedOn: model.savedServiceIntents?.contains("standard-ports"), blockedReason: model.startupIssue(for: "standard-ports"))
                        switch control.action {
                        case .enable: Button("Enable Standard Ports…") { action = .portsEnable }.buttonStyle(.borderedProminent)
                        case .retry: Button("Retry Port Setup…") { action = .portsRetry }.buttonStyle(.borderedProminent)
                        case .disable: Button("Disable Standard Ports…", role: .destructive) { action = .portsDisable }.buttonStyle(.bordered).settingsDestructiveTint()
                        case .stop: EmptyView()
                        case nil: EmptyView()
                        }
                    } else if !model.isServiceReadPending("standard-ports") { Button("Refresh Port Status") { Task { await model.refresh() } } }
                }
                    capability(title: "Local HTTPS", symbol: "lock.shield", readKey: "TLS", description: "Use Vaelen’s local certificate authority for HTTPS on .test sites.", status: status.1.map { TLSTrustControlPresentation($0).title } ?? readState("TLS"), detail: status.1.map { "Trust \($0.trustObserved ? "observed" : "not observed") · provenance \($0.trustProvenance.rawValue) · SHA-256 \($0.caFingerprint ?? "unavailable") · certificate \($0.caCertificatePath ?? "path unavailable") · \($0.detail ?? "Local .test certificate authority")" } ?? readDetail("TLS")) {
                    if let tls = status.1 {
                        let control = TLSTrustControlPresentation(tls)
                        if control.canTrust { Button("Trust Local CA…") { action = .trust }.buttonStyle(.borderedProminent) }
                        if control.canRemove { Button("Remove Vaelen Trust…", role: .destructive) { action = .removeTrust }.buttonStyle(.bordered).settingsDestructiveTint() }
                        if control.canManageTrust { Button("Manage Trust Details…") { showingTrustDetails = true }.buttonStyle(.bordered) }
                    } else if !model.isServiceReadPending("TLS") { Button("Refresh HTTPS Status") { Task { await model.refresh() } } }
                }
                    if let operation = model.serviceOperation { Label(operation, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
                    if let error = model.serviceError ?? model.trustError { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(12).background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)) }
                }.frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading).padding(22)
            }
        }
        .confirmationDialog(action?.title ?? "Confirm", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
            if let action { Button(action.button, role: action.destructive ? .destructive : nil) { perform(action) }.tint(action.destructive ? .red : .accentColor); Button("Cancel", role: .cancel) { self.action = nil } }
        } message: { Text(action?.message ?? "") }
        .sheet(isPresented: $showingTrustDetails) {
            if let tls = status.1, let details = TLSTrustControlPresentation(tls).manageTrustDetails(caFingerprint: tls.caFingerprint, certificatePath: tls.caCertificatePath) {
                LocalTrustDetailsSheet(details: details)
            }
        }
    }

    private func capability<Action: View>(title: String, symbol: String, readKey: String, description: String, status: String, detail: String?, @ViewBuilder actions: () -> Action) -> some View {
        let checking = status == "Checking" || coreConnecting || model.isServiceReadPending(readKey)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 28, height: 28).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                Text(title).font(.headline)
                Spacer()
                if checking { ProgressView().controlSize(.small); Text("Checking").font(.caption).foregroundStyle(.secondary) }
                else if model.refreshError != nil { SettingsStateBadge(title: "Last confirmed · \(status)", tone: .neutral) }
                else { SettingsStateBadge(title: status, tone: capabilityTone(status)) }
            }
            Text(description).font(.subheadline).foregroundStyle(.secondary)
            if checking, let detail { Text("Current read is pending. Last report: \(detail)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            else if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 9) { if !checking { actions(); Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }.buttonStyle(.borderless) } }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor).opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
    }
    private func readState(_ key: String) -> String {
        if case .connecting = model.state { return "Checking" }
        return model.isServiceReadPending(key) ? "Checking" : "Unavailable"
    }
    private var coreConnecting: Bool { if case .connecting = model.state { true } else { false } }
    private func readDetail(_ key: String) -> String {
        if model.isServiceReadPending(key) || coreConnecting { return "Core is checking this capability. No state is inferred while the read is pending." }
        return "Core did not provide an authoritative report. No healthy or stopped state is inferred."
    }
    private func capabilityTone(_ value: String) -> SettingsStateBadge.Tone {
        if value.localizedCaseInsensitiveContains("unavailable") || value.localizedCaseInsensitiveContains("conflict") || value.localizedCaseInsensitiveContains("attention") || value.localizedCaseInsensitiveContains("unhealthy") || value.localizedCaseInsensitiveContains("not trusted") || value.localizedCaseInsensitiveContains("failed") { return .attention }
        if value == "Checking" { return .pending }
        if value.localizedCaseInsensitiveContains("running") || value.localizedCaseInsensitiveContains("trusted") || value.localizedCaseInsensitiveContains("enabled") || value.localizedCaseInsensitiveContains("healthy") || value == "On" { return .healthy }
        return .neutral
    }
    private func dnsPresentation(_ s: DNSStatus) -> String { ServiceControlPresentation.dns(status: s, savedOn: model.savedServiceIntents?.contains("dns"), blockedReason: model.startupIssue(for: "dns")).title }
    private func portsPresentation(_ s: StandardPortsStatus) -> String { ServiceControlPresentation.standardPorts(status: s, savedOn: model.savedServiceIntents?.contains("standard-ports"), blockedReason: model.startupIssue(for: "standard-ports")).title }
    private func perform(_ action: NetworkAction) {
        self.action = nil
        switch action.id {
        case "dns-stop", "dns-disable": Task { await model.stopDNS() }
        case "dns-enable", "dns-retry": Task { await model.startDNS() }
        case "ports-disable": Task { await model.removeStandardPorts() }
        case "ports-enable", "ports-retry": Task { await model.installStandardPorts() }
        case "trust": Task { await model.trustLocalCA() }
        case "remove-trust": Task { await model.removeLocalCATrust() }
        default: break
        }
    }
}

private struct NetworkAction {
    let id: String; let title: String; let button: String; let message: String; var destructive = false
    static let dnsStop = Self(id: "dns-stop", title: "Stop Vaelen DNS?", button: "Stop DNS", message: ".test hostnames may stop resolving. External DNS configuration is preserved.", destructive: true)
    static let dnsDisable = Self(id: "dns-disable", title: "Disable Vaelen DNS?", button: "Disable DNS", message: "Only Vaelen-owned resolver configuration is removed. External resolver configuration is preserved.", destructive: true)
    static let dnsEnable = Self(id: "dns-enable", title: "Enable Vaelen DNS?", button: "Continue…", message: "Vaelen installs its .test resolver only if Core can safely preserve existing DNS. macOS may ask you to approve its background helper.")
    static let dnsRetry = Self(id: "dns-retry", title: "Retry Vaelen DNS setup?", button: "Retry…", message: "Core re-checks ownership before retrying. External resolver configuration remains untouched; macOS may request helper approval.")
    static let portsDisable = Self(id: "ports-disable", title: "Disable Standard Ports?", button: "Disable Ports", message: "Local sites on ports 80/443 may be unavailable. Only Vaelen-owned PF state can be removed.", destructive: true)
    static let portsEnable = Self(id: "ports-enable", title: "Enable Standard Ports?", button: "Continue…", message: "Vaelen installs fixed forwarding only after helper-confirmed ownership. macOS may request background-helper approval.")
    static let portsRetry = Self(id: "ports-retry", title: "Retry Standard Ports setup?", button: "Retry…", message: "The helper verifies current ownership before retrying. External PF configuration is not adopted or replaced.")
    static let trust = Self(id: "trust", title: "Trust Vaelen Local CA?", button: "Continue to macOS…", message: "macOS will request approval to trust Vaelen’s local CA in your user Keychain.")
    static let removeTrust = Self(id: "remove-trust", title: "Remove Vaelen CA trust?", button: "Remove Trust", message: "Core removes trust only when Vaelen has confirmed provenance.", destructive: true)
    static let manageTrust = Self(id: "manage-trust", title: "Manage Trust", button: "OK", message: "Vaelen did not create this trust override. Verify the full SHA-256 in Keychain Access; do not delete certificates or change other trust settings.")
}

private struct LocalTrustDetailsSheet: View {
    let details: TLSTrustManagementDetails
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage Local CA Trust").font(.title2.weight(.semibold))
            if let fingerprint = details.fingerprint {
                Text("CA certificate SHA-256").font(.subheadline.weight(.semibold))
                Text(fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button(copied ? "Copied" : "Copy SHA-256", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(fingerprint, forType: .string); copied = true
                }
            } else {
                Label("Fingerprint unavailable. Do not change any Keychain trust setting.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let path = details.certificatePath { Text("Certificate file: \(path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text(details.explanation).fixedSize(horizontal: false, vertical: true)
            if let manual = details.manualSteps { Text(manual).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(minWidth: 480, idealWidth: 540, minHeight: 300, idealHeight: 450)
    }
}
