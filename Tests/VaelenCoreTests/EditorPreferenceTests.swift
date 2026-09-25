import XCTest
@testable import VaelenCore

final class EditorPreferenceTests: XCTestCase {
    func testPreferenceRoundTripsAndCanBeCleared() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vaelen-editor-preference-\(UUID().uuidString)")
        let store = EditorPreferenceStore(fileURL: root.appendingPathComponent("config/editor.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try store.load())
        let preference = EditorPreference(bundleIdentifier: "com.example.Editor", applicationPath: "/Applications/Editor.app")
        try store.save(preference)
        XCTAssertEqual(try store.load(), preference)
        try store.save(nil)
        XCTAssertNil(try store.load())
    }
}
