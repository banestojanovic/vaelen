import XCTest
import VaelenCore
import VaelenIPC
@testable import VaelenCLI

final class DoctorTests: XCTestCase {
    func testHealthyRequestedServicesAndIntentionalOffAreHealthyOverall() {
        var snapshot = baseSnapshot(intents: ["mysql", "mailpit", "caddy", "dns", "standard-ports"])
        snapshot.mysql = mysql(.running, health: "healthy", pid: 100)
        snapshot.mailpit = mailpit(.running, health: "healthy", pid: 101)
        snapshot.routing = RouterStatus(provider: "caddy", state: .running, health: .healthy, routeCount: 2)
        snapshot.dns = dns(state: .installed, health: "healthy", ownership: .vaelen, responder: .ownedRunning)
        snapshot.ports = StandardPortsStatus(state: .healthy, ownership: .vaelen, forwardingActive: true)
        snapshot.phpInstalled = ["8.4.23"]
        snapshot.phpStatuses["8.4.23"] = php("8.4.23", .stopped)

        let report = DoctorEvaluator.evaluate(snapshot)
        XCTAssertEqual(report.overall, "healthy")
        XCTAssertEqual(report.exitCode, 0, report.terminalOutput)
        XCTAssertEqual(check(report, "mysql").state, .healthy)
        XCTAssertEqual(check(report, "php:8.4.23").state, .off)
    }

    func testIntentionallyOffServicesIncludingHistoricalPortsIntegration() {
        var snapshot = baseSnapshot(intents: [])
        snapshot.phpInstalled = ["8.4.23"]
        snapshot.phpStatuses["8.4.23"] = php("8.4.23", .stopped)
        snapshot.mysql = mysql(.installed, health: "not-initialized")
        snapshot.mailpit = mailpit(.stopped, health: "stopped")
        snapshot.routing = RouterStatus(provider: "caddy", state: .stopped, health: .unknown, routeCount: 0)
        snapshot.dns = dns(state: .notInstalled, health: "stopped", ownership: .none, responder: .stopped)
        snapshot.ports = StandardPortsStatus(state: .installed, ownership: .external, forwardingActive: false)

        let report = DoctorEvaluator.evaluate(snapshot)
        XCTAssertEqual(report.overall, "healthy")
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(check(report, "php:8.4.23").state, .off)
        XCTAssertEqual(check(report, "mysql").state, .off)
        XCTAssertEqual(check(report, "standard-ports").state, .off)
        XCTAssertTrue(check(report, "standard-ports").detail.contains("historical"))
    }

    func testRequestedOnUnhealthyServiceFails() {
        var snapshot = baseSnapshot(intents: ["mysql"])
        snapshot.mysql = mysql(.stopped, health: "stopped")

        let report = DoctorEvaluator.evaluate(snapshot)
        XCTAssertEqual(check(report, "mysql").state, .failed)
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertEqual(check(report, "mysql").recommendation, "Inspect `val mysql status` before retrying `val mysql start`.")
    }

    func testInstalledPHPVersionsAreProbedAndRequestedStoppedRuntimeFails() {
        var snapshot = baseSnapshot(intents: ["php:8.4.23"])
        snapshot.phpInstalled = ["8.4.23"]
        snapshot.phpStatuses["8.4.23"] = php("8.4.23", .stopped, installed: true)
        let report = DoctorEvaluator.evaluate(snapshot)
        XCTAssertEqual(check(report, "php:8.4.23").state, .failed)
        XCTAssertEqual(check(report, "php:8.4.23").recommendation, "val php start 8.4.23")
    }

    func testUnknownIntentOrMissingObservationNeverMeansOff() {
        var unknownIntent = baseSnapshot(intents: nil)
        unknownIntent.mysql = mysql(.stopped, health: "stopped")
        XCTAssertEqual(check(DoctorEvaluator.evaluate(unknownIntent), "mysql").state, .notChecked)

        var missingObservation = baseSnapshot(intents: ["mysql"])
        missingObservation.mysql = nil
        missingObservation.observationErrors["mysql"] = "status endpoint unavailable"
        XCTAssertEqual(check(DoctorEvaluator.evaluate(missingObservation), "mysql").state, .notChecked)
    }

