import Foundation

public actor CaddyRouter: Router {
    private let supervisor: CaddyProcessSupervisor
    private let layout: VaelenFilesystemLayout
    private let tls: TLSCapability
    private var routes: [RouteID: Route] = [:]
    private var loadedConfiguration: Data?

    public init(layout: VaelenFilesystemLayout, supervisor: CaddyProcessSupervisor? = nil, tls: TLSCapability? = nil) {
        self.layout = layout; self.tls = tls ?? TLSCapability(layout: layout)
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

    public func observedRoutes() async throws -> [Route] {
        let process = await supervisor.status()
        guard process.state == .running, process.health == .healthy else { throw RouterError.notRunning }
        return try Self.decodeObservedRoutes(try CaddyAdminClient(endpoint: process.adminEndpoint).getConfig())
    }

    static func decodeObservedRoutes(_ data: Data) throws -> [Route] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = root["apps"] as? [String: Any],
              let http = apps["http"] as? [String: Any],
              let servers = http["servers"] as? [String: Any] else { throw RouterError.invalidRoute("Caddy runtime configuration is unreadable") }

        var byHostname = [String: [Route]]()
        for (serverName, rawServer) in servers {
            guard let server = rawServer as? [String: Any], let rawRoutes = server["routes"] as? [[String: Any]] else { throw RouterError.invalidRoute("Caddy runtime configuration is unreadable") }
            let tls: TLSMode = serverName == "vaelen-https" ? .local : .disabled
            for rawRoute in rawRoutes {
                guard let matchers = rawRoute["match"] as? [[String: Any]],
                      let hostMatcher = matchers.first,
                      let hosts = hostMatcher["host"] as? [String],
                      let hostname = hosts.first, !hostname.isEmpty,
                      let handlers = rawRoute["handle"] as? [[String: Any]] else { throw RouterError.invalidRoute("Caddy runtime configuration is unreadable") }
                if handlers.contains(where: { ($0["handler"] as? String) == "static_response" }) { continue }
                let route: Route?
                if let proxy = handlers.first(where: { ($0["handler"] as? String) == "reverse_proxy" }),
                   let upstreams = proxy["upstreams"] as? [[String: Any]],
                   let dial = upstreams.first?["dial"] as? String {
                    if let transport = proxy["transport"] as? [String: Any], transport["protocol"] as? String == "fastcgi" {
                        guard dial.hasPrefix("unix//"), dial.count > "unix//".count else { throw RouterError.invalidRoute("Caddy runtime configuration is unreadable") }
                        let root = (handlers.first(where: { ($0["handler"] as? String) == "vars" })?["root"] as? String) ?? ""
                        guard !root.isEmpty else { throw RouterError.invalidRoute("Caddy runtime configuration is unreadable") }
                        route = Route(hostname: hostname, target: .fastCGI(socketPath: String(dial.dropFirst("unix//".count)), documentRoot: root), tls: tls)
                    } else if let separator = dial.lastIndex(of: ":"), let port = Int(dial[dial.index(after: separator)...]) {
                        route = Route(hostname: hostname, target: .http(host: String(dial[..<separator]), port: port), tls: tls)
                    } else {
                        throw RouterError.invalidRoute("Caddy runtime configuration is unreadable")
                    }
                } else if let fileServer = handlers.first(where: { ($0["handler"] as? String) == "file_server" }), let root = fileServer["root"] as? String {
                    guard !root.isEmpty else { throw RouterError.invalidRoute("Caddy runtime configuration is unreadable") }
                    route = Route(hostname: hostname, target: .staticFiles(documentRoot: root), tls: tls)
                } else {
                    throw RouterError.invalidRoute("Caddy runtime configuration is unreadable")
                }
                if let route { byHostname[hostname, default: []].append(route) }
            }
        }

        var result = [Route]()
        for routes in byHostname.values {
            let unique = routes.reduce(into: [Route]()) { partial, route in
                if !partial.contains(where: { $0.target == route.target && $0.hostname == route.hostname && $0.tls == route.tls }) { partial.append(route) }
            }
            let https = unique.filter { $0.tls == .local }
            let selected = https.isEmpty ? unique : https
            let fastCGI = selected.filter { $0.target.isFastCGI }
            result.append(contentsOf: fastCGI.isEmpty ? selected : fastCGI)
        }
        return result
    }

    private func makeConfiguration(routes: [Route]) async throws -> Data {
        let process = await supervisor.status()
        let runtimeConfiguration = supervisor.configuration
        let httpListen = "127.0.0.1:\(process.httpPort)"
        let httpsListen = "127.0.0.1:\(runtimeConfiguration.httpsPort)"
        let documentEntries: [(String, CaddyRoute)] = routes.flatMap { route in
            let handlers: [CaddyHandler]
            switch route.target {
            case .staticFiles(let documentRoot):
                handlers = [.fileServer(root: documentRoot)]
            case .http(let host, let port):
                handlers = [.reverseProxy(upstream: "\(host):\(port)")]
            case .fastCGI(let socketPath, let documentRoot):
                let staticMatcher = CaddyHostMatcher(host: [route.hostname], file: CaddyFileMatcher(root: documentRoot, tryFiles: ["{http.request.uri.path}"]), not: [CaddyPathMatcher(path: ["/*.php"])])
                let staticRoute = CaddyRoute(match: [staticMatcher], handle: [.fileServer(root: documentRoot)], terminal: true)
                let fastCGIRoute = CaddyRoute(match: [CaddyHostMatcher(host: [route.hostname])], handle: [.variables(root: documentRoot), .rewrite(uri: "/index.php"), .fastCGI(socketPath: socketPath)], terminal: true)
                return [(route.hostname, staticRoute), (route.hostname, fastCGIRoute)]
            }
            return [(route.hostname, CaddyRoute(match: [CaddyHostMatcher(host: [route.hostname])], handle: handlers, terminal: true))]
        }
        let documents = documentEntries.map(\.1)
        var leaves = [CaddyCertificateFile]()
        var tlsHostnames = [String]()
        for route in routes where route.tls == .local {
            let leaf = try await tls.issueLeaf(hostname: route.hostname)
            leaves.append(CaddyCertificateFile(certificate: leaf.certificateURL.path, key: leaf.keyURL.path))
            tlsHostnames.append(route.hostname)
        }
        // Plain HTTP on the backend port redirects TLS routes to their https:// origin.
        // Redirect routes precede content routes so they win for TLS hostnames.
        let redirects = tlsHostnames.map { hostname in
            CaddyRoute(match: [CaddyHostMatcher(host: [hostname])], handle: [.redirect(to: "https://{http.request.host}{http.request.uri}")], terminal: true)
        }
        let httpServer = CaddyHTTPServer(listen: [httpListen], automaticHTTPS: CaddyAutoHTTPS(disable: true), protocols: ["h1", "h2"], tlsConnectionPolicies: nil, routes: redirects + documents)
        var servers = ["vaelen-http": httpServer]
        if !leaves.isEmpty {
            let httpsDocuments = documentEntries.filter { tlsHostnames.contains($0.0) }.map(\.1)
            servers["vaelen-https"] = CaddyHTTPServer(listen: [httpsListen], automaticHTTPS: CaddyAutoHTTPS(disable: true), protocols: ["h1", "h2"], tlsConnectionPolicies: [CaddyTLSConnectionPolicy()], routes: httpsDocuments)
        }
        let tlsApp = leaves.isEmpty ? nil : CaddyTLSApp(certificates: CaddyTLSCertificates(loadFiles: leaves))
        let configuration = CaddyConfiguration(admin: CaddyAdminConfiguration(listen: process.adminEndpoint), storage: CaddyStorageConfiguration(root: layout.routingRuntimeDirectoryURL.appendingPathComponent("data").path), apps: CaddyApps(http: CaddyHTTPApp(servers: servers), tls: tlsApp))
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
private struct CaddyApps: Encodable { let http: CaddyHTTPApp; let tls: CaddyTLSApp? }
private struct CaddyTLSApp: Encodable { let certificates: CaddyTLSCertificates }
private struct CaddyTLSCertificates: Encodable { let loadFiles: [CaddyCertificateFile]; private enum CodingKeys: String, CodingKey { case loadFiles = "load_files" } }
private struct CaddyCertificateFile: Encodable { let certificate: String; let key: String }
private struct CaddyHTTPApp: Encodable { let servers: [String: CaddyHTTPServer] }
private struct CaddyHTTPServer: Encodable { let listen: [String]; let automaticHTTPS: CaddyAutoHTTPS; let protocols: [String]; let tlsConnectionPolicies: [CaddyTLSConnectionPolicy]?; let routes: [CaddyRoute]; private enum CodingKeys: String, CodingKey { case listen, automaticHTTPS = "automatic_https", protocols, tlsConnectionPolicies = "tls_connection_policies", routes } }
private struct CaddyTLSConnectionPolicy: Encodable {}
private struct CaddyRoute: Encodable { let match: [CaddyHostMatcher]; let handle: [CaddyHandler]; let terminal: Bool }
private struct CaddyHostMatcher: Encodable { let host: [String]; let file: CaddyFileMatcher?; let not: [CaddyPathMatcher]?; init(host: [String], file: CaddyFileMatcher? = nil, not: [CaddyPathMatcher]? = nil) { self.host = host; self.file = file; self.not = not } }
private struct CaddyFileMatcher: Encodable { let root: String; let tryFiles: [String]; private enum CodingKeys: String, CodingKey { case root; case tryFiles = "try_files" } }
private struct CaddyPathMatcher: Encodable { let path: [String] }
private struct CaddyUpstream: Encodable { let dial: String }
private struct CaddyTransport: Encodable { let protocolName: String; let splitPath: [String]; private enum CodingKeys: String, CodingKey { case protocolName = "protocol"; case splitPath = "split_path" } }

private struct CaddyHandler: Encodable {
    let handler: String
    let root: String?
    let uri: String?
    let upstreams: [CaddyUpstream]?
    let transport: CaddyTransport?
    let splitPath: [String]?
    let statusCode: Int?
    let headers: [String: [String]]?

    static func fileServer(root: String) -> CaddyHandler { CaddyHandler(handler: "file_server", root: root, uri: nil, upstreams: nil, transport: nil, splitPath: nil, statusCode: nil, headers: nil) }
    static func reverseProxy(upstream: String) -> CaddyHandler { CaddyHandler(handler: "reverse_proxy", root: nil, uri: nil, upstreams: [CaddyUpstream(dial: upstream)], transport: nil, splitPath: nil, statusCode: nil, headers: nil) }
    static func variables(root: String) -> CaddyHandler { CaddyHandler(handler: "vars", root: root, uri: nil, upstreams: nil, transport: nil, splitPath: nil, statusCode: nil, headers: nil) }
    static func rewrite(uri: String) -> CaddyHandler { CaddyHandler(handler: "rewrite", root: nil, uri: uri, upstreams: nil, transport: nil, splitPath: nil, statusCode: nil, headers: nil) }
    static func fastCGI(socketPath: String) -> CaddyHandler { CaddyHandler(handler: "reverse_proxy", root: nil, uri: nil, upstreams: [CaddyUpstream(dial: "unix//\(socketPath)")], transport: CaddyTransport(protocolName: "fastcgi", splitPath: [".php"]), splitPath: nil, statusCode: nil, headers: nil) }
    static func redirect(to location: String) -> CaddyHandler { CaddyHandler(handler: "static_response", root: nil, uri: nil, upstreams: nil, transport: nil, splitPath: nil, statusCode: 308, headers: ["Location": [location]]) }

    private enum CodingKeys: String, CodingKey { case handler, root, uri, upstreams, transport, splitPath = "split_path", statusCode = "status_code", headers }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handler, forKey: .handler)
        try container.encodeIfPresent(root, forKey: .root)
        try container.encodeIfPresent(uri, forKey: .uri)
        try container.encodeIfPresent(upstreams, forKey: .upstreams)
        try container.encodeIfPresent(transport, forKey: .transport)
        try container.encodeIfPresent(splitPath, forKey: .splitPath)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(headers, forKey: .headers)
    }
}

private extension JSONEncoder {
    static let caddy: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
