import XCTest
@testable import VaelenCore

final class ServiceControlPresentationTests: XCTestCase {
    func testDNSOffWithUnavailableHelperOffersRegistrationPath() {
        let status = DNSStatus(state: .unavailable, ownership: .unknown, health: "privilege-unavailable", conflict: "Vaelen’s privileged helper is not registered or approved.")
        let view = ServiceControlPresentation.dns(status: status, savedOn: false)

        XCTAssertEqual(view.title, "Needs attention")
        XCTAssertTrue(view.detail?.contains("register Vaelen’s helper") == true)
        XCTAssertEqual(view.action, .enable)
        XCTAssertFalse(view.canDisable)
    }

    func testDNSOffWithGenericInspectionUncertaintyRemainsFailClosed() {
        let status = DNSStatus(state: .unavailable, ownership: .unknown, health: "unavailable", conflict: "Resolver inspection failed unexpectedly.")
        let view = ServiceControlPresentation.dns(status: status, savedOn: false)

        XCTAssertEqual(view.title, "Off")
        XCTAssertEqual(view.detail, "Resolver inspection failed unexpectedly.")
        XCTAssertNil(view.action)
        XCTAssertFalse(view.canDisable)
    }

    func testDNSOffWithOwnershipConflictRemainsFailClosed() {
        let status = DNSStatus(state: .conflict, ownership: .unknown, health: "ownership-uncertain", conflict: "Durable resolver ownership record is unreadable.")
        let view = ServiceControlPresentation.dns(status: status, savedOn: false)

        XCTAssertEqual(view.title, "Off")
        XCTAssertEqual(view.detail, "Durable resolver ownership record is unreadable.")
        XCTAssertNil(view.action)
        XCTAssertFalse(view.canDisable)
    }

    func testDNSOffWithSafeExternalPreimageOffersEnableWithoutDisable() {
        let status = DNSStatus(state: .notInstalled, ownership: .external, resolverContent: "nameserver 127.0.0.1\n", health: "stopped")
        let view = ServiceControlPresentation.dns(status: status, savedOn: false)

        XCTAssertEqual(view.title, "Off · External DNS")
        XCTAssertTrue(view.detail?.contains("preserves and restores it exactly") == true)
        XCTAssertEqual(view.action, .enable)
        XCTAssertFalse(view.canDisable)
    }

    func testDNSOffWithExternalResolverConflictHasNoAction() {
        let status = DNSStatus(state: .conflict, ownership: .external, resolverContent: "nameserver 127.0.0.1\n", health: "conflict", conflict: "External /etc/resolver/test exists")
        let view = ServiceControlPresentation.dns(status: status, savedOn: false)

        XCTAssertEqual(view.title, "Off · External DNS")
        XCTAssertEqual(view.detail, "External /etc/resolver/test exists")
        XCTAssertNil(view.action)
        XCTAssertFalse(view.canDisable)
    }

    func testDNSOwnedAndOnOffersStop() {
        let status = DNSStatus(state: .installed, ownership: .vaelen, pid: 123, responderState: .ownedRunning, health: "healthy")
        let view = ServiceControlPresentation.dns(status: status, savedOn: true)

        XCTAssertEqual(view.title, "On")
        XCTAssertEqual(view.action, .stop)
        XCTAssertTrue(view.canDisable)
    }

    func testDNSSavedOnAndBlockedShowsReasonAndRetryWithoutUnownedDisable() {
        let status = DNSStatus(state: .conflict, ownership: .external, responderState: .stopped, health: "conflict", conflict: "External /etc/resolver/test exists")
        let view = ServiceControlPresentation.dns(status: status, savedOn: true, blockedReason: "Herd resolver is present; no takeover was attempted.")

        XCTAssertEqual(view.title, "Needs attention")
        XCTAssertEqual(view.detail, "Herd resolver is present; no takeover was attempted.")
        XCTAssertEqual(view.action, .retry)
        XCTAssertFalse(view.canDisable)
    }

    func testDNSHealthySnapshotSupersedesStaleStartupIssue() {
        let healthy = DNSStatus(state: .installed, ownership: .vaelen, pid: 123, responderState: .ownedRunning, health: "healthy")
        let view = ServiceControlPresentation.dns(status: healthy, savedOn: true, blockedReason: "Stale startup error")

        XCTAssertEqual(view.title, "On")
        XCTAssertEqual(view.action, .stop)
        XCTAssertNil(ServiceControlPresentation.dnsStartFailure("Stale first-Retry error", authoritativeStatus: healthy))
    }

    func testDNSStartFailureIsPreservedUnlessAuthoritativeStateProvesHealthy() {
        let failed = DNSStatus(state: .conflict, ownership: .external, responderState: .stopped, health: "conflict", conflict: "External resolver drift")

        XCTAssertEqual(ServiceControlPresentation.dnsStartFailure("Exact startup failure", authoritativeStatus: failed), "Exact startup failure")
        XCTAssertEqual(ServiceControlPresentation.dnsStartFailure("Exact startup failure", authoritativeStatus: nil), "Exact startup failure")
    }

    func testStandardPortsOffWithExactCompatibleExternalConfigurationOffersEnable() {
        let status = StandardPortsStatus(state: .installed, detail: "PF integration is present; backend router is not running", ownership: .external)
        let view = ServiceControlPresentation.standardPorts(status: status, savedOn: false)

        XCTAssertEqual(view.title, "Off · Existing PF configuration")
        XCTAssertEqual(view.action, .enable)
        XCTAssertFalse(view.canDisable)
    }

    func testStandardPortsOwnedAndOnOffersDisable() {
        let status = StandardPortsStatus(state: .healthy, ownership: .vaelen)
        let view = ServiceControlPresentation.standardPorts(status: status, savedOn: true)

        XCTAssertEqual(view.title, "Enabled")
        XCTAssertEqual(view.action, .disable)
        XCTAssertTrue(view.canDisable)
    }

    func testStandardPortsSavedOnBlockedShowsExactReasonAndRetryWithoutDisable() {
        let status = StandardPortsStatus(state: .installed, detail: "PF integration is present", ownership: .external)
        let view = ServiceControlPresentation.standardPorts(status: status, savedOn: true, blockedReason: "Existing PF integration has no active Vaelen ownership record; it was left unchanged")

        XCTAssertEqual(view.title, "Needs attention")
        XCTAssertEqual(view.detail, "Existing PF integration has no active Vaelen ownership record; it was left unchanged")
        XCTAssertEqual(view.action, .retry)
        XCTAssertFalse(view.canDisable)
    }
}
