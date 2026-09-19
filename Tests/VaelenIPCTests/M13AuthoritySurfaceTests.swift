import XCTest

final class M13AuthoritySurfaceTests: XCTestCase {
    func testGUIHasNoDirectTrustMutationOrFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Vaelen/Vaelen/VaelenApp.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("LocalCATrustService().trust"))
        XCTAssertFalse(source.contains("LocalCATrustService().removeTrust"))
        XCTAssertTrue(source.contains("client.tlsTrustLocalCA()"))
        XCTAssertTrue(source.contains("client.tlsRemoveLocalCATrust()"))
    }

    func testCLIUsesOnlySemanticCoreTrustOperations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/VaelenCLI/main.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("case tlsTrust"))
        XCTAssertTrue(source.contains("case tlsUntrust"))
        XCTAssertTrue(source.contains("client.tlsTrustLocalCA()"))
        XCTAssertTrue(source.contains("client.tlsRemoveLocalCATrust()"))
        XCTAssertFalse(source.contains("SecTrustSettings"))
        XCTAssertFalse(source.contains("LocalCATrustService"))
    }
}
