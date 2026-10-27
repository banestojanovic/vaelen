import XCTest

final class M13AuthoritySurfaceTests: XCTestCase {
    func testGUIHasNoDirectTrustMutationOrFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appSource = try String(contentsOf: root.appendingPathComponent("App/Vaelen/Vaelen/VaelenApp.swift"), encoding: .utf8)
        let modelSource = try String(contentsOf: root.appendingPathComponent("App/Vaelen/Vaelen/AppModel.swift"), encoding: .utf8)
        let source = appSource + modelSource
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

    func testAdoptionPickerUsesEligibleKindsAndSelectsAnInstanceWhenKindChanges() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Vaelen/Vaelen/VaelenApp.swift"), encoding: .utf8)
        let fixtureSource = try String(contentsOf: root.appendingPathComponent("App/Vaelen/Vaelen/AppModel.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let eligibleEntries = inventory.entries.filter { $0.eligibleForProjectBinding == true }"))
        XCTAssertTrue(source.contains("let eligibleKinds = Set(eligibleEntries.map(\\.instance.kind))"))
        XCTAssertTrue(source.contains(".onChange(of: kind) { _, selectedKind in"))
        XCTAssertTrue(source.contains("instanceName = eligibleEntries.first(where: { $0.instance.kind == selectedKind })?.instance.name.value"))
        XCTAssertTrue(fixtureSource.contains("eligibleForProjectBinding: true"))
        XCTAssertTrue(fixtureSource.contains("eligibleForProjectBinding: false"))
    }
}
