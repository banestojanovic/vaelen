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
    case phpVersions(json: Bool)
    case phpInstall(String)
    case phpUse(String)
    case phpExec(version: String?, arguments: [String])
    case phpStart(String)
    case phpStop(String)
    case phpStatus(String, json: Bool)
    case routingStatus
    case routingStart
    case routingStop
    case routeList(json: Bool)
    case routeAdd(hostname: String, documentRoot: String, socketPath: String?, projectID: UUID?)
    case routeRemove(RouteID)
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
                var index = 4
                while index < args.count {
                    guard index + 1 < args.count else { throw CLIError.usage }
                    if args[index] == "--php-socket" { socket = args[index + 1] }
                    else if args[index] == "--project-id" { guard let value = UUID(uuidString: args[index + 1]) else { throw CLIError.usage }; projectID = value }
                    else { throw CLIError.usage }
                    index += 2
                }
                return .routeAdd(hostname: args[2], documentRoot: args[3], socketPath: socket, projectID: projectID)
            case "remove":
                guard args.count == 3, let uuid = UUID(uuidString: args[2]) else { throw CLIError.usage }
                return .routeRemove(RouteID(rawValue: uuid))
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
        case .phpVersions(let json):
            let result = try await client.phpVersions(); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print("Available  \(result.available.joined(separator: ", "))\nInstalled  \(result.installed.map(\.version).joined(separator: ", "))\nDefault    \(result.default ?? "none")") }
        case .phpInstall(let version): let result = try await client.phpInstall(version); print("Installed PHP \(result.version)")
        case .phpUse(let version): let result = try await client.phpUse(version); print("Using PHP \(result.version) for CLI")
        case .phpExec(let version, let arguments): let result = try await client.phpExec(version: version, workingDirectory: FileManager.default.currentDirectoryPath, arguments: arguments); print(result.output, terminator: ""); if result.exitStatus != 0 { exit(result.exitStatus) }
        case .phpStart(let version): let result = try await client.phpStart(version); print("PHP \(result.version) FPM \(result.state.rawValue) \(result.health)")
        case .phpStop(let version): let result = try await client.phpStop(version); print("PHP \(result.version) FPM \(result.state.rawValue)")
        case .phpStatus(let version, let json): let result = try await client.phpStatus(version); if json { print(String(decoding: try IPCCodec.encode(result), as: UTF8.self)) } else { print("PHP \(result.version)\nPackage    \(result.package == nil ? "Missing" : "Installed")\nFPM        \(result.state.rawValue)\nPID        \(result.pid.map(String.init) ?? "none")\nSocket     \(displayPath(result.socket))\nHealth     \(result.health)") }
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
        case .routeAdd(let hostname, let documentRoot, let socketPath, let projectID):
            let target: RouteTarget = socketPath.map { .fastCGI(socketPath: $0, documentRoot: documentRoot) } ?? .staticFiles(documentRoot: documentRoot)
            let result = try await client.routeAdd(.init(route: .init(hostname: hostname, target: target, tls: .disabled), projectID: projectID))
            print("Added route \(result.route.id)\t\(result.route.hostname)\t\(targetDescription(result.route.target))")
        case .routeRemove(let id):
            _ = try await client.routeRemove(id); print("Removed route \(id)")
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

    private static func message(for error: Error) -> String {
        if let error = error as? CLIError { return error.description }
        return "val failed: \(error)"
    }

    private static func fail(_ text: String, code: Int32) -> Never { FileHandle.standardError.write(Data((text + "\n").utf8)); exit(code) }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case message(String)
    var description: String { switch self { case .usage: return "Usage: val status | val routing status|start|stop | val route list|add|remove | val php versions|install|use|exec|start|stop|status ..."; case .message(let text): return text } }
}
