import Foundation
import Yams

public enum ProjectEnvironmentFileState: String, Codable, Sendable {
    case absent
    case valid
    case invalid
}

public enum ProjectEnvironmentSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

public enum ProjectEnvironmentConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case unknown
}

public enum ProjectSecretAvailability: String, Codable, Sendable {
    case available
    case missing
    case unknown
}

public struct ProjectDiagnostic: Codable, Equatable, Sendable {
    public let code: String
    public let severity: ProjectEnvironmentSeverity
    public let message: String
    public let suggestion: String?

    public init(code: String, severity: ProjectEnvironmentSeverity, message: String, suggestion: String? = nil) {
        self.code = code
        self.severity = severity
        self.message = message
        self.suggestion = suggestion
    }
}

public struct ProjectEnvironmentIdentity: Codable, Equatable, Sendable {
    public let id: ProjectID?
    public let name: String
    public let path: String
    public let registration: ProjectRegistrationKind
    public let availability: PathAvailability

    public init(project: Project) {
        id = project.id
        name = project.name
        path = project.rootPath.string
        registration = project.registrationKind
        availability = project.availability
    }
}

public struct ProjectFrameworkInspection: Codable, Equatable, Sendable {
    public let framework: String
    public let confidence: ProjectEnvironmentConfidence
    public let evidence: [String]
    public let suggestedDocumentRoot: String?
    public let composerPHPRequirement: String?

    public init(framework: String, confidence: ProjectEnvironmentConfidence, evidence: [String], suggestedDocumentRoot: String? = nil, composerPHPRequirement: String? = nil) {
        self.framework = framework
        self.confidence = confidence
        self.evidence = evidence
        self.suggestedDocumentRoot = suggestedDocumentRoot
        self.composerPHPRequirement = composerPHPRequirement
    }
}

public struct ProjectDesiredEnvironment: Codable, Equatable, Sendable {
    public let file: ProjectEnvironmentFileState
    public let fileError: String?
    public let php: String?
    public let secureWeb: Bool?
    public let mysql: Bool?
    public let mailpit: Bool?

    public init(file: ProjectEnvironmentFileState, fileError: String? = nil, php: String? = nil, secureWeb: Bool? = nil, mysql: Bool? = nil, mailpit: Bool? = nil) {
        self.file = file
        self.fileError = fileError
        self.php = php
        self.secureWeb = secureWeb
        self.mysql = mysql
        self.mailpit = mailpit
    }
}

public struct ProjectConfiguredEnvironment: Codable, Equatable, Sendable {
    public let envFile: String
    public let envFilePresent: Bool
    public let dbConnection: String?
    public let dbHost: String?
    public let dbPort: String?
    public let database: String?
    public let usernameConfigured: Bool
    public let password: ProjectSecretAvailability
    public let mailer: String?
    public let mailHost: String?
    public let mailPort: String?
    public let mailEncryption: String?
    public let mailPassword: ProjectSecretAvailability
    public let interpolationDetected: Bool
    public let source: String

    public init(envFile: String, envFilePresent: Bool, dbConnection: String? = nil, dbHost: String? = nil, dbPort: String? = nil, database: String? = nil, usernameConfigured: Bool = false, password: ProjectSecretAvailability = .unknown, mailer: String? = nil, mailHost: String? = nil, mailPort: String? = nil, mailEncryption: String? = nil, mailPassword: ProjectSecretAvailability = .unknown, interpolationDetected: Bool = false, source: String = ".env") {
        self.envFile = envFile
        self.envFilePresent = envFilePresent
        self.dbConnection = dbConnection
        self.dbHost = dbHost
        self.dbPort = dbPort
        self.database = database
        self.usernameConfigured = usernameConfigured
        self.password = password
        self.mailer = mailer
        self.mailHost = mailHost
        self.mailPort = mailPort
        self.mailEncryption = mailEncryption
        self.mailPassword = mailPassword
        self.interpolationDetected = interpolationDetected
        self.source = source
    }
}

public struct ProjectConfigCacheObservation: Codable, Equatable, Sendable {
    public let state: String
    public let cachePath: String
    public let cacheModifiedAt: Date?
    public let envModifiedAt: Date?
    public let envNewerThanCache: Bool?

