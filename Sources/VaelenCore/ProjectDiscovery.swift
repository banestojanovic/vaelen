import Foundation

public enum DirectChildProjectScanError: Error, Sendable {
    case parentUnavailable(String, PathAvailability)
    case enumerationFailed(String, String)
    case childUnavailable(String, PathAvailability)
}

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

    /// Complete, direct-child-only scan for park-owned routing. Unlike the
    /// presentation discovery API, failures are surfaced so callers never
    /// mistake an incomplete scan for proof that prior children disappeared.
    public func discoverDirectChildren(under parkedPath: ParkedPath) throws -> [Project] {
        guard parkedPath.availability == .available,
              paths.availability(of: parkedPath.rootPath) == .available else {
            throw DirectChildProjectScanError.parentUnavailable(parkedPath.rootPath.string, parkedPath.availability)
        }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(at: parkedPath.rootPath.url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        } catch {
            throw DirectChildProjectScanError.enumerationFailed(parkedPath.rootPath.string, String(describing: error))
        }
        var projects = [Project]()
        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard !shouldIgnore(child.lastPathComponent) else { continue }
            let values: URLResourceValues
            do { values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
            catch { throw DirectChildProjectScanError.enumerationFailed(child.path, String(describing: error)) }
            guard values.isSymbolicLink != true, values.isDirectory == true else { continue }
            let canonical = paths.canonicalize(child)
            let availability = paths.availability(of: canonical)
            guard availability == .available, fileManager.isReadableFile(atPath: canonical.string) else {
                throw DirectChildProjectScanError.childUnavailable(canonical.string, availability == .available ? .unreadable : availability)
            }
            let inspection = detector.inspect(root: canonical.url)
            guard detector.isRecognizedProject(inspection) else { continue }
            projects.append(Project(id: nil, name: canonical.url.lastPathComponent, rootPath: canonical, registrationKind: .discovered, availability: .available, detectedFramework: inspection.framework, visibilitySources: [.parkedFolder]))
        }
        return projects
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
