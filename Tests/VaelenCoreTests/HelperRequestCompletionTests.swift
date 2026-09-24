import XCTest
@testable import VaelenCore

final class HelperRequestCompletionTests: XCTestCase {
    func testFirstTerminalXPCResultWinsAndLaterFailureDoesNotResumeTwice() async throws {
        let completionTask = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let completion = HelperRequestCompletion(continuation)
                completion.succeed(Data([1, 2, 3]))
                completion.fail(DNSCapabilityError.privilegeUnavailable)
                completion.succeed(Data([4]))
            }
        }

        let result = try await completionTask.value
        XCTAssertEqual(result, Data([1, 2, 3]))
    }
}
