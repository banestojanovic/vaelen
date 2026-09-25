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
    case help
    case status(json: Bool)
    case doctor(json: Bool)
    case routeTLS(hostname: String?, secure: Bool)
    case link(path: String?, hostname: String?)
    case unlink(path: String)
    case links(json: Bool)
    case park(path: String?)
    case unpark(path: String?)
    case parks(json: Bool)
    case parked(json: Bool)
    case sites(json: Bool)
    case siteDriver(selector: String?, json: Bool)
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
    case phpExec(version: String?, arguments: [String])
    case phpResolvePath
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
    static let usage = helpText(for: [])

    static func helpText(for path: [String]) -> String {
        if path.isEmpty {
            let sections: [(String, [(String, String)])] = [
                ("Projects", [("link", "Link a project"), ("links", "List linked projects"), ("unlink", "Unlink project; keep files"), ("park", "Park a workspace folder"), ("parks", "List parked folders"), ("parked", "List sites discovered in parked folders"), ("sites", "List configured sites and serving observations"), ("open", "Open a configured site"), ("db", "Open an eligible project database"), ("site", "Inspect a site driver"), ("unpark", "Unpark a workspace folder"), ("project", "Inspect and configure projects")]),
                ("Overview", [("status", "Show Vaelen status"), ("doctor", "Check Vaelen services")]),
                ("Web", [("secure", "Enable HTTPS for a site route"), ("unsecure", "Serve a site route over HTTP")]),
                ("Runtime", [("php", "Manage PHP"), ("mysql", "Manage MySQL"), ("mailpit", "Manage Mailpit")]),
                ("Networking", [("routing", "Manage router"), ("route", "Manage project routes"), ("dns", "Manage DNS"), ("tls", "Manage HTTPS"), ("ports", "Manage web ports")]),
                ("Integration", [("shell", "PHP shell integration")]),
                ("Discoverability", [("list", "List available val commands")])
            ]
            var lines = wrappedText("Vaelen — local development environments for your projects.", indent: "").components(separatedBy: "\n")
            lines += ["", "Usage: val <command> [options]", ""]
            for (title, commands) in sections {
                lines.append(title)
                lines += rootCommandRows(commands)
                lines.append("")
            }
            lines += wrappedText("Run “val list” to redisplay commands, or “val <command> --help” for details.", indent: "").components(separatedBy: "\n")
            return lines.joined(separator: "\n")
        }
        let name = path[0]
        let body: String
        switch name {
        case "doctor": body = "Usage: val doctor [--json]\nCheck Vaelen Core and managed service health without starting or repairing services.\nExample: val doctor --json"
        case "list": body = "Usage: val list\nList available val commands. Use “val <command> --help” for command-specific usage."
        case "secure": body = "Usage: val secure [hostname]\nEnable local HTTPS and HTTP-to-HTTPS redirect for an existing route. Without a hostname, the current directory must resolve to exactly one route.\nExample: val secure app.test"
        case "unsecure": body = "Usage: val unsecure [hostname]\nServe an existing route over HTTP without redirect. Without a hostname, the current directory must resolve to exactly one route. Browsers may retain a cached HTTPS redirect.\nExample: val unsecure app.test"
        case "project": body = groupHelp("val project <command> [project] [options]", [
                ("status [project] [--json]", "Show project environment summary"),
                ("inspect [project] [--json]", "Show configuration and diagnostics"),
                ("doctor [project] [--json]", "Report project diagnostic findings"),
                ("plan [project] [--json]", "Preview project setup actions"),
                ("activate [project] [--json]", "Apply actionable project setup"),
                ("php [project] [options]", "Set a project PHP version")
            ], examples: ["val project inspect", "val project php my-app --version 8.3"]) + "\n\n" + wrappedText("PHP options: --version <exact>, --use-default, --json", indent: "  ")
        case "php": body = groupHelp("val php <command> [arguments]", [
                ("versions [--json]", "List available and installed PHP"),
                ("default [--json]", "Show the default PHP version"),
                ("default set <version>", "Set the default PHP version"),
                ("install <version>", "Install a PHP version"),
                ("update <version>", "Update a PHP version"),
                ("remove <version>", "Remove a PHP version"),
                ("operation [--json]", "Show the current PHP operation"),
                ("use <version>", "Select PHP for the shell"),
                ("start <version>", "Start PHP-FPM"),
                ("stop <version>", "Stop PHP-FPM"),
                ("status <version> [--json]", "Show PHP runtime status"),
                ("config [version]", "Open managed PHP configuration files; with a version, edit its FPM ini"),
                ("exec -- <arguments>", "Run PHP with the selected version"),
                ("resolve --path", "Print the project PHP executable")
            ], examples: ["val php install 8.3", "val php resolve --path"])
        case "mysql": body = groupHelp("val mysql <command> [arguments]", [
            ("versions [--json]", "List available and installed MySQL versions"), ("install <version>", "Install a MySQL version"), ("use <version>", "Select the MySQL version"), ("initialize", "Initialize the selected MySQL data"), ("start", "Start MySQL"), ("stop", "Stop MySQL"), ("status [--json]", "Show MySQL status")], examples: ["val mysql status"])
        case "mailpit": body = groupHelp("val mailpit <command> [arguments]", [
            ("versions [--json]", "List available and installed versions"), ("install <version>", "Install Mailpit"), ("start", "Start Mailpit"), ("stop", "Stop Mailpit"), ("status [--json]", "Show Mailpit status"), ("open", "Open the Mailpit web interface")], examples: ["val mailpit start"])
        case "routing": body = groupHelp("val routing <status|start|stop>", [("status", "Show router status"), ("start", "Start routing"), ("stop", "Stop routing")], examples: ["val routing status"])
        case "route": body = groupHelp("val route <command> [arguments]", [("list [--json]", "List configured routes"), ("add <hostname> <document-root> [options]", "Add a route"), ("remove <route-id>", "Remove a route"), ("associate <route-id> <project-id>", "Associate a route with a project")], examples: ["val route add app.test ./public --tls"]) + "\n\n" + wrappedText("Options: --php-socket <path>, --project-id <uuid>, --tls", indent: "  ")
        case "dns": body = groupHelp("val dns <status|install|remove> [options]", [("status [--json]", "Show local DNS status"), ("install [--takeover]", "Install local DNS"), ("remove", "Remove Vaelen local DNS")], examples: ["val dns status --json"])
        case "tls": body = groupHelp("val tls <command>", [("status [--json]", "Show local HTTPS status"), ("install", "Install the local certificate authority"), ("remove", "Remove local HTTPS"), ("trust", "Trust the local certificate authority"), ("untrust", "Remove local CA trust")], examples: ["val tls status"])
        case "ports": body = groupHelp("val ports <status|install|remove>", [("status [--json]", "Show standard local port status"), ("install", "Enable standard local ports"), ("remove", "Remove standard local port forwarding")], examples: ["val ports status"])
        case "shell": body = groupHelp("val shell <status|install|uninstall>", [("status", "Show PHP shell integration"), ("install", "Install PHP shell integration"), ("uninstall", "Remove PHP shell integration")], examples: ["val shell status"])
        case "status": body = "Usage: val status [--json]\nShow whether Vaelen Core is running."
        case "link": body = "Usage: val link [project-directory] [--host HOST]\nLink and serve a project folder. With no directory, use the current directory. Use --host to add an exact hostname; repeating the same host is safe. New hosts inherit configuration only when all current project routes have the same target and TLS mode. If they differ, Vaelen refuses to guess; use ‘val route add’ with an explicit target and TLS choice.\nExample: val link ./my-app --host api.my-app.test"
        case "unlink": body = "Usage: val unlink <project-directory>\nRemove Vaelen's explicit project-link relationship without deleting files or changing any route. To remove just one hostname, use ‘val route remove <route-id>’.\nExample: val unlink ./my-app"
        case "park": body = "Usage: val park [workspace-folder]\nPark a folder in your workspace. With no folder, use the current directory.\nExample: val park\nExample: val park ~/Code/old-project"
        case "unpark": body = "Usage: val unpark [workspace-folder]\nUnpark a folder without deleting it. With no folder, use the current directory.\nExample: val unpark\nExample: val unpark ~/Code/old-project"
        case "links": body = "Usage: val links [--json]\nList linked projects."
        case "parks": body = "Usage: val parks [--json]\nList parked workspace folders."
        case "parked": body = "Usage: val parked [--json]\nList projects discovered inside parked workspace folders. This is distinct from val parks, which lists the folders themselves. Missing parked folders are reported separately."
        case "sites": body = "Usage: val sites [--json]\nList configured route sites, project availability, and the router's independent serving observation. A configured route is not assumed to be served."
        case "open": body = "Usage: val open [hostname|project]\nOpen the exact selected site's configured HTTP or HTTPS URL. Without a selector, the current directory must match exactly one configured site route."
        case "db": body = "Usage: val db [project]\nOpen a project database in TablePlus only when the menu-bar action's MySQL eligibility checks pass. Credentials are never printed."
        case "site": body = "Usage: val site driver [project] [--json]\nReport detected framework and evidence separately from every configured route target and its exact Caddy route observation. No route, multiple routes, missing projects, and unknown frameworks are reported without guessing."
        default: return "Unknown command: \(name). Run ‘val --help’ to see available commands."
        }
        return "\(name)\n\n\(body)\n"
    }

    private static func groupHelp(_ usage: String, _ commands: [(String, String)], examples: [String]) -> String {
        var lines = ["Usage: \(usage)", "", "Commands:"]
        lines += commandRows(commands)
        lines.append("")
        lines.append(examples.count == 1 ? "Example:" : "Examples:")
        lines += examples.map { "  \($0)" }
        return lines.joined(separator: "\n")
    }

    private static func commandRows(_ commands: [(String, String)]) -> [String] {
        let width = max(40, min(120, Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "80") ?? 80))
        if width < 60 {
            return commands.flatMap { syntax, description in
                wrappedText(syntax, indent: "  ").components(separatedBy: "\n")
                    + wrappedText(description, indent: "    ").components(separatedBy: "\n")
            }
        }
        let longest = commands.map { $0.0.count }.max() ?? 0
        let nameWidth = min(longest, max(10, width / 2 - 2))
        return commands.flatMap { syntax, description -> [String] in
            let prefix = "  \(syntax)" + String(repeating: " ", count: max(2, nameWidth - syntax.count + 2))
            let continuation = String(repeating: " ", count: prefix.count)
            let descriptionWidth = max(8, width - prefix.count)
            let words = description.split(whereSeparator: \.isWhitespace).map(String.init)
            var result: [String] = []
            var line = ""
            for word in words {
                if !line.isEmpty && line.count + 1 + word.count > descriptionWidth {
                    result.append((result.isEmpty ? prefix : continuation) + line)
                    line = word
                } else {
                    line += (line.isEmpty ? "" : " ") + word
                }
            }
            if !line.isEmpty { result.append((result.isEmpty ? prefix : continuation) + line) }
            return result
        }
    }

    private static func rootCommandRows(_ commands: [(String, String)]) -> [String] {
        commandRows(commands)
    }

    private static func wrappedText(_ text: String, indent: String) -> String {
        let width = max(40, min(120, Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "80") ?? 80))
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines: [String] = []
        var line = indent
        for word in words {
            if line.count > indent.count && line.count + 1 + word.count > width {
                lines.append(line)
                line = indent + word
            } else {
                line += (line == indent ? "" : " ") + word
            }
        }
        if line != indent { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    private static func groupTitle(for line: String) -> Bool {
        ["Projects", "Overview", "Runtime", "Networking", "Integration", "Discoverability", "Commands", "Examples", "Example:"].contains(line)
    }

    static func printHelp(_ text: String) {
        guard ProcessInfo.processInfo.environment["NO_COLOR"] == nil,
              ProcessInfo.processInfo.environment["TERM"] != "dumb",
              isatty(STDOUT_FILENO) == 1 else { print(text); return }
        let rendered = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let value = String(line)
            if groupTitle(for: value) || (["project", "php", "mysql", "mailpit", "routing", "route", "dns", "tls", "ports", "shell", "status", "link", "unlink", "park", "unpark", "links", "parks", "parked", "sites", "open", "db", "site", "list"].contains(value)) {
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
            if arguments == ["--version"] || arguments == ["-V"] {
                print("Vaelen \(VaelenBuildInfo.version)")
                exit(0)
            }
            if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] || arguments == ["help"] {
                printHelp(usage)
                exit(0)
            }
            if arguments.last == "--help" || arguments.last == "-h" {
                printHelp(helpText(for: Array(arguments.dropLast()).filter { $0 != "help" }))
                exit(0)
            }
            let command = try parse(arguments)
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
            if case .help = command {
                printHelp(usage)
                exit(0)
            }
            switch command {
            case .shellStatus: print(try PHPShellIntegration.status()); exit(0)
            case .shellInstall: print(try PHPShellIntegration.install()); exit(0)
            case .shellUninstall: print(try PHPShellIntegration.uninstall()); exit(0)
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
                FileHandle.standardError.write(Data((error.description + "\n").utf8))
                exit(1)
            case .message:
                fail(error.description, code: 1)
            }
        } catch {
            fail(message(for: error), code: 1)
        }
    }

    static func parse(_ args: [String]) throws -> CLICommand {
        guard let first = args.first else { throw CLIError.usage }
        switch first {
        case "help", "--help", "-h":
            guard args.count == 1 else { throw CLIError.usage }
            return .help
        case "list":
            guard args.count == 1 else { throw CLIError.usage }
            return .help
        case "status": return .status(json: try listJSONOption(args))
        case "doctor": return .doctor(json: try listJSONOption(args))
        case "secure", "unsecure":
            guard args.count <= 2 else { throw CLIError.usage }
            return .routeTLS(hostname: args.count == 2 ? args[1] : nil, secure: first == "secure")
        case "links": return .links(json: try listJSONOption(args))
        case "parks", "paths": return .parks(json: try listJSONOption(args))
        case "parked": return .parked(json: try listJSONOption(args))
        case "sites": return .sites(json: try listJSONOption(args))
        case "open": guard args.count <= 2 else { throw CLIError.commandUsage("open") }; return .openSite(selector: args.count == 2 ? args[1] : nil)
        case "db": guard args.count <= 2 else { throw CLIError.commandUsage("db") }; return .databaseOpen(selector: args.count == 2 ? args[1] : nil)
        case "site":
            guard args.count >= 2, args[1] == "driver" else { throw CLIError.commandUsage("site") }
            var selector: String?
            var json = false
            for value in args.dropFirst(2) {
                if value == "--json", !json { json = true }
                else if !value.hasPrefix("-"), selector == nil { selector = value }
                else { throw CLIError.commandUsage("site") }
            }
            return .siteDriver(selector: selector, json: json)
        case "project":
            guard args.count >= 2 else { throw CLIError.usage }
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
                if args[index] == "--host", index + 1 < args.count, hostname == nil {
                    hostname = args[index + 1]; index += 2
                } else if !args[index].hasPrefix("-"), path == nil {
                    path = args[index]; index += 1
                } else { throw CLIError.commandUsage("link") }
            }
            return .link(path: path, hostname: hostname)
        case "unlink": return .unlink(path: try requiredPath(args))
        case "park":
            guard args.count <= 2 else { throw CLIError.commandUsage("park") }
            return .park(path: args.count == 2 ? args[1] : nil)
        case "unpark":
            guard args.count <= 2 else { throw CLIError.commandUsage("unpark") }
            return .unpark(path: args.count == 2 ? args[1] : nil)
        case "php":
            guard args.count >= 2 else { throw CLIError.usage }
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
                let rest = Array(args.dropFirst(2)); guard let marker = rest.firstIndex(of: "--") else { throw CLIError.usage }; return .phpExec(version: nil, arguments: Array(rest.dropFirst(marker + 1)))
            case "resolve": guard args.count == 3, args[2] == "--path" else { throw CLIError.usage }; return .phpResolvePath
             default: throw CLIError.usage
              }
        case "shell":
            guard args.count == 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .shellStatus
            case "install": return .shellInstall
            case "uninstall": return .shellUninstall
            default: throw CLIError.usage
            }
        case "mysql":
            guard args.count >= 2 else { throw CLIError.usage }
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
            guard args.count == 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .routingStatus
            case "start": return .routingStart
            case "stop": return .routingStop
            default: throw CLIError.usage
            }
        case "route":
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
            guard args.count >= 2 else { throw CLIError.usage }
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
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .dnsStatus(json: try optionalJSONOption(Array(args.dropFirst(2))))
            case "install": return .dnsInstall(takeover: try optionalFlag(Array(args.dropFirst(2)), flag: "--takeover"))
            case "remove": guard args.count == 2 else { throw CLIError.usage }; return .dnsRemove
            default: throw CLIError.usage
            }
        case "tls":
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
        case .help:
            print(usage)
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
            guard path == nil || requestedHostname != nil else {
                print("\(result.created ? "Linked" : "Already linked") \(project.name)\n\(displayPath(project.path))")
                break
            }
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
            print("\(result.created ? "Linked" : "Already linked") \(project.name)\n\(requestedHostname == nil ? "Serving" : "Configured") \(servingRoute.route.hostname) at \(servingRoute.route.tls == .local ? "https" : "http")://\(servingRoute.route.hostname)")
        case .unlink(let path):
            try await client.unlink(path: path, name: nil, workingDirectory: workingDirectory)
            print("Unlinked project")
        case .links(let json):
            let projects = try await client.linkedProjects()
            if json { print(String(decoding: try IPCCodec.encode(ProjectListEnvelope(projects: projects)), as: UTF8.self)) }
            else { print(linkedProjectsOutput(projects)) }
        case .park(let path):
            let result = try await client.park(path: path, workingDirectory: workingDirectory)
            guard let parked = result.path else { throw CLIError.message("Core returned no parked path.") }
            print("\(result.created ? "Parked" : "Already parked")\n\(displayPath(parked.path))")
            if let summary = result.reconciliation {
                for hostname in summary.added { print("Serving http://\(hostname)") }
                for hostname in summary.removed { print("Removed parked route \(hostname)") }
                for conflict in summary.conflicts { print("Conflict: \(conflict)") }
                for issue in summary.issues { print(HumanOutput.warning(issue)) }
            }
        case .unpark(let path):
            let targetPath = Self.unparkTargetPath(path, workingDirectory: workingDirectory)
            let result = try await client.unpark(path: path, workingDirectory: workingDirectory)
            let remainingPaths = try await client.parkedPaths()
            guard !remainingPaths.contains(where: { $0.path == targetPath }) else {
                throw CLIError.message("Vaelen Core reported success, but \(displayPath(targetPath)) is still parked.")
            }
            print("Unparked\n\(displayPath(targetPath))")
            if let summary = result.reconciliation {
                for hostname in summary.removed { print("Removed parked route \(hostname)") }
                for conflict in summary.conflicts { print("Conflict: \(conflict)") }
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
                let note = HumanOutput.wrap("Configured routes and live router observations are shown separately.", width: HumanOutput.terminalWidth)
                print(HumanOutput.heading("Configured sites", subtitle: note))
                print(HumanOutput.list(items.map { [$0.hostname, $0.target, $0.tls, $0.project ?? "—", $0.projectAvailability, caddyObservationLabel($0.caddyObservationState), $0.url] }, headers: ["Hostname", "Target", "TLS", "Project", "Availability", "Caddy route", "URL"], empty: "No configured site routes."))
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
                print("Framework evidence")
                if result.evidence.isEmpty { print("  No recognized framework markers found.") }
                else { result.evidence.forEach { print(HumanOutput.wrap($0, width: max(20, HumanOutput.terminalWidth - 4), firstPrefix: "  ", nextPrefix: "  ")) } }
                print("Configured serving routes")
                if result.configuredRoutes.isEmpty { print("  No configured route belongs to this project.") }
                else {
                    let rows = result.configuredRoutes.map { [$0.hostname, $0.target, $0.tls, caddyObservationLabel($0.caddyObservationState)] }
                    print(HumanOutput.list(rows, headers: ["Hostname", "Configured target", "TLS", "Caddy route"], empty: "No configured route belongs to this project."))
                }
            }
        case .openSite(let selector):
            let projects = try await client.projectList()
            let routes = try await client.routeList()
            let route = try selectedRoute(selector, projects: projects, routes: routes, workingDirectory: workingDirectory)
            guard let url = siteURL(for: route.route) else { throw CLIError.message("The selected configured site has an invalid URL.") }
            try launchExternalURL(url)
            print("Opening \(url.absoluteString)")
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
            print("Opened \(project.name)'s configured database in TablePlus.")
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
            else { print("Project \(result.project.name)\nOverride    \(result.overrideVersion ?? "Uses Default")\nDefault     \(result.defaultVersion ?? "none")\nEffective   \(result.effectiveVersion ?? "unavailable")\nObserved    \(result.observedVersion ?? "not running")") }
        case .phpVersions(let json):
            let result = try await client.phpCatalog(); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print("Available  \(result.availableVersions.joined(separator: ", "))\nInstalled  \(result.installedVersions.map(\.version).joined(separator: ", "))\nDefault    \(result.defaultVersion ?? "none")\nRunning    \(result.runningVersions.joined(separator: ", ").isEmpty ? "none" : result.runningVersions.joined(separator: ", "))") }
        case .phpInstall(let version): let result = try await client.phpInstall(version); print("Installed PHP \(result.version)")
        case .phpUpdate(let version): let result = try await client.phpUpdate(version); print("Updated PHP \(result.version)")
        case .phpRemove(let version): _ = try await client.phpRemove(version); print("Removed PHP \(version)")
        case .phpOperation(let json):
            let operation = try await client.phpOperation(); if json { print(String(decoding: try IPCCodec.encode(PHPOperationResult(operation: operation)), as: UTF8.self)) } else if let operation { print("PHP \(operation.kind.rawValue) \(operation.targetVersion): \(operation.phase.rawValue)\(operation.message.map { " — \($0)" } ?? "")") } else { print("No PHP operation recorded") }
        case .phpDefault(let json):
            let catalog = try await client.phpCatalog(); if json { print(String(decoding: try IPCCodec.encode(PHPRuntimeCatalogResult(catalog: catalog)), as: UTF8.self)) } else { print("Default PHP \(catalog.defaultVersion ?? "none")") }
        case .phpDefaultSet(let version):
            let catalog = try await client.phpDefaultSet(version); print("Default PHP \(catalog.defaultVersion ?? version)")
        case .phpUse(let version): let result = try await client.phpUse(version); print("Using PHP \(result.version) for CLI")
        case .phpExec(let version, let arguments): let result = try await client.phpExec(version: version, workingDirectory: FileManager.default.currentDirectoryPath, arguments: arguments); print(result.output, terminator: ""); if result.exitStatus != 0 { exit(result.exitStatus) }
        case .phpResolvePath:
            print(try await resolvePHPPath(client: client, workingDirectory: workingDirectory))
        case .shellStatus: print(try PHPShellIntegration.status())
        case .shellInstall: print(try PHPShellIntegration.install())
        case .shellUninstall: print(try PHPShellIntegration.uninstall())
        case .phpStart(let version): let result = try await client.phpStart(version); print("PHP \(result.version) FPM \(result.state.rawValue) \(result.health)")
        case .phpStop(let version): let result = try await client.phpStop(version); print("PHP \(result.version) FPM \(result.state.rawValue)")
        case .phpStatus(let version, let json): let result = try await client.phpStatus(version); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print("PHP \(result.version)\nPackage    \(result.package == nil ? "Missing" : "Installed")\nFPM        \(result.state.rawValue)\nPID        \(result.pid.map(String.init) ?? "none")\nSocket     \(displayPath(result.socket))\nHealth     \(result.health)") }
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
                print("Opening PHP \(version) FPM configuration: \(runtime.fpmIniPath)")
            } else {
                let directoryURL = URL(fileURLWithPath: configuration.directory, isDirectory: true)
                let openConfiguration = NSWorkspace.OpenConfiguration(); openConfiguration.activates = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.open([directoryURL], withApplicationAt: appURL, configuration: openConfiguration) { _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                print("Opened Vaelen PHP configuration folder in \(preference.bundleIdentifier): \(configuration.directory)")
            }
        case .mysqlVersions(let json): let result = try await client.mysqlVersions(); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print("MySQL\nAvailable  \(result.available.joined(separator: ", "))\nInstalled  \(result.installed.map(\.version).joined(separator: ", "))\nSelected   \(result.default ?? "none")") }
        case .mysqlInstall(let version): let result = try await client.mysqlInstall(version); print("Installed MySQL \(result.installed.first(where: { $0.version == version })?.version ?? version)")
        case .mysqlUse(let version): let result = try await client.mysqlUse(version); print("Using MySQL \(result.default ?? version)")
        case .mysqlInitialize: let result = try await client.mysqlInitialize(); print("MySQL \(result.state.rawValue) \(result.health)")
        case .mysqlStart: let result = try await client.mysqlStart(); print("MySQL \(result.state.rawValue) \(result.health)")
        case .mysqlStop: let result = try await client.mysqlStop(); print("MySQL \(result.state.rawValue)")
         case .mysqlStatus(let json): let result = try await client.mysqlStatus(); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print("MySQL\nState      \(result.state.rawValue)\nInstalled  \(result.installedVersion ?? "none")\nSelected   \(result.selectedVersion ?? "none")\nPID        \(result.pid.map(String.init) ?? "none")\nPort       127.0.0.1:\(result.port)\nSocket     \(displayPath(result.socket))\nData       \(displayPath(result.datadir))\nHealth     \(result.health)") }
         case .mailpitVersions(let json): let result = try await client.mailpitVersions(); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print("Mailpit\nAvailable  \(result.available.joined(separator: ", "))\nInstalled  \(result.installed.map(\.version).joined(separator: ", "))") }
         case .mailpitInstall(let version): let result = try await client.mailpitInstall(version); print("Installed Mailpit \(result.version)")
         case .mailpitStart: let result = try await client.mailpitStart(); print("Mailpit \(result.state.rawValue) \(result.health)\nSMTP       127.0.0.1:\(result.smtpPort)\nUI         \(result.uiEndpoint)")
         case .mailpitStop: let result = try await client.mailpitStop(); print("Mailpit \(result.state.rawValue)")
         case .mailpitStatus(let json): let result = try await client.mailpitStatus(); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print("Mailpit\nState      \(result.state.rawValue)\nVersion    \(result.installedVersion ?? "none")\nPID        \(result.pid.map(String.init) ?? "none")\nSMTP       127.0.0.1:\(result.smtpPort)\nUI         \(result.uiEndpoint)\nDatabase   \(displayPath(result.database))\nHealth     \(result.health)") }
         case .mailpitOpen:
             let result = try await client.mailpitStatus(); guard result.state == .running else { throw CLIError.message("Mailpit is not healthy; start it before opening \(result.uiEndpoint).") }; let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = [result.uiEndpoint]; try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CLIError.message("Unable to open \(result.uiEndpoint).") }
        case .routingStatus:
            let result = try await client.routingStatus(); print("Routing\nProvider   \(result.provider)\nVersion    \(result.providerVersion ?? "unknown")\nState      \(result.state.rawValue)\nHealth     \(result.health.rawValue)\nRoutes     \(result.routeCount)")
        case .routingStart:
            let result = try await client.routingStart(); print("Routing \(result.state.rawValue) \(result.health.rawValue)")
        case .routingStop:
            let result = try await client.routingStop(); print("Routing \(result.state.rawValue)")
        case .routeList(let json):
            let routes = try await client.routeList()
            if json { print(String(decoding: try IPCCodec.encode(RouteListEnvelope(routes: routes)), as: UTF8.self)) }
            else {
                print(HumanOutput.heading("Routes"))
                print(HumanOutput.list(routes.map { [String(describing: $0.route.id), $0.route.hostname, targetDescription($0.route.target), $0.route.tls.rawValue] }, headers: ["ID", "Hostname", "Target", "TLS"], empty: "No routes configured."))
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
            print("\(secure ? "Secured" : "Unsecured"): \(secure ? "https" : "http")://\(result.route.hostname)")
            if !secure { print(HumanOutput.warning("A browser may retain a cached HTTPS redirect; clear its site data or try a private window if it keeps opening HTTPS.")) }
        case .routeAdd(let hostname, let documentRoot, let socketPath, let projectID, let tls):
            let target: RouteTarget = socketPath.map { .fastCGI(socketPath: $0, documentRoot: documentRoot) } ?? .staticFiles(documentRoot: documentRoot)
            let result = try await client.routeAdd(.init(route: .init(hostname: hostname, target: target, tls: tls ? .local : .disabled), projectID: projectID))
            print("Added route \(result.route.id)\t\(result.route.hostname)\t\(targetDescription(result.route.target))")
        case .routeRemove(let id):
            _ = try await client.routeRemove(id); print("Removed route \(id)")
        case .routeAssociate(let routeID, let projectID):
            let routes = try await client.routeList()
            guard let route = routes.first(where: { $0.route.id == routeID }) else { throw CLIError.message("Route \(routeID) was not found.") }
            let projects = try await client.linkedProjects()
            guard let project = projects.first(where: { $0.id == projectID.rawValue }) else { throw CLIError.message("Linked project \(projectID) was not found.") }
            print("Route association review\nRoute       \(route.route.id)\nHostname    \(route.route.hostname)\nProject     \(project.name)\nProject ID  \(projectID)\nPath        \(displayPath(project.path))\nMetadata    project_id and project_path only")
            let result = try await client.routeAssociate(routeID: routeID, projectID: projectID)
            print(result.state == .satisfied ? "Already associated" : "Associated route \(routeID) with project \(projectID)")
        case .dnsStatus(let json):
            let result = try await client.dnsStatus()
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else {
                let conflict = result.conflict.map { "\nConflict   \($0)" } ?? ""
                print("DNS\nState      \(result.state.rawValue)\nOwnership  \(result.ownership.rawValue)\nResponder  \(result.responderState.rawValue)\nResolver   \(result.resolverPath)\nAddress    \(result.address):\(result.port)\nPID        \(result.pid.map(String.init) ?? "none")\nHealth     \(result.health)\(conflict)")
            }
        case .dnsInstall(let takeover):
            let result = try await client.dnsInstall(takeover: takeover); print("DNS \(result.state.rawValue) \(result.health)")
        case .dnsRemove:
            let result = try await client.dnsRemove(); print("DNS \(result.state.rawValue)")
        case .tlsStatus(let json):
            let result = try await client.tlsStatus()
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else { print("Local TLS\nState      \(result.state.rawValue)\nTrust      \(result.trustObserved ? "Trusted" : "Not Trusted")\nPort       \(result.tlsPort)\(result.detail.map { "\\nDetail     \($0)" } ?? "")") }
        case .tlsInstall:
            let result = try await client.tlsInstall(); print("Local CA \(result.state.rawValue). Trust requires approval in Vaelen.app.")
        case .tlsRemove:
            let result = try await client.tlsRemove(); print("Local TLS \(result.state.rawValue)")
        case .tlsTrust:
            let result = try await client.tlsTrustLocalCA(); print("Local TLS \(result.operation.rawValue): \(result.message)")
        case .tlsUntrust:
            let result = try await client.tlsRemoveLocalCATrust(); print("Local TLS \(result.operation.rawValue): \(result.message)")
        case .portsStatus(let json):
            let result = try await client.portsStatus()
            if json { print(String(decoding: try IPCCodec.encode(LegacyPortsStatusEnvelope(ports: LegacyPortsStatus(result))), as: UTF8.self)) }
            else {
                let conflict = result.conflict.map { "\nConflict   \($0)" } ?? ""
                let detail = result.detail.map { "\nDetail     \($0)" } ?? ""
                print("Standard Local Ports\nState      \(result.state.rawValue)\nHTTP       127.0.0.1:\(result.httpPort) → 127.0.0.1:\(result.backendHTTPPort)\nHTTPS      127.0.0.1:\(result.httpsPort) → 127.0.0.1:\(result.backendHTTPSPort)\(conflict)\(detail)")
            }
        case .portsInstall:
            let result = try await client.portsInstall(); print("Standard Local Ports \(result.state.rawValue).")
        case .portsRemove:
            let result = try await client.portsRemove(); print("Standard Local Ports \(result.state.rawValue)")
        }
    }

    private static func resolvePHPPath(client: VaelenCoreClient, workingDirectory: String) async throws -> String {
        let resolution = try await client.resolvePHPExecutable(workingDirectory: workingDirectory)
        return resolution.cliPath
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func linkedProjectsOutput(_ projects: [ProjectWire]) -> String {
        HumanOutput.list(projects.map { [$0.name, displayPath($0.path), $0.availability] }, headers: ["Project", "Path", "Availability"], empty: "No linked projects.")
    }

    static func parkedPathsOutput(_ paths: [ParkedPathWire]) -> String {
        HumanOutput.list(paths.map { [displayPath($0.path), $0.availability] }, headers: ["Workspace folder", "Availability"], empty: "No parked folders.")
    }

    static func unparkTargetPath(_ path: String?, workingDirectory: String) -> String {
        CanonicalPathService().canonicalize(path ?? workingDirectory, relativeTo: workingDirectory).string
    }

    private static func targetDescription(_ target: RouteTarget) -> String {
        switch target {
        case .staticFiles(let root): return "static \(root)"
        case .fastCGI(let socket, let root): return "fastcgi \(socket) root=\(root)"
        case .http(let host, let port): return "http \(host):\(port)"
        }
    }

    private static func projectSummary(_ report: ProjectEnvironmentReport) -> String {
        let desiredPHP = report.desired.php ?? "none"
        let mysql = report.desired.mysql == true ? "requested / \(report.observed.mysql?.state.rawValue ?? "unknown")" : "not requested"
        let mailpit = report.desired.mailpit == true ? "requested / \(report.observed.mailpit?.state.rawValue ?? "unknown")" : "not requested"
        let warnings = report.diagnostics.filter { $0.severity != .info }.count
        return "Project \(report.identity.name)\nPath       \(displayPath(report.identity.path))\nFramework  \(report.derived.framework.framework) (\(report.derived.framework.confidence.rawValue))\nPHP        desired \(desiredPHP); \(report.derived.phpResolution)\nMySQL      \(mysql)\nMailpit    \(mailpit)\nRoute      \(report.observed.route.intentExists ? (report.observed.route.hostname ?? "present") : "missing")\nDNS        \(report.observed.dns.health)\nTLS        \(report.observed.tls.trustObserved ? "trusted" : "not trusted")\nWarnings   \(warnings)"
    }

    private static func projectInspection(_ report: ProjectEnvironmentReport) -> String {
        let evidence = report.derived.framework.evidence.joined(separator: ", ")
        let diagnostics = report.diagnostics.map { "\($0.severity.rawValue.uppercased()) \($0.code): \($0.message)" }.joined(separator: "\n")
        let mailAuthenticationEvidence = report.derived.mailAuthentication.evidence.joined(separator: "; ")
        return "\(projectSummary(report))\n\nDesired\n  vaelen.yml: \(report.desired.file.rawValue)\n  PHP: \(report.desired.php ?? "unknown")\n  Secure web: \(report.desired.secureWeb.map(String.init) ?? "unknown")\n  MySQL: \(report.desired.mysql.map(String.init) ?? "unknown")\n  Mailpit: \(report.desired.mailpit.map(String.init) ?? "unknown")\n\nConfigured\n  DB: \(report.configured.dbConnection ?? "unknown") \(report.configured.dbHost ?? "unknown"): \(report.configured.dbPort ?? "unknown")\n  Mail: \(report.configured.mailer ?? "unknown") \(report.configured.mailHost ?? "unknown"): \(report.configured.mailPort ?? "unknown")\n  Secrets: database \(report.secret.databasePassword.rawValue), mail \(report.secret.mailPassword.rawValue)\n\nDerived\n  Evidence: \(evidence.isEmpty ? "none" : evidence)\n  Document root: \(report.derived.framework.suggestedDocumentRoot ?? "unknown")\n  Mail authentication: \(report.derived.mailAuthentication.requirement.rawValue)\(mailAuthenticationEvidence.isEmpty ? "" : " (\(mailAuthenticationEvidence))")\n  Config cache: \(report.derived.configCache.state)\n\nDiagnostics\n\(diagnostics.isEmpty ? "none" : diagnostics)"
    }

    private static func projectDoctor(_ report: ProjectEnvironmentReport) -> String {
        if report.diagnostics.isEmpty { return "No diagnostic findings for \(report.identity.name)." }
        return report.diagnostics.map { "\($0.severity.rawValue.uppercased()) \($0.code)\n  \($0.message)\($0.suggestion.map { "\n  Suggested: \($0)" } ?? "")" }.joined(separator: "\n")
    }

    private static func projectPlan(_ plan: ProjectReconciliationPlan) -> String {
        let groups = [
            ("Satisfied", plan.operations.filter { $0.disposition == .satisfied }),
            ("Actionable", plan.operations.filter { $0.disposition == .actionable }),
            ("Blocked or deferred", plan.operations.filter { $0.disposition != .satisfied && $0.disposition != .actionable })
        ]
        let sections = groups.compactMap { title, operations -> String? in
            guard !operations.isEmpty else { return nil }
            let lines = operations.map { operation in
                let reason = operation.reason.map { "\n  \($0)" } ?? ""
                return "  \(operation.id) [\(operation.disposition.rawValue)]\(reason)"
            }.joined(separator: "\n")
            return "\(title)\n\(lines)"
        }.joined(separator: "\n\n")
        return "Project \(plan.identity.name)\nOverall    \(plan.state.rawValue)\n\n\(sections.isEmpty ? "No operations required." : sections)"
    }

    private static func projectActivation(_ execution: ProjectReconciliationExecutionResult) -> String {
        let operations = execution.operations.map { "\($0.operationID) [\($0.state.rawValue)] \($0.message)" }.joined(separator: "\n")
        return "Project \(execution.finalPlan.identity.name)\nResult     \(execution.state.rawValue)\n\(operations.isEmpty ? "No operations required." : operations)\nFinal plan \(execution.finalPlan.state.rawValue)"
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
    var description: String {
        switch self {
        case .usage: return VaelenCLIMain.usage
        case .commandUsage(let command): return VaelenCLIMain.helpText(for: [command])
        case .message(let text): return text
        }
    }
}
