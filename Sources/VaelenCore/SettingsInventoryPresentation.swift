import Foundation

/// A presentation-only summary of Core observations. It never infers package
/// state from a process, desired setting, path, or health string.
public enum ManagedPackageInventoryState: Equatable, Sendable {
    case installed
    case available
    case unknown
    case pending

    public static func classify(coreState: String?, installedVersion: String?, readPending: Bool) -> Self {
        guard !readPending else { return .pending }
        guard let coreState else { return readPending ? .pending : .unknown }
        let hasInstalledVersion = installedVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if coreState == "notInstalled" {
            return hasInstalledVersion ? .unknown : .available
        }
        guard hasInstalledVersion else { return .unknown }
        return .installed
    }
}

public enum SettingsInventoryTab: Equatable, Sendable { case installed, available }

public struct SettingsInventoryCount: Equatable, Sendable {
    public let confirmedInstalledPackages: Int
    public let confirmedAvailablePackages: Int
    public let unknownPackages: Int
    public let pendingPackages: Int
    public let builtInItems: Int

    public init(confirmedInstalledPackages: Int, confirmedAvailablePackages: Int, unknownPackages: Int, pendingPackages: Int, builtInItems: Int) {
        self.confirmedInstalledPackages = confirmedInstalledPackages
        self.confirmedAvailablePackages = confirmedAvailablePackages
        self.unknownPackages = unknownPackages
        self.pendingPackages = pendingPackages
        self.builtInItems = builtInItems
    }

    public func label(for tab: SettingsInventoryTab) -> String {
        let confirmed = tab == .installed ? confirmedInstalledPackages + builtInItems : confirmedAvailablePackages
        let uncertain = unknownPackages + pendingPackages
        if uncertain > 0 && confirmed == 0 { return pendingPackages > 0 ? "? · checking" : "?" }
        let base = uncertain > 0 ? "\(confirmed)+" : String(confirmed)
        return pendingPackages > 0 ? "\(base) · checking" : base
    }
}

public struct SettingsInventorySelection: Equatable, Sendable {
    public let itemID: String
    public let tab: SettingsInventoryTab

    public init(itemID: String, tab: SettingsInventoryTab) {
        self.itemID = itemID
        self.tab = tab
    }

    /// Pending/unknown observations preserve the current selection and tab.
    /// Only an authoritative classification may move selection across tabs.
    public static func reconcile(itemID: String, currentTab: SettingsInventoryTab, observedState: ManagedPackageInventoryState) -> Self {
        switch observedState {
        case .installed: .init(itemID: itemID, tab: .installed)
        case .available: .init(itemID: itemID, tab: .available)
        case .unknown, .pending: .init(itemID: itemID, tab: currentTab)
        }
    }

    /// Manual tab changes are user intent: retain a still-visible selection,
    /// otherwise select the first row, or nil for an empty tab.
    public static func manualTabChange(currentItemID: String?, newTab: SettingsInventoryTab, visibleItemIDs: [String]) -> Self? {
        if let currentItemID, visibleItemIDs.contains(currentItemID) {
            return .init(itemID: currentItemID, tab: newTab)
        }
        guard let first = visibleItemIDs.first else { return nil }
        return .init(itemID: first, tab: newTab)
    }
}
