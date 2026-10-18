import Darwin
import Foundation
import AppKit
import VaelenCore
import VaelenIPC

private struct PHPConfigurationEditorPreference: Codable {
    let bundleIdentifier: String
    let applicationPath: String

    static func load() throws -> PHPConfigurationEditorPreference? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vaelen/config/editor.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

enum CLICommand {
    case help(path: [String])
    case version
    case status(json: Bool)
    case doctor(json: Bool)
    case routeTLS(hostname: String?, secure: Bool)
    case link(path: String?, hostname: String?)
    case unlink(path: String?)
    case links(json: Bool)
    case edit(selector: String?)
    case park(path: String?)
    case unpark(path: String?)
    case parks(json: Bool)
    case parked(json: Bool)
    case sites(json: Bool)
    case siteDriver(selector: String?, json: Bool)
    case siteInfo(selector: String?, json: Bool)
    case openSite(selector: String?)
    case databaseOpen(selector: String?)
    case projectStatus(selector: String?, json: Bool)
    case projectInspect(selector: String?, json: Bool)
    case projectDoctor(selector: String?, json: Bool)
    case projectPlan(selector: String?, json: Bool)
    case projectActivate(selector: String?, json: Bool)
    case projectPHP(selector: String?, version: String?, useDefault: Bool, json: Bool)
    case phpVersions(json: Bool)
    case phpInstall(String)
    case phpUpdate(String)
    case phpRemove(String)
    case phpOperation(json: Bool)
    case phpDefault(json: Bool)
    case phpDefaultSet(String)
    case phpUse(String)
    case phpExec(version: String?, effective: Bool, arguments: [String])
    case phpResolvePath
    case isolated(json: Bool)
    case phpINI(version: String?)
    case shellStatus
    case shellInstall
    case shellUninstall
    case phpStart(String)
    case phpStop(String)
    case phpStatus(String, json: Bool)
    case phpConfig(version: String?)
    case mysqlVersions(json: Bool)
    case mysqlInstall(String)
    case mysqlUse(String)
    case mysqlInitialize
    case mysqlStart
    case mysqlStop
    case mysqlStatus(json: Bool)
    case mailpitVersions(json: Bool)
    case mailpitInstall(String)
    case mailpitStart
    case mailpitStop
    case mailpitStatus(json: Bool)
    case mailpitOpen
    case routingStatus
    case routingStart
    case routingStop
    case routeList(json: Bool)
    case routeAdd(hostname: String, documentRoot: String, socketPath: String?, projectID: UUID?, tls: Bool)
    case routeRemove(RouteID)
    case routeAssociate(RouteID, ProjectID)
    case dnsStatus(json: Bool)
    case dnsInstall(takeover: Bool)
    case dnsRemove
    case tlsStatus(json: Bool)
    case tlsInstall
    case tlsRemove
    case tlsTrust
    case tlsUntrust
    case portsStatus(json: Bool)
    case portsInstall
    case portsRemove
}

enum RouteSelectionError: Error, Equatable {
    case notFound(String)
    case noRouteForDirectory
    case ambiguous([String])
}

func selectSiteRoute(_ routes: [RouteIntent], hostname: String?, workingDirectory: String) throws -> RouteIntent {
    if let hostname {
        guard let route = routes.first(where: { $0.route.hostname.caseInsensitiveCompare(hostname) == .orderedSame }) else { throw RouteSelectionError.notFound(hostname) }
        return route
    }
    let cwd = URL(fileURLWithPath: workingDirectory).standardizedFileURL.resolvingSymlinksInPath().path
    let matches = routes.filter { intent in
        let path: String
        if let projectPath = intent.projectPath { path = projectPath }
        else {
            switch intent.route.target {
            case .fastCGI(_, let documentRoot), .staticFiles(let documentRoot):
                let root = URL(fileURLWithPath: documentRoot).standardizedFileURL
                path = root.lastPathComponent == "public" ? root.deletingLastPathComponent().path : root.path
            case .http: return false
            }
        }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == cwd
    }
    guard !matches.isEmpty else { throw RouteSelectionError.noRouteForDirectory }
    guard matches.count == 1 else { throw RouteSelectionError.ambiguous(matches.map(\.route.hostname).sorted()) }
    return matches[0]
}

func routeTLSUpdate(_ intent: RouteIntent, secure: Bool) -> RouteIntent? {
    let mode: TLSMode = secure ? .local : .disabled
    guard intent.route.tls != mode else { return nil }
    return RouteIntent(route: Route(id: intent.route.id, hostname: intent.route.hostname, target: intent.route.target, tls: mode), projectID: intent.projectID, projectPath: intent.projectPath)
}

func routesForProject(_ routes: [RouteIntent], projectID: UUID?, projectPath: String) -> [RouteIntent] {
    let canonicalPath = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath().path
    return routes.filter { route in
        if projectID != nil && route.projectID == projectID { return true }
        if let path = route.projectPath { return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == canonicalPath }
        let docroot: String
        switch route.route.target {
        case .fastCGI(_, let value), .staticFiles(let value): docroot = value
        case .http: return false
        }
        let root = URL(fileURLWithPath: docroot).standardizedFileURL
        let inferredProjectPath = root.lastPathComponent == "public" ? root.deletingLastPathComponent().path : root.path
        return URL(fileURLWithPath: inferredProjectPath).resolvingSymlinksInPath().path == canonicalPath
    }
}

func hostnameCollision(_ hostname: String, candidateProjectRoutes: [RouteIntent], allRoutes: [RouteIntent]) -> RouteIntent? {
    guard let collision = allRoutes.first(where: { $0.route.hostname.caseInsensitiveCompare(hostname) == .orderedSame }) else { return nil }
    return candidateProjectRoutes.contains(where: { $0.route.id == collision.route.id }) ? nil : collision
}

enum AdditionalHostConfigurationError: Error, Equatable {
    case differingTargets
    case differingTLSModes
}

func additionalHostConfiguration(from routes: [RouteIntent]) throws -> (target: RouteTarget, tls: TLSMode)? {
    guard let first = routes.first else { return nil }
    guard routes.allSatisfy({ $0.route.target == first.route.target }) else { throw AdditionalHostConfigurationError.differingTargets }
    guard routes.allSatisfy({ $0.route.tls == first.route.tls }) else { throw AdditionalHostConfigurationError.differingTLSModes }
    return (first.route.target, first.route.tls)
}

func preflightLinkCollision(hostname: String, projectPath: String, routes: [RouteIntent]) -> RouteIntent? {
    let samePathRoutes = routesForProject(routes, projectID: nil, projectPath: projectPath)
    guard samePathRoutes.isEmpty else { return nil }
    return hostnameCollision(hostname, candidateProjectRoutes: [], allRoutes: routes)
}

func withNewLinkRollback<Value>(linkCreatedByInvocation: Bool, rollback: () async -> Void, operation: () async throws -> Value) async throws -> Value {
    do { return try await operation() }
    catch {
        if linkCreatedByInvocation { await rollback() }
        throw error
    }
}

func linkFailureDescription(_ error: Error) -> String {
    if let clientError = error as? CoreClientError, case .remote(let payload) = clientError { return payload.message }
    if let cliError = error as? CLIError { return cliError.description }
    return String(describing: error)
}

private struct ProjectListEnvelope: Encodable { let projects: [ProjectWire] }
private struct ParkedPathListEnvelope: Encodable { let paths: [ParkedPathWire] }
private struct RouteListEnvelope: Encodable { let routes: [RouteIntent] }
private struct StatusEnvelope: Encodable {
    let core: StatusPayload
}
private struct StatusPayload: Encodable {
    let state: String
    let version: String
    let pid: Int32
    let protocolVersion: Int
}
private struct LegacyPortsStatusEnvelope: Encodable { let ports: LegacyPortsStatus }
private struct LegacyPortsStatus: Encodable {
    let state: StandardPortsState
    let httpPort: Int
    let httpsPort: Int
    let backendHTTPPort: Int
    let backendHTTPSPort: Int
    let anchor: String
    let detail: String?
    let conflict: String?
    let ownership: StandardPortsOwnership?

    init(_ value: StandardPortsStatus) {
        state = value.state; httpPort = value.httpPort; httpsPort = value.httpsPort
        backendHTTPPort = value.backendHTTPPort; backendHTTPSPort = value.backendHTTPSPort
        anchor = value.anchor; detail = value.detail; conflict = value.conflict; ownership = value.ownership
    }
}

@main
struct VaelenCLIMain {
    static let usage = CLIDocumentation.text(for: [])

    static func helpText(for path: [String]) -> String { CLIDocumentation.text(for: path) }

    private static func groupTitle(for line: String) -> Bool {
        let titles = CLIDocumentation.groups + ["PHP commands", "MySQL commands", "Mailpit commands", "Project commands", "Web commands", "Runtime commands", "Networking commands", "Site commands", "Routing commands", "Route commands", "Dns commands", "Tls commands", "Ports commands", "Shell commands", "Commands", "Examples", "Example:"]
        return titles.contains(line)
    }

