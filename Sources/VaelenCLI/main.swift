import Darwin
import Foundation
import VaelenIPC

private enum CLICommand {
    case status(json: Bool)
    case link(path: String?, name: String?)
    case unlink(path: String?, name: String?)
    case links(json: Bool)
    case park(path: String?)
    case unpark(path: String?)
    case paths(json: Bool)
}

private struct ProjectListEnvelope: Encodable { let projects: [ProjectWire] }
private struct ParkedPathListEnvelope: Encodable { let paths: [ParkedPathWire] }
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
        }
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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
    var description: String { switch self { case .usage: return "Usage: val status [--json] | val link [path] [--name name] | val unlink [--path path|--name name] | val links [--json] | val park [path] | val unpark [path] | val paths [--json]"; case .message(let text): return text } }
}
