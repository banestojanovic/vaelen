import Darwin
import Foundation
import VaelenCore
import VaelenIPC

private enum CLICommand {
    case status(json: Bool)
    case link(path: String?, name: String?)
    case unlink(path: String?, name: String?)
    case links(json: Bool)
    case park(path: String?)
    case unpark(path: String?)
    case paths(json: Bool)
    case projectStatus(selector: String?, json: Bool)
    case projectInspect(selector: String?, json: Bool)
    case projectDoctor(selector: String?, json: Bool)
    case projectPlan(selector: String?, json: Bool)
    case projectActivate(selector: String?, json: Bool)
    case phpVersions(json: Bool)
    case phpInstall(String)
    case phpUse(String)
    case phpExec(version: String?, arguments: [String])
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
    case dnsStatus(json: Bool)
    case dnsInstall(takeover: Bool)
    case dnsRemove
    case tlsStatus(json: Bool)
    case tlsInstall
    case tlsRemove
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
    static func main() async {
        do {
            let command = try parse(Array(CommandLine.arguments.dropFirst()))
            let paths = CoreEndpointPaths()
            let client = VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: .init(name: "val", version: VaelenBuildInfo.version))
            try await client.connect()
            try await execute(command, client: client, workingDirectory: FileManager.default.currentDirectoryPath)
            await client.disconnect()
            exit(0)
        } catch let error as CoreClientError {
            if case .coreUnavailable = error { fail("Vaelen Core is not running.", code: 3) }
            if case .protocolIncompatible(let client, let core) = error { fail("Vaelen Core uses an incompatible protocol version.\n\nClient: \(client)\nCore:   \(core)", code: 4) }
            if case .remote(let payload) = error { fail(payload.message, code: 1) }
            fail("Vaelen Core returned an invalid response.", code: 1)
        } catch {
            fail(message(for: error), code: 1)
        }
    }

    private static func parse(_ args: [String]) throws -> CLICommand {
        guard let first = args.first else { throw CLIError.usage }
        switch first {
        case "status": return .status(json: args.dropFirst().elementsEqual(["--json"]))
        case "links": return .links(json: args.dropFirst().elementsEqual(["--json"]))
        case "paths": return .paths(json: args.dropFirst().elementsEqual(["--json"]))
        case "project":
            guard args.count >= 2 else { throw CLIError.usage }
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
            var path: String?; var name: String?
            var index = 1
            while index < args.count {
                if args[index] == "--name", index + 1 < args.count { name = args[index + 1]; index += 2 }
                else if args[index].hasPrefix("--") { throw CLIError.usage }
                else if path == nil { path = args[index]; index += 1 }
                else { throw CLIError.usage }
            }
            return .link(path: path, name: name)
        case "unlink":
            var path: String?; var name: String?; var index = 1
            while index < args.count {
                if args[index] == "--path", index + 1 < args.count { path = args[index + 1]; index += 2 }
                else if args[index] == "--name", index + 1 < args.count { name = args[index + 1]; index += 2 }
                else { throw CLIError.usage }
            }
            guard !(path != nil && name != nil) else { throw CLIError.usage }
            return .unlink(path: path, name: name)
        case "park": return .park(path: try optionalPath(args, command: "park"))
        case "unpark": return .unpark(path: try optionalPath(args, command: "unpark"))
        case "php":
            guard args.count >= 2 else { throw CLIError.usage }
            switch args[1] {
            case "versions": return .phpVersions(json: args.dropFirst(2).elementsEqual(["--json"]))
            case "install": guard args.count == 3 else { throw CLIError.usage }; return .phpInstall(args[2])
            case "use": guard args.count == 3 else { throw CLIError.usage }; return .phpUse(args[2])
            case "start": guard args.count == 3 else { throw CLIError.usage }; return .phpStart(args[2])
            case "stop": guard args.count == 3 else { throw CLIError.usage }; return .phpStop(args[2])
            case "status": guard args.count == 3 || args.count == 4 else { throw CLIError.usage }; return .phpStatus(args[2], json: args.count == 4 && args[3] == "--json")
            case "exec":
                let rest = Array(args.dropFirst(2)); guard let marker = rest.firstIndex(of: "--") else { throw CLIError.usage }; return .phpExec(version: nil, arguments: Array(rest.dropFirst(marker + 1)))
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

    private static func optionalPath(_ args: [String], command: String) throws -> String? {
        let rest = Array(args.dropFirst())
        guard rest.count <= 1 else { throw CLIError.usage }
        return rest.first
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
        case .status(let json):
            let status = try await client.status()
            if json {
                let value = StatusEnvelope(core: StatusPayload(state: status.core.state.rawValue, version: status.core.version, pid: status.core.pid, protocolVersion: status.protocolVersion))
                print(String(decoding: try IPCCodec.encode(value), as: UTF8.self))
            } else {
                print("Vaelen\nCore       \(status.core.state == .running ? "Running" : "Unavailable")\nVersion    \(status.core.version)\nPID        \(status.core.pid)\nProtocol   \(status.protocolVersion)")
            }
        case .link(let path, let name):
            let result = try await client.link(path: path, workingDirectory: workingDirectory, name: name)
            guard let project = result.project else { throw CLIError.message("Core returned no linked project.") }
            print("\(result.created ? "Linked" : "Already linked") \(project.name)\n\(displayPath(project.path))")
        case .unlink(let path, let name):
            try await client.unlink(path: path, name: name, workingDirectory: workingDirectory)
            print("Unlinked project")
        case .links(let json):
            let projects = try await client.linkedProjects()
            if json { print(String(decoding: try IPCCodec.encode(ProjectListEnvelope(projects: projects)), as: UTF8.self)) }
            else { projects.forEach { print("\($0.name)\t\(displayPath($0.path))\t\($0.availability)") } }
        case .park(let path):
            let result = try await client.park(path: path, workingDirectory: workingDirectory)
            guard let parked = result.path else { throw CLIError.message("Core returned no parked path.") }
            print("\(result.created ? "Parked" : "Already parked")\n\(displayPath(parked.path))")
        case .unpark(let path):
            try await client.unpark(path: path, workingDirectory: workingDirectory)
            print("Unparked path")
        case .paths(let json):
            let paths = try await client.parkedPaths()
            if json { print(String(decoding: try IPCCodec.encode(ParkedPathListEnvelope(paths: paths)), as: UTF8.self)) }
            else { paths.forEach { print("\(displayPath($0.path))\t\($0.availability)") } }
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
        case .phpVersions(let json):
            let result = try await client.phpVersions(); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print("Available  \(result.available.joined(separator: ", "))\nInstalled  \(result.installed.map(\.version).joined(separator: ", "))\nDefault    \(result.default ?? "none")") }
        case .phpInstall(let version): let result = try await client.phpInstall(version); print("Installed PHP \(result.version)")
        case .phpUse(let version): let result = try await client.phpUse(version); print("Using PHP \(result.version) for CLI")
        case .phpExec(let version, let arguments): let result = try await client.phpExec(version: version, workingDirectory: FileManager.default.currentDirectoryPath, arguments: arguments); print(result.output, terminator: ""); if result.exitStatus != 0 { exit(result.exitStatus) }
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
        case .dnsStatus(let json):
            let result = try await client.dnsStatus()
            if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) }
            else {
                let conflict = result.conflict.map { "\nConflict   \($0)" } ?? ""
                print("DNS\nState      \(result.state.rawValue)\nOwnership  \(result.ownership.rawValue)\nResolver   \(result.resolverPath)\nAddress    \(result.address):\(result.port)\nPID        \(result.pid.map(String.init) ?? "none")\nHealth     \(result.health)\(conflict)")
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

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case message(String)
    var description: String { switch self { case .usage: return "Usage: val status | val project status|inspect|doctor|plan|activate [project] [--json] | val routing status|start|stop | val route list|add|remove | val php ... | val mysql ... | val mailpit versions|install|start|stop|status|open"; case .message(let text): return text } }
}
