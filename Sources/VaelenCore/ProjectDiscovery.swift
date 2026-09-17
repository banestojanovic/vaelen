import Foundation

public struct ProjectDiscovery: @unchecked Sendable {
    private let paths: CanonicalPathService
    private let fileManager: FileManager
    public init(paths: CanonicalPathService = .init(), fileManager: FileManager = .default) { self.paths = paths; self.fileManager = fileManager }

    public func discover(under parkedPaths: [ParkedPath]) -> [Project] {
        var result = [Project](), seen = Set<CanonicalPath>()
        for parked in parkedPaths where parked.availability == .available {
            guard let children = try? fileManager.contentsOfDirectory(at: parked.rootPath.url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for child in children.sorted(by: { $0.path < $1.path }) {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let path = paths.canonicalize(child)
                guard seen.insert(path).inserted else { continue }
                result.append(Project(id: nil, name: child.lastPathComponent, rootPath: path, registrationKind: .discovered, availability: .available))
            }
        }
        return result
    }
}
