import Foundation

public enum RouteAssociationState: String, Codable, Equatable, Sendable {
    case durable
    case safelyAssociable
    case inferred
    case ambiguous
    case orphaned
    case conflicted
    case none
}

public enum RouteMutationAuthority: String, Codable, Equatable, Sendable {
    case allowed
    case blocked
}

public struct RouteAssociationEvidence: Codable, Equatable, Sendable {
    public let projectID: Bool
    public let projectPath: Bool
    public let documentRoot: Bool

    public init(projectID: Bool = false, projectPath: Bool = false, documentRoot: Bool = false) {
        self.projectID = projectID
        self.projectPath = projectPath
        self.documentRoot = documentRoot
    }

    public var categories: [String] {
        var result = [String]()
        if projectID { result.append("projectID") }
        if projectPath { result.append("projectPath") }
        if documentRoot { result.append("documentRoot") }
        return result
    }
}

public struct RouteAssociationResult: Codable, Equatable, Sendable {
    public let state: RouteAssociationState
    public let evidence: RouteAssociationEvidence
    public let mutationAuthority: RouteMutationAuthority
    public let mutationAuthorityReason: String
    public let routeIDs: [RouteID]
    public let selectedRouteID: RouteID?

    public init(state: RouteAssociationState, evidence: RouteAssociationEvidence = .init(), mutationAuthority: RouteMutationAuthority, mutationAuthorityReason: String, routeIDs: [RouteID] = [], selectedRouteID: RouteID? = nil) {
        self.state = state
        self.evidence = evidence
        self.mutationAuthority = mutationAuthority
        self.mutationAuthorityReason = mutationAuthorityReason
        self.routeIDs = routeIDs
        self.selectedRouteID = selectedRouteID
    }
}

public struct RouteAssociationClassifier: Sendable {
    private let paths = CanonicalPathService()

    public init() {}

