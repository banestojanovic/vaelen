import XCTest
import VaelenCore
import VaelenIPC

final class ProjectDatabaseConnectionProtocolTests: XCTestCase {
    func testReviewWireAndResultNeverContainPasswordCanary() throws {
        let canary = "password-canary-never-wire"
        let project = ProjectEnvironmentIdentity(project: Project(id: ProjectID(), name: "demo", rootPath: CanonicalPath(url: URL(fileURLWithPath: "/tmp/demo")), registrationKind: .linked, availability: .available))
        let review = ProjectDatabaseConnectionReview(confirmation: UUID(), project: project, expiresAt: Date().addingTimeInterval(30), edits: [
            .init(key: "DB_HOST", action: "replace", value: "127.0.0.1"),
            .init(key: "DB_PASSWORD", action: "replace", value: "managed password (hidden)")
        ], advisories: [])
        let result = ProjectDatabaseConnectionReviewResult(review: review)
        let encoded = String(decoding: try IPCCodec.encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains(canary))
        XCTAssertTrue(encoded.contains("managed password (hidden)"))
        let decoded = try IPCCodec.decode(ProjectDatabaseConnectionReviewResult.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded, result)
    }

    func testRecoveryRequestRoundTripsTypedActionsAndToken() throws {
        let id = UUID()
        let token = UUID()
        let request = ProjectDatabaseConnectionRecoveryRequest(selector: "project", workingDirectory: "/tmp/project", recoveryAction: .restore, recoveryID: id, confirmation: token)
        let decoded = try IPCCodec.decode(ProjectDatabaseConnectionRecoveryRequest.self, from: IPCCodec.encode(request))
        XCTAssertEqual(decoded, request)
    }
}
