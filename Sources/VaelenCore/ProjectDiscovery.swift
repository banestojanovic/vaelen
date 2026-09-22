import Foundation

public struct ProjectDiscovery: @unchecked Sendable {
    public static let maximumDepth = 2
    public static let ignoredDirectoryNames: Set<String> = [
        ".git", "node_modules", "vendor", ".build", "deriveddata", "pods", ".cache", "tmp", "temp"
    ]

    private let paths: CanonicalPathService
    private let fileManager: FileManager
    private let detector: ProjectFrameworkDetector

    public init(paths: CanonicalPathService = .init(), fileManager: FileManager = .default, detector: ProjectFrameworkDetector? = nil) {
        self.paths = paths
        self.fileManager = fileManager
        self.detector = detector ?? ProjectFrameworkDetector(fileManager: fileManager)
    }

    public func discover(under parkedPaths: [ParkedPath]) -> [Project] {
        var result = [CanonicalPath: Project]()
        var inspected = Set<CanonicalPath>()
        for parked in parkedPaths where parked.availability == .available {
            inspectChildren(of: parked.rootPath.url, depth: 1, inspected: &inspected, result: &result)
        }
        return result.values.sorted { $0.rootPath.string < $1.rootPath.string }
    }

    private func inspectChildren(of directory: URL, depth: Int, inspected: inout Set<CanonicalPath>, result: inout [CanonicalPath: Project]) {
        guard depth <= Self.maximumDepth,
              let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        for child in children.sorted(by: { $0.path < $1.path }) {
            guard !shouldIgnore(child.lastPathComponent),
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true || values.isSymbolicLink == true else { continue }
            let canonical = paths.canonicalize(child)
            guard paths.availability(of: canonical) == .available else { continue }

            let inspection = detector.inspect(root: canonical.url)
            if detector.isRecognizedProject(inspection) {
                result[canonical] = Project(
                    id: nil,
                    name: canonical.url.lastPathComponent,
                    rootPath: canonical,
                    registrationKind: .discovered,
                    availability: .available,
                    detectedFramework: inspection.framework,
                    visibilitySources: [.parkedFolder]
                )
                inspected.insert(canonical)
                continue
            }

            guard values.isSymbolicLink != true, inspected.insert(canonical).inserted else { continue }
            inspectChildren(of: canonical.url, depth: depth + 1, inspected: &inspected, result: &result)
        }
    }

    private func shouldIgnore(_ name: String) -> Bool {
        name.hasPrefix(".") || Self.ignoredDirectoryNames.contains(name.lowercased())
    }
}
