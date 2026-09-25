import Foundation
import VaelenCore
import VaelenIPC

enum SiteCommandError: Error, CustomStringConvertible {
    case projectNotFound(String)
    case projectAmbiguous(String, [String])
    case routeNotFound(String)
    case routeMissing(String)
    case routeAmbiguous([String])

    var description: String {
        switch self {
        case .projectNotFound(let value): return "No project matches ‘\(value)’. Use a project name or path from val links/val parked."
        case .projectAmbiguous(let value, let paths): return "Project ‘\(value)’ is ambiguous:\n\(paths.map { "  \($0)" }.joined(separator: "\n"))\nSelect a full project path."
        case .routeNotFound(let value): return "No configured site route matches ‘\(value)’."
        case .routeMissing(let value): return "No configured site route belongs to ‘\(value)’."
        case .routeAmbiguous(let hosts): return "More than one site route matches this project: \(hosts.sorted().joined(separator: ", ")). Select a hostname."
        }
    }
}

struct SiteListItem: Codable, Equatable {
    let hostname: String
    let url: String
    let target: String
    let tls: String
    let configured: Bool
    let caddyRouteObserved: Bool?
    let caddyObservationState: String
    let project: String?
    let projectPath: String?
    let projectAvailability: String
    let registration: String?
}

struct ParkedSitesEnvelope: Encodable {
    let sites: [ProjectWire]
    let unavailableFolders: [ParkedPathWire]
}

struct SitesEnvelope: Encodable { let sites: [SiteListItem] }
struct SiteDriverRoute: Codable, Equatable {
    let hostname: String
    let target: String
    let tls: String
    let caddyRouteObserved: Bool?
    let caddyObservationState: String
}
struct SiteDriverEnvelope: Encodable {
    let project: String
    let path: String
    let detectedFramework: String
    let frameworkConfidence: String
    let evidence: [String]
    let configuredRouteCount: Int
    let configuredRoutes: [SiteDriverRoute]
}

func discoveredParkedProjects(_ projects: [ProjectWire]) -> [ProjectWire] {
    projects.filter { ($0.sources ?? []).contains(ProjectVisibilitySource.parkedFolder.rawValue) }
}

