import XCTest
@testable import VaelenCore

final class M14BootstrapObservabilityTests: XCTestCase {
    private func store() throws -> SQLiteStateStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-m14-observability-").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
    }

    func testMintCarriesCorrelationAndDiagnosticsContainOnlyTokenHash() throws {
        let store = try store(); let token = "secret-token-not-for-storage"
        let authorization = try store.mintBootstrapInvocation()
        try store.recordDiagnostic(.init(correlationID: authorization.correlationID, phase: .mint, outcome: "success", detail: "minted", databasePath: store.databaseURL.path, invocationID: authorization.correlationID, tokenHash: SQLiteStateStore.safeTokenHash(token)))
        let rows = try store.diagnostics()
        XCTAssertEqual(rows.first?.correlationID, authorization.correlationID)
        XCTAssertEqual(rows.first?.tokenHash, SQLiteStateStore.safeTokenHash(token))
        XCTAssertFalse(rows.contains { $0.detail.contains(token) })
        XCTAssertFalse(try String(decoding: Data(contentsOf: store.databaseURL), as: UTF8.self).contains(token))
    }

    func testDiagnosticRetentionIsBoundedAndNonAuthoritative() throws {
        let store = try store(); let id = UUID()
        for index in 0..<300 {
            try store.recordDiagnostic(.init(correlationID: id, phase: .lifecycle, outcome: "unknown", detail: "phase-\(index)", databasePath: store.databaseURL.path))
        }
        XCTAssertEqual(try store.diagnostics(limit: 500).count, 256)
        // A breadcrumb cannot create intent or ownership authority.
        XCTAssertNil(try LifecycleStateRepository(store: store).intent())
        XCTAssertNil(try LifecycleStateRepository(store: store).ownership())
    }

    func testExternalUnknownCanRetainConcreteDiagnosticPhase() throws {
        let store = try store(); let id = UUID()
        try store.recordDiagnostic(.init(correlationID: id, phase: .platform, outcome: "unknown", detail: "ServiceManagement result boundary was interrupted", databasePath: store.databaseURL.path))
        let row = try XCTUnwrap(try store.diagnostics().first)
        XCTAssertEqual(row.phase, .platform)
        XCTAssertEqual(row.outcome, "unknown")
    }
}
