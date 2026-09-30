import XCTest
@testable import VaelenCore

final class SettingsInventoryPresentationTests: XCTestCase {
    func testPackageClassificationRequiresPositiveInstallationEvidence() {
        XCTAssertEqual(ManagedPackageInventoryState.classify(coreState: "notInstalled", installedVersion: nil, readPending: false), ManagedPackageInventoryState.available)
        XCTAssertEqual(ManagedPackageInventoryState.classify(coreState: "notInstalled", installedVersion: "8.4.11", readPending: false), ManagedPackageInventoryState.unknown)
        XCTAssertEqual(ManagedPackageInventoryState.classify(coreState: "unhealthy", installedVersion: nil, readPending: false), ManagedPackageInventoryState.unknown)
        XCTAssertEqual(ManagedPackageInventoryState.classify(coreState: "stopped", installedVersion: "8.4.11", readPending: false), ManagedPackageInventoryState.installed)
        XCTAssertEqual(ManagedPackageInventoryState.classify(coreState: nil, installedVersion: nil, readPending: true), ManagedPackageInventoryState.pending)
        XCTAssertEqual(ManagedPackageInventoryState.classify(coreState: "notInstalled", installedVersion: nil, readPending: true), ManagedPackageInventoryState.pending)
        XCTAssertEqual(ManagedPackageInventoryState.classify(coreState: nil, installedVersion: nil, readPending: false), ManagedPackageInventoryState.unknown)
    }

    func testCountsRepresentVisibleBuiltInsAndUnknownInventoryWithoutZeroFabrication() {
        let complete = SettingsInventoryCount(confirmedInstalledPackages: 2, confirmedAvailablePackages: 1, unknownPackages: 0, pendingPackages: 0, builtInItems: 4)
        XCTAssertEqual(complete.label(for: .installed), "6")
        XCTAssertEqual(complete.label(for: .available), "1")

        let partial = SettingsInventoryCount(confirmedInstalledPackages: 1, confirmedAvailablePackages: 0, unknownPackages: 1, pendingPackages: 0, builtInItems: 4)
        XCTAssertEqual(partial.label(for: .installed), "5+")
        XCTAssertEqual(partial.label(for: .available), "?")

        let loading = SettingsInventoryCount(confirmedInstalledPackages: 0, confirmedAvailablePackages: 0, unknownPackages: 0, pendingPackages: 2, builtInItems: 4)
        XCTAssertEqual(loading.label(for: .installed), "4+ · checking")
        XCTAssertEqual(loading.label(for: .available), "? · checking")
    }

    func testSelectionPreservesPendingAndUnknownThenFollowsConfirmedCategory() {
        let pending = SettingsInventorySelection.reconcile(itemID: "mysql", currentTab: .installed, observedState: .pending)
        XCTAssertEqual(pending, SettingsInventorySelection(itemID: "mysql", tab: .installed))
        let unknown = SettingsInventorySelection.reconcile(itemID: "mysql", currentTab: .installed, observedState: .unknown)
        XCTAssertEqual(unknown, SettingsInventorySelection(itemID: "mysql", tab: .installed))

        let installed = SettingsInventorySelection.reconcile(itemID: "mysql", currentTab: .available, observedState: .installed)
        XCTAssertEqual(installed, SettingsInventorySelection(itemID: "mysql", tab: .installed))
        let removed = SettingsInventorySelection.reconcile(itemID: "mysql", currentTab: .installed, observedState: .available)
        XCTAssertEqual(removed, SettingsInventorySelection(itemID: "mysql", tab: .available))
    }

    func testFailedInstallAndRemovalLeaveSelectionInConfirmedCategory() {
        // A failed operation does not mutate Core's observed package state.
        let failedInstall = SettingsInventorySelection.reconcile(itemID: "mysql", currentTab: .available, observedState: .available)
        XCTAssertEqual(failedInstall, SettingsInventorySelection(itemID: "mysql", tab: .available))
        let failedRemoval = SettingsInventorySelection.reconcile(itemID: "mysql", currentTab: .installed, observedState: .installed)
        XCTAssertEqual(failedRemoval, SettingsInventorySelection(itemID: "mysql", tab: .installed))
    }

    func testManualTabSwitchSelectsVisibleItemAndEmptyTabHasNoSelection() {
        XCTAssertEqual(SettingsInventorySelection.manualTabChange(currentItemID: "mysql", newTab: .available, visibleItemIDs: ["mysql", "mailpit"]), SettingsInventorySelection(itemID: "mysql", tab: .available))
        XCTAssertEqual(SettingsInventorySelection.manualTabChange(currentItemID: "mysql", newTab: .available, visibleItemIDs: ["mailpit"]), SettingsInventorySelection(itemID: "mailpit", tab: .available))
        XCTAssertNil(SettingsInventorySelection.manualTabChange(currentItemID: "mysql", newTab: .available, visibleItemIDs: []))
    }
}