func parkedSitesHumanOutput(_ projects: [ProjectWire], folders: [ParkedPathWire]) -> String {
    func display(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
    let rows = projects.map { project -> [String] in
        let parent = folders.filter { project.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }.max { $0.path.count < $1.path.count }?.path ?? "—"
        let provenance = project.registration == ProjectRegistrationKind.linked.rawValue ? "Linked · parked" : "Discovered"
        return [project.name, display(project.path), project.detectedFramework ?? "Unknown", provenance, display(parent)]
    }
    var output = HumanOutput.heading("Sites inside parked folders") + "\n"
    output += HumanOutput.list(rows, headers: ["Site", "Path", "Framework", "Relationship", "Parked folder"], empty: "No sites discovered in available parked folders.")
    return output
}

func siteDriverRoutes(project: ProjectWire, routeIntents: [RouteIntent], observedRoutes: [Route]?, unavailableReason: String?) -> [SiteDriverRoute] {
    matchingRoutes(for: project, among: routeIntents).map { intent in
        let caddyMatch = observedRoutes.map { routes in routes.contains { routeConfigurationMatches($0, configured: intent.route) } }
        let sameHostDifferentConfiguration = observedRoutes?.contains { $0.hostname.caseInsensitiveCompare(intent.route.hostname) == .orderedSame && !routeConfigurationMatches($0, configured: intent.route) } ?? false
        let state: String
        if caddyMatch == true { state = "exact-route-observed" }
        else if caddyMatch == false, sameHostDifferentConfiguration { state = "hostname-observed-with-different-route" }
        else if caddyMatch == false { state = "exact-route-not-observed" }
        else { state = unavailableReason ?? "caddy-observation-unavailable" }
        return SiteDriverRoute(hostname: intent.route.hostname, target: routeTargetDescription(intent.route.target), tls: intent.route.tls.rawValue, caddyRouteObserved: caddyMatch, caddyObservationState: state)
    }
}

func routeTargetDescription(_ target: RouteTarget) -> String {
    switch target {
    case .fastCGI(let socket, let root): return "PHP FastCGI · document root \(root) · socket \(socket)"
    case .staticFiles(let root): return "Static files · document root \(root)"
    case .http(let host, let port): return "HTTP proxy · \(host):\(port)"
    }
}

func caddyObservationLabel(_ state: String) -> String {
    switch state {
    case "exact-route-observed": return "Exact route observed"
    case "exact-route-not-observed": return "Exact route not observed"
    case "hostname-observed-with-different-route": return "Hostname observed with different route"
    case "caddy-observation-unavailable": return "Caddy observation unavailable"
    default: return state
    }
}

func selectedProject(_ selector: String?, projects: [ProjectWire], workingDirectory: String) throws -> ProjectWire {
    let canonical = CanonicalPathService()
    let normalizedCWD = canonical.canonicalize(workingDirectory).string
    if let selector, !selector.isEmpty {
        if let id = UUID(uuidString: selector), let project = projects.first(where: { $0.id == id }) { return project }
        if selector.hasPrefix("/") || selector.hasPrefix("~") || selector.contains("/") {
            let path = canonical.canonicalize(selector, relativeTo: workingDirectory).string
            if let project = projects.first(where: { canonical.canonicalize($0.path).string == path }) { return project }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw SiteCommandError.projectNotFound(selector) }
            return ProjectWire(id: nil, name: URL(fileURLWithPath: path).lastPathComponent, path: path, registration: "unlinked", availability: canonical.availability(of: canonical.canonicalize(path)).rawValue)
        }
        let matches = projects.filter { $0.name.localizedCaseInsensitiveCompare(selector) == .orderedSame }
        if matches.count > 1 { throw SiteCommandError.projectAmbiguous(selector, matches.map(\.path).sorted()) }
        if let match = matches.first { return match }
        throw SiteCommandError.projectNotFound(selector)
    }
    guard let project = projects.first(where: { canonical.canonicalize($0.path).string == normalizedCWD }) else {
        throw SiteCommandError.projectNotFound(normalizedCWD)
    }
    return project
}

func matchingRoutes(for project: ProjectWire, among allRoutes: [RouteIntent]) -> [RouteIntent] {
    let canonical = CanonicalPathService()
    return allRoutes.filter { route in
        if let projectID = project.id, route.projectID == projectID { return true }
        if let routePath = route.projectPath,
           canonical.canonicalize(routePath).string == canonical.canonicalize(project.path).string { return true }
        let root: String
        switch route.route.target {
        case .fastCGI(_, let documentRoot), .staticFiles(let documentRoot):
            let url = URL(fileURLWithPath: documentRoot).standardizedFileURL
            root = url.lastPathComponent == "public" ? url.deletingLastPathComponent().path : url.path
        case .http: return false
        }
        return canonical.canonicalize(root).string == canonical.canonicalize(project.path).string
    }
}

func selectedRoute(_ selector: String?, projects: [ProjectWire], routes: [RouteIntent], workingDirectory: String) throws -> RouteIntent {
    if let selector, let hostname = routes.first(where: { $0.route.hostname.caseInsensitiveCompare(selector) == .orderedSame })?.route.hostname,
       let route = routes.first(where: { $0.route.hostname == hostname }) { return route }
    guard let selector else {
        do { return try selectSiteRoute(routes, hostname: nil, workingDirectory: workingDirectory) }
        catch RouteSelectionError.noRouteForDirectory { throw SiteCommandError.routeMissing(workingDirectory) }
        catch RouteSelectionError.ambiguous(let hosts) { throw SiteCommandError.routeAmbiguous(hosts) }
        catch RouteSelectionError.notFound(let hostname) { throw SiteCommandError.routeNotFound(hostname) }
    }
    let project = try selectedProject(selector, projects: projects, workingDirectory: workingDirectory)
    let matches = matchingRoutes(for: project, among: routes)
    guard !matches.isEmpty else { throw SiteCommandError.routeMissing(project.path) }
    guard matches.count == 1 else { throw SiteCommandError.routeAmbiguous(matches.map { $0.route.hostname }) }
    return matches[0]
}