    public init(state: String, cachePath: String, cacheModifiedAt: Date? = nil, envModifiedAt: Date? = nil, envNewerThanCache: Bool? = nil) {
        self.state = state
        self.cachePath = cachePath
        self.cacheModifiedAt = cacheModifiedAt
        self.envModifiedAt = envModifiedAt
        self.envNewerThanCache = envNewerThanCache
    }
}

public struct ProjectEndpointObservation: Codable, Equatable, Sendable {
    public let configuredHost: String?
    public let configuredPort: String?
    public let expectedHost: String?
    public let expectedPort: Int?
    public let matches: Bool?
    public let effective: String

    public init(configuredHost: String?, configuredPort: String?, expectedHost: String?, expectedPort: Int?, matches: Bool?, effective: String = "unknown") {
        self.configuredHost = configuredHost
        self.configuredPort = configuredPort
        self.expectedHost = expectedHost
        self.expectedPort = expectedPort
        self.matches = matches
        self.effective = effective
    }
}

public struct ProjectObservedPHP: Codable, Equatable, Sendable {
    public let installedVersions: [String]
    public let runningVersions: [String]
    public let resolvedVersion: String?
    public let resolvedState: String
    public let defaultVersion: String?

    public init(installedVersions: [String], runningVersions: [String], resolvedVersion: String?, resolvedState: String, defaultVersion: String?) {
        self.installedVersions = installedVersions
        self.runningVersions = runningVersions
        self.resolvedVersion = resolvedVersion
        self.resolvedState = resolvedState
        self.defaultVersion = defaultVersion
    }
}

public struct ProjectObservedRoute: Codable, Equatable, Sendable {
    public let intentExists: Bool
    public let hostname: String?
    public let documentRoot: String?
    public let target: String?
    public let tls: TLSMode?
    public let routerState: RouterState
    public let routerHealth: RouterHealth

    public init(intentExists: Bool, hostname: String? = nil, documentRoot: String? = nil, target: String? = nil, tls: TLSMode? = nil, routerState: RouterState, routerHealth: RouterHealth) {
        self.intentExists = intentExists
        self.hostname = hostname
        self.documentRoot = documentRoot
        self.target = target
        self.tls = tls
        self.routerState = routerState
        self.routerHealth = routerHealth
    }
}

public struct ProjectObservedEnvironment: Codable, Equatable, Sendable {
    public let php: ProjectObservedPHP
    public let mysql: MySQLStatus?
    public let mailpit: MailpitStatus?
    public let route: ProjectObservedRoute
    public let dns: DNSStatus
    public let tls: TLSStatus
    public let standardPorts: StandardPortsStatus

    public init(php: ProjectObservedPHP, mysql: MySQLStatus?, mailpit: MailpitStatus?, route: ProjectObservedRoute, dns: DNSStatus, tls: TLSStatus, standardPorts: StandardPortsStatus) {
        self.php = php
        self.mysql = mysql
        self.mailpit = mailpit
        self.route = route
        self.dns = dns
        self.tls = tls
        self.standardPorts = standardPorts
    }
}

public struct ProjectDerivedEnvironment: Codable, Equatable, Sendable {
    public let framework: ProjectFrameworkInspection
    public let phpResolution: String
    public let dbEndpoint: ProjectEndpointObservation
    public let mailEndpoint: ProjectEndpointObservation
    public let routeDocumentRootMatches: Bool?
    public let configCache: ProjectConfigCacheObservation

    public init(framework: ProjectFrameworkInspection, phpResolution: String, dbEndpoint: ProjectEndpointObservation, mailEndpoint: ProjectEndpointObservation, routeDocumentRootMatches: Bool?, configCache: ProjectConfigCacheObservation) {
        self.framework = framework
        self.phpResolution = phpResolution
        self.dbEndpoint = dbEndpoint
        self.mailEndpoint = mailEndpoint
        self.routeDocumentRootMatches = routeDocumentRootMatches
        self.configCache = configCache
    }
}

