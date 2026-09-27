import VaelenCore
import VaelenIPC

func phpCatalogHumanOutput(_ catalog: PHPRuntimeCatalog, width: Int = HumanOutput.terminalWidth, color: Bool = HumanOutput.colorEnabled) -> String {
    let installed = Dictionary(uniqueKeysWithValues: catalog.installedVersions.map { ($0.version, $0) })
    let versions = Set(catalog.availableVersions).union(installed.keys).sorted()
    guard !versions.isEmpty else { return HumanOutput.heading("PHP runtimes", color: color) + "\nNo PHP versions reported." }
    let rows = versions.map { version -> [String] in
        let runtime = installed[version]
        let package = runtime == nil ? "Not installed" : "Installed"
        let availability = catalog.availableVersionsKnown ? (catalog.availableVersions.contains(version) ? "Available" : "Not listed") : "Unknown"
        let running = runtime?.running.map { $0 ? "Running" : "Stopped" } ?? "Unknown"
        let update = runtime?.updateAvailable.map { $0 ? "Available · \(runtime?.latestVersion ?? "")" : "Current" } ?? "Unknown"
        let packageLabel = HumanOutput.semantic(package, tint: HumanOutput.stateColor(package), color: color)
        let availabilityLabel = HumanOutput.semantic(availability, tint: HumanOutput.stateColor(availability), color: color)
        let defaultLabel = runtime?.isDefault == true ? HumanOutput.semantic("Default", tint: 32, color: color) : "—"
        let runningLabel = HumanOutput.semantic(running, tint: HumanOutput.stateColor(running), color: color)
        let updateLabel = HumanOutput.semantic(update, tint: update.hasPrefix("Available") ? 32 : HumanOutput.stateColor(update), color: color)
        return [version, packageLabel, availabilityLabel, defaultLabel, runningLabel, updateLabel]
    }
    let info = "Default: \(catalog.defaultVersion ?? "none") · Running: \(catalog.runningVersions.isEmpty ? "none" : catalog.runningVersions.joined(separator: ", "))"
    return HumanOutput.heading("PHP runtimes", color: color) + "\n" + info + "\n" + HumanOutput.table(rows, headers: ["Version", "Package", "Availability", "Server default", "FPM", "Update"], width: width, color: color)
}

func mysqlCatalogHumanOutput(_ payload: MySQLVersionsPayload, width: Int = HumanOutput.terminalWidth, color: Bool = HumanOutput.colorEnabled) -> String {
    let installed = Set(payload.installed.map(\.version))
    let versions = Set(payload.available).union(installed).sorted()
    guard !versions.isEmpty else { return HumanOutput.heading("MySQL versions", color: color) + "\nNo MySQL versions reported." }
    let rows = versions.map { version in
        let availability = payload.available.contains(version) ? "Available" : "Not listed"
        let package = installed.contains(version) ? "Installed" : "Not installed"
        return [version, HumanOutput.semantic(availability, tint: HumanOutput.stateColor(availability), color: color), HumanOutput.semantic(package, tint: HumanOutput.stateColor(package), color: color), version == payload.default ? HumanOutput.semantic("Selected", tint: 32, color: color) : "—"]
    }
    return HumanOutput.heading("MySQL versions", color: color) + "\n" + HumanOutput.table(rows, headers: ["Version", "Availability", "Package", "Selection"], width: width, color: color)
}

func mailpitCatalogHumanOutput(_ payload: MailpitVersionsPayload, width: Int = HumanOutput.terminalWidth, color: Bool = HumanOutput.colorEnabled) -> String {
    let installed = Set(payload.installed.map(\.version))
    let versions = Set(payload.available).union(installed).sorted()
    guard !versions.isEmpty else { return HumanOutput.heading("Mailpit versions", color: color) + "\nNo Mailpit versions reported." }
    let rows = versions.map { version in
        let availability = payload.available.contains(version) ? "Available" : "Not listed"
        let package = installed.contains(version) ? "Installed" : "Not installed"
        return [version, HumanOutput.semantic(availability, tint: HumanOutput.stateColor(availability), color: color), HumanOutput.semantic(package, tint: HumanOutput.stateColor(package), color: color)]
    }
    return HumanOutput.heading("Mailpit versions", color: color) + "\n" + HumanOutput.table(rows, headers: ["Version", "Availability", "Package"], width: width, color: color)
}
