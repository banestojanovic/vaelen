import Foundation

public struct RouteID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() { rawValue = UUID() }
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public enum TLSMode: String, Codable, Sendable {
    case disabled
    case local
}

public enum RouteTarget: Equatable, Sendable {
    case fastCGI(socketPath: String, documentRoot: String)
    case http(host: String, port: Int)
    case staticFiles(documentRoot: String)
}

extension RouteTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, socketPath, documentRoot, host, port }
    private enum Kind: String, Codable { case fastCGI, http, staticFiles }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fastCGI(let socketPath, let documentRoot):
            try container.encode(Kind.fastCGI, forKey: .kind)
            try container.encode(socketPath, forKey: .socketPath)
            try container.encode(documentRoot, forKey: .documentRoot)
        case .http(let host, let port):
            try container.encode(Kind.http, forKey: .kind)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        case .staticFiles(let documentRoot):
            try container.encode(Kind.staticFiles, forKey: .kind)
            try container.encode(documentRoot, forKey: .documentRoot)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .fastCGI:
            self = .fastCGI(socketPath: try container.decode(String.self, forKey: .socketPath), documentRoot: try container.decode(String.self, forKey: .documentRoot))
        case .http:
            self = .http(host: try container.decode(String.self, forKey: .host), port: try container.decode(Int.self, forKey: .port))
        case .staticFiles:
            self = .staticFiles(documentRoot: try container.decode(String.self, forKey: .documentRoot))
        }
    }
}

public struct Route: Identifiable, Codable, Equatable, Sendable {
    public let id: RouteID
    public let hostname: String
    public let target: RouteTarget
    public let tls: TLSMode

    public init(id: RouteID = RouteID(), hostname: String, target: RouteTarget, tls: TLSMode = .local) {
        self.id = id
        self.hostname = hostname
        self.target = target
        self.tls = tls
    }

    public func validated() throws -> Route {
        let normalizedHostname = hostname.lowercased()
        guard Self.isValidHostname(normalizedHostname) else { throw RouterError.invalidRoute("invalid hostname: \(hostname)") }
        switch target {
        case .fastCGI(let socketPath, let documentRoot):
            guard !socketPath.isEmpty, !documentRoot.isEmpty else { throw RouterError.invalidRoute("FastCGI socket and document root are required") }
        case .http(_, let port):
            guard (1...65535).contains(port) else { throw RouterError.invalidRoute("HTTP target port is invalid") }
        case .staticFiles(let documentRoot):
            guard !documentRoot.isEmpty else { throw RouterError.invalidRoute("static document root is required") }
        }
        return Route(id: id, hostname: normalizedHostname, target: target, tls: tls)
    }

    private static func isValidHostname(_ hostname: String) -> Bool {
        guard !hostname.isEmpty, hostname.count <= 253, !hostname.hasPrefix("."), !hostname.hasSuffix(".") else { return false }
        return hostname.split(separator: ".").allSatisfy { label in
            guard let first = label.first, !label.isEmpty, label.count <= 63 else { return false }
            guard first.isLetter || first.isNumber else { return false }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } && !label.hasSuffix("-")
        }
    }
}

public enum RouterState: String, Codable, Sendable { case stopped, running, degraded }
public enum RouterHealth: String, Codable, Sendable { case unknown, healthy, unhealthy }

public struct RouterStatus: Codable, Equatable, Sendable {
    public let provider: String
    public let providerVersion: String?
    public let state: RouterState
    public let health: RouterHealth
    public let routeCount: Int

    public init(provider: String, providerVersion: String? = nil, state: RouterState, health: RouterHealth, routeCount: Int) {
        self.provider = provider
        self.providerVersion = providerVersion
        self.state = state
        self.health = health
        self.routeCount = routeCount
    }
}

public enum RouterError: Error, Equatable, Sendable {
    case notRunning
    case invalidRoute(String)
    case duplicateHostname(String)
    case routeNotFound(RouteID)
}

public protocol Router: Sendable {
    func start() async throws
    func stop() async throws
    func status() async -> RouterStatus
    func health() async -> RouterHealth
    func reconcile(routes: [Route]) async throws
    func addRoute(_ route: Route) async throws
    func updateRoute(_ route: Route) async throws
    func removeRoute(id: RouteID) async throws
}

/// Deterministic provider used by Core tests until the external router is integrated.
public actor InMemoryRouter: Router {
    private var routes: [RouteID: Route] = [:]
    private var state: RouterState = .stopped

    public init() {}

    public func start() async throws { state = .running }

    public func stop() async throws {
        state = .stopped
    }

    public func status() async -> RouterStatus {
        RouterStatus(provider: "memory", state: state, health: state == .running ? .healthy : .unknown, routeCount: routes.count)
    }

    public func health() async -> RouterHealth {
        state == .running ? .healthy : .unknown
    }

    public func reconcile(routes desiredRoutes: [Route]) async throws {
        guard state == .running else { throw RouterError.notRunning }
        let normalized = try desiredRoutes.map { try $0.validated() }
        var next: [RouteID: Route] = [:]
        for route in normalized {
            if next.values.contains(where: { $0.hostname == route.hostname && $0.id != route.id }) {
                throw RouterError.duplicateHostname(route.hostname)
            }
            next[route.id] = route
        }
        routes = next
    }

    public func addRoute(_ route: Route) async throws {
        guard state == .running else { throw RouterError.notRunning }
        let route = try route.validated()
        guard routes[route.id] == nil else { throw RouterError.invalidRoute("route already exists: \(route.id)") }
        guard !routes.values.contains(where: { $0.hostname == route.hostname }) else { throw RouterError.duplicateHostname(route.hostname) }
        routes[route.id] = route
    }

    public func updateRoute(_ route: Route) async throws {
        guard state == .running else { throw RouterError.notRunning }
        let route = try route.validated()
        guard routes[route.id] != nil else { throw RouterError.routeNotFound(route.id) }
        guard !routes.values.contains(where: { $0.id != route.id && $0.hostname == route.hostname }) else { throw RouterError.duplicateHostname(route.hostname) }
        routes[route.id] = route
    }

    public func removeRoute(id: RouteID) async throws {
        guard state == .running else { throw RouterError.notRunning }
        guard routes.removeValue(forKey: id) != nil else { throw RouterError.routeNotFound(id) }
    }
}
