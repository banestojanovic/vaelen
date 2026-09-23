import Foundation

/// Durable user choices for the existing Core-managed services. Observed
/// runtime state is deliberately not stored here.
public final class ServiceIntentStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func enabledServices() throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return Set(try JSONDecoder().decode([String: Bool].self, from: data).compactMap { $0.value ? $0.key : nil })
    }

    public func failures() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        let errorsURL = url.deletingPathExtension().appendingPathExtension("errors.json")
        guard let data = try? Data(contentsOf: errorsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    public func setFailure(_ service: String, detail: String) throws {
        try updateFailure(service, detail: detail)
    }

    public func clearFailure(_ service: String) throws {
        try updateFailure(service, detail: nil)
    }

    private func updateFailure(_ service: String, detail: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let errorsURL = url.deletingPathExtension().appendingPathExtension("errors.json")
        var errors = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: errorsURL))) ?? [:]
        if let detail { errors[service] = detail } else { errors.removeValue(forKey: service) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(errors).write(to: errorsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: errorsURL.path)
    }

    public func set(_ service: String, enabled: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        var values: [String: Bool] = [:]
        if let data = try? Data(contentsOf: url) { values = (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:] }
        values[service] = enabled
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let errorsURL = url.deletingPathExtension().appendingPathExtension("errors.json")
        var errors = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: errorsURL))) ?? [:]
        errors.removeValue(forKey: service)
        try JSONEncoder().encode(errors).write(to: errorsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: errorsURL.path)
    }
}
