import XCTest
@testable import VaelenIPC

final class CoreServiceReadinessTests: XCTestCase {
    func testPendingStatusReadsRemainChecking() {
        XCTAssertEqual(
            CoreServiceReadiness.resolve(serviceIssues: [:], requiredReadCount: 7, completedReadCount: 6, successfulReadCount: 6),
            .checking
        )
    }

    func testReportedDegradedServiceNeedsAttentionWithoutWaitingForOtherReads() {
        XCTAssertEqual(
            CoreServiceReadiness.resolve(serviceIssues: ["mysql": "startup failed"], requiredReadCount: 7, completedReadCount: 1, successfulReadCount: 1),
            .attention
        )
    }

    func testFailedRequiredReadIsUnavailableAfterAllReadsComplete() {
        XCTAssertEqual(
            CoreServiceReadiness.resolve(serviceIssues: [:], requiredReadCount: 7, completedReadCount: 7, successfulReadCount: 6),
            .unavailable
        )
    }

    func testTimeoutIsUnavailableEvenWhileReadsArePending() {
        XCTAssertEqual(
            CoreServiceReadiness.resolve(serviceIssues: [:], requiredReadCount: 7, completedReadCount: 2, successfulReadCount: 2, timedOut: true),
            .unavailable
        )
    }

    func testReadyRequiresEveryRequiredReadToSucceed() {
        XCTAssertEqual(
            CoreServiceReadiness.resolve(serviceIssues: [:], requiredReadCount: 7, completedReadCount: 7, successfulReadCount: 7),
            .ready
        )
    }
}
