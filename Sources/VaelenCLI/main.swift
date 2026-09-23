import Darwin
import Foundation
import VaelenCore
import VaelenIPC

enum CLICommand {
    case help
    case status(json: Bool)
    case link(path: String)
    case unlink(path: String)
    case links(json: Bool)
    case park(path: String)
    case unpark(path: String)
    case parks(json: Bool)
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

@main
struct VaelenCLIMain {
    static let usage = """
    Usage:
      val park <directory>
      val parks [--json]
      val unpark <directory>

      val link <project-directory>
      val links [--json]
      val unlink <project-directory>

      val status [--json]
       val project status|inspect|doctor|plan|activate [project] [--json]
       val project php [project] [--version <exact>] [--use-default] [--json]
      val routing status|start|stop
      val route list|add|remove|associate
      val php versions|default|install|update|remove|operation ...
      val php resolve --path
      val shell status|install|uninstall
      val mysql ...
      val mailpit versions|install|start|stop|status|open
    """

    static func main() async {
        do {
            let command = try parse(Array(CommandLine.arguments.dropFirst()))
            if case .help = command {
                print(usage)
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
        case "status": return .status(json: args.dropFirst().elementsEqual(["--json"]))
        case "links": return .links(json: try listJSONOption(args))
        case "parks", "paths": return .parks(json: try listJSONOption(args))
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
        case "link": return .link(path: try requiredPath(args))
        case "unlink": return .unlink(path: try requiredPath(args))
        case "park": return .park(path: try requiredPath(args))
        case "unpark": return .unpark(path: try requiredPath(args))
        case "php":
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "versions": return .phpVersions(json: args.dropFirst(2).elementsEqual(["--json"]))
            case "install": guard args.count == 3 else { throw CLIError.usage }; return .phpInstall(args[2])
            case "update": guard args.count == 3 else { throw CLIError.usage }; return .phpUpdate(args[2])
            case "remove": guard args.count == 3 else { throw CLIError.usage }; return .phpRemove(args[2])
            case "operation": return .phpOperation(json: args.dropFirst(2).elementsEqual(["--json"]))
            case "default":
                if args.count == 2 || (args.count == 3 && args[2] == "--json") { return .phpDefault(json: args.count == 3) }
                if args.count == 3, args[2] != "set" { return .phpDefaultSet(args[2]) }
                guard args.count == 4, args[2] == "set" else { throw CLIError.usage }
                return .phpDefaultSet(args[3])
            case "use": guard args.count == 3 else { throw CLIError.usage }; return .phpUse(args[2])
            case "start": guard args.count == 3 else { throw CLIError.usage }; return .phpStart(args[2])
            case "stop": guard args.count == 3 else { throw CLIError.usage }; return .phpStop(args[2])
            case "status": guard args.count == 3 || args.count == 4 else { throw CLIError.usage }; return .phpStatus(args[2], json: args.count == 4 && args[3] == "--json")
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
            case "versions": return .mysqlVersions(json: args.dropFirst(2).elementsEqual(["--json"]))
            case "install": guard args.count == 3 else { throw CLIError.usage }; return .mysqlInstall(args[2])
            case "use": guard args.count == 3 else { throw CLIError.usage }; return .mysqlUse(args[2])
            case "initialize": guard args.count == 2 else { throw CLIError.usage }; return .mysqlInitialize
            case "start": guard args.count == 2 else { throw CLIError.usage }; return .mysqlStart
            case "stop": guard args.count == 2 else { throw CLIError.usage }; return .mysqlStop
            case "status": guard args.count == 2 || args.count == 3 else { throw CLIError.usage }; return .mysqlStatus(json: args.count == 3 && args[2] == "--json")
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
            case "list": return .routeList(json: args.dropFirst(2).elementsEqual(["--json"]))
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
            case "versions": return .mailpitVersions(json: args.dropFirst(2).elementsEqual(["--json"]))
            case "install": guard args.count == 3 else { throw CLIError.usage }; return .mailpitInstall(args[2])
            case "start": guard args.count == 2 else { throw CLIError.usage }; return .mailpitStart
            case "stop": guard args.count == 2 else { throw CLIError.usage }; return .mailpitStop
            case "status": guard args.count == 2 || args.count == 3 else { throw CLIError.usage }; return .mailpitStatus(json: args.count == 3 && args[2] == "--json")
            case "open": guard args.count == 2 else { throw CLIError.usage }; return .mailpitOpen
            default: throw CLIError.usage
            }
        case "dns":
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .dnsStatus(json: args.dropFirst(2).elementsEqual(["--json"]))
            case "install": return .dnsInstall(takeover: args.dropFirst(2).elementsEqual(["--takeover"]))
            case "remove": guard args.count == 2 else { throw CLIError.usage }; return .dnsRemove
            default: throw CLIError.usage
            }
        case "tls":
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .tlsStatus(json: args.dropFirst(2).elementsEqual(["--json"]))
            case "install": guard args.count == 2 else { throw CLIError.usage }; return .tlsInstall
            case "remove": guard args.count == 2 else { throw CLIError.usage }; return .tlsRemove
            case "trust": guard args.count == 2 else { throw CLIError.usage }; return .tlsTrust
            case "untrust": guard args.count == 2 else { throw CLIError.usage }; return .tlsUntrust
            default: throw CLIError.usage
            }
        case "ports":
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "status": return .portsStatus(json: args.dropFirst(2).elementsEqual(["--json"]))
            case "install": guard args.count == 2 else { throw CLIError.usage }; return .portsInstall
            case "remove": guard args.count == 2 else { throw CLIError.usage }; return .portsRemove
            default: throw CLIError.usage
            }
        default: throw CLIError.usage
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