    func testCoreUnavailableMarksDependentChecksAndProducesValidJSONReport() throws {
        let report = DoctorEvaluator.evaluate(DoctorSnapshot(coreFailure: "Not running; service checks unavailable.", coreFailureCode: 3))
        XCTAssertEqual(report.overall, "unavailable")
        XCTAssertEqual(report.exitCode, 3)
        XCTAssertEqual(check(report, "mysql").state, .notChecked)
        XCTAssertTrue(report.terminalOutput.contains("○ Not running"))
        XCTAssertFalse(report.terminalOutput.contains("× Failed"))
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)
        XCTAssertEqual(decoded.overall, "unavailable")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Not running; service checks unavailable."))
    }

    func testRecoveredHistoricalRestorationErrorDoesNotDegradeReport() {
        var snapshot = baseSnapshot(intents: ["mysql"])
        snapshot.mysql = mysql(.running, health: "healthy", pid: 100)
        snapshot.coreStatus = core(intents: ["mysql"], issues: ["mysql": "Previous startup attempt failed."])

        let report = DoctorEvaluator.evaluate(snapshot)
        XCTAssertEqual(check(report, "mysql").state, .healthy)
        XCTAssertEqual(report.history.count, 1)
        XCTAssertEqual(report.exitCode, 0, report.terminalOutput)
    }

    func testLocalDNSHealthUsesKnownSavedIntentAndUnknownIntentStaysUnverified() {
        var requestedOn = baseSnapshot(intents: ["dns"])
        requestedOn.dns = dns(state: .installed, health: "healthy", ownership: .vaelen, responder: .ownedRunning)
        XCTAssertEqual(check(DoctorEvaluator.evaluate(requestedOn), "dns").state, .healthy)

        var intentionallyOff = baseSnapshot(intents: [])
        intentionallyOff.dns = dns(state: .installed, health: "healthy", ownership: .vaelen, responder: .ownedRunning)
        XCTAssertEqual(check(DoctorEvaluator.evaluate(intentionallyOff), "dns").state, .warning)

        var unknownIntent = baseSnapshot(intents: nil)
        unknownIntent.dns = dns(state: .installed, health: "healthy", ownership: .vaelen, responder: .ownedRunning)
        XCTAssertEqual(check(DoctorEvaluator.evaluate(unknownIntent), "dns").state, .notChecked)
    }

    func testDoctorJSONOptionParses() throws {
        guard case .doctor(json: true) = try VaelenCLIMain.parse(["doctor", "--json"]) else {
            return XCTFail("val doctor --json did not parse")
        }
    }

    func testTerminalRendererUsesBorderlessColumnsAndSubtleStateSymbols() {
        var snapshot = baseSnapshot(intents: [])
        snapshot.mysql = mysql(.installed, health: "not-initialized")
        let report = DoctorEvaluator.evaluate(snapshot)
        let output = report.render(width: 100, color: false)
        XCTAssertTrue(output.contains("Check"))
        XCTAssertTrue(output.contains("Status"))
        XCTAssertTrue(output.contains("Detail"))
        XCTAssertTrue(output.contains("○ Off"))
        XCTAssertFalse(output.contains("\u{001B}["))
        XCTAssertFalse(output.contains("notInstalled"))
        XCTAssertFalse(output.contains("· healthy"))
    }

    func testTerminalRendererStacksAndWrapsAtFortyColumns() {
        var snapshot = baseSnapshot(intents: ["mysql"])
        snapshot.mysql = mysql(.stopped, health: "stopped")
        let output = DoctorEvaluator.evaluate(snapshot).render(width: 40, color: false)
        XCTAssertTrue(output.contains("Check  Status  Detail"))
        XCTAssertTrue(output.contains("Recommendation:"))
        XCTAssertFalse(output.split(separator: "\n").contains { $0.count > 40 })
    }

    func testTerminalRendererColorsStatusOnlyWhenRequested() {
        let report = DoctorEvaluator.evaluate(baseSnapshot(intents: []))
        XCTAssertTrue(report.render(width: 100, color: true).contains("\u{001B}[32m✓ Healthy"))
        XCTAssertFalse(report.render(width: 100, color: false).contains("\u{001B}["))
    }

    func testTTYColorPolicyHonorsNoColorDumbTermAndPipes() {
        XCTAssertTrue(DoctorReport.colorEnabled(isTTY: true, environment: ["TERM": "xterm-256color"]))
        XCTAssertFalse(DoctorReport.colorEnabled(isTTY: true, environment: ["TERM": "xterm-256color", "NO_COLOR": ""]))
        XCTAssertFalse(DoctorReport.colorEnabled(isTTY: true, environment: ["TERM": "dumb"]))
        XCTAssertFalse(DoctorReport.colorEnabled(isTTY: false, environment: ["TERM": "xterm-256color"]))
    }

    private func baseSnapshot(intents: Set<String>?) -> DoctorSnapshot {
        var snapshot = DoctorSnapshot(coreStatus: core(intents: intents))
        snapshot.phpAvailable = []
        snapshot.phpInstalled = []
        snapshot.mysql = mysql(.stopped, health: "stopped")
        snapshot.mailpit = mailpit(.stopped, health: "stopped")
        snapshot.routing = RouterStatus(provider: "caddy", state: .stopped, health: .unknown, routeCount: 0)
        snapshot.dns = dns(state: .notInstalled, health: "stopped", ownership: .none, responder: .stopped)
        snapshot.ports = StandardPortsStatus(state: .absent, ownership: StandardPortsOwnership.none, forwardingActive: false)
        return snapshot
    }

    private func core(intents: Set<String>?, issues: [String: String]? = [:]) -> CoreStatusResponse {
        CoreStatusResponse(core: CoreRuntimeStatus(state: .running, version: "test", pid: 42), protocolVersion: 1, serviceIssues: issues, serviceIntents: intents)
    }

    private func check(_ report: DoctorReport, _ id: String) -> DoctorCheck {
        guard let value = report.checks.first(where: { $0.id == id }) else { XCTFail("Missing check \(id)"); return DoctorCheck(id: id, name: id, state: .notChecked, detail: "missing", recommendation: nil) }
        return value
    }

    private func php(_ version: String, _ state: PHPFPMState, installed: Bool = false) -> PHPStatus {
        let package: Any = installed ? ["version": version, "architecture": "arm64", "packagePath": "/tmp/php", "cliPath": "/tmp/php/bin/php", "fpmPath": "/tmp/php/sbin/php-fpm", "source": "test", "cliSHA256": "", "fpmSHA256": "", "installedAt": 0] : NSNull()
        let object: [String: Any] = ["version": version, "package": package, "state": state.rawValue, "pid": state == .running ? 42 : NSNull(), "socket": "", "health": state == .running ? "healthy" : "stopped", "isDefault": false]
        return try! JSONDecoder().decode(PHPStatus.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func mysql(_ state: MySQLState, health: String, pid: Int32? = nil) -> MySQLStatus {
        MySQLStatus(state: state, health: health, installedVersion: state == .notInstalled ? nil : "8.4", selectedVersion: "8.4", pid: pid, port: 3306, socket: "", datadir: "", executablePath: "")
    }

    private func mailpit(_ state: MailpitState, health: String, pid: Int32? = nil) -> MailpitStatus {
        MailpitStatus(state: state, health: health, installedVersion: state == .notInstalled ? nil : "1.31", pid: pid, smtpPort: 1025, httpPort: 8025, database: "", uiEndpoint: "", executablePath: "")
    }

    private func dns(state: SystemCapabilityState, health: String, ownership: DNSOwnership, responder: DNSResponderState) -> DNSStatus {
        DNSStatus(state: state, ownership: ownership, responderState: responder, health: health)
    }
}