    public func classify(project: Project, framework: ProjectFrameworkInspection, routes: [RouteIntent], registeredProjects: [Project] = []) -> RouteAssociationResult {
        let projects = registeredProjects.isEmpty ? [project] : registeredProjects
        let projectPath = paths.canonicalize(project.rootPath.string).string
        let currentID = project.id?.rawValue
        let expectedRoot = framework.suggestedDocumentRoot.map { paths.canonicalize(URL(fileURLWithPath: projectPath).appendingPathComponent($0)).string }
        let knownProjectIDs = Set(projects.compactMap { $0.id?.rawValue })
        let duplicateHostnames = duplicateHostnames(in: routes)

        if let currentID {
            let durable = routes.filter { $0.projectID == currentID }
            if !durable.isEmpty {
                let rootConflict = durable.contains { intent in
                    guard let expectedRoot else { return false }
                    return routeDocumentRoot(intent.route).map { paths.canonicalize($0).string != expectedRoot } ?? true
                }
                if rootConflict || durable.contains(where: { duplicateHostnames.contains($0.route.hostname.lowercased()) }) {
                    return .init(state: .conflicted, evidence: .init(projectID: true), mutationAuthority: .blocked, mutationAuthorityReason: rootConflict ? "The durable project association disagrees with the validated document root." : "The route hostname conflicts with another persisted route.", routeIDs: durable.map(\.route.id))
                }
                let selected = durable.count == 1 ? durable[0].route.id : nil
                let pathExact = durable.contains { intent in
                    guard let path = intent.projectPath else { return false }
                    return paths.canonicalize(path).string == projectPath
                }
                let pathConflict = durable.contains { intent in
                    guard let path = intent.projectPath else { return false }
                    let canonical = paths.canonicalize(path).string
                    return canonical != projectPath && projects.contains { $0.id?.rawValue != currentID && $0.rootPath.string == canonical }
                }
                if pathConflict {
                    return .init(state: .conflicted, evidence: .init(projectID: true), mutationAuthority: .blocked, mutationAuthorityReason: "The durable project ID disagrees with a path belonging to another registered project.", routeIDs: durable.map(\.route.id))
                }
                let reason = pathExact || durable.allSatisfy { $0.projectPath == nil } ? "The route has an exact registered ProjectID." : "The route has an exact registered ProjectID; its stored project path is stale metadata."
                return .init(state: .durable, evidence: .init(projectID: true, projectPath: pathExact), mutationAuthority: .allowed, mutationAuthorityReason: reason, routeIDs: durable.map(\.route.id), selectedRouteID: selected)
            }
        }

        let relatedRoutes = routes.filter { intent in
            guard intent.projectID != nil else { return false }
            let referencesCurrent = intent.projectID == currentID
            guard !referencesCurrent else { return false }
            let pathMatches = intent.projectPath.map { paths.canonicalize($0).string == projectPath } ?? false
            let rootMatches = expectedRoot != nil && routeDocumentRoot(intent.route).map { paths.canonicalize($0).string == expectedRoot } == true
            return pathMatches || rootMatches
        }
        if let orphan = relatedRoutes.first(where: { !knownProjectIDs.contains($0.projectID!) }) {
            return .init(state: .orphaned, evidence: .init(projectPath: orphan.projectPath.map { paths.canonicalize($0).string == projectPath } ?? false, documentRoot: expectedRoot != nil && routeDocumentRoot(orphan.route).map { paths.canonicalize($0).string == expectedRoot } == true), mutationAuthority: .blocked, mutationAuthorityReason: "The route references a project that is no longer registered.", routeIDs: relatedRoutes.map(\.route.id))
        }
        if !relatedRoutes.isEmpty {
            return .init(state: .conflicted, mutationAuthority: .blocked, mutationAuthorityReason: "The route evidence points to another registered project.", routeIDs: relatedRoutes.map(\.route.id))
        }

        let pathCandidates = routes.filter { intent in
            intent.projectID == nil && intent.projectPath.map { paths.canonicalize($0).string == projectPath } == true
        }
        let rootCandidates = routes.filter { intent in
            guard intent.projectID == nil, let expectedRoot else { return false }
            return routeDocumentRoot(intent.route).map { paths.canonicalize($0).string == expectedRoot } == true
        }
        let candidateIDs = Set((pathCandidates + rootCandidates).map(\.route.id))
        guard !candidateIDs.isEmpty else {
            return .init(state: .none, mutationAuthority: .blocked, mutationAuthorityReason: "No route association evidence was found.")
        }
        if pathCandidates.count > 1 || rootCandidates.count > 1 || candidateIDs.count > 1 {
            return .init(state: .ambiguous, evidence: .init(projectPath: !pathCandidates.isEmpty, documentRoot: !rootCandidates.isEmpty), mutationAuthority: .blocked, mutationAuthorityReason: "Multiple persisted routes match the project evidence.", routeIDs: Array(candidateIDs).sorted { $0.description < $1.description })
        }

        guard let candidate = routes.first(where: { $0.route.id == candidateIDs.first! }) else {
            return .init(state: .none, mutationAuthority: .blocked, mutationAuthorityReason: "The route association candidate could not be resolved.")
        }
        let pathMatch = pathCandidates.contains { $0.route.id == candidate.route.id }
        let rootMatch = rootCandidates.contains { $0.route.id == candidate.route.id }
        let uniqueHostname = !duplicateHostnames.contains(candidate.route.hostname.lowercased())
        if !uniqueHostname {
            return .init(state: .conflicted, evidence: .init(projectPath: pathMatch, documentRoot: rootMatch), mutationAuthority: .blocked, mutationAuthorityReason: "The route hostname conflicts with another persisted route.", routeIDs: [candidate.route.id])
        }
        let stronglyCorroborated = uniqueHostname && ((pathMatch && rootMatch) || (rootMatch && framework.confidence == .high))
        let evidence = RouteAssociationEvidence(projectPath: pathMatch, documentRoot: rootMatch)
        if stronglyCorroborated {
            return .init(state: .safelyAssociable, evidence: evidence, mutationAuthority: .blocked, mutationAuthorityReason: "The unique route has independently corroborated legacy project evidence; explicit association is required.", routeIDs: [candidate.route.id], selectedRouteID: candidate.route.id)
        }
        return .init(state: .inferred, evidence: evidence, mutationAuthority: .blocked, mutationAuthorityReason: "The route can be observed through legacy evidence but that evidence is not mutation authority.", routeIDs: [candidate.route.id], selectedRouteID: candidate.route.id)
    }

    private func duplicateHostnames(in routes: [RouteIntent]) -> Set<String> {
        var counts = [String: Int]()
        for route in routes { counts[route.route.hostname.lowercased(), default: 0] += 1 }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    private func routeDocumentRoot(_ route: Route) -> String? {
        switch route.target {
        case .fastCGI(_, let root), .staticFiles(let root): return root
        case .http: return nil
        }
    }
}
