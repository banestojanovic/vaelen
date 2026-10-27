import Foundation

public enum ProjectAdoptionRequirementState: String, Codable, Equatable, Sendable {
    case readyForReview, needsChoice, conflict, notDetected
}

public struct ProjectAdoptionRequirementSource: Codable, Equatable, Sendable {
    public let source: String
    public let rawValue: String
    public init(source: String, rawValue: String) { self.source = source; self.rawValue = rawValue }
}

public struct ProjectAdoptionRequirement: Codable, Equatable, Sendable {
    public let state: ProjectAdoptionRequirementState
    public let sources: [ProjectAdoptionRequirementSource]
    public let exactSelectorCandidate: String?
    public init(state: ProjectAdoptionRequirementState, sources: [ProjectAdoptionRequirementSource], exactSelectorCandidate: String? = nil) {
        self.state = state; self.sources = sources; self.exactSelectorCandidate = exactSelectorCandidate
    }
}

public enum ProjectAdoptionRouteTargetKind: String, Codable, Equatable, Sendable { case fastCGI, http, staticFiles }
public struct ProjectAdoptionRoute: Codable, Equatable, Sendable {
    public let id: RouteID
    public let hostname: String
    public let targetKind: ProjectAdoptionRouteTargetKind
    public let documentRoot: String?
    public let tls: TLSMode
    public let liveObserved: Bool?
    public init(id: RouteID, hostname: String, targetKind: ProjectAdoptionRouteTargetKind, documentRoot: String?, tls: TLSMode, liveObserved: Bool?) {
        self.id = id
        self.hostname = hostname
        self.targetKind = targetKind
        self.documentRoot = documentRoot
        self.tls = tls
        self.liveObserved = liveObserved
    }
}

public struct ProjectAdoptionEndpoint: Codable, Equatable, Sendable {
    public let connection: String?
    public let host: String?
    public let port: String?
    public let secretAvailability: ProjectSecretAvailability
    public init(connection: String?, host: String?, port: String?, secretAvailability: ProjectSecretAvailability) {
        self.connection = connection
        self.host = host
        self.port = port
        self.secretAvailability = secretAvailability
    }
}

public struct ProjectAdoptionPreview: Codable, Equatable, Sendable {
    public let identity: ProjectEnvironmentIdentity
    public let manifestState: ProjectEnvironmentFileState
    public let manifestVersion: Int?
    public let php: ProjectAdoptionRequirement
    public let node: ProjectAdoptionRequirement
    public let routes: [ProjectAdoptionRoute]
    public let liveRoutesAvailable: Bool
    public let liveRoutesUnavailableReason: String?
    public let database: ProjectAdoptionEndpoint
    public let mail: ProjectAdoptionEndpoint
    public let cache: ProjectAdoptionEndpoint?
    public let herdYMLPresent: Bool
    public let hasRouteOwnershipConflicts: Bool
    public let unresolvedDecisions: [String]
    public let safetyBoundary: String
    public let discoveryIssues: [String]?

    public init(identity: ProjectEnvironmentIdentity, manifestState: ProjectEnvironmentFileState, manifestVersion: Int?, php: ProjectAdoptionRequirement, node: ProjectAdoptionRequirement, routes: [ProjectAdoptionRoute], liveRoutesAvailable: Bool, liveRoutesUnavailableReason: String?, database: ProjectAdoptionEndpoint, mail: ProjectAdoptionEndpoint, cache: ProjectAdoptionEndpoint?, herdYMLPresent: Bool, hasRouteOwnershipConflicts: Bool = false, unresolvedDecisions: [String], safetyBoundary: String, discoveryIssues: [String]? = nil) {
        self.identity = identity; self.manifestState = manifestState; self.manifestVersion = manifestVersion
        self.php = php; self.node = node; self.routes = routes; self.liveRoutesAvailable = liveRoutesAvailable
        self.liveRoutesUnavailableReason = liveRoutesUnavailableReason; self.database = database; self.mail = mail
        self.cache = cache; self.herdYMLPresent = herdYMLPresent; self.hasRouteOwnershipConflicts = hasRouteOwnershipConflicts
        self.unresolvedDecisions = unresolvedDecisions; self.safetyBoundary = safetyBoundary; self.discoveryIssues = discoveryIssues
    }
}