public struct ProjectSecretEnvironment: Codable, Equatable, Sendable {
    public let databasePassword: ProjectSecretAvailability
    public let mailPassword: ProjectSecretAvailability
    public let notes: [String]

    public init(databasePassword: ProjectSecretAvailability, mailPassword: ProjectSecretAvailability, notes: [String] = []) {
        self.databasePassword = databasePassword
        self.mailPassword = mailPassword
        self.notes = notes
    }
}

public struct ProjectEnvironmentReport: Codable, Equatable, Sendable {
    public let identity: ProjectEnvironmentIdentity
    public let desired: ProjectDesiredEnvironment
    public let configured: ProjectConfiguredEnvironment
    public let observed: ProjectObservedEnvironment
    public let derived: ProjectDerivedEnvironment
    public let secret: ProjectSecretEnvironment
    public let diagnostics: [ProjectDiagnostic]

    public init(identity: ProjectEnvironmentIdentity, desired: ProjectDesiredEnvironment, configured: ProjectConfiguredEnvironment, observed: ProjectObservedEnvironment, derived: ProjectDerivedEnvironment, secret: ProjectSecretEnvironment, diagnostics: [ProjectDiagnostic]) {
        self.identity = identity
        self.desired = desired
        self.configured = configured
        self.observed = observed
        self.derived = derived
        self.secret = secret
        self.diagnostics = diagnostics
    }
}

public struct ProjectEnvironmentRequest: Codable, Equatable, Sendable {
    public let selector: String?
    public let workingDirectory: String

    public init(selector: String? = nil, workingDirectory: String) {
        self.selector = selector
        self.workingDirectory = workingDirectory
    }
}

public enum ProjectEnvironmentInspectionError: Error, Equatable, Sendable {
    case projectNotFound
    case projectNameAmbiguous
    case unavailable
}

public struct ProjectEnvironmentInspector: Sendable {
    public init() {}

    public func inspect(project: Project, routes: [RouteIntent], phpPackages: [PHPPackage], phpStatuses: [PHPStatus], phpDefault: String?, mysql: MySQLStatus?, mailpit: MailpitStatus?, router: RouterStatus, dns: DNSStatus, tls: TLSStatus, standardPorts: StandardPortsStatus) -> ProjectEnvironmentReport {
        let root = URL(fileURLWithPath: project.rootPath.string, isDirectory: true)
        let framework = inspectFramework(root: root)
        let desiredResult = readDesiredState(root: root)
        let env = readDotenv(root: root)
        let cache = inspectConfigCache(root: root, envPath: root.appendingPathComponent(".env"))
        let route = routeObservation(project: project, framework: framework, routes: routes, router: router)
        let installed = phpPackages.map(\.version).sorted()
        let running = phpStatuses.filter { $0.state == .running }.map(\.version).sorted()
        let resolved = resolvePHP(family: desiredResult.state.php, packages: phpPackages)
        let phpState = resolved == nil ? "unresolved" : (phpStatuses.first(where: { $0.version == resolved })?.state.rawValue ?? "not-running")
        let observedPHP = ProjectObservedPHP(installedVersions: installed, runningVersions: running, resolvedVersion: resolved, resolvedState: phpState, defaultVersion: phpDefault)
        let dbEndpoint = endpointObservation(host: env.dbHost, port: env.dbPort, expectedHost: "127.0.0.1", expectedPort: mysql?.port, matches: endpointMatches(host: env.dbHost, port: env.dbPort, expectedPort: mysql?.port))
        let mailEndpoint = endpointObservation(host: env.mailHost, port: env.mailPort, expectedHost: "127.0.0.1", expectedPort: mailpit?.smtpPort, matches: endpointMatches(host: env.mailHost, port: env.mailPort, expectedPort: mailpit?.smtpPort))
        let routeRootMatch = framework.suggestedDocumentRoot.map { root.appendingPathComponent($0).path } == route.documentRoot
        let derived = ProjectDerivedEnvironment(framework: framework, phpResolution: phpResolution(desired: desiredResult.state.php, resolved: resolved), dbEndpoint: dbEndpoint, mailEndpoint: mailEndpoint, routeDocumentRootMatches: route.documentRoot == nil ? nil : routeRootMatch, configCache: cache)
        let observed = ProjectObservedEnvironment(php: observedPHP, mysql: mysql, mailpit: mailpit, route: route, dns: dns, tls: tls, standardPorts: standardPorts)
        let secrets = ProjectSecretEnvironment(databasePassword: env.databasePassword, mailPassword: env.mailPassword, notes: ["Secret values are never returned by inspection."])
        return ProjectEnvironmentReport(identity: .init(project: project), desired: desiredResult.state, configured: env.configured, observed: observed, derived: derived, secret: secrets, diagnostics: diagnostics(project: project, desired: desiredResult.state, desiredError: desiredResult.error, framework: framework, env: env, cache: cache, route: route, resolvedPHP: resolved, mysql: mysql, mailpit: mailpit, dns: dns, tls: tls, standardPorts: standardPorts, routeRootMatch: derived.routeDocumentRootMatches))
    }