    private static func execute(_ command: CLICommand, client: VaelenCoreClient, workingDirectory: String) async throws {
        switch command {
        case .help:
            print(usage)
        case .status(let json):
            let status = try await client.status()
            if json {
                let value = StatusEnvelope(core: StatusPayload(state: status.core.state.rawValue, version: status.core.version, pid: status.core.pid, protocolVersion: status.protocolVersion))
                print(String(decoding: try IPCCodec.encode(value), as: UTF8.self))
            } else {
                print("Vaelen\nCore       \(status.core.state == .running ? "Running" : "Unavailable")\nVersion    \(status.core.version)\nPID        \(status.core.pid)\nProtocol   \(status.protocolVersion)")
            }
        case .link(let path):
            let result = try await client.link(path: path, workingDirectory: workingDirectory, name: nil)
            guard let project = result.project else { throw CLIError.message("Core returned no linked project.") }
            print("\(result.created ? "Linked" : "Already linked") \(project.name)\n\(displayPath(project.path))")
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
        case .unpark(let path):
            try await client.unpark(path: path, workingDirectory: workingDirectory)
            print("Unparked path")
        case .parks(let json):
            let paths = try await client.parkedPaths()
            if json { print(String(decoding: try IPCCodec.encode(ParkedPathListEnvelope(paths: paths)), as: UTF8.self)) }
            else { print(parkedPathsOutput(paths)) }
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
            else { routes.forEach { intent in print("\(intent.route.id)\t\(intent.route.hostname)\t\(targetDescription(intent.route.target))\tDesired") } }
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
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
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
        guard !projects.isEmpty else { return "No linked projects." }
        return projects.map { "\($0.name)\t\(displayPath($0.path))\t\($0.availability)" }.joined(separator: "\n")
    }

    static func parkedPathsOutput(_ paths: [ParkedPathWire]) -> String {
        guard !paths.isEmpty else { return "No parked folders." }
        return paths.map { "\(displayPath($0.path))\t\($0.availability)" }.joined(separator: "\n")
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

    private static func fail(_ text: String, code: Int32) -> Never { FileHandle.standardError.write(Data((text + "\n").utf8)); exit(code) }
}

enum CLIError: Error, CustomStringConvertible {
    case usage
    case message(String)
    var description: String { switch self { case .usage: return VaelenCLIMain.usage; case .message(let text): return text } }
}
