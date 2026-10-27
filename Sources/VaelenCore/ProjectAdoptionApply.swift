import Foundation
import Darwin
import Yams

public enum ProjectAdoptionApplyError: Error, Equatable, Sendable {
    case unsupportedManifest
    case manifestExists
    case manifestChanged
    case invalidSpec(String)
    case writeFailed(String)
}

public enum ProjectAdoptionManifestWriter {
    @discardableResult
    public static func create(spec: ProjectEnvironmentSpec, at projectPath: String, expectedManifest: Data?) throws -> Data {
        guard spec.version == 2 else { throw ProjectAdoptionApplyError.unsupportedManifest }
        let directory = URL(fileURLWithPath: projectPath, isDirectory: true)
        let target = directory.appendingPathComponent("vaelen.yml")
        if let expectedManifest {
            guard FileManager.default.fileExists(atPath: target.path), (try? Data(contentsOf: target)) == expectedManifest else { throw ProjectAdoptionApplyError.manifestChanged }
            throw ProjectAdoptionApplyError.manifestExists
        }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ProjectAdoptionApplyError.manifestChanged }
        let encoded: String
        do { encoded = try YAMLEncoder().encode(ProjectEnvironmentV2Manifest(spec: spec)) + "\n" }
        catch { throw ProjectAdoptionApplyError.invalidSpec(error.localizedDescription) }
        let temporary = directory.appendingPathComponent(".vaelen-adopt-\(UUID().uuidString).tmp")
        do {
            try Data(encoded.utf8).write(to: temporary, options: .atomic)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            guard link(temporary.path, target.path) == 0 else {
                if errno == EEXIST { throw ProjectAdoptionApplyError.manifestChanged }
                throw ProjectAdoptionApplyError.writeFailed(String(cString: strerror(errno)))
            }
            try FileManager.default.removeItem(at: temporary)
            return Data(encoded.utf8)
        } catch let error as ProjectAdoptionApplyError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ProjectAdoptionApplyError.writeFailed(error.localizedDescription)
        }
    }
}

private struct ProjectEnvironmentV2Manifest: Encodable {
    struct Web: Encodable { let host: String?; let documentRoot: String?; let secure: Bool?; let createRoute: Bool }
    struct Service: Encodable { let kind: String; let instance: String; let version: String? }
    let version: Int
    let php: String?
    let node: String?
    let web: Web?
    let services: [String: Service]

    init(spec: ProjectEnvironmentSpec) {
        version = 2
        php = spec.php?.value
        node = spec.node?.value
        web = spec.web.map { Web(host: $0.host, documentRoot: $0.documentRoot, secure: $0.secure, createRoute: $0.createRoute) }
        services = Dictionary(uniqueKeysWithValues: spec.services.map { binding in
            (binding.alias.value, Service(kind: binding.kind.rawValue, instance: binding.instance.value, version: binding.version))
        })
    }
}