    private struct DesiredRead { let state: ProjectDesiredEnvironment; let error: String? }
    private struct EnvRead { let configured: ProjectConfiguredEnvironment; let dbHost: String?; let dbPort: String?; let mailHost: String?; let mailPort: String?; let databasePassword: ProjectSecretAvailability; let mailPassword: ProjectSecretAvailability }

    private func readDesiredState(root: URL) -> DesiredRead {
        let url = root.appendingPathComponent("vaelen.yml")
        guard FileManager.default.fileExists(atPath: url.path) else { return DesiredRead(state: .init(file: .absent), error: nil) }
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            try validateYAMLKeys(contents)
            let value = try YAMLDecoder().decode(ProjectEnvironmentYAML.self, from: contents)
            return DesiredRead(state: .init(file: .valid, php: value.php, secureWeb: value.web?.secure, mysql: value.services?.mysql, mailpit: value.services?.mailpit), error: nil)
        } catch { return DesiredRead(state: .init(file: .invalid, fileError: String(describing: error)), error: String(describing: error)) }
    }

    private func validateYAMLKeys(_ contents: String) throws {
        guard let root = try load(yaml: contents) as? [String: Any] else { throw ProjectYAMLError.invalidRoot }
        let allowedRoot = Set(["version", "php", "web", "services"])
        if let unknown = root.keys.first(where: { !allowedRoot.contains($0) }) { throw ProjectYAMLError.unknownField(unknown) }
        if let web = root["web"] as? [String: Any], let unknown = web.keys.first(where: { $0 != "secure" }) { throw ProjectYAMLError.unknownField("web.\(unknown)") }
        if let services = root["services"] as? [String: Any], let unknown = services.keys.first(where: { $0 != "mysql" && $0 != "mailpit" }) { throw ProjectYAMLError.unknownField("services.\(unknown)") }
    }

    private func readDotenv(root: URL) -> EnvRead {
        let path = root.appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
            let configured = ProjectConfiguredEnvironment(envFile: path.path, envFilePresent: false)
            return EnvRead(configured: configured, dbHost: nil, dbPort: nil, mailHost: nil, mailPort: nil, databasePassword: .unknown, mailPassword: .unknown)
        }
        let values = parseDotenv(contents)
        let dbPassword = secretAvailability(values["DB_PASSWORD"])
        let mailPassword = secretAvailability(values["MAIL_PASSWORD"])
        let configured = ProjectConfiguredEnvironment(envFile: path.path, envFilePresent: true, dbConnection: values["DB_CONNECTION"], dbHost: values["DB_HOST"], dbPort: values["DB_PORT"], database: values["DB_DATABASE"], usernameConfigured: values["DB_USERNAME"]?.isEmpty == false, password: dbPassword, mailer: values["MAIL_MAILER"], mailHost: values["MAIL_HOST"], mailPort: values["MAIL_PORT"], mailEncryption: values["MAIL_ENCRYPTION"] ?? values["MAIL_SCHEME"], mailPassword: mailPassword, interpolationDetected: values.values.contains { $0.contains("${") || $0.contains("$ ") })
        return EnvRead(configured: configured, dbHost: values["DB_HOST"], dbPort: values["DB_PORT"], mailHost: values["MAIL_HOST"], mailPort: values["MAIL_PORT"], databasePassword: dbPassword, mailPassword: mailPassword)
    }

    private func parseDotenv(_ contents: String) -> [String: String] {
        var result = [String: String]()
        for line in contents.split(whereSeparator: \.isNewline) {
            let raw = String(line).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty, !raw.hasPrefix("#"), let separator = raw.firstIndex(of: "=") else { continue }
            let key = String(raw[..<separator]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { continue }
            var value = String(raw[raw.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") { value = String(value.dropFirst().dropLast()) }
            result[key] = value
        }
        return result
    }

    private func inspectConfigCache(root: URL, envPath: URL) -> ProjectConfigCacheObservation {
        let cache = root.appendingPathComponent("bootstrap/cache/config.php")
        let envDate = try? FileManager.default.attributesOfItem(atPath: envPath.path)[.modificationDate] as? Date
        guard let cacheDate = try? FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date else { return .init(state: "absent", cachePath: cache.path, envModifiedAt: envDate) }
        let newer = envDate.map { $0 > cacheDate }
        return .init(state: newer == true ? "present, .env is newer" : "present, appears current", cachePath: cache.path, cacheModifiedAt: cacheDate, envModifiedAt: envDate, envNewerThanCache: newer)
    }

    private func inspectFramework(root: URL) -> ProjectFrameworkInspection {
        let fm = FileManager.default
        let markers = ["artisan": fm.fileExists(atPath: root.appendingPathComponent("artisan").path), "composer.json": fm.fileExists(atPath: root.appendingPathComponent("composer.json").path), "bootstrap/": fm.fileExists(atPath: root.appendingPathComponent("bootstrap", isDirectory: true).path), "config/": fm.fileExists(atPath: root.appendingPathComponent("config", isDirectory: true).path), "public/index.php": fm.fileExists(atPath: root.appendingPathComponent("public/index.php").path)]
        var evidence = markers.filter { $0.value }.map(\.key).sorted()
        var composerPHP: String?
        if let data = try? Data(contentsOf: root.appendingPathComponent("composer.json")), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let requirements = object["require"] as? [String: Any] {
            if let php = requirements["php"] as? String { composerPHP = php; evidence.append("composer.json require.php") }
            if (requirements["laravel/framework"] as? String) != nil { evidence.append("composer.json laravel/framework") }
        }
        let laravel = markers["artisan"] == true && markers["bootstrap/"] == true && markers["config/"] == true && markers["public/index.php"] == true
        if laravel { return .init(framework: "Laravel", confidence: .high, evidence: Array(Set(evidence)).sorted(), suggestedDocumentRoot: "public/", composerPHPRequirement: composerPHP) }
        if markers.values.filter({ $0 }).count >= 2 { return .init(framework: "Generic PHP", confidence: .medium, evidence: Array(Set(evidence)).sorted(), suggestedDocumentRoot: fm.fileExists(atPath: root.appendingPathComponent("public", isDirectory: true).path) ? "public/" : nil, composerPHPRequirement: composerPHP) }
        return .init(framework: "Generic/Unknown", confidence: .low, evidence: evidence, composerPHPRequirement: composerPHP)
    }

    private func routeObservation(project: Project, framework: ProjectFrameworkInspection, routes: [RouteIntent], router: RouterStatus) -> ProjectObservedRoute {
        let inferredDocumentRoot = framework.suggestedDocumentRoot.map { URL(fileURLWithPath: project.rootPath.string).appendingPathComponent($0).path }
        let intent = routes.first {
            ($0.projectID == project.id?.rawValue) ||
            ($0.projectPath == project.rootPath.string) ||
            routeDocumentRoot($0.route) == inferredDocumentRoot
        }
        guard let route = intent?.route else { return .init(intentExists: false, routerState: router.state, routerHealth: router.health) }
        let documentRoot: String?
        let target: String
        switch route.target {
        case .fastCGI(let socket, let root): documentRoot = root; target = "fastcgi \(socket)"
        case .staticFiles(let root): documentRoot = root; target = "static"
        case .http(let host, let port): documentRoot = nil; target = "http \(host):\(port)"
        }
        return .init(intentExists: true, hostname: route.hostname, documentRoot: documentRoot, target: target, tls: route.tls, routerState: router.state, routerHealth: router.health)
    }

    private func routeDocumentRoot(_ route: Route) -> String? {
        switch route.target {
        case .fastCGI(_, let root), .staticFiles(let root): return root
        case .http: return nil
        }
    }

    private func resolvePHP(family: String?, packages: [PHPPackage]) -> String? {
        guard let family else { return nil }
        return packages.filter { $0.version == family || $0.version.split(separator: ".").prefix(2).joined(separator: ".") == family }.sorted { $0.version < $1.version }.last?.version
    }

    private func phpResolution(desired: String?, resolved: String?) -> String { guard let desired else { return "unknown" }; guard let resolved else { return "desired \(desired) is unavailable" }; return "\(desired) resolves to \(resolved)" }
    private func endpointObservation(host: String?, port: String?, expectedHost: String?, expectedPort: Int?, matches: Bool?) -> ProjectEndpointObservation { .init(configuredHost: host, configuredPort: port, expectedHost: expectedHost, expectedPort: expectedPort, matches: matches) }
    private func endpointMatches(host: String?, port: String?, expectedPort: Int?) -> Bool? { guard let host, let port, let expectedPort else { return nil }; return host == "127.0.0.1" && port == String(expectedPort) }
    private func secretAvailability(_ value: String?) -> ProjectSecretAvailability { guard let value else { return .unknown }; return value.isEmpty || value.lowercased() == "null" ? .missing : .available }

    private func diagnostics(project: Project, desired: ProjectDesiredEnvironment, desiredError: String?, framework: ProjectFrameworkInspection, env: EnvRead, cache: ProjectConfigCacheObservation, route: ProjectObservedRoute, resolvedPHP: String?, mysql: MySQLStatus?, mailpit: MailpitStatus?, dns: DNSStatus, tls: TLSStatus, standardPorts: StandardPortsStatus, routeRootMatch: Bool?) -> [ProjectDiagnostic] {
        var result = [ProjectDiagnostic]()
        if project.registrationKind == .discovered { result.append(.init(code: "PROJECT_DISCOVERED_EPHEMERAL", severity: .info, message: "This project is discovered and can be inspected read-only; durable environment ownership requires linking it.", suggestion: "Link the project before assigning durable Vaelen environment state.")) }
        if let desiredError { result.append(.init(code: "VAELEN_CONFIG_INVALID", severity: .error, message: "vaelen.yml is invalid: \(desiredError)", suggestion: "Correct vaelen.yml version, fields, and types.")) }
        if desired.php != nil && resolvedPHP == nil { result.append(.init(code: "PHP_FAMILY_UNAVAILABLE", severity: .warning, message: "The desired PHP family is not installed in Vaelen.", suggestion: "Install a compatible Vaelen PHP package explicitly.")) }
        if desired.mysql == true, mysql?.state != .running { result.append(.init(code: "MYSQL_NOT_HEALTHY", severity: .warning, message: "The project requests MySQL, but the Vaelen MySQL service is not running healthy.", suggestion: "Start or inspect MySQL explicitly.")) }
        if desired.mailpit == true, mailpit?.state != .running { result.append(.init(code: "MAILPIT_NOT_HEALTHY", severity: .warning, message: "The project requests Mailpit, but the Vaelen Mailpit service is not running healthy.", suggestion: "Start or inspect Mailpit explicitly.")) }
        if env.configured.dbHost != nil, env.configured.dbPort != nil, env.configured.dbConnection == "mysql", env.configured.database != nil, env.configured.password != .unknown { }
        if env.configured.dbHost != nil, env.configured.dbPort != nil, env.configured.password == .missing { result.append(.init(code: "DB_PASSWORD_MISSING", severity: .warning, message: "A database password is not configured.", suggestion: "Review application configuration explicitly.")) }
        if env.configured.mailer == "smtp", env.configured.mailPassword == .missing { result.append(.init(code: "MAIL_PASSWORD_MISSING", severity: .info, message: "SMTP mail password is explicitly empty or null.", suggestion: nil)) }
        if cache.state == "present, .env is newer" { result.append(.init(code: "LARAVEL_CONFIG_CACHE_STALE_POSSIBLE", severity: .warning, message: "Laravel config cache exists and .env is newer; effective Laravel configuration is unknown.", suggestion: "Clear the cache explicitly if the application owner intends to do so.")) }
        if !route.intentExists { result.append(.init(code: "ROUTE_INTENT_MISSING", severity: .warning, message: "No Vaelen route intent is associated with this project.", suggestion: "Inspect existing routing before making an explicit route change.")) }
        if routeRootMatch == false { result.append(.init(code: "ROUTE_DOCUMENT_ROOT_MISMATCH", severity: .warning, message: "The route document root differs from the framework-derived document root.", suggestion: "Review the route manually; no route was changed.")) }
        if desired.secureWeb == true && tls.trustObserved == false { result.append(.init(code: "TLS_NOT_TRUSTED", severity: .warning, message: "Secure web access is desired but Vaelen TLS is not observed as trusted.", suggestion: "Inspect TLS capability state.")) }
        if dns.health != "healthy" { result.append(.init(code: "DNS_UNHEALTHY", severity: .warning, message: "Vaelen DNS capability is not healthy.", suggestion: "Inspect DNS capability state.")) }
        if standardPorts.state.rawValue != "healthy" && desired.secureWeb == true { result.append(.init(code: "STANDARD_PORTS_UNHEALTHY", severity: .warning, message: "Secure web intent exists but standard local ports are not healthy.", suggestion: "Inspect standard port capability state.")) }
        if project.availability != .available { result.append(.init(code: "PROJECT_UNAVAILABLE", severity: .error, message: "The registered project path is unavailable.", suggestion: "Restore the project path before inspecting runtime integration.")) }
        return result
    }
}

private struct ProjectEnvironmentYAML: Decodable {
    let version: Int
    let php: String?
    let web: Web?
    let services: Services?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let allowed = Set(CodingKeys.allCases.map(\.stringValue))
        if let unknown = keys.subtracting(allowed).sorted().first { throw ProjectYAMLError.unknownField(unknown) }
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else { throw ProjectYAMLError.unsupportedVersion(version) }
        php = try container.decodeIfPresent(String.self, forKey: .php)
        web = try container.decodeIfPresent(Web.self, forKey: .web)
        services = try container.decodeIfPresent(Services.self, forKey: .services)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, php, web, services }

    struct Web: Decodable {
        let secure: Bool?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: WebKeys.self)
            let keys = Set(container.allKeys.map(\.stringValue))
            if let unknown = keys.subtracting(Set(WebKeys.allCases.map(\.stringValue))).sorted().first { throw ProjectYAMLError.unknownField("web.\(unknown)") }
            secure = try container.decodeIfPresent(Bool.self, forKey: .secure)
        }
        private enum WebKeys: String, CodingKey, CaseIterable { case secure }
    }

    struct Services: Decodable {
        let mysql: Bool?
        let mailpit: Bool?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ServiceKeys.self)
            let keys = Set(container.allKeys.map(\.stringValue))
            if let unknown = keys.subtracting(Set(ServiceKeys.allCases.map(\.stringValue))).sorted().first { throw ProjectYAMLError.unknownField("services.\(unknown)") }
            mysql = try container.decodeIfPresent(Bool.self, forKey: .mysql)
            mailpit = try container.decodeIfPresent(Bool.self, forKey: .mailpit)
        }
        private enum ServiceKeys: String, CodingKey, CaseIterable { case mysql, mailpit }
    }
}

private enum ProjectYAMLError: Error, CustomStringConvertible {
    case unknownField(String)
    case unsupportedVersion(Int)
    case invalidRoot
    var description: String {
        switch self {
        case .unknownField(let field): return "unknown field \(field)"
        case .unsupportedVersion(let version): return "unsupported schema version \(version)"
        case .invalidRoot: return "root must be a mapping"
        }
    }
}
