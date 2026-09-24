import Foundation
import Darwin
import VaelenCore
import VaelenIPC

enum DoctorCheckState: String, Codable {
    case healthy
    case off
    case warning
    case failed
    case notChecked = "not_checked"
}

struct DoctorCheck: Codable {
    let id: String
    let name: String
    let state: DoctorCheckState
    let detail: String
    let recommendation: String?
}

struct DoctorReport: Codable {
    let overall: String
    let checks: [DoctorCheck]
    let history: [String]
    let exitCode: Int32

    var terminalOutput: String {
        var size = winsize()
        let hasWidth = isatty(STDOUT_FILENO) == 1 && ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0
        let width = hasWidth ? Int(size.ws_col) : 100
        let environment = ProcessInfo.processInfo.environment
        let color = Self.colorEnabled(isTTY: isatty(STDOUT_FILENO) == 1, environment: environment)
        return render(width: width, color: color)
    }

    static func colorEnabled(isTTY: Bool, environment: [String: String]) -> Bool {
        isTTY && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
    }

    func render(width: Int, color: Bool) -> String {
        let width = max(20, width)
        let stacked = width < 76
        let checkWidth = min(20, max(10, checks.map { $0.name.count }.max() ?? 10))
        let statusWidth = 18
        let heading = stacked ? "Check  Status  Detail" : "\("Check".padding(toLength: checkWidth, withPad: " ", startingAt: 0))  \("Status".padding(toLength: statusWidth, withPad: " ", startingAt: 0))  Detail"
        var lines = ["Vaelen Doctor", "", heading]
        for check in checks {
            let (symbol, label, tint) = statusPresentation(check)
            let status = "\(symbol) \(label)"
            let detail = presentationDetail(check)
            if stacked {
                lines.append("\(check.name)  \(styled(status, tint: tint, color: color))")
                lines += wrap(detail, width: max(12, width - 2), indent: "  ")
            } else {
                let paddedStatus = status.padding(toLength: statusWidth, withPad: " ", startingAt: 0)
                let prefix = "\(check.name.padding(toLength: checkWidth, withPad: " ", startingAt: 0))  \(styled(paddedStatus, tint: tint, color: color))  "
                let detailLines = wrap(detail, width: width, indent: String(repeating: " ", count: checkWidth + statusWidth + 4))
                lines.append(prefix + (detailLines.first.map { stripIndent($0) } ?? ""))
                lines += detailLines.dropFirst()
            }
            if let recommendation = check.recommendation {
                lines += wrap("Recommendation: \(recommendation.replacingOccurrences(of: "`", with: ""))", width: width, indent: "  ")
            }
        }
        if !history.isEmpty {
            lines += ["", "Startup history"]
            lines += history.flatMap { wrap($0, width: width, indent: "  ") }
        }
        let counts = Dictionary(grouping: checks, by: \.state).mapValues(\.count)
        let suffix = [
            counts[.failed].map { "\($0) failure\($0 == 1 ? "" : "s")" },
            counts[.warning].map { "\($0) warning\($0 == 1 ? "" : "s")" },
            counts[.notChecked].map { "\($0) not checked" }
        ].compactMap { $0 }.joined(separator: ", ")
        lines += ["", "Result: \(overall == "healthy" ? "Healthy" : overall == "unavailable" ? "Not running" : overall.capitalized)\(suffix.isEmpty ? "" : " · \(suffix)")"]
        return lines.joined(separator: "\n")
    }

    private func statusPresentation(_ check: DoctorCheck) -> (String, String, Int) {
        if overall == "unavailable" && check.id == "core" { return ("○", "Not running", 0) }
        switch check.state {
        case .healthy: return ("✓", "Healthy", 32)
        case .off: return ("○", "Off", 0)
        case .warning: return ("!", "Warning", 33)
        case .failed: return ("×", "Failed", 31)
        case .notChecked: return ("–", "Not checked", 90)
        }
    }

    private func presentationDetail(_ check: DoctorCheck) -> String {
        if check.id == "core", overall == "unavailable" { return "Not running; service checks unavailable." }
        var text = check.detail
        let redundant: [(String, String)] = [
            ("notInstalled · not-installed", "Not installed"),
            ("running · healthy", "Running"),
            ("stopped · stopped", "Stopped"),
            ("installed · not-initialized", "Installed; not initialized")
        ]
        for (from, to) in redundant { if text.hasPrefix(from) { text = to + text.dropFirst(from.count); break } }
        let replacements = [
            "notInstalled": "Not installed", "installed": "Installed", "stopped": "Stopped",
            "unhealthy": "Unhealthy", "starting": "Starting", "conflict": "Conflict",
            "ownershipMismatch": "Ownership mismatch", "unavailable": "Unavailable",
            "vaelen ownership": "Vaelen-managed", "external ownership": "Externally managed",
            "Forwarding true": "Forwarding active", "Forwarding false": "Forwarding inactive",
            "forwarding true": "forwarding active", "forwarding false": "forwarding inactive",
            "ownership vaelen": "Vaelen-managed", "ownership external": "Externally managed"
        ]
        for (from, to) in replacements { text = text.replacingOccurrences(of: from, with: to) }
        text = text.replacingOccurrences(of: " · healthy", with: "")
        text = text.replacingOccurrences(of: " · vaelen ownership", with: " · Vaelen-managed")
        text = text.replacingOccurrences(of: "Requested on · ", with: "")
        return text
    }

    private func styled(_ value: String, tint: Int, color: Bool) -> String {
        color && tint != 0 ? "\u{001B}[\(tint)m\(value)\u{001B}[0m" : value
    }

    private func wrap(_ text: String, width: Int, indent: String) -> [String] {
        let available = max(8, width - indent.count)
        var result: [String] = []
        var line = ""
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if line.isEmpty { line = word }
            else if line.count + 1 + word.count <= available { line += " " + word }
            else { result.append(indent + line); line = word }
        }
        if !line.isEmpty { result.append(indent + line) }
        return result
    }

    private func stripIndent(_ value: String) -> String { String(value.drop(while: { $0 == " " })) }
}

struct DoctorSnapshot {
    var coreStatus: CoreStatusResponse?
    var coreFailure: String?
    var coreFailureCode: Int32 = 3
    var phpAvailable: [String]?
    var phpInstalled: [String]?
    var phpStatuses: [String: PHPStatus] = [:]
    var mysql: MySQLStatus?
    var mailpit: MailpitStatus?
    var routing: RouterStatus?
    var dns: DNSStatus?
    var ports: StandardPortsStatus?
    var observationErrors: [String: String] = [:]
}

enum DoctorEvaluator {
    static func evaluate(_ snapshot: DoctorSnapshot) -> DoctorReport {
        guard let core = snapshot.coreStatus else {
            let detail = snapshot.coreFailure ?? "Not running; service checks unavailable."
            var checks = [DoctorCheck(id: "core", name: "Core", state: .failed, detail: detail, recommendation: "Open Vaelen.app and start Core.")]
            checks += [
                ("php", "PHP"), ("mysql", "MySQL"), ("mailpit", "Mailpit"), ("routing", "Routing"), ("dns", "Local DNS"), ("standard-ports", "Standard ports")
            ].map { id, name in DoctorCheck(id: id, name: name, state: .notChecked, detail: "Core unavailable; service check not run.", recommendation: nil) }
            let overall = snapshot.coreFailureCode == 4 ? "incompatible" : snapshot.coreFailureCode == 1 ? "error" : "unavailable"
            return DoctorReport(overall: overall, checks: checks, history: [], exitCode: snapshot.coreFailureCode)
        }

        var checks = [DoctorCheck(id: "core", name: "Core", state: .healthy, detail: "Running · version \(core.core.version), PID \(core.core.pid)", recommendation: nil)]
        let intents = core.serviceIntents
        let issues = core.serviceIssues ?? [:]

        appendPHPChecks(snapshot, intents: intents, to: &checks)
        checks.append(serviceCheck(id: "mysql", name: "MySQL", intentKey: "mysql", intents: intents,
                                   observed: snapshot.mysql.map(mysqlObservation), error: snapshot.observationErrors["mysql"],
                                   onRecommendation: "val mysql start", offRecommendation: "val mysql stop"))
        checks.append(serviceCheck(id: "mailpit", name: "Mailpit", intentKey: "mailpit", intents: intents,
                                   observed: snapshot.mailpit.map(mailpitObservation), error: snapshot.observationErrors["mailpit"],
                                   onRecommendation: "val mailpit start", offRecommendation: "val mailpit stop"))
        checks.append(serviceCheck(id: "routing", name: "Routing", intentKey: "caddy", intents: intents,
                                   observed: snapshot.routing.map(routingObservation), error: snapshot.observationErrors["routing"],
                                   onRecommendation: "val routing start", offRecommendation: "val routing stop"))
        checks.append(serviceCheck(id: "dns", name: "Local DNS", intentKey: "dns", intents: intents,
                                   observed: snapshot.dns.map(dnsObservation), error: snapshot.observationErrors["dns"],
                                   onRecommendation: "Review Vaelen Settings → DNS; inspect with `val dns status`.", offRecommendation: "val dns remove"))
        checks.append(portsCheck(snapshot.ports, intents: intents, error: snapshot.observationErrors["standard-ports"]))

        let history = issues.keys.sorted().map { "\($0): \(issues[$0]!)" }
        let allOkay = checks.allSatisfy { $0.state == .healthy || $0.state == .off }
        let overall = allOkay ? "healthy" : "degraded"
        let exitCode: Int32 = allOkay ? 0 : 1
        return DoctorReport(overall: overall, checks: checks, history: history, exitCode: exitCode)
    }

    private struct Observation {
        let description: String
        let healthy: Bool
        let off: Bool
        let issue: Bool
        let recommendation: String?
    }

    private static func serviceCheck(id: String, name: String, intentKey: String, intents: Set<String>?, observed: Observation?, error: String?, onRecommendation: String, offRecommendation: String) -> DoctorCheck {
        guard let intents else {
            let observedDetail = error ?? observed?.description ?? "No live observation."
            return DoctorCheck(id: id, name: name, state: .notChecked, detail: "\(observedDetail) · saved intent unavailable; desired state unknown.", recommendation: nil)
        }
        guard let observed else {
            return DoctorCheck(id: id, name: name, state: .notChecked, detail: error ?? "Core did not provide an observation.", recommendation: nil)
        }
        let requestedOn = intents.contains(intentKey)
        if requestedOn {
            if observed.healthy { return DoctorCheck(id: id, name: name, state: .healthy, detail: "Requested on · \(observed.description)", recommendation: nil) }
            if observed.issue || observed.off { return DoctorCheck(id: id, name: name, state: .failed, detail: "Requested on · \(observed.description)", recommendation: observed.recommendation ?? onRecommendation) }
            return DoctorCheck(id: id, name: name, state: .notChecked, detail: "Requested on · \(observed.description)", recommendation: onRecommendation)
        }
        if observed.off { return DoctorCheck(id: id, name: name, state: .off, detail: observed.description, recommendation: nil) }
        if observed.healthy { return DoctorCheck(id: id, name: name, state: .warning, detail: "Running although saved intent is Off · \(observed.description)", recommendation: offRecommendation) }
        return DoctorCheck(id: id, name: name, state: .warning, detail: "Saved intent is Off · \(observed.description)", recommendation: observed.recommendation)
    }

    private static func appendPHPChecks(_ snapshot: DoctorSnapshot, intents: Set<String>?, to checks: inout [DoctorCheck]) {
        let requested = Set((intents ?? []).compactMap { value -> String? in
            guard value.hasPrefix("php:") else { return nil }
            let version = String(value.dropFirst(4))
            return version.isEmpty ? nil : version
        })
        guard let installed = snapshot.phpInstalled else {
            checks.append(DoctorCheck(id: "php", name: "PHP", state: .notChecked, detail: snapshot.observationErrors["php-inventory"] ?? "Installed PHP versions could not be discovered; runtime state is unknown.", recommendation: nil))
            for version in requested.sorted() {
                checks.append(phpMissingStatus(version, snapshot: snapshot, intents: intents))
            }
            return
        }
        let versions = Set(installed).union(requested).sorted()
        if versions.isEmpty {
            if intents == nil {
                checks.append(DoctorCheck(id: "php", name: "PHP", state: .notChecked, detail: "No installed versions observed; saved intent is unavailable.", recommendation: nil))
            } else {
                checks.append(DoctorCheck(id: "php", name: "PHP", state: .off, detail: "No installed or requested PHP runtimes.", recommendation: nil))
            }
            return
        }
        for version in versions {
            let key = "php:\(version)"
            let status = snapshot.phpStatuses[version]
            let observation = status.map(phpObservation)
            let error = snapshot.observationErrors[key]
            checks.append(serviceCheck(id: key, name: "PHP \(version)", intentKey: key, intents: intents,
                                       observed: observation, error: error,
                                       onRecommendation: phpOnRecommendation(version, status: status, available: snapshot.phpAvailable),
                                       offRecommendation: "val php stop \(version)"))
        }
    }

    private static func phpMissingStatus(_ version: String, snapshot: DoctorSnapshot, intents: Set<String>?) -> DoctorCheck {
        let key = "php:\(version)"
        return serviceCheck(id: key, name: "PHP \(version)", intentKey: key, intents: intents,
                            observed: snapshot.phpStatuses[version].map(phpObservation), error: snapshot.observationErrors[key],
                            onRecommendation: phpOnRecommendation(version, status: nil, available: snapshot.phpAvailable), offRecommendation: "val php stop \(version)")
    }

    private static func phpOnRecommendation(_ version: String, status: PHPStatus?, available: [String]?) -> String {
        if status == nil { return "Check `val php status \(version)` after Core can report the runtime." }
        if status?.package == nil, available?.contains(version) == true { return "val php install \(version), then `val php start \(version)`" }
        if status?.package == nil { return "Review PHP Settings; requested version \(version) is not installed or available." }
        return "val php start \(version)"
    }

    private static func phpObservation(_ value: PHPStatus) -> Observation {
        let healthy = value.state == .running && value.health == "healthy" && value.package != nil
        let off = value.state == .stopped && value.pid == nil
        let issue = value.package == nil || value.state == .degraded || (value.state == .running && !healthy)
        let description = value.state == .running && healthy ? "Running" : value.state == .stopped ? "Stopped" : "\(stateName(value.state.rawValue)) · health \(value.health)"
        return Observation(description: description, healthy: healthy, off: off, issue: issue,
                           recommendation: value.package == nil ? nil : "val php start \(value.version)")
    }

    private static func mysqlObservation(_ value: MySQLStatus) -> Observation {
        let healthy = value.state == .running && value.health == "healthy"
        let off = [.notInstalled, .installed, .stopped].contains(value.state) && value.pid == nil
        let issue = [.starting, .unhealthy, .conflict].contains(value.state) || (value.state == .running && !healthy)
        let recommendation = value.state == .notInstalled ? "Install MySQL in Vaelen Settings before enabling it." : value.health == "not-initialized" ? "Initialize only if you intend to create a new MySQL data directory (`val mysql initialize`)." : "Inspect `val mysql status` before retrying `val mysql start`."
        let description = value.state == .running && healthy ? "Running" : value.state == .notInstalled ? "Not installed" : value.state == .installed && value.health == "not-initialized" ? "Installed; not initialized" : value.state == .installed ? "Installed" : "\(stateName(value.state.rawValue)) · health \(value.health)"
        return Observation(description: description, healthy: healthy, off: off, issue: issue, recommendation: recommendation)
    }

    private static func mailpitObservation(_ value: MailpitStatus) -> Observation {
        let healthy = value.state == .running && value.health == "healthy"
        let off = [.notInstalled, .installed, .stopped].contains(value.state) && value.pid == nil
        let issue = [.starting, .unhealthy, .conflict].contains(value.state) || (value.state == .running && !healthy)
        let recommendation = value.state == .notInstalled ? "Install Mailpit in Vaelen Settings before enabling it." : "Inspect `val mailpit status`, then retry `val mailpit start` if appropriate."
        let description = value.state == .running && healthy ? "Running" : value.state == .notInstalled ? "Not installed" : value.state == .installed ? "Installed" : "\(stateName(value.state.rawValue)) · health \(value.health)"
        return Observation(description: description, healthy: healthy, off: off, issue: issue, recommendation: recommendation)
    }

    private static func routingObservation(_ value: RouterStatus) -> Observation {
        let healthy = value.state == .running && value.health == .healthy
        let off = value.state == .stopped
        let issue = value.state == .degraded || (value.state == .running && value.health == .unhealthy)
        let recommendation = issue ? "Inspect Vaelen routing diagnostics before retrying `val routing start`." : "val routing start"
        let description = value.state == .running && healthy ? "Running" : "\(stateName(value.state.rawValue)) · health \(stateName(value.health.rawValue))"
        return Observation(description: description, healthy: healthy, off: off, issue: issue, recommendation: recommendation)
    }

    private static func dnsObservation(_ value: DNSStatus) -> Observation {
        let healthy = value.state == .installed && value.health == "healthy" && value.ownership == .vaelen && value.responderState == .ownedRunning
        let off = value.state == .notInstalled && value.responderState != .ownedRunning
        let issue = value.state == .unhealthy || value.state == .conflict || value.state == .installing || value.state == .removing
        let recommendation = "Review Vaelen Settings → DNS; inspect with `val dns status` before changing resolver state."
        let description = healthy ? "Vaelen-managed and active" : "\(stateName(value.state.rawValue)) · \(stateName(value.health)) · \(stateName(value.ownership.rawValue)) ownership"
        return Observation(description: description, healthy: healthy, off: off, issue: issue, recommendation: recommendation)
    }

    private static func stateName(_ raw: String) -> String {
        switch raw {
        case "notInstalled": return "Not installed"
        case "not-initialized": return "not initialized"
        case "ownershipMismatch": return "Ownership mismatch"
        case "ownedRunning": return "running"
        case "vaelen": return "Vaelen-managed"
        case "none": return "none"
        case "unknown": return "unknown"
        default: return raw.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private static func portsCheck(_ status: StandardPortsStatus?, intents: Set<String>?, error: String?) -> DoctorCheck {
        guard let intents else { return DoctorCheck(id: "standard-ports", name: "Standard ports", state: .notChecked, detail: error ?? "Saved service intent is unavailable; desired state is unknown.", recommendation: nil) }
        guard let status else { return DoctorCheck(id: "standard-ports", name: "Standard ports", state: .notChecked, detail: error ?? "Core did not provide a PF forwarding observation.", recommendation: nil) }
        // Older Core versions omit the explicit forwarding observation. Their
        // healthy state is only emitted after the helper verifies active
        // Vaelen-owned forwarding, so it remains an authoritative positive.
        let forwardingActive = status.forwardingActive ?? (status.state == .healthy && status.ownership == .vaelen ? true : nil)
        let requested = intents.contains("standard-ports")
        let healthy = status.state == .healthy && status.ownership == .vaelen && forwardingActive == true
        if requested {
            if healthy { return DoctorCheck(id: "standard-ports", name: "Standard ports", state: .healthy, detail: "Requested on · Vaelen-owned forwarding active", recommendation: nil) }
            let knownIssue = [.absent, .installed, .unhealthy, .conflict, .ownershipMismatch].contains(status.state)
                || forwardingActive == false
                || (status.state == .healthy && status.ownership != .some(.vaelen))
            return DoctorCheck(id: "standard-ports", name: "Standard ports", state: knownIssue ? .failed : .notChecked,
                               detail: "\(stateName(status.state.rawValue)) · forwarding \(forwardingActive.map { $0 ? "active" : "inactive" } ?? "unknown") · \(status.ownership.map { stateName($0.rawValue) } ?? "ownership unknown")",
                               recommendation: "Review `val ports status` and Vaelen Settings → Standard Local Ports; do not alter PF until ownership is clear.")
        }
        if status.state == .absent && status.ownership == StandardPortsOwnership.none {
            return DoctorCheck(id: "standard-ports", name: "Standard ports", state: .off, detail: "Forwarding absent · no Vaelen ownership", recommendation: nil)
        }
        if status.state == .installed && forwardingActive == false && [.none, .external].contains(status.ownership ?? .unknown) {
            return DoctorCheck(id: "standard-ports", name: "Standard ports", state: .off, detail: "Forwarding inactive · compatible historical PF configuration retained", recommendation: nil)
        }
        if forwardingActive == true {
            return DoctorCheck(id: "standard-ports", name: "Standard ports", state: .warning, detail: "Forwarding active although saved intent is Off · ownership \(status.ownership?.rawValue ?? "unknown")", recommendation: "Review `val ports status`; use `val ports remove` only if you intend to disable Vaelen forwarding.")
        }
        let state = status.state == .unavailable || forwardingActive == nil ? DoctorCheckState.notChecked : .warning
        return DoctorCheck(id: "standard-ports", name: "Standard ports", state: state, detail: "\(stateName(status.state.rawValue)) · forwarding \(forwardingActive.map { $0 ? "active" : "inactive" } ?? "unknown") · \(status.ownership.map { stateName($0.rawValue) } ?? "ownership unknown")", recommendation: state == .warning ? "Review `val ports status` and confirm external ownership before taking action." : nil)
    }
}
