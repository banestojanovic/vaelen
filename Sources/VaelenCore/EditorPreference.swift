import Foundation

/// Shared user preference consumed by both the native app and `val`.
/// The bundle identifier and exact application URL are persisted together so a
/// stale or moved application never silently falls back to another editor.
public struct EditorPreference: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let applicationPath: String

    public init(bundleIdentifier: String, applicationPath: String) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
    }
}

public struct EditorPreferenceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vaelen/config/editor.json")
    }

    public func load() throws -> EditorPreference? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(EditorPreference.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ preference: EditorPreference?) throws {
        if let preference {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(preference)
            try data.write(to: fileURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