    static func printHelp(_ text: String) {
        guard ProcessInfo.processInfo.environment["NO_COLOR"] == nil,
              ProcessInfo.processInfo.environment["TERM"] != "dumb",
              isatty(STDOUT_FILENO) == 1 else { print(text); return }
        let rendered = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let value = String(line)
            if groupTitle(for: value) || (["project", "php", "mysql", "mailpit", "routing", "route", "dns", "tls", "ports", "shell", "status", "link", "unlink", "park", "unpark", "links", "parks", "parked", "sites", "open", "db", "site", "site driver", "site info", "list"].contains(value)) {
                return "\u{001B}[1;36m\(value)\u{001B}[0m"
            }
            if value.hasPrefix("  "), let gap = value.range(of: "  ", range: value.index(value.startIndex, offsetBy: 2)..<value.endIndex) {
                let commandEnd = gap.lowerBound
                let command = value[..<commandEnd]
                if command.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    return "\u{001B}[36m\(command)\u{001B}[0m\(value[commandEnd...])"
                }
            }
            return value
        }.joined(separator: "\n")
        print(rendered)
    }

    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
                printHelp(usage)
                exit(0)
            }
            if arguments.last == "--help" || arguments.last == "-h" {
                printHelp(CLIDocumentation.focusedText(for: Array(arguments.dropLast()).filter { $0 != "help" }))
                exit(0)
            }
            let command = try parse(arguments)
            if case .version = command {
                print("Vaelen \(VaelenBuildInfo.version)")
                exit(0)
            }
            if case .doctor(let json) = command {
                let paths = CoreEndpointPaths()
                let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: .init(name: "val", version: VaelenBuildInfo.version))
                let report = await runDoctor(client)
                if json {
                    do { print(String(decoding: try IPCCodec.encode(report), as: UTF8.self)) }
                    catch { fail("Unable to encode Vaelen Doctor report.", code: 1) }
                } else {
                    print(report.terminalOutput)
                }
                exit(report.exitCode)
            }
            if case .help(let path) = command {
                printHelp(helpText(for: path))
                exit(0)
            }
            switch command {
            case .shellStatus:
                let status = try PHPShellIntegration.status()
                let tint = status.contains("Enabled") ? 32 : status.contains("Broken") ? 31 : 90
                print(HumanOutput.message(status, tint: tint)); exit(0)
            case .shellInstall: print(HumanOutput.success(try PHPShellIntegration.install())); exit(0)
            case .shellUninstall: print(HumanOutput.success(try PHPShellIntegration.uninstall())); exit(0)
            default: break
            }
            let paths = CoreEndpointPaths()
            let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: .init(name: "val", version: VaelenBuildInfo.version))
            try await client.connect()
            try await execute(command, client: client, workingDirectory: FileManager.default.currentDirectoryPath)
            await client.disconnect()
            exit(0)
        } catch let error as CoreClientError {
            if case .coreUnavailable = error { fail("Vaelen Core is not running. Start Vaelen and retry.", code: 3) }
            if case .protocolIncompatible(let client, let core) = error { fail("Vaelen Core uses an incompatible protocol version.\n\nClient: \(client)\nCore:   \(core)", code: 4) }
            if case .coreIncompatible = error { fail("The running Vaelen Core is incompatible with this client.\nRestart Vaelen Core and try again.", code: 4) }
            if case .remote(let payload) = error {
                if payload.message == "Unknown Core method: php.resolve." || payload.message == "Unknown Core method: php.resolve" {
                    fail("Vaelen Core is too old for project-aware PHP resolution. Restart or update Vaelen, then retry.", code: 4)
                }
                fail(payload.message, code: 1)
            }
            fail("Vaelen Core returned an invalid response.", code: 1)
        } catch let error as CLIError {
            switch error {
            case .usage, .commandUsage:
                FileHandle.standardError.write(Data((HumanOutput.semantic(error.description, tint: 31) + "\n").utf8))
                exit(1)
            case .message:
                fail(error.description, code: 1)
            case .applicationFailure(let command, let status):
                fail("\(command) exited with status \(status).", code: siteInfoProcessExitCode(status))
            }
        } catch {
            fail(message(for: error), code: 1)
        }
    }

    static func parse(_ args: [String]) throws -> CLICommand {
        guard let first = args.first else { throw CLIError.usage }
        switch first {
        case "--version", "-V":
            guard args.count == 1 else { throw CLIError.usage }
            return .version
        case "help", "--help", "-h":
            return .help(path: Array(args.dropFirst()))
        case "list":
            guard args.count == 1 else { throw CLIError.usage }
            return .help(path: ["list"])
        case "web", "runtime", "networking":
            guard args.count == 1 else { throw CLIError.commandUsage(first) }
            return .help(path: [first])
        case "use":
            guard args.count == 2 else { throw CLIError.commandUsage("use") }
            return .phpUse(args[1])
        case "isolate":
            guard args.count == 2 || args.count == 3 else { throw CLIError.commandUsage("isolate") }
            return .projectPHP(selector: args.count == 3 ? args[2] : nil, version: args[1], useDefault: false, json: false)
        case "unisolate":
            guard args.count == 1 || args.count == 2 else { throw CLIError.commandUsage("unisolate") }
            return .projectPHP(selector: args.count == 2 ? args[1] : nil, version: nil, useDefault: true, json: false)
        case "isolated":
            return .isolated(json: try optionalJSONOption(Array(args.dropFirst())))
        case "which-php":
            guard args.count == 1 else { throw CLIError.commandUsage("which-php") }
            return .phpResolvePath
        case "ini":
            guard args.count == 1 || args.count == 2 else { throw CLIError.commandUsage("ini") }
            return .phpINI(version: args.count == 2 ? args[1] : nil)
        case "status": return .status(json: try listJSONOption(args))
        case "doctor": return .doctor(json: try listJSONOption(args))
        case "secure", "unsecure":
            guard args.count <= 2 else { throw CLIError.usage }
            return .routeTLS(hostname: args.count == 2 ? args[1] : nil, secure: first == "secure")
        case "links": return .links(json: try listJSONOption(args))
        case "edit": guard args.count <= 2 else { throw CLIError.commandUsage("edit") }; return .edit(selector: args.count == 2 ? args[1] : nil)
        case "parks", "paths": return .parks(json: try listJSONOption(args))
        case "parked": return .parked(json: try listJSONOption(args))
        case "sites": return .sites(json: try listJSONOption(args))
        case "open": guard args.count <= 2 else { throw CLIError.commandUsage("open") }; return .openSite(selector: args.count == 2 ? args[1] : nil)
        case "db": guard args.count <= 2 else { throw CLIError.commandUsage("db") }; return .databaseOpen(selector: args.count == 2 ? args[1] : nil)
        case "site":
            if args.count == 1 { return .help(path: [first]) }
            guard args.count >= 2, ["driver", "info"].contains(args[1]) else { throw CLIError.commandUsage("site") }
            var selector: String?
            var json = false
            for value in args.dropFirst(2) {
                if value == "--json", !json { json = true }
                else if !value.hasPrefix("-"), selector == nil { selector = value }
                else { throw CLIError.commandUsage("site") }
            }
            return args[1] == "driver" ? .siteDriver(selector: selector, json: json) : .siteInfo(selector: selector, json: json)
        case "project":
            if args.count == 1 { return .help(path: [first]) }
            if args[1] == "php" {
                var selector: String?; var version: String?; var useDefault = false; var json = false
                var i = 2
                while i < args.count { let value = args[i]; if value == "--json" { json = true } else if value == "--use-default" { useDefault = true } else if value == "--version" { i += 1; guard i < args.count else { throw CLIError.usage }; version = args[i] } else if selector == nil { selector = value } else { throw CLIError.usage }; i += 1 }
                guard !(version != nil && useDefault) else { throw CLIError.usage }
                return .projectPHP(selector: selector, version: version, useDefault: useDefault, json: json)
            }
            let parsed = try projectEnvironmentArguments(Array(args.dropFirst(2)))
            switch args[1] {
            case "status": return .projectStatus(selector: parsed.selector, json: parsed.json)
            case "inspect": return .projectInspect(selector: parsed.selector, json: parsed.json)
            case "doctor": return .projectDoctor(selector: parsed.selector, json: parsed.json)
            case "plan": return .projectPlan(selector: parsed.selector, json: parsed.json)
            case "activate": return .projectActivate(selector: parsed.selector, json: parsed.json)
            default: throw CLIError.usage
            }
        case "link":
            var path: String?
            var hostname: String?
            var index = 1
            while index < args.count {
                let value = args[index]
                if value == "--host", hostname == nil, index + 1 < args.count {
                    hostname = args[index + 1]
                    index += 2
                } else if value == "--path", path == nil, index + 1 < args.count {
                    path = args[index + 1]
                    index += 2
                } else if !value.hasPrefix("-"), path == nil, hostname == nil {
                    if Self.looksLikePath(value) { path = value }
                    else { hostname = Self.linkSiteHostname(value) }
                    index += 1
                } else {
                    throw CLIError.commandUsage("link")
                }
            }
            return .link(path: path, hostname: hostname)
        case "unlink":
            guard args.count <= 2 else { throw CLIError.commandUsage("unlink") }
            return .unlink(path: args.count == 2 ? args[1] : nil)
        case "park":
            guard args.count <= 2 else { throw CLIError.commandUsage("park") }
            return .park(path: args.count == 2 ? args[1] : nil)
        case "unpark":
            guard args.count <= 2 else { throw CLIError.commandUsage("unpark") }
            return .unpark(path: args.count == 2 ? args[1] : nil)
        case "php":
            if args.count == 1 { return .help(path: [first]) }
            switch args[1] {
            case "versions": return .phpVersions(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "install": guard args.count == 3 else { throw CLIError.usage }; return .phpInstall(args[2])
            case "update": guard args.count == 3 else { throw CLIError.usage }; return .phpUpdate(args[2])
            case "remove": guard args.count == 3 else { throw CLIError.usage }; return .phpRemove(args[2])
            case "operation": return .phpOperation(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "default":
                if args.count == 2 || (args.count == 3 && args[2] == "--json") { return .phpDefault(json: args.count == 3) }
                if args.count == 3, args[2] != "set" { return .phpDefaultSet(args[2]) }
                guard args.count == 4, args[2] == "set" else { throw CLIError.usage }
                return .phpDefaultSet(args[3])
            case "use": guard args.count == 3 else { throw CLIError.usage }; return .phpUse(args[2])
            case "start": guard args.count == 3 else { throw CLIError.usage }; return .phpStart(args[2])
            case "stop": guard args.count == 3 else { throw CLIError.usage }; return .phpStop(args[2])
            case "status": guard args.count == 3 || args.count == 4 else { throw CLIError.usage }; return .phpStatus(args[2], json: try optionalJSONOption(Array(args.dropFirst(3))))
            case "config": guard args.count == 2 || args.count == 3 else { throw CLIError.usage }; return .phpConfig(version: args.count == 3 ? args[2] : nil)
            case "exec":
                let rest = Array(args.dropFirst(2)); guard let marker = rest.firstIndex(of: "--") else { throw CLIError.usage }
                let flags = Array(rest[..<marker]); guard flags.allSatisfy({ $0 == "--effective" }), flags.count <= 1 else { throw CLIError.usage }
                return .phpExec(version: nil, effective: flags.contains("--effective"), arguments: Array(rest.dropFirst(marker + 1)))
            case "resolve": guard args.count == 3, args[2] == "--path" else { throw CLIError.usage }; return .phpResolvePath
             default: throw CLIError.usage
              }
        case "shell":
            if args.count == 1 { return .help(path: [first]) }
            guard args.count == 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .shellStatus
            case "install": return .shellInstall
            case "uninstall": return .shellUninstall
            default: throw CLIError.usage
            }
        case "mysql":
            if args.count == 1 { return .help(path: [first]) }
            switch args[1] {
            case "versions": return .mysqlVersions(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "install": guard args.count == 3 else { throw CLIError.usage }; return .mysqlInstall(args[2])
            case "use": guard args.count == 3 else { throw CLIError.usage }; return .mysqlUse(args[2])
            case "initialize": guard args.count == 2 else { throw CLIError.usage }; return .mysqlInitialize
            case "start": guard args.count == 2 else { throw CLIError.usage }; return .mysqlStart
            case "stop": guard args.count == 2 else { throw CLIError.usage }; return .mysqlStop
            case "status": guard args.count == 2 || args.count == 3 else { throw CLIError.usage }; return .mysqlStatus(json: try optionalJSONOption(Array(args.dropFirst(2))))
            default: throw CLIError.usage
            }
        case "routing":
            if args.count == 1 { return .help(path: [first]) }
            guard args.count == 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .routingStatus
            case "start": return .routingStart
            case "stop": return .routingStop
            default: throw CLIError.usage
            }
        case "route":
            if args.count == 1 { return .help(path: [first]) }
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "list": return .routeList(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "add":
                guard args.count >= 4 else { throw CLIError.usage }
                var socket: String?
                var projectID: UUID?
                var tls = false
                var index = 4
                while index < args.count {
                    if args[index] == "--tls" { tls = true; index += 1; continue }
                    guard index + 1 < args.count else { throw CLIError.usage }
                    if args[index] == "--php-socket" { socket = args[index + 1] }
                    else if args[index] == "--project-id" { guard let value = UUID(uuidString: args[index + 1]) else { throw CLIError.usage }; projectID = value }
                    else { throw CLIError.usage }
                    index += 2
                }
                return .routeAdd(hostname: args[2], documentRoot: args[3], socketPath: socket, projectID: projectID, tls: tls)
            case "remove":
                guard args.count == 3, let uuid = UUID(uuidString: args[2]) else { throw CLIError.usage }
                return .routeRemove(RouteID(rawValue: uuid))
            case "associate":
                guard args.count == 4, let routeUUID = UUID(uuidString: args[2]), let projectUUID = UUID(uuidString: args[3]) else { throw CLIError.usage }
                return .routeAssociate(RouteID(rawValue: routeUUID), ProjectID(rawValue: projectUUID))
            default: throw CLIError.usage
            }
        case "mailpit":
            if args.count == 1 { return .help(path: [first]) }
            switch args[1] {
            case "versions": return .mailpitVersions(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "install": guard args.count == 3 else { throw CLIError.usage }; return .mailpitInstall(args[2])
            case "start": guard args.count == 2 else { throw CLIError.usage }; return .mailpitStart
            case "stop": guard args.count == 2 else { throw CLIError.usage }; return .mailpitStop
            case "status": guard args.count == 2 || args.count == 3 else { throw CLIError.usage }; return .mailpitStatus(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "open": guard args.count == 2 else { throw CLIError.usage }; return .mailpitOpen
            default: throw CLIError.usage
            }
        case "dns":
            if args.count == 1 { return .help(path: [first]) }
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .dnsStatus(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "install": return .dnsInstall(takeover: try optionalFlag(Array(args.dropFirst(2)), flag: "--takeover"))
            case "remove": guard args.count == 2 else { throw CLIError.usage }; return .dnsRemove
            default: throw CLIError.usage
            }
        case "tls":
            if args.count == 1 { return .help(path: [first]) }
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .tlsStatus(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "install": guard args.count == 2 else { throw CLIError.usage }; return .tlsInstall
            case "remove": guard args.count == 2 else { throw CLIError.usage }; return .tlsRemove
            case "trust": guard args.count == 2 else { throw CLIError.usage }; return .tlsTrust
            case "untrust": guard args.count == 2 else { throw CLIError.usage }; return .tlsUntrust
            default: throw CLIError.usage
            }
        case "ports":
            if args.count == 1 { return .help(path: [first]) }
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .portsStatus(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "install": guard args.count == 2 else { throw CLIError.usage }; return .portsInstall
            case "remove": guard args.count == 2 else { throw CLIError.usage }; return .portsRemove
            default: throw CLIError.usage
            }
        default: throw CLIError.message("Unknown command: \(first). Run ‘val --help’ to see available commands.")
        }
    }

    private static func requiredPath(_ args: [String]) throws -> String {
        guard args.count == 2 else { throw CLIError.usage }
        return args[1]
    }

    private static func listJSONOption(_ args: [String]) throws -> Bool {
        guard args.count == 1 || args.dropFirst().elementsEqual(["--json"]) else { throw CLIError.usage }
        return args.count == 2
    }

    private static func optionalJSONOption(_ args: [String]) throws -> Bool {
        guard args.isEmpty || args == ["--json"] else { throw CLIError.usage }
        return !args.isEmpty
    }

    private static func optionalFlag(_ args: [String], flag: String) throws -> Bool {
        guard args.isEmpty || args == [flag] else { throw CLIError.usage }
        return !args.isEmpty
    }

    private static func projectEnvironmentArguments(_ args: [String]) throws -> (selector: String?, json: Bool) {
        var selector: String?
        var json = false
        for argument in args {
            if argument == "--json" { guard !json else { throw CLIError.usage }; json = true }
            else if argument.hasPrefix("--") || selector != nil { throw CLIError.usage }
            else { selector = argument }
        }
        return (selector, json)
    }

    private static func runDoctor(_ client: VaelenCoreClient) async -> DoctorReport {
        do {
            try await client.connect()
        } catch let error as CoreClientError {
            let code = errorCode(for: error)
            let detail = error == .coreUnavailable ? "Not running; service checks unavailable." : error.localizedDescription
            return DoctorEvaluator.evaluate(DoctorSnapshot(coreFailure: detail, coreFailureCode: code))
        } catch {
            return DoctorEvaluator.evaluate(DoctorSnapshot(coreFailure: "Core connection failed: \(error.localizedDescription)", coreFailureCode: 1))
        }

        var snapshot = DoctorSnapshot()
        do {
            snapshot.coreStatus = try await client.status()
        } catch let error as CoreClientError {
            snapshot.coreFailure = error == .coreUnavailable ? "Not running; service checks unavailable." : error.localizedDescription
            snapshot.coreFailureCode = errorCode(for: error)
            await client.disconnect()
            return DoctorEvaluator.evaluate(snapshot)
        } catch {
            snapshot.coreFailure = "Core status could not be read: \(error.localizedDescription)"
            snapshot.coreFailureCode = 1
            await client.disconnect()
            return DoctorEvaluator.evaluate(snapshot)
        }

        do {
            let php = try await client.phpVersions()
            snapshot.phpAvailable = php.available
            snapshot.phpInstalled = php.installed.map(\.version)
        } catch { snapshot.observationErrors["php-inventory"] = error.localizedDescription }
        let requestedPHP = (snapshot.coreStatus?.serviceIntents ?? []).compactMap { value -> String? in
            guard value.hasPrefix("php:") else { return nil }
            let version = String(value.dropFirst(4))
            return version.isEmpty ? nil : version
        }
        for version in Set((snapshot.phpInstalled ?? []) + requestedPHP).sorted() {
            do { snapshot.phpStatuses[version] = try await client.phpStatus(version) }
            catch { snapshot.observationErrors["php:\(version)"] = error.localizedDescription }
        }
        do { snapshot.mysql = try await client.mysqlStatus() }
        catch { snapshot.observationErrors["mysql"] = error.localizedDescription }
        do { snapshot.mailpit = try await client.mailpitStatus() }
        catch { snapshot.observationErrors["mailpit"] = error.localizedDescription }
        do { snapshot.routing = try await client.routingStatus() }
        catch { snapshot.observationErrors["routing"] = error.localizedDescription }
        do { snapshot.dns = try await client.dnsStatus() }
        catch { snapshot.observationErrors["dns"] = error.localizedDescription }
        do { snapshot.ports = try await client.portsStatus() }
        catch { snapshot.observationErrors["standard-ports"] = error.localizedDescription }
        await client.disconnect()
        return DoctorEvaluator.evaluate(snapshot)
    }

    private static func errorCode(for error: CoreClientError) -> Int32 {
        switch error {
        case .coreUnavailable: return 3
        case .protocolIncompatible, .coreIncompatible: return 4
        case .invalidResponse, .remote: return 1
        }
    }

    private static func execute(_ command: CLICommand, client: VaelenCoreClient, workingDirectory: String) async throws {
        switch command {
        case .version:
            print("Vaelen \(VaelenBuildInfo.version)")
        case .help(let path):
            print(helpText(for: path), terminator: "")
        case .isolated(let json):
            print(try await isolatedProjectsOutput(client: client, json: json))
        case .doctor:
            break
        case .status(let json):
            let status = try await client.status()
            if json {
                let value = StatusEnvelope(core: StatusPayload(state: status.core.state.rawValue, version: status.core.version, pid: status.core.pid, protocolVersion: status.protocolVersion))
                print(String(decoding: try IPCCodec.encode(value), as: UTF8.self))
            } else {
                print(HumanOutput.heading("Vaelen") + "\n" + HumanOutput.aligned([
                    ("Core", status.core.state == .running ? "Running" : "Unavailable"),
                    ("Version", status.core.version), ("PID", String(status.core.pid)),
                    ("Protocol", String(status.protocolVersion))
                ]))
            }
        case .link(let path, let requestedHostname):
            let workingPath = URL(fileURLWithPath: workingDirectory).standardizedFileURL.resolvingSymlinksInPath().path
            var preflightRoutes: [RouteIntent] = []
            if path == nil {
                preflightRoutes = try await client.routeList()
                let linkedAtPath = routesForProject(preflightRoutes, projectID: nil, projectPath: workingPath)
                if linkedAtPath.isEmpty {
                    let expectedHost = requestedHostname ?? (URL(fileURLWithPath: workingPath).lastPathComponent + ".test")
                    if let collision = preflightLinkCollision(hostname: expectedHost, projectPath: workingPath, routes: preflightRoutes) {
                        throw CLIError.message("Cannot link this project: \(expectedHost) is already routed to another project (\(collision.projectPath ?? "existing route")). Nothing was registered or changed.")
                    }
                }
            }
            let result = try await client.link(path: path, workingDirectory: workingDirectory, name: nil)
            guard let project = result.project else { throw CLIError.message("Core returned no linked project.") }
            let canonicalPath = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath().path
            var attemptedRoute: RouteIntent?
            var rollbackProblems = [String]()
            let servingRoute: RouteIntent
            do {
                servingRoute = try await withNewLinkRollback(linkCreatedByInvocation: result.created, rollback: {
                    if let attemptedRoute {
                        do {
                            let routes = try await client.routeList()
                            if routes.contains(where: { $0.route.id == attemptedRoute.route.id && $0.projectID == attemptedRoute.projectID && $0.projectPath == attemptedRoute.projectPath }) {
                                _ = try await client.routeRemove(attemptedRoute.route.id)
                            }
                        } catch { rollbackProblems.append("could not remove route \(attemptedRoute.route.id): \(message(for: error))") }
                    }
                    guard result.created else { return }
                    do {
                        let projects = try await client.linkedProjects()
                        if projects.contains(where: { $0.id == project.id && URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == canonicalPath }) {
                            try await client.unlink(path: canonicalPath, name: nil, workingDirectory: canonicalPath)
                        }
                    } catch { rollbackProblems.append("could not undo the newly created project link: \(message(for: error))") }
                }) {
                    let report = try await client.projectInspect(selector: canonicalPath, workingDirectory: canonicalPath)
                    let allRoutes = try await client.routeList()
                    let ownedRoutes = routesForProject(allRoutes, projectID: project.id, projectPath: canonicalPath)
                    if requestedHostname == nil {
                        guard ownedRoutes.count <= 1 else { throw CLIError.message("The project has multiple Vaelen routes. Choose one with --host HOST; no route was changed.") }
                        if let existing = ownedRoutes.first { return existing }
                    }
                    let hostname = requestedHostname ?? (URL(fileURLWithPath: canonicalPath).lastPathComponent + ".test")
                    if let existing = allRoutes.first(where: { $0.route.hostname.caseInsensitiveCompare(hostname) == .orderedSame }) {
                        guard ownedRoutes.contains(where: { $0.route.id == existing.route.id }) else {
                            throw CLIError.message("\(hostname) is already routed to another project (\(existing.projectPath ?? "existing route")). Nothing was changed.")
                        }
                        return existing
                    }
                    if let collision = hostnameCollision(hostname, candidateProjectRoutes: ownedRoutes, allRoutes: allRoutes) {
                        throw CLIError.message("\(hostname) is already routed to another project (\(collision.projectPath ?? "existing route")).")
                    }
                    let inheritedConfiguration: (target: RouteTarget, tls: TLSMode)?
                    do {
                        inheritedConfiguration = try additionalHostConfiguration(from: ownedRoutes)
                    } catch AdditionalHostConfigurationError.differingTargets {
                        throw CLIError.message("This project has routes with different targets. Use ‘val route add’ to choose the new route target explicitly.")
                    } catch AdditionalHostConfigurationError.differingTLSModes {
                        throw CLIError.message("This project has routes with different TLS modes. Vaelen will not guess a mode for the new hostname; use ‘val route add’ with an explicit TLS choice.")
                    }
                    guard let relativeRoot = report.derived.framework.suggestedDocumentRoot else {
                        throw CLIError.message("Vaelen could not determine a supported document root. Add or correct the project’s web entry point, then retry.")
                    }
                    let documentRoot = URL(fileURLWithPath: canonicalPath).appendingPathComponent(relativeRoot).standardizedFileURL.path
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: documentRoot, isDirectory: &isDirectory), isDirectory.boolValue else {
                        throw CLIError.message("The planned document root does not exist: \(documentRoot).")
                    }
                    let target: RouteTarget
                    if let inheritedConfiguration {
                        target = inheritedConfiguration.target
                    } else {
                    let detectedFramework = report.derived.framework.framework.lowercased()
                    if report.derived.framework.composerPHPRequirement != nil || detectedFramework.contains("php") || detectedFramework.contains("laravel") || detectedFramework.contains("wordpress") {
                        guard report.observed.php.fpmHealth == "healthy", let socket = report.observed.php.fpmSocket else {
                            throw CLIError.message("The PHP runtime is not healthy/available. Start or install the required PHP version, then retry.")
                        }
                        target = .fastCGI(socketPath: socket, documentRoot: documentRoot)
                    } else {
                        target = .staticFiles(documentRoot: documentRoot)
                    }
                    }
                    let tls = inheritedConfiguration?.tls ?? .disabled
                    let intent = RouteIntent(route: Route(hostname: hostname, target: target, tls: tls), projectID: project.id, projectPath: canonicalPath)
                    attemptedRoute = intent
                    let router = try await client.routingStatus()
                    guard router.state == .running, router.health == .healthy else { throw CLIError.message("Vaelen routing is not healthy; no route was applied.") }
                    return try await client.routeAdd(intent)
                }
            } catch {
                let cleanup = rollbackProblems.isEmpty ? "" : " Rollback was incomplete: \(rollbackProblems.joined(separator: "; "))."
                let disposition = result.created ? "The project link created by this invocation was rolled back." : "The pre-existing project link and all existing routes were left unchanged."
                throw CLIError.message("Could not finish linking \(project.name): \(linkFailureDescription(error)). \(disposition)\(cleanup)")
            }
            print(HumanOutput.success("\(result.created ? "Linked" : "Already linked") \(project.name)\n\(requestedHostname == nil ? "Serving" : "Configured") \(servingRoute.route.hostname) at \(servingRoute.route.tls == .local ? "https" : "http")://\(servingRoute.route.hostname)"))
        case .unlink(let path):
            let target = Self.unlinkTargetPath(path, workingDirectory: workingDirectory)
            try await client.unlink(path: target, name: nil, workingDirectory: workingDirectory)
            print(HumanOutput.success("Unlinked project"))
        case .links(let json):
            let projects = try await client.linkedProjects()
            if json { print(String(decoding: try IPCCodec.encode(ProjectListEnvelope(projects: projects)), as: UTF8.self)) }
            else {
                let routes = try await client.routeList()
                let observation = try await client.routeObservedList()
                let phpByProject = await effectivePHPByProject(client: client)
                print(linkedProjectsOutput(projects, routes: routes, observedRoutes: observation.observedRoutes, phpByProject: phpByProject))
            }
        case .edit(let selector):
            let projects = try await client.linkedProjects()
            let project = try selectedProject(selector, projects: projects, workingDirectory: workingDirectory)
            guard project.registration == ProjectRegistrationKind.linked.rawValue else {
                throw CLIError.message("\(project.name) is not linked. Link it with ‘val link’ before opening it in the configured editor.")
            }
            guard project.availability == PathAvailability.available.rawValue, FileManager.default.isReadableFile(atPath: project.path) else {
                throw CLIError.message("Project ‘\(project.name)’ is unavailable at \(displayPath(project.path)); it cannot be opened in an editor.")
            }
            let preference = try EditorPreferenceStore().load()
            guard let preference else { throw CLIError.message("No editor is configured. Choose an installed editor in Vaelen Settings → General, then run ‘val edit’ again.") }
            let appURL = URL(fileURLWithPath: preference.applicationPath, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: appURL.path),
                  Bundle(url: appURL)?.bundleIdentifier == preference.bundleIdentifier else {
                throw CLIError.message("The configured editor ‘\(preference.bundleIdentifier)’ is no longer installed at \(preference.applicationPath). Choose it again in Vaelen Settings → General.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([URL(fileURLWithPath: project.path, isDirectory: true)], withApplicationAt: appURL, configuration: configuration) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            print(HumanOutput.message("Opening \(project.name) in \(preference.bundleIdentifier): \(project.path)"))
        case .park(let path):
            let result = try await client.park(path: path, workingDirectory: workingDirectory)
            guard let parked = result.path else { throw CLIError.message("Core returned no parked path.") }
            print(HumanOutput.success("\(result.created ? "Parked" : "Already parked")\n\(displayPath(parked.path))"))
            if let summary = result.reconciliation {
                for hostname in summary.added { print(HumanOutput.success("Serving http://\(hostname)")) }
                for hostname in summary.removed { print(HumanOutput.success("Removed parked route \(hostname)")) }
                for conflict in summary.conflicts { print(HumanOutput.conflict(conflict)) }
                for issue in summary.issues { print(HumanOutput.warning(issue)) }
            }
        case .unpark(let path):
            let targetPath = Self.unparkTargetPath(path, workingDirectory: workingDirectory)
            let result = try await client.unpark(path: path, workingDirectory: workingDirectory)
            let remainingPaths = try await client.parkedPaths()
            guard !remainingPaths.contains(where: { $0.path == targetPath }) else {
                throw CLIError.message("Vaelen Core reported success, but \(displayPath(targetPath)) is still parked.")
            }
            print(HumanOutput.success("Unparked\n\(displayPath(targetPath))"))
            if let summary = result.reconciliation {
                for hostname in summary.removed { print(HumanOutput.success("Removed parked route \(hostname)")) }
                for conflict in summary.conflicts { print(HumanOutput.conflict(conflict)) }
                for issue in summary.issues { print(HumanOutput.warning(issue)) }
            }
        case .parks(let json):
            let paths = try await client.parkedPaths()
            if json { print(String(decoding: try IPCCodec.encode(ParkedPathListEnvelope(paths: paths)), as: UTF8.self)) }
            else { print(parkedPathsOutput(paths)) }
        case .parked(let json):
            let projects = discoveredParkedProjects(try await client.projectList())
            let folders = try await client.parkedPaths()
            let unavailable = folders.filter { $0.availability != PathAvailability.available.rawValue }
            if json { print(String(decoding: try IPCCodec.encode(ParkedSitesEnvelope(sites: projects, unavailableFolders: unavailable)), as: UTF8.self)) }
            else {
                print(parkedSitesHumanOutput(projects, folders: folders))
                for folder in unavailable { print(HumanOutput.warning("Parked folder unavailable: \(displayPath(folder.path)) (\(folder.availability))")) }
            }
        case .sites(let json):
            let routes = try await client.routeList()
            let projects = try await client.projectList()
            let routerObservation = try await client.routeObservedList()
            let items = configuredSiteItems(routes: routes, projects: projects, observedRoutes: routerObservation.observedRoutes, unavailableReason: routerObservation.unavailableReason)
            if json { print(String(decoding: try IPCCodec.encode(SitesEnvelope(sites: items)), as: UTF8.self)) }
            else {
                print(sitesHumanOutput(items))
            }
        case .siteDriver(let selector, let json):
            let projects = try await client.projectList()
            let project = try selectedProject(selector, projects: projects, workingDirectory: workingDirectory)
            let available = project.availability == PathAvailability.available.rawValue && FileManager.default.isReadableFile(atPath: project.path)
            let inspection = available ? ProjectFrameworkDetector().inspect(root: URL(fileURLWithPath: project.path, isDirectory: true)) : ProjectFrameworkInspection(framework: "Generic/Unknown", confidence: .low, evidence: [])
            let routes = try await client.routeList()
            let caddy = try await client.routeObservedList()
            let selectedRoutes = siteDriverRoutes(project: project, routeIntents: routes, observedRoutes: caddy.observedRoutes, unavailableReason: caddy.unavailableReason)
            let result = SiteDriverEnvelope(
                project: project.name,
                path: project.path,
                detectedFramework: inspection.confidence == .low ? "Unknown" : inspection.framework,
                frameworkConfidence: inspection.confidence.rawValue,
                evidence: available ? inspection.evidence : ["Project folder is unavailable; framework could not be inspected."],
                configuredRouteCount: selectedRoutes.count,
                configuredRoutes: selectedRoutes
            )
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else {
                print(HumanOutput.heading("Site driver"))
                print(HumanOutput.aligned([("Project", result.project), ("Path", displayPath(result.path)), ("Detected framework", result.detectedFramework), ("Framework confidence", result.frameworkConfidence)]))
                print(HumanOutput.heading("Framework evidence"))
                if result.evidence.isEmpty { print("No recognized framework markers found.") }
                else { print(HumanOutput.table(result.evidence.map { [$0] }, headers: ["Evidence"])) }
                print(HumanOutput.heading("Configured serving routes"))
                if result.configuredRoutes.isEmpty { print("No configured route belongs to this project.") }
                else {
                    let rows = result.configuredRoutes.map { [$0.hostname, $0.target, $0.tls, caddyObservationLabel($0.caddyObservationState)] }
                    print(HumanOutput.list(rows, headers: ["Hostname", "Configured target", "TLS", "Caddy route"], empty: "No configured route belongs to this project."))
                }
            }
        case .siteInfo(let selector, let json):
            let projects = try await client.projectList()
            let project = try selectedProject(selector, projects: projects, workingDirectory: workingDirectory)
            guard project.availability == PathAvailability.available.rawValue,
                  FileManager.default.isReadableFile(atPath: project.path) else {
                throw CLIError.message("Project folder is unavailable: \(displayPath(project.path))")
            }
            let inspection = ProjectFrameworkDetector().inspect(root: URL(fileURLWithPath: project.path, isDirectory: true))
            guard siteInfoSupportsFramework(inspection.framework, confidence: inspection.confidence) else {
                throw CLIError.message("Site information currently supports detected Laravel projects only. Detected: \(inspection.framework).")
            }
            guard FileManager.default.fileExists(atPath: project.path + "/artisan") else {
                throw CLIError.message("Laravel Artisan entry point is missing in \(displayPath(project.path)).")
            }
            let routes = try await client.routeList()
            let caddy = try await client.routeObservedList()
            let configured = siteDriverRoutes(project: project, routeIntents: routes, observedRoutes: caddy.observedRoutes, unavailableReason: caddy.unavailableReason)
            let phpPath = try await client.resolvePHPExecutable(workingDirectory: project.path).cliPath
            let application = try runSiteInformation(phpPath: phpPath, projectPath: project.path)
            let result = SiteInfoEnvelope(project: project.name, path: project.path, detectedFramework: inspection.framework, frameworkEvidence: inspection.evidence, configuredRoutes: configured.map { SiteInfoConfiguredRoute(hostname: $0.hostname, target: $0.target, tls: $0.tls) }, runtimeObservations: configured.map { SiteInfoRuntimeObservation(hostname: $0.hostname, caddyRouteObserved: $0.caddyRouteObserved, caddyObservationState: $0.caddyObservationState) }, applicationCommand: ["php", "artisan", "about", "--no-ansi"], applicationExitCode: application.exitCode, applicationOutput: application.output)
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else { print(siteInfoHumanOutput(result, width: HumanOutput.terminalWidth, color: HumanOutput.colorEnabled)) }
            if application.exitCode != 0 { throw CLIError.applicationFailure("Laravel Artisan about", status: application.exitCode) }
        case .openSite(let selector):
            let projects = try await client.projectList()
            let routes = try await client.routeList()
            let route = try selectedRoute(selector, projects: projects, routes: routes, workingDirectory: workingDirectory)
            guard let url = siteURL(for: route.route) else { throw CLIError.message("The selected configured site has an invalid URL.") }
            try launchExternalURL(url)
            print(HumanOutput.message("Opening \(url.absoluteString)"))
        case .databaseOpen(let selector):
            let projects = try await client.projectList()
            let project = try selectedProject(selector, projects: projects, workingDirectory: workingDirectory)
            guard project.availability == PathAvailability.available.rawValue, FileManager.default.isReadableFile(atPath: project.path) else {
                throw CLIError.message("Project \(project.name) is unavailable at \(displayPath(project.path)); its database settings cannot be inspected.")
            }
            let report = try await client.projectInspect(selector: project.path, workingDirectory: workingDirectory)
            let tablePlusURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tinyapp.TablePlus")
            let action = ProjectDatabaseViewerAction.tablePlus(configured: report.configured, mysql: report.observed.mysql, tablePlusInstalled: tablePlusURL != nil)
            guard let url = action.url, tablePlusURL != nil else { throw CLIError.message("Cannot open \(project.name)'s database in TablePlus: \(action.reason).") }
            try launchExternalURL(url, bundleIdentifier: "com.tinyapp.TablePlus")
            print(HumanOutput.success("Opened \(project.name)'s configured database in TablePlus."))
        case .projectStatus(let selector, let json):
            let report = try await client.projectStatus(selector: selector, workingDirectory: workingDirectory)
            if json { print(String(decoding: try IPCCodec.encode(report), as: UTF8.self)) } else { print(projectSummary(report)) }
        case .projectInspect(let selector, let json):
            let report = try await client.projectInspect(selector: selector, workingDirectory: workingDirectory)
            if json { print(String(decoding: try IPCCodec.encode(report), as: UTF8.self)) } else { print(projectInspection(report)) }
        case .projectDoctor(let selector, let json):
            let report = try await client.projectDoctor(selector: selector, workingDirectory: workingDirectory)
            if json { print(String(decoding: try IPCCodec.encode(report), as: UTF8.self)) } else { print(projectDoctor(report)) }
        case .projectPlan(let selector, let json):
            let plan = try await client.projectPlan(selector: selector, workingDirectory: workingDirectory)
            if json { print(String(decoding: try IPCCodec.encode(plan), as: UTF8.self)) } else { print(projectPlan(plan)) }
        case .projectActivate(let selector, let json):
            let execution = try await client.projectActivate(selector: selector, workingDirectory: workingDirectory)
            if json { print(String(decoding: try IPCCodec.encode(execution), as: UTF8.self)) } else { print(projectActivation(execution)) }
        case .projectPHP(let selector, let version, let useDefault, let json):
            let result = try await client.setProjectPHP(selector: selector, workingDirectory: workingDirectory, version: version, useDefault: useDefault)
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else { print(HumanOutput.report("Project PHP · \(result.project.name)", rows: [("Override", result.overrideVersion ?? "Uses Default"), ("Default", result.defaultVersion ?? "none"), ("Effective", HumanOutput.state(result.effectiveVersion ?? "unavailable")), ("Observed", HumanOutput.state(result.observedVersion ?? "not running"))])) }
        case .phpVersions(let json):
            let result = try await client.phpCatalog()
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else { print(phpCatalogHumanOutput(result)) }
        case .phpInstall(let version): let result = try await client.phpInstall(version); print(HumanOutput.success("Installed PHP \(result.version)"))
        case .phpUpdate(let version):
            let result = try await client.phpUpdate(version)
            if let failure = result.convergenceError {
                print(HumanOutput.warning("PHP \(result.version) installed, but some work did not finish: \(failure)"))
            } else {
                var summary = "Updated PHP \(result.version)"
                if let replaced = result.replacedVersion { summary += " (replacing \(replaced))" }
                print(HumanOutput.success(summary))
                if let replaced = result.replacedVersion, result.convergence.contains("cleanup") {
                    print("  Removed superseded PHP \(replaced); saved settings are preserved.")
                }
            }
        case .phpRemove(let version): _ = try await client.phpRemove(version); print(HumanOutput.success("Removed PHP \(version)"))
        case .phpOperation(let json):
            let operation = try await client.phpOperation(); if json { print(String(decoding: try IPCCodec.encode(PHPOperationResult(operation: operation)), as: UTF8.self)) } else if let operation { print(HumanOutput.report("PHP operation", rows: [("Operation", "\(operation.kind.rawValue) \(operation.targetVersion)"), ("Phase", HumanOutput.state(operation.phase.rawValue)), ("Details", operation.message ?? "none")])) } else { print(HumanOutput.message("No PHP operation recorded", tint: 90)) }
        case .phpDefault(let json):
            let catalog = try await client.phpCatalog(); if json { print(String(decoding: try IPCCodec.encode(PHPRuntimeCatalogResult(catalog: catalog)), as: UTF8.self)) } else { print(HumanOutput.report("Default PHP", rows: [("Server default", HumanOutput.state(catalog.defaultVersion ?? "none"))])) }
        case .phpDefaultSet(let version):
            let catalog = try await client.phpDefaultSet(version); print(HumanOutput.success("Default PHP \(catalog.defaultVersion ?? version)"))
        case .phpUse(let version): let result = try await client.phpUse(version); print(HumanOutput.success("Using PHP \(result.version) for CLI"))
        case .phpExec(let version, let effective, let arguments):
            let selectedVersion: String?
            if effective {
                let selection = try await client.projectPHP(selector: nil, workingDirectory: workingDirectory)
                guard let resolved = selection.effectiveVersion else { throw CLIError.message("No effective managed PHP runtime is available for this project.") }
                selectedVersion = resolved
            } else { selectedVersion = version }
            let result = try await client.phpExec(version: selectedVersion, workingDirectory: workingDirectory, arguments: arguments)
            print(result.output, terminator: "")
            if result.exitStatus != 0 { exit(result.exitStatus) }
        case .phpResolvePath:
            print(try await resolvePHPPath(client: client, workingDirectory: workingDirectory))
        case .phpINI(let requestedVersion):
            let version: String
            if let requestedVersion { version = requestedVersion }
            else {
                let selection = try await client.projectPHP(selector: nil, workingDirectory: workingDirectory)
                guard let resolved = selection.effectiveVersion else { throw CLIError.message("No effective managed PHP version is available for this project.") }
                version = resolved
            }
            try await openPHPINI(version: version, client: client)
        case .shellStatus: print(try PHPShellIntegration.status())
        case .shellInstall: print(try PHPShellIntegration.install())
        case .shellUninstall: print(try PHPShellIntegration.uninstall())
        case .phpStart(let version): let result = try await client.phpStart(version); print(HumanOutput.report("PHP-FPM · \(result.version)", rows: [("State", HumanOutput.state(result.state.rawValue)), ("Health", HumanOutput.state(result.health))]))
        case .phpStop(let version): let result = try await client.phpStop(version); print(HumanOutput.report("PHP-FPM · \(result.version)", rows: [("State", HumanOutput.state(result.state.rawValue))]))
        case .phpStatus(let version, let json): let result = try await client.phpStatus(version); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print(HumanOutput.report("PHP \(result.version)", rows: [("Package", result.package == nil ? "Missing" : "Installed"), ("FPM", HumanOutput.state(result.state.rawValue)), ("PID", result.pid.map(String.init) ?? "none"), ("Socket", displayPath(result.socket)), ("Health", HumanOutput.state(result.health))])) }
        case .phpConfig(let version):
            let configuration = try await client.phpConfiguration()
            let preference = try PHPConfigurationEditorPreference.load()
            guard let preference else { throw CLIError.message("No editor is configured. Choose an installed editor in Vaelen Settings → General, then run ‘val php config’ again.") }
            let appURL = URL(fileURLWithPath: preference.applicationPath, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: appURL.path), Bundle(url: appURL)?.bundleIdentifier == preference.bundleIdentifier else {
                throw CLIError.message("The configured editor ‘\(preference.bundleIdentifier)’ is no longer installed at \(preference.applicationPath). Choose it again in Vaelen Settings → General.")
            }
            if let version {
                guard let runtime = configuration.versions.first(where: { $0.version == version }) else { throw CLIError.message("PHP \(version) is not installed by Vaelen. Run ‘val php versions’ to see installed versions.") }
                let configURL = URL(fileURLWithPath: runtime.fpmIniPath)
                let openConfiguration = NSWorkspace.OpenConfiguration(); openConfiguration.activates = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.open([configURL], withApplicationAt: appURL, configuration: openConfiguration) { _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                print(HumanOutput.message("Opening PHP \(version) FPM configuration: \(runtime.fpmIniPath)"))
            } else {
                let directoryURL = URL(fileURLWithPath: configuration.directory, isDirectory: true)
                let openConfiguration = NSWorkspace.OpenConfiguration(); openConfiguration.activates = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.open([directoryURL], withApplicationAt: appURL, configuration: openConfiguration) { _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                print(HumanOutput.success("Opened Vaelen PHP configuration folder in \(preference.bundleIdentifier): \(configuration.directory)"))
            }
        case .mysqlVersions(let json):
            let result = try await client.mysqlVersions()
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else { print(mysqlCatalogHumanOutput(result)) }
        case .mysqlInstall(let version): let result = try await client.mysqlInstall(version); print(HumanOutput.success("Installed MySQL \(result.installed.first(where: { $0.version == version })?.version ?? version)"))
        case .mysqlUse(let version): let result = try await client.mysqlUse(version); print(HumanOutput.success("Using MySQL \(result.default ?? version)"))
          case .mysqlInitialize: let result = try await client.mysqlInitialize(); print(HumanOutput.report("MySQL initialization", rows: [("State", HumanOutput.state(result.state.rawValue)), ("Health", HumanOutput.state(result.health))]))
          case .mysqlStart: let result = try await client.mysqlStart(); print(HumanOutput.report("MySQL", rows: [("State", HumanOutput.state(result.state.rawValue)), ("Health", HumanOutput.state(result.health))]))
          case .mysqlStop: let result = try await client.mysqlStop(); print(HumanOutput.report("MySQL", rows: [("State", HumanOutput.state(result.state.rawValue))]))
         case .mysqlStatus(let json): let result = try await client.mysqlStatus(); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print(HumanOutput.heading("MySQL") + "\n" + HumanOutput.aligned([("State", HumanOutput.state(result.state.rawValue)), ("Installed", result.installedVersion ?? "none"), ("Selected", result.selectedVersion ?? "none"), ("PID", result.pid.map(String.init) ?? "none"), ("Port", "127.0.0.1:\(result.port)"), ("Socket", displayPath(result.socket)), ("Data", displayPath(result.datadir)), ("Health", HumanOutput.state(result.health))])) }
          case .mailpitVersions(let json):
            let result = try await client.mailpitVersions()
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else { print(mailpitCatalogHumanOutput(result)) }
         case .mailpitInstall(let version): let result = try await client.mailpitInstall(version); print(HumanOutput.success("Installed Mailpit \(result.version)"))
          case .mailpitStart: let result = try await client.mailpitStart(); print(HumanOutput.report("Mailpit", rows: [("State", HumanOutput.state(result.state.rawValue)), ("Health", HumanOutput.state(result.health)), ("SMTP", "127.0.0.1:\(result.smtpPort)"), ("Web UI", result.uiEndpoint)]))
          case .mailpitStop: let result = try await client.mailpitStop(); print(HumanOutput.report("Mailpit", rows: [("State", HumanOutput.state(result.state.rawValue))]))
         case .mailpitStatus(let json): let result = try await client.mailpitStatus(); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print(HumanOutput.heading("Mailpit") + "\n" + HumanOutput.aligned([("State", HumanOutput.state(result.state.rawValue)), ("Version", result.installedVersion ?? "none"), ("PID", result.pid.map(String.init) ?? "none"), ("SMTP", "127.0.0.1:\(result.smtpPort)"), ("UI", result.uiEndpoint), ("Database", displayPath(result.database)), ("Health", HumanOutput.state(result.health))])) }
         case .mailpitOpen:
             let result = try await client.mailpitStatus(); guard result.state == .running else { throw CLIError.message("Mailpit is not healthy; start it before opening \(result.uiEndpoint).") }; let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = [result.uiEndpoint]; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CLIError.message("Unable to open \(result.uiEndpoint).") }
        case .routingStatus:
              let result = try await client.routingStatus(); print(HumanOutput.report("Routing", rows: [("Provider", result.provider), ("Version", result.providerVersion ?? "unknown"), ("State", HumanOutput.state(result.state.rawValue)), ("Health", HumanOutput.state(result.health.rawValue)), ("Routes", String(result.routeCount))]))
        case .routingStart:
              let result = try await client.routingStart(); print(HumanOutput.report("Routing", rows: [("State", HumanOutput.state(result.state.rawValue)), ("Health", HumanOutput.state(result.health.rawValue))]))
        case .routingStop:
              let result = try await client.routingStop(); print(HumanOutput.report("Routing", rows: [("State", HumanOutput.state(result.state.rawValue))]))
        case .routeList(let json):
            let routes = try await client.routeList()
            if json { print(String(decoding: try IPCCodec.encode(RouteListEnvelope(routes: routes)), as: UTF8.self)) }
            else {
                print(HumanOutput.heading("Routes"))
                let rows = routes.map { [String(describing: $0.route.id), $0.route.hostname, targetDescription($0.route.target), $0.route.tls.rawValue] }
                print(rows.isEmpty ? "No routes configured." : HumanOutput.table(rows, headers: ["ID", "Hostname", "Target", "TLS"]))
            }
        case .routeTLS(let hostname, let secure):
            let routes = try await client.routeList()
            let intent: RouteIntent
            do { intent = try selectSiteRoute(routes, hostname: hostname, workingDirectory: workingDirectory) }
            catch RouteSelectionError.notFound(let value) { throw CLIError.message("No Vaelen route exists for \(value). Add an explicit route with ‘val route add’, then retry.") }
            catch RouteSelectionError.noRouteForDirectory { throw CLIError.message("No site route is associated with the current directory. Specify an existing hostname (val secure <hostname>) or add a route with ‘val route add’.") }
            catch RouteSelectionError.ambiguous { throw CLIError.message("Multiple site routes are associated with the current directory. Specify the exact hostname: val \(secure ? "secure" : "unsecure") <hostname>.") }
            let result: RouteIntent
            if let update = routeTLSUpdate(intent, secure: secure) { result = try await client.routeAdd(update) }
            else { result = intent }
            print(HumanOutput.success("\(secure ? "Secured" : "Unsecured"): \(secure ? "https" : "http")://\(result.route.hostname)"))
            if !secure { print(HumanOutput.warning("A browser may retain a cached HTTPS redirect; clear its site data or try a private window if it keeps opening HTTPS.")) }
        case .routeAdd(let hostname, let documentRoot, let socketPath, let projectID, let tls):
            let target: RouteTarget = socketPath.map { .fastCGI(socketPath: $0, documentRoot: documentRoot) } ?? .staticFiles(documentRoot: documentRoot)
            let result = try await client.routeAdd(.init(route: .init(hostname: hostname, target: target, tls: tls ? .local : .disabled), projectID: projectID))
            print(HumanOutput.success("Added route \(result.route.id)  \(result.route.hostname)  \(targetDescription(result.route.target))"))
        case .routeRemove(let id):
            _ = try await client.routeRemove(id); print(HumanOutput.success("Removed route \(id)"))
        case .routeAssociate(let routeID, let projectID):
            let routes = try await client.routeList()
            guard let route = routes.first(where: { $0.route.id == routeID }) else { throw CLIError.message("Route \(routeID) was not found.") }
            let projects = try await client.linkedProjects()
            guard let project = projects.first(where: { $0.id == projectID.rawValue }) else { throw CLIError.message("Linked project \(projectID) was not found.") }
            print(HumanOutput.report("Route association review", rows: [("Route", String(describing: route.route.id)), ("Hostname", route.route.hostname), ("Project", project.name), ("Project ID", String(describing: projectID)), ("Path", displayPath(project.path)), ("Metadata", "project_id and project_path only")]))
            let result = try await client.routeAssociate(routeID: routeID, projectID: projectID)
            print(HumanOutput.success(result.state == .satisfied ? "Already associated" : "Associated route \(routeID) with project \(projectID)"))
        case .dnsStatus(let json):
            let result = try await client.dnsStatus()
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else {
                var rows: [(String, String)] = [("State", HumanOutput.state(result.state.rawValue)), ("Ownership", HumanOutput.state(result.ownership.rawValue)), ("Responder", HumanOutput.state(result.responderState.rawValue)), ("Resolver", displayPath(result.resolverPath)), ("Address", "\(result.address):\(result.port)"), ("PID", result.pid.map(String.init) ?? "none"), ("Health", HumanOutput.state(result.health))]
                if let conflict = result.conflict { rows.append(("Conflict", HumanOutput.state("conflict") + " · " + conflict)) }
                print(HumanOutput.report("DNS", rows: rows))
            }
        case .dnsInstall(let takeover):
            let result = try await client.dnsInstall(takeover: takeover); print(HumanOutput.report("DNS", rows: [("State", HumanOutput.state(result.state.rawValue)), ("Health", HumanOutput.state(result.health))]))
        case .dnsRemove:
            let result = try await client.dnsRemove(); print(HumanOutput.report("DNS", rows: [("State", HumanOutput.state(result.state.rawValue))]))
        case .tlsStatus(let json):
            let result = try await client.tlsStatus()
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else { print(HumanOutput.report("Local TLS", rows: [("State", HumanOutput.state(result.state.rawValue)), ("Trust", HumanOutput.state(result.trustObserved ? "Trusted" : "Not Trusted")), ("Port", String(result.tlsPort)), ("Detail", result.detail ?? "None")])) }
        case .tlsInstall:
            let result = try await client.tlsInstall(); print(HumanOutput.report("Local CA", rows: [("State", HumanOutput.state(result.state.rawValue)), ("Next step", "Trust requires approval in Vaelen.app.")]))
        case .tlsRemove:
            let result = try await client.tlsRemove(); print(HumanOutput.report("Local TLS", rows: [("State", HumanOutput.state(result.state.rawValue))]))
        case .tlsTrust:
            let result = try await client.tlsTrustLocalCA(); print(HumanOutput.report("Local TLS trust", rows: [("Operation", HumanOutput.state(result.operation.rawValue)), ("Details", result.message)]))
        case .tlsUntrust:
            let result = try await client.tlsRemoveLocalCATrust(); print(HumanOutput.report("Local TLS trust", rows: [("Operation", HumanOutput.state(result.operation.rawValue)), ("Details", result.message)]))
        case .portsStatus(let json):
            let result = try await client.portsStatus()
            if json { print(String(decoding: try IPCCodec.encode(LegacyPortsStatusEnvelope(ports: LegacyPortsStatus(result))), as: UTF8.self)) }
            else {
                var rows: [(String, String)] = [("State", HumanOutput.state(result.state.rawValue)), ("HTTP", "127.0.0.1:\(result.httpPort) → 127.0.0.1:\(result.backendHTTPPort)"), ("HTTPS", "127.0.0.1:\(result.httpsPort) → 127.0.0.1:\(result.backendHTTPSPort)")]
                if let conflict = result.conflict { rows.append(("Conflict", HumanOutput.state("conflict") + " · " + conflict)) }
                // Preserve the real diagnostic rather than reporting every
                // observation failure as "observation unavailable".
                rows.append(("Forwarding", result.forwardingActive == true ? "active" : (result.forwardingActive == false ? "inactive" : "not observed")))
                if result.repairAvailable == true { rows.append(("Repair", "available · run ‘val ports install’")) }
                if let detail = result.detail { rows.append(("Detail", detail)) }
                print(HumanOutput.report("Standard Local Ports", rows: rows))
            }
        case .portsInstall:
            // Both the GUI and this command use the same Core capability. When
            // authorization is what is missing, say exactly where to grant it and
            // that the command can simply be repeated afterwards.
            do {
                let result = try await client.portsInstall()
                var rows = [("State", HumanOutput.state(result.state.rawValue)), ("Details", result.detail ?? "None")]
                if result.repairAvailable == true { rows.append(("Repair", "Restored the missing PF reference")) }
                print(HumanOutput.report("Standard Local Ports", rows: rows))
            } catch {
                print(HumanOutput.warning(error.localizedDescription))
                if error.localizedDescription.contains("approval in Vaelen.app") {
                    print("  Approve it once: open Vaelen.app, go to Settings → Network & Security → Standard Local Ports, and choose Repair.")
                    print("  Then run ‘val ports install’ again to verify HTTP on 80 and HTTPS on 443.")
                } else if error.localizedDescription.contains("conflict") || error.localizedDescription.contains("ownership") || error.localizedDescription.contains("incomplete") {
                    print("  Vaelen left the existing PF configuration unchanged. See ‘val ports status’ for the specific reason.")
                }
            }
        case .portsRemove:
            let result = try await client.portsRemove(); print(HumanOutput.report("Standard Local Ports", rows: [("State", HumanOutput.state(result.state.rawValue)), ("Details", result.detail ?? "None")]))
        }
    }

    private static func resolvePHPPath(client: VaelenCoreClient, workingDirectory: String) async throws -> String {
        let resolution = try await client.resolvePHPExecutable(workingDirectory: workingDirectory)
        return resolution.cliPath
    }

    private static func openPHPINI(version: String, client: VaelenCoreClient) async throws {
        let configuration = try await client.phpConfiguration()
        guard let runtime = configuration.versions.first(where: { $0.version == version }) else {
            throw CLIError.message("PHP \(version) is not installed by Vaelen. Run ‘val php versions’ to see installed versions.")
        }
        guard let preference = try PHPConfigurationEditorPreference.load() else {
            throw CLIError.message("No editor is configured. Choose an installed editor in Vaelen Settings → General.")
        }
        let appURL = URL(fileURLWithPath: preference.applicationPath, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: appURL.path), Bundle(url: appURL)?.bundleIdentifier == preference.bundleIdentifier else {
            throw CLIError.message("The configured editor ‘\(preference.bundleIdentifier)’ is no longer installed. Choose it again in Vaelen Settings → General.")
        }
        let fileURL = URL(fileURLWithPath: runtime.fpmIniPath)
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: openConfiguration) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        print(HumanOutput.message("Opening PHP \(version) FPM configuration: \(runtime.fpmIniPath)"))
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func linkedProjectsOutput(_ projects: [ProjectWire], routes: [RouteIntent] = [], observedRoutes: [Route]? = nil, phpByProject: [String: String] = [:], width: Int = HumanOutput.terminalWidth, color: Bool = HumanOutput.colorEnabled) -> String {
        linkedProjectsHumanOutput(projects, routes: routes, observedRoutes: observedRoutes, phpByProject: phpByProject, width: width, color: color)
    }

    static func parkedPathsOutput(_ paths: [ParkedPathWire], width: Int = HumanOutput.terminalWidth, color: Bool = HumanOutput.colorEnabled) -> String {
        var lines = [HumanOutput.heading("Parked folders", color: color), ""]
        guard !paths.isEmpty else { lines.append("No parked folders."); return lines.joined(separator: "\n") }
        let rows = paths.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }).map { path -> [String] in
            let state = path.availability == PathAvailability.available.rawValue ? "Available" : "Unavailable · \(path.availability)"
            return [displayPath(path.path), HumanOutput.semantic(state, tint: HumanOutput.stateColor(state), color: color)]
        }
        lines.append(HumanOutput.table(rows, headers: ["Parked folder", "Availability"], width: width, color: color))
        return lines.joined(separator: "\n")
    }

    static func isolatedProjectsOutput(_ selections: [ProjectPHPSelection], json: Bool) throws -> String {
        let overrides = selections
            .filter { $0.overrideVersion != nil }
            .sorted { $0.project.path.localizedStandardCompare($1.project.path) == .orderedAscending }
        if json {
            let result = ProjectPHPSelectionsResult(selections: overrides)
            return String(decoding: try IPCCodec.encode(result), as: UTF8.self)
        }
        let rows = overrides.map { selection in
            [selection.project.name, displayPath(selection.project.path), selection.overrideVersion ?? "—", selection.effectiveVersion ?? "unavailable"]
        }
        return HumanOutput.heading("Isolated projects") + "\n" + (rows.isEmpty ? "No project-specific PHP overrides." : HumanOutput.table(rows, headers: ["Project", "Path", "Override", "Effective"]))
    }

    static func isolatedProjectsOutput(client: VaelenCoreClient, json: Bool) async throws -> String {
        try isolatedProjectsOutput(await client.projectPHPSelections(), json: json)
    }

    private static func effectivePHPByProject(client: VaelenCoreClient) async -> [String: String] {
        do {
            let selections = try await client.projectPHPSelections()
            var result = [String: String]()
            for selection in selections where selection.available {
                if let version = selection.effectiveVersion {
                    result[selection.project.path] = version
                }
            }
            return result
        } catch {
            return [:]
        }
    }

    static func unparkTargetPath(_ path: String?, workingDirectory: String) -> String {
        CanonicalPathService().canonicalize(path ?? workingDirectory, relativeTo: workingDirectory).string
    }

    static func unlinkTargetPath(_ path: String?, workingDirectory: String) -> String {
        guard let path else { return CanonicalPathService().canonicalize(workingDirectory).string }
        if path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") {
            return CanonicalPathService().canonicalize(path).string
        }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent(path)
            .standardizedFileURL.path
    }

    private static func looksLikePath(_ value: String) -> Bool {
        value == "~" || value.hasPrefix("~/") || value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("/") || value.contains("/") || value.hasSuffix(".test")
    }

    private static func linkSiteHostname(_ siteName: String) -> String {
        siteName.lowercased().hasSuffix(".test") ? siteName : "\(siteName).test"
    }

    private static func targetDescription(_ target: RouteTarget) -> String {
        switch target {
        case .staticFiles(let root): return "static \(root)"
        case .fastCGI(let socket, let root): return "fastcgi \(socket) root=\(root)"
        case .http(let host, let port): return "http \(host):\(port)"
        }
    }

    private static func projectSummary(_ report: ProjectEnvironmentReport) -> String {
        let warnings = report.diagnostics.filter { $0.severity != .info }.count
        let mysql = report.desired.mysql == true ? "Requested · \(HumanOutput.state(report.observed.mysql?.state.rawValue ?? "unknown"))" : "Not requested"
        let mailpit = report.desired.mailpit == true ? "Requested · \(HumanOutput.state(report.observed.mailpit?.state.rawValue ?? "unknown"))" : "Not requested"
        let route = report.observed.route.intentExists ? (report.observed.route.hostname ?? "Present") : "Missing"
        let warningValue = warnings == 0 ? "None" : HumanOutput.semantic("\(warnings) warning\(warnings == 1 ? "" : "s")", tint: 33)
        return HumanOutput.report("Project · \(report.identity.name)", rows: [
            ("Path", displayPath(report.identity.path)),
            ("Framework", "\(report.derived.framework.framework) · confidence \(report.derived.framework.confidence.rawValue)"),
            ("PHP", "Desired \(report.desired.php ?? "none") · \(report.derived.phpResolution)"),
            ("MySQL", mysql), ("Mailpit", mailpit), ("Route", route),
            ("DNS", HumanOutput.state(report.observed.dns.health)),
            ("TLS", HumanOutput.state(report.observed.tls.trustObserved ? "Trusted" : "Not Trusted")),
            ("Warnings", warningValue)
        ])
    }

    private static func projectInspection(_ report: ProjectEnvironmentReport) -> String {
        let evidence = report.derived.framework.evidence.joined(separator: ", ")
        let mailAuthenticationEvidence = report.derived.mailAuthentication.evidence.joined(separator: "; ")
        let yesNoUnknown: (Bool?) -> String = { $0.map { $0 ? "On" : "Off" } ?? "Unknown" }
        let configuredDB = "\(report.configured.dbConnection ?? "unknown") · \(report.configured.dbHost ?? "unknown"): \(report.configured.dbPort ?? "unknown")"
        let configuredMail = "\(report.configured.mailer ?? "unknown") · \(report.configured.mailHost ?? "unknown"): \(report.configured.mailPort ?? "unknown")"
        let derivedRows: [(String, String)] = [
            ("Framework evidence", evidence.isEmpty ? "None" : evidence),
            ("Document root", report.derived.framework.suggestedDocumentRoot ?? "Unknown"),
            ("Mail authentication", "\(report.derived.mailAuthentication.requirement.rawValue)\(mailAuthenticationEvidence.isEmpty ? "" : " · \(mailAuthenticationEvidence)")"),
            ("Config cache", report.derived.configCache.state)
        ]
        let diagnosticTable = report.diagnostics.isEmpty ? "No diagnostic findings." : HumanOutput.table(report.diagnostics.map { diagnostic in
            let tint = diagnostic.severity == .error ? 31 : diagnostic.severity == .warning ? 33 : 90
            let headline = HumanOutput.semantic("\(diagnostic.severity.rawValue.uppercased()) · \(diagnostic.code)", tint: tint)
            return [headline, diagnostic.message, diagnostic.suggestion ?? "—"]
        }, headers: ["Finding", "Detail", "Suggested action"])
        return [
            projectSummary(report),
            HumanOutput.report("Desired", rows: [("Configuration", HumanOutput.state(report.desired.file.rawValue)), ("PHP", report.desired.php ?? "Unknown"), ("Secure web", yesNoUnknown(report.desired.secureWeb)), ("MySQL", yesNoUnknown(report.desired.mysql)), ("Mailpit", yesNoUnknown(report.desired.mailpit)), ("Read error", report.desired.fileError ?? "None")]),
            HumanOutput.report("Configured", rows: [("Database", configuredDB), ("Mail", configuredMail), ("Secret availability", "Database · \(report.secret.databasePassword.rawValue) · Mail · \(report.secret.mailPassword.rawValue)")]),
            HumanOutput.report("Derived", rows: derivedRows),
            HumanOutput.heading("Diagnostics") + "\n" + diagnosticTable
        ].joined(separator: "\n\n")
    }

    private static func projectDoctor(_ report: ProjectEnvironmentReport) -> String {
        guard !report.diagnostics.isEmpty else { return HumanOutput.success("No diagnostic findings for \(report.identity.name).") }
        let findings = report.diagnostics.map { diagnostic in
            let tint = diagnostic.severity == .error ? 31 : diagnostic.severity == .warning ? 33 : 90
            let header = HumanOutput.semantic("\(diagnostic.severity.rawValue.uppercased()) · \(diagnostic.code)", tint: tint)
            return [header, diagnostic.message, diagnostic.suggestion ?? "—"]
        }
        return HumanOutput.heading("Project diagnostics · \(report.identity.name)") + "\n" + HumanOutput.table(findings, headers: ["Finding", "Detail", "Suggested action"])
    }

    private static func projectPlan(_ plan: ProjectReconciliationPlan) -> String {
        let rows = plan.operations.map { operation in
            (operation.id, "\(HumanOutput.state(operation.disposition.rawValue)) · \(operation.reason ?? operation.action.rawValue)")
        }
        return HumanOutput.report("Project setup plan · \(plan.identity.name)", rows: [("Overall", HumanOutput.state(plan.state.rawValue))] + (rows.isEmpty ? [("Operations", "None required")] : rows))
    }

    private static func projectActivation(_ execution: ProjectReconciliationExecutionResult) -> String {
        let operationRows = execution.operations.map { ($0.operationID, "\(HumanOutput.state($0.state.rawValue)) · \($0.message)") }
        return HumanOutput.report("Project activation · \(execution.finalPlan.identity.name)", rows: [("Result", HumanOutput.state(execution.state.rawValue)), ("Final plan", HumanOutput.state(execution.finalPlan.state.rawValue))] + (operationRows.isEmpty ? [("Operations", "None required")] : operationRows))
    }

    private static func message(for error: Error) -> String {
        if let error = error as? CLIError { return error.description }
        return "val failed: \(error)"
    }

    private static func fail(_ text: String, code: Int32) -> Never { FileHandle.standardError.write(Data((HumanOutput.error(text) + "\n").utf8)); exit(code) }
}

enum CLIError: Error, CustomStringConvertible {
    case usage
    case commandUsage(String)
    case message(String)
    case applicationFailure(String, status: Int32)
    var description: String {
        switch self {
        case .usage: return VaelenCLIMain.usage
        case .commandUsage(let command): return VaelenCLIMain.helpText(for: [command])
        case .message(let text): return text
        case .applicationFailure(let command, let status): return "\(command) exited with status \(status)."
        }
    }
}
