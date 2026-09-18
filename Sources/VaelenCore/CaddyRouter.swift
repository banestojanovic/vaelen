import Foundation

public actor CaddyRouter: Router {
    private let supervisor: CaddyProcessSupervisor
    private let layout: VaelenFilesystemLayout
    private var routes: [RouteID: Route] = [:]
    private var loadedConfiguration: Data?

    public init(layout: VaelenFilesystemLayout, supervisor: CaddyProcessSupervisor? = nil) {
        self.layout = layout
        self.supervisor = supervisor ?? CaddyProcessSupervisor(layout: layout)
    }

    public func start() async throws {
        _ = try await supervisor.start()
    }

    public func stop() async throws {
        _ = try await supervisor.stop()
        loadedConfiguration = nil
        routes.removeAll()
    }

    public func status() async -> RouterStatus {
        let process = await supervisor.status()
        return RouterStatus(provider: "caddy", providerVersion: process.version.isEmpty ? nil : process.version, state: process.state == .running ? .running : process.state == .degraded ? .degraded : .stopped, health: process.health, routeCount: routes.count)
    }

    public func health() async -> RouterHealth {
        let process = await supervisor.status()
        guard process.state == .running, process.health == .healthy else { return .unhealthy }
        return (try? CaddyAdminClient(endpoint: process.adminEndpoint).getConfig()) == nil ? .unhealthy : .healthy
    }

    public func reconcile(routes desiredRoutes: [Route]) async throws {
        let normalized = try desiredRoutes.map { try $0.validated() }
        var next: [RouteID: Route] = [:]
        for route in normalized {
            guard next.values.allSatisfy({ $0.hostname != route.hostname }) else { throw RouterError.duplicateHostname(route.hostname) }
            next[route.id] = route
        }
        let configuration = try await makeConfiguration(routes: normalized)
        if configuration != loadedConfiguration {
            let process = await supervisor.status()
            guard process.state == .running, process.health == .healthy else { throw RouterError.notRunning }
            _ = try CaddyAdminClient(endpoint: process.adminEndpoint).load(configuration: configuration)
            loadedConfiguration = configuration
        }
        routes = next
    }

    public func addRoute(_ route: Route) async throws {
        var next = Array(routes.values)
        guard !next.contains(where: { $0.id == route.id }) else { throw RouterError.invalidRoute("route already exists: \(route.id)") }
        next.append(route)
        try await reconcile(routes: next)
    }

    public func updateRoute(_ route: Route) async throws {
        guard routes[route.id] != nil else { throw RouterError.routeNotFound(route.id) }
        try await reconcile(routes: routes.values.filter { $0.id != route.id } + [route])
    }

    public func removeRoute(id: RouteID) async throws {
        guard routes[id] != nil else { throw RouterError.routeNotFound(id) }
        try await reconcile(routes: routes.values.filter { $0.id != id })
    }

    private func makeConfiguration(routes: [Route]) async throws -> Data {
        let process = await supervisor.status()
        let documents = routes.map { route in
            let handlers: [CaddyHandler]
            switch route.target {
            case .staticFiles(let documentRoot):
                handlers = [.fileServer(root: documentRoot)]
            case .http(let host, let port):
                handlers = [.reverseProxy(upstream: "\(host):\(port)")]
            case .fastCGI(let socketPath, let documentRoot):
                handlers = [.variables(root: documentRoot), .rewrite(uri: "/index.php"), .fastCGI(socketPath: socketPath)]
            }
            return CaddyRoute(match: [CaddyHostMatcher(host: [route.hostname])], handle: handlers, terminal: true)
        }
        let configuration = CaddyConfiguration(admin: CaddyAdminConfiguration(listen: process.adminEndpoint), storage: CaddyStorageConfiguration(root: layout.routingRuntimeDirectoryURL.appendingPathComponent("data").path), apps: CaddyApps(http: CaddyHTTPApp(servers: ["vaelen": CaddyHTTPServer(listen: ["127.0.0.1:\(process.httpPort)"], automaticHTTPS: CaddyAutoHTTPS(disable: true), routes: documents)])))
        return try JSONEncoder.caddy.encode(configuration)
    }
}

private struct CaddyConfiguration: Encodable {
    let admin: CaddyAdminConfiguration
    let storage: CaddyStorageConfiguration
    let apps: CaddyApps
}

private struct CaddyAdminConfiguration: Encodable { let listen: String }
private struct CaddyStorageConfiguration: Encodable { let module = "file_system"; let root: String }
private struct CaddyAutoHTTPS: Encodable { let disable: Bool }
private struct CaddyApps: Encodable { let http: CaddyHTTPApp }
private struct CaddyHTTPApp: Encodable { let servers: [String: CaddyHTTPServer] }
private struct CaddyHTTPServer: Encodable { let listen: [String]; let automaticHTTPS: CaddyAutoHTTPS; let routes: [CaddyRoute]; private enum CodingKeys: String, CodingKey { case listen, automaticHTTPS = "automatic_https", routes } }
private struct CaddyRoute: Encodable { let match: [CaddyHostMatcher]; let handle: [CaddyHandler]; let terminal: Bool }
private struct CaddyHostMatcher: Encodable { let host: [String] }
private struct CaddyUpstream: Encodable { let dial: String }
private struct CaddyTransport: Encodable { let protocolName: String; let splitPath: [String]; private enum CodingKeys: String, CodingKey { case protocolName = "protocol"; case splitPath = "split_path" } }

private struct CaddyHandler: Encodable {
    let handler: String
    let root: String?
    let uri: String?
    let upstreams: [CaddyUpstream]?
    let transport: CaddyTransport?
    let splitPath: [String]?

    static func fileServer(root: String) -> CaddyHandler { CaddyHandler(handler: "file_server", root: root, uri: nil, upstreams: nil, transport: nil, splitPath: nil) }
    static func reverseProxy(upstream: String) -> CaddyHandler { CaddyHandler(handler: "reverse_proxy", root: nil, uri: nil, upstreams: [CaddyUpstream(dial: upstream)], transport: nil, splitPath: nil) }
    static func variables(root: String) -> CaddyHandler { CaddyHandler(handler: "vars", root: root, uri: nil, upstreams: nil, transport: nil, splitPath: nil) }
    static func rewrite(uri: String) -> CaddyHandler { CaddyHandler(handler: "rewrite", root: nil, uri: uri, upstreams: nil, transport: nil, splitPath: nil) }
    static func fastCGI(socketPath: String) -> CaddyHandler { CaddyHandler(handler: "reverse_proxy", root: nil, uri: nil, upstreams: [CaddyUpstream(dial: "unix//\(socketPath)")], transport: CaddyTransport(protocolName: "fastcgi", splitPath: [".php"]), splitPath: nil) }

    private enum CodingKeys: String, CodingKey { case handler, root, uri, upstreams, transport, splitPath = "split_path" }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handler, forKey: .handler)
        try container.encodeIfPresent(root, forKey: .root)
        try container.encodeIfPresent(uri, forKey: .uri)
        try container.encodeIfPresent(upstreams, forKey: .upstreams)
        try container.encodeIfPresent(transport, forKey: .transport)
        try container.encodeIfPresent(splitPath, forKey: .splitPath)
    }
}

private extension JSONEncoder {
    static let caddy: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
