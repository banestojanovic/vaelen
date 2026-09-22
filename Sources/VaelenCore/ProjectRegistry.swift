import Foundation

public enum ProjectRegistryError: Error, Equatable, Sendable {
    case pathUnavailable(PathAvailability)
    case projectNotFound
    case projectNameAmbiguous
    case projectNameConflict
    case invalidName
    case parkedPathNotFound
}

public actor ProjectRegistry {
    private let paths: CanonicalPathService
    private let projects: ProjectRepository
    private let parked: ParkedPathRepository
    private let discovery: ProjectDiscovery

    public init(store: SQLiteStateStore, paths: CanonicalPathService = .init()) {
        self.paths = paths
        self.projects = ProjectRepository(store: store)
        self.parked = ParkedPathRepository(store: store)
        self.discovery = ProjectDiscovery(paths: paths)
    }

    @discardableResult
    public func link(path: URL? = nil, name: String? = nil) throws -> Project {
        try linkWithCreation(path: path, name: name).project
    }

    public func linkWithCreation(path: URL? = nil, name: String? = nil) throws -> (project: Project, created: Bool) {
        let canonical = paths.canonicalize(path ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let availability = paths.availability(of: canonical)
        guard availability == .available else { throw ProjectRegistryError.pathUnavailable(availability) }
        if let name, !isValidName(name) { throw ProjectRegistryError.invalidName }
        let records = try projects.all()
        if let existing = records.first(where: { $0.canonicalPath == canonical.string }) { return (makeProject(existing), false) }
        if let name, records.contains(where: { $0.customName == name }) { throw ProjectRegistryError.projectNameConflict }
        let record = LinkedProjectRecord(id: ProjectID(), name: name ?? canonical.url.lastPathComponent, canonicalPath: canonical.string, customName: name)
        try projects.upsert(record)
        return (makeProject(record), true)
    }

    @discardableResult
    public func link(path: String, workingDirectory: String, name: String? = nil) throws -> Project {
        try link(path: paths.canonicalize(path, relativeTo: workingDirectory).url, name: name)
    }

    public func linkWithCreation(path: String?, workingDirectory: String, name: String? = nil) throws -> (project: Project, created: Bool) {
        try linkWithCreation(path: path.map { paths.canonicalize($0, relativeTo: workingDirectory).url }, name: name)
    }

    public func unlink(path: URL? = nil) throws {
        let canonical = paths.canonicalize(path ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        guard try projects.all().contains(where: { $0.canonicalPath == canonical.string }) else { throw ProjectRegistryError.projectNotFound }
        try projects.remove(canonicalPath: canonical.string)
    }

    public func unlink(path: String, workingDirectory: String) throws {
        try unlink(path: paths.canonicalize(path, relativeTo: workingDirectory).url)
    }

    public func unlink(name: String) throws {
        let matches = try projects.all().filter { $0.name == name || $0.customName == name }
        guard matches.count == 1, let match = matches.first else {
            if matches.count > 1 { throw ProjectRegistryError.projectNameAmbiguous }
            throw ProjectRegistryError.projectNotFound
        }
        try projects.remove(canonicalPath: match.canonicalPath)
    }

    @discardableResult
    public func park(path: URL? = nil) throws -> ParkedPath {
        try parkWithCreation(path: path).path
    }

    public func parkWithCreation(path: URL? = nil) throws -> (path: ParkedPath, created: Bool) {
        let canonical = paths.canonicalize(path ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let availability = paths.availability(of: canonical)
        guard availability == .available else { throw ProjectRegistryError.pathUnavailable(availability) }
        let existing = try parked.all().first(where: { $0.canonicalPath == canonical.string })
        let record = existing ?? ParkedPathRecord(id: ParkedPathID(), canonicalPath: canonical.string)
        if existing == nil { try parked.upsert(record) }
        return (makeParked(record), existing == nil)
    }

    @discardableResult
    public func park(path: String, workingDirectory: String) throws -> ParkedPath {
        try park(path: paths.canonicalize(path, relativeTo: workingDirectory).url)
    }

    public func parkWithCreation(path: String?, workingDirectory: String) throws -> (path: ParkedPath, created: Bool) {
        try parkWithCreation(path: path.map { paths.canonicalize($0, relativeTo: workingDirectory).url })
    }

    public func unpark(path: URL? = nil) throws {
        let canonical = paths.canonicalize(path ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        guard try parked.all().contains(where: { $0.canonicalPath == canonical.string }) else { throw ProjectRegistryError.parkedPathNotFound }
        try parked.remove(canonicalPath: canonical.string)
    }

    public func unpark(path: String, workingDirectory: String) throws {
        try unpark(path: paths.canonicalize(path, relativeTo: workingDirectory).url)
    }

    public func linkedProjects() throws -> [Project] { try projects.all().map(makeProject) }
    public func linkedProject(id: ProjectID) throws -> Project? { try linkedProjects().first { $0.id == id } }

    public func phpOverride(for project: ProjectID) throws -> String? { try projects.phpOverride(for: project) }
    public func setPHPOverride(_ version: String?, for project: ProjectID) throws { try projects.setPHPOverride(version, for: project) }
    public func parkedPaths() throws -> [ParkedPath] { try parked.all().map(makeParked) }

    public func projectsList() throws -> [Project] {
        let linked = try linkedProjects()
        let discovered = discovery.discover(under: try parkedPaths())
        let discoveredByPath = Dictionary(uniqueKeysWithValues: discovered.map { ($0.rootPath, $0) })
        let linkedPaths = Set(linked.map(\.rootPath))
        let presentedLinks = linked.map { project in
            guard let observation = discoveredByPath[project.rootPath] else { return project }
            return Project(
                id: project.id,
                name: project.name,
                rootPath: project.rootPath,
                registrationKind: .linked,
                availability: project.availability,
                detectedFramework: observation.detectedFramework,
                visibilitySources: [.explicitLink, .parkedFolder]
            )
        }
        return (presentedLinks + discovered.filter { !linkedPaths.contains($0.rootPath) })
            .sorted { $0.rootPath.string < $1.rootPath.string }
    }

    private func makeProject(_ record: LinkedProjectRecord) -> Project {
        let path = paths.canonicalize(record.canonicalPath)
        return Project(id: record.id, name: record.name, rootPath: path, registrationKind: .linked, availability: paths.availability(of: path), visibilitySources: [.explicitLink])
    }

    private func makeParked(_ record: ParkedPathRecord) -> ParkedPath {
        let path = paths.canonicalize(record.canonicalPath)
        return ParkedPath(id: record.id, rootPath: path, availability: paths.availability(of: path))
    }

    private func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}
