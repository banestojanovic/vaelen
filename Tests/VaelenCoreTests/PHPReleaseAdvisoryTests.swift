import XCTest
@testable import VaelenCore

final class PHPReleaseAdvisoryTests: XCTestCase {
    private let payload = Data(#"{"version":"8.4.27","date":"21 Oct 2026","tags":["security"],"announcement":true}"#.utf8)

    func testOfficialReleaseValidation() throws {
        let release = try PHPReleaseAdvisory.parse(payload, family: "8.4")
        XCTAssertEqual(release.version, "8.4.27")
        XCTAssertTrue(release.isSecurity)
        XCTAssertNoThrow(try PHPReleaseAdvisory.parse(Data(#"{"version":"8.4.26","date":"7 Oct 2026","tags":[]}"#.utf8), family: "8.4"))
        XCTAssertThrowsError(try PHPReleaseAdvisory.parse(payload, family: "8.3"))
        for invalid in [#"{"version":"8.4.27RC1","date":"21 Oct 2026","tags":[]}"#, #"{"version":"8.4.27","date":"impossible","tags":[]}"#, #"{"version":"8.4.27","date":"21 Oct 2026","tags":[1]}"#] {
            XCTAssertThrowsError(try PHPReleaseAdvisory.parse(Data(invalid.utf8), family: "8.4"))
        }
    }

    func testOfficialCalendarDateDoesNotShiftWithLocalTimezone() throws {
        let release = try PHPReleaseAdvisory.parse(payload, family: "8.4")
        let prior = NSTimeZone.default
        defer { NSTimeZone.default = prior }
        for zone in ["America/Los_Angeles", "Pacific/Honolulu", "Asia/Tokyo", "UTC"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            XCTAssertEqual(release.formattedReleaseDate(locale: Locale(identifier: "en_US")), "Oct 21, 2026", zone)
        }
    }

    func testConcurrentChecksUseSnapshotWithoutWaitingForInFlightFetch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let store = PHPReleaseAdvisoryStore(directory: directory, fetch: { _ in
            entered.signal()
            _ = finish.wait(timeout: .now() + 5)
            return self.payload
        })
        DispatchQueue.global().async {
            store.refresh(families: ["8.4"], force: true)
            completed.signal()
        }
        defer { finish.signal(); _ = completed.wait(timeout: .now() + 5) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            store.refresh(families: ["8.4"], force: false)
            store.refresh(families: ["8.4"], force: true)
            returned.signal()
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 1), .success)
        XCTAssertNil(store.snapshot(families: ["8.4"]).first?.release)
    }

    func testAdvisoryAndPackageTargetsAreIndependent() throws {
        let release = try PHPReleaseAdvisory.parse(payload, family: "8.4")
        let source = PHPReleaseSourceStatus(family: "8.4", release: release)
        let installed = [PHPRuntimeVersion(version: "8.4.24")]
        let advisoryOnly = PHPUpdateReport.project(installed: installed, available: [], sources: [source])
        XCTAssertEqual(advisoryOnly.first?.upstreamRelease?.version, "8.4.27")
        XCTAssertNil(advisoryOnly.first?.packageVersion)
        XCTAssertEqual(advisoryOnly.first?.upstreamPackageAvailable, false)
        let both = PHPUpdateReport.project(installed: installed, available: ["8.4.26"], sources: [source])
        XCTAssertEqual(both.first?.packageVersion, "8.4.26")
        XCTAssertEqual(both.first?.upstreamRelease?.version, "8.4.27")
        XCTAssertTrue(PHPUpdateReport.project(installed: [PHPRuntimeVersion(version: "8.4.27")], available: [], sources: [source]).first?.upstreamRelease == nil)
    }

    func testSnapshotDoesNotFetch() {
        let store = PHPReleaseAdvisoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), fetch: { _ in
            XCTFail("Snapshots must not fetch official releases")
            return Data()
        })
        XCTAssertNil(store.snapshot(families: ["8.4"]).first?.release)
    }

    func testCatalogDecodesOlderCoreWithoutAdvisoryReports() throws {
        let old = Data(#"{"availableVersions":[],"installedVersions":[],"runningVersions":[],"availableVersionsKnown":true,"advertisedUnverifiedVersions":[]}"#.utf8)
        let catalog = try JSONDecoder().decode(PHPRuntimeCatalog.self, from: old)
        XCTAssertNil(catalog.updateReports)
    }

    func testFailedRefreshRetainsLastGoodPerFamilyCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let success = PHPReleaseAdvisoryStore(directory: directory, fetch: { _ in self.payload })
        success.refresh(families: ["8.4"], force: true)
        let failed = PHPReleaseAdvisoryStore(directory: directory, fetch: { _ in throw URLError(.notConnectedToInternet) })
        failed.refresh(families: ["8.4", "8.3"], force: true)
        let statuses = failed.snapshot(families: ["8.4", "8.3"])
        XCTAssertEqual(statuses.first { $0.family == "8.4" }?.release?.version, "8.4.27")
        XCTAssertNotNil(statuses.first { $0.family == "8.4" }?.error)
        XCTAssertNil(statuses.first { $0.family == "8.3" }?.release)
    }
}