public struct ProjectAdoptionDiscovery: Equatable, Sendable {
    public let php: [ProjectAdoptionRequirementSource]
    public let node: [ProjectAdoptionRequirementSource]
    public let herdYMLPresent: Bool
    public let issues: [String]
    public init(php: [ProjectAdoptionRequirementSource], node: [ProjectAdoptionRequirementSource], herdYMLPresent: Bool, issues: [String] = []) {
        self.php = php; self.node = node; self.herdYMLPresent = herdYMLPresent; self.issues = issues
    }
}

public enum ProjectAdoptionPreviewBuilder {
    public static func discover(at projectPath: String) -> ProjectAdoptionDiscovery {
        let root = URL(fileURLWithPath: projectPath, isDirectory: true)
        var php = [ProjectAdoptionRequirementSource]()
        var node = [ProjectAdoptionRequirementSource]()
        var issues = [String]()
        enum FileRead { case missing, valid(String), invalid(String) }
        func read(_ name: String) -> FileRead {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { return .invalid("\(name) is not a readable regular file.") }
            guard let size = values.fileSize else { return .invalid("\(name) size could not be determined.") }
            guard size <= 64 * 1024 else { return .invalid("\(name) exceeds the 64 KiB discovery limit.") }
            guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024 else { return .invalid("\(name) could not be read within the 64 KiB limit.") }
            guard let text = String(data: data, encoding: .utf8) else { return .invalid("\(name) is not valid UTF-8.") }
            return .valid(text)
        }
        switch read("composer.json") {
        case .valid(let text):
            if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let dictionary = object as? [String: Any], let required = dictionary["require"] as? [String: Any], let value = required["php"] as? String {
                php.append(.init(source: "composer.json require.php", rawValue: value))
            } else if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let dictionary = object as? [String: Any] {
                if dictionary["require"] != nil {
                    guard let required = dictionary["require"] as? [String: Any] else { issues.append("composer.json require section is not an object."); break }
                    if let value = required["php"] { if let value = value as? String { php.append(.init(source: "composer.json require.php", rawValue: value)) } else { issues.append("composer.json require.php is not a string.") } }
                }
            } else { issues.append("composer.json is not valid JSON object data.") }
        case .invalid(let issue): issues.append(issue)
        case .missing: break
        }
        switch read("package.json") {
        case .valid(let text):
            if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let dictionary = object as? [String: Any], let engines = dictionary["engines"] as? [String: Any], let value = engines["node"] as? String {
                node.append(.init(source: "package.json engines.node", rawValue: value))
            } else if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let dictionary = object as? [String: Any] {
                if dictionary["engines"] != nil {
                    guard let engines = dictionary["engines"] as? [String: Any] else { issues.append("package.json engines section is not an object."); break }
                    if let value = engines["node"] { if let value = value as? String { node.append(.init(source: "package.json engines.node", rawValue: value)) } else { issues.append("package.json engines.node is not a string.") } }
                }
            } else { issues.append("package.json is not valid JSON object data.") }
        case .invalid(let issue): issues.append(issue)
        case .missing: break
        }
        for name in [".nvmrc", ".node-version"] {
            if case .valid(let text) = read(name), let value = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                node.append(.init(source: name, rawValue: value))
            }
        }
        if case .valid(let text) = read(".php-version"), let value = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            php.append(.init(source: ".php-version", rawValue: value))
        }
        if case .valid(let text) = read(".tool-versions") {
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2 else { continue }
                if fields[0] == "nodejs" { node.append(.init(source: ".tool-versions nodejs", rawValue: String(fields[1]))) }
                if fields[0] == "php" { php.append(.init(source: ".tool-versions php", rawValue: String(fields[1]))) }
            }
        }
        let herdURL = root.appendingPathComponent("herd.yml")
        let herdPresent = (try? herdURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        for name in [".nvmrc", ".node-version", ".php-version", ".tool-versions"] {
            if case .invalid(let issue) = read(name) { issues.append(issue) }
        }
        return .init(php: php, node: node, herdYMLPresent: herdPresent, issues: issues)
    }

    public static func build(report: ProjectEnvironmentReport, routes: [RouteIntent], observedRoutes: [Route]?, unavailableReason: String? = nil, discovery: ProjectAdoptionDiscovery) -> ProjectAdoptionPreview {
        let path = canonical(report.identity.path)
        let associated = routes.filter { intent in
            if let projectID = intent.projectID { return report.identity.id?.rawValue == projectID }
            guard let routePath = intent.projectPath else { return false }
            return canonical(routePath) == path
        }
        let ownerConflicts = routes.filter { intent in
            guard let owner = intent.projectID, owner != report.identity.id?.rawValue, let routePath = intent.projectPath else { return false }
            return canonical(routePath) == path
        }
        let projectedRoutes = associated.map { intent -> ProjectAdoptionRoute in
            let kind: ProjectAdoptionRouteTargetKind
            let root: String?
            switch intent.route.target {
            case .fastCGI(_, let documentRoot): kind = .fastCGI; root = documentRoot
            case .http: kind = .http; root = nil
            case .staticFiles(let documentRoot): kind = .staticFiles; root = documentRoot
            }
            let observed = observedRoutes.map { routes in routes.contains { $0.hostname == intent.route.hostname && $0.target == intent.route.target && $0.tls == intent.route.tls } }
            return .init(id: intent.route.id, hostname: intent.route.hostname, targetKind: kind, documentRoot: root, tls: intent.route.tls, liveObserved: observed)
        }
        let decisions = [
            discovery.herdYMLPresent ? "Review herd.yml manually; its schema is not interpreted." : nil,
            report.desired.file == .invalid ? "Review the invalid vaelen.yml configuration before adoption." : nil,
            discovery.issues.isEmpty ? nil : "Review incomplete discovery evidence: \(discovery.issues.joined(separator: " "))",
            requirement(sources: discovery.php, runtime: "PHP").state == .needsChoice ? "Choose a PHP selector from the discovered constraints." : nil,
            requirement(sources: discovery.node, runtime: "Node").state == .needsChoice ? "Choose a Node selector from the discovered constraints." : nil,
            requirement(sources: discovery.php, runtime: "PHP").state == .conflict ? "Resolve conflicting PHP requirement sources." : nil,
            requirement(sources: discovery.node, runtime: "Node").state == .conflict ? "Resolve conflicting Node requirement sources." : nil,
            ownerConflicts.isEmpty ? nil : "Resolve route ownership conflicts; routes with another ProjectID were excluded despite matching paths.",
            associated.isEmpty ? "No route is associated with this project. You may select an existing reviewed route, or explicitly create a route by declaring a host, document root, and TLS mode with --create-route." : "Choose which associated route hosts to adopt and confirm each route's TLS mode.",
            [configValue(report.configured.dbConnection, report.configured.dbHost, report.configured.dbPort), configValue(report.configured.mailer, report.configured.mailHost, report.configured.mailPort), configValue(report.configured.cacheDriver, report.configured.cacheHost, report.configured.cachePort)].contains(true) ? "Review database, mail, and cache endpoint mappings before adoption." : nil,
            observedRoutes == nil ? "Live route observation is unavailable; configured routes remain listed." : nil
        ].compactMap { $0 }
        let config = report.configured
        return .init(identity: report.identity, manifestState: report.desired.file, manifestVersion: report.projectSpec?.version,
                     php: requirement(sources: discovery.php, runtime: "PHP"), node: requirement(sources: discovery.node, runtime: "Node"), routes: projectedRoutes,
                     liveRoutesAvailable: observedRoutes != nil, liveRoutesUnavailableReason: unavailableReason,
                     database: endpoint(connection: config.dbConnection, host: config.dbHost, port: config.dbPort, secretAvailability: config.password),
                     mail: endpoint(connection: config.mailer, host: config.mailHost, port: config.mailPort, secretAvailability: config.mailPassword),
                     cache: configValue(config.cacheDriver, config.cacheHost, config.cachePort) ? endpoint(connection: config.cacheDriver, host: config.cacheHost, port: config.cachePort, secretAvailability: config.cachePassword ?? .unknown) : nil,
                     herdYMLPresent: discovery.herdYMLPresent, hasRouteOwnershipConflicts: !ownerConflicts.isEmpty, unresolvedDecisions: decisions,
                     safetyBoundary: "Preview only. No project, route, service, or ownership mutation is performed. No secret values are imported or emitted.",
                     discoveryIssues: discovery.issues)
    }

    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private static func configValue(_ connection: String?, _ host: String?, _ port: String?) -> Bool { connection != nil || host != nil || port != nil }
    private static func endpoint(connection: String?, host: String?, port: String?, secretAvailability: ProjectSecretAvailability) -> ProjectAdoptionEndpoint {
        let safeConnection = connection.flatMap { $0.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,31}$", options: .regularExpression) == nil ? nil : $0 }
        let safeHost = host.flatMap { $0.range(of: "^[A-Za-z0-9._:\\[\\]-]{1,253}$", options: .regularExpression) == nil ? nil : $0 }
        let safePort = port.flatMap { value -> String? in
            guard value.range(of: "^[0-9]{1,5}$", options: .regularExpression) != nil, let number = Int(value), (1...65535).contains(number) else { return nil }
            return value
        }
        return .init(connection: safeConnection, host: safeHost, port: safePort, secretAvailability: secretAvailability)
    }
    private static func requirement(sources: [ProjectAdoptionRequirementSource], runtime: String) -> ProjectAdoptionRequirement {
        guard !sources.isEmpty else { return .init(state: .notDetected, sources: []) }
        let candidates = sources.map { exactCandidate($0.rawValue, runtime: runtime) }
        let concrete = candidates.compactMap { $0 }
        if concrete.contains(where: { candidate in
            concrete.contains { other in selectorsConflict(candidate, other, runtime: runtime) }
        }) { return .init(state: .conflict, sources: sources) }
        let distinct = Set(concrete)
        if let candidate = distinct.first, distinct.count == 1, candidates.allSatisfy({ $0 == candidate }) {
            return .init(state: .readyForReview, sources: sources, exactSelectorCandidate: candidate)
        }
        return .init(state: .needsChoice, sources: sources)
    }
    private static func selectorsConflict(_ lhs: String, _ rhs: String, runtime: String) -> Bool {
        guard lhs != rhs else { return false }
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        guard left.count == (runtime == "Node" ? 1 : 2) || left.count == 3,
              right.count == (runtime == "Node" ? 1 : 2) || right.count == 3 else { return false }
        let familyComponents = runtime == "Node" ? 1 : 2
        guard Array(left.prefix(familyComponents)) == Array(right.prefix(familyComponents)) else { return true }
        return left.count == 3 && right.count == 3
    }
    private static func exactCandidate(_ raw: String, runtime: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if runtime == "PHP", value.range(of: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil { return value }
        if runtime == "Node" {
            let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
            if normalized.range(of: "^[0-9]+(?:\\.[0-9]+\\.[0-9]+)?$", options: .regularExpression) != nil { return normalized }
        }
        return nil
    }
}