func siteURL(for route: Route) -> URL? {
    var components = URLComponents()
    components.scheme = route.tls == .local ? "https" : "http"
    components.host = route.hostname
    return components.url
}

func routeConfigurationMatches(_ observed: Route, configured: Route) -> Bool {
    observed.hostname.caseInsensitiveCompare(configured.hostname) == .orderedSame
        && observed.target == configured.target
        && observed.tls == configured.tls
}

func externalOpenArguments(bundleIdentifier: String?, url: URL) -> [String] {
    if let bundleIdentifier { return ["-b", bundleIdentifier, url.absoluteString] }
    return [url.absoluteString]
}

func launchExternalURL(_ url: URL, bundleIdentifier: String? = nil) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = externalOpenArguments(bundleIdentifier: bundleIdentifier, url: url)
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CLIError.message("macOS could not open \(url.absoluteString). Check that the selected application is available.")
    }
}

func configuredSiteItems(routes: [RouteIntent], projects: [ProjectWire], observedRoutes: [Route]?, unavailableReason: String?) -> [SiteListItem] {
    let paths = CanonicalPathService()
    return routes.sorted { $0.route.hostname.localizedStandardCompare($1.route.hostname) == .orderedAscending }.map { intent in
        let path: String?
        if let projectPath = intent.projectPath { path = paths.canonicalize(projectPath).string }
        else if let projectID = intent.projectID, let project = projects.first(where: { $0.id == projectID }) { path = paths.canonicalize(project.path).string }
        else {
            switch intent.route.target {
            case .fastCGI(_, let root), .staticFiles(let root):
                let url = URL(fileURLWithPath: root).standardizedFileURL
                path = paths.canonicalize(url.lastPathComponent == "public" ? url.deletingLastPathComponent() : url).string
            case .http: path = nil
            }
        }
        let project = projects.first { candidate in
            if let id = intent.projectID, candidate.id == id { return true }
            guard let path else { return false }
            return paths.canonicalize(candidate.path).string == path
        }
        let observedRoute = observedRoutes?.first(where: { $0.hostname.caseInsensitiveCompare(intent.route.hostname) == .orderedSame })
        let observed = observedRoutes.map { values in values.contains { routeConfigurationMatches($0, configured: intent.route) } }
        let availability: String
        if let project { availability = project.availability }
        else if let path, !FileManager.default.fileExists(atPath: path) { availability = "missing" }
        else if path != nil { availability = "available" }
        else { availability = "not-applicable" }
        let observationState: String
        if observed == true { observationState = "exact-route-observed" }
        else if observed == false, observedRoute != nil { observationState = "hostname-observed-with-different-route" }
        else if observed == false { observationState = "exact-route-not-observed" }
        else if unavailableReason == "Router is not observed healthy." { observationState = "caddy-observation-unavailable" }
        else { observationState = unavailableReason ?? "caddy-observation-unavailable" }
        let target: String
        switch intent.route.target {
        case .fastCGI(_, let root): target = "PHP · \(root)"
        case .staticFiles(let root): target = "Files · \(root)"
        case .http(let host, let port): target = "Proxy · \(host):\(port)"
        }
        return SiteListItem(
            hostname: intent.route.hostname,
            url: siteURL(for: intent.route)?.absoluteString ?? "",
            target: target,
            tls: intent.route.tls.rawValue,
            configured: true,
            caddyRouteObserved: observed,
            caddyObservationState: observationState,
            project: project?.name,
            projectPath: path,
            projectAvailability: availability,
            registration: project?.registration
        )
    }
}
