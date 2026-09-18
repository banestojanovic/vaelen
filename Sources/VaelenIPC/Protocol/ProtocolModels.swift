import Foundation
import VaelenCore

public enum ProtocolVersion: Int, Codable, Sendable {
    case v1 = 1
}

public struct ClientIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public init(name: String, version: String) { self.name = name; self.version = version }
}

public struct HandshakeParams: Codable, Equatable, Sendable {
    public let client: ClientIdentity
    public init(client: ClientIdentity) { self.client = client }
}

public struct HandshakeResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let coreVersion: String
    public init(protocolVersion: Int, coreVersion: String) { self.protocolVersion = protocolVersion; self.coreVersion = coreVersion }
}

public struct CoreStatusResponse: Codable, Equatable, Sendable {
    public let core: CoreRuntimeStatus
    public let protocolVersion: Int
    public init(core: CoreRuntimeStatus, protocolVersion: Int) { self.core = core; self.protocolVersion = protocolVersion }
}

public enum CoreMethod: String, Sendable {
    case handshake = "core.handshake"
    case status = "core.status"
    case projectLink = "project.link"
    case projectUnlink = "project.unlink"
    case projectLinks = "project.links"
    case projectList = "project.list"
    case pathPark = "path.park"
    case pathUnpark = "path.unpark"
    case pathList = "path.list"
    case phpVersions = "php.versions"
    case phpInstall = "php.install"
    case phpUse = "php.use"
    case phpExec = "php.exec"
    case phpStart = "php.start"
    case phpStop = "php.stop"
    case phpStatus = "php.status"
    case routingStatus = "routing.status"
    case routingStart = "routing.start"
    case routingStop = "routing.stop"
    case routeList = "route.list"
    case routeAdd = "route.add"
    case routeRemove = "route.remove"
}

public enum RequestParams: Codable, Equatable, Sendable {
    case handshake(HandshakeParams)
    case link(LinkProjectRequest)
    case unlink(UnlinkProjectRequest)
    case listProjects(ListProjectsRequest)
    case park(ParkPathRequest)
    case unpark(UnparkPathRequest)
    case phpVersion(PHPVersionRequest)
    case phpExec(PHPExecRequest)
    case route(RouteIntent)
    case routeRemove(RouteRemoveRequest)
    case empty
    case raw(JSONValue)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .handshake(let value): try value.encode(to: encoder)
        case .link(let value): try value.encode(to: encoder)
        case .unlink(let value): try value.encode(to: encoder)
        case .listProjects(let value): try value.encode(to: encoder)
        case .park(let value): try value.encode(to: encoder)
        case .unpark(let value): try value.encode(to: encoder)
        case .phpVersion(let value): try value.encode(to: encoder)
        case .phpExec(let value): try value.encode(to: encoder)
        case .route(let value): try value.encode(to: encoder)
        case .routeRemove(let value): try value.encode(to: encoder)
        case .empty: try EmptyParams().encode(to: encoder)
        case .raw(let value): try value.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        if case .object(let fields) = value {
            if fields["client"] != nil, let params = try? IPCCodec.decode(HandshakeParams.self, from: IPCCodec.encode(value)) {
                self = .handshake(params); return
            }
        }
        self = .raw(value)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try IPCCodec.decode(type, from: IPCCodec.encode(self))
    }
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let protocolVersion: Int
    public let method: String
    public let params: RequestParams?

    public init(id: UUID = UUID(), method: CoreMethod, params: RequestParams? = nil, protocolVersion: Int = ProtocolVersion.v1.rawValue) {
        self.id = id; self.protocolVersion = protocolVersion; self.method = method.rawValue; self.params = params
    }

    public init(id: UUID = UUID(), rawMethod: String, params: RequestParams? = nil, protocolVersion: Int = ProtocolVersion.v1.rawValue) {
        self.id = id; self.protocolVersion = protocolVersion; self.method = rawMethod; self.params = params
    }

    public var knownMethod: CoreMethod? { CoreMethod(rawValue: method) }
}

public enum IPCErrorCode: String, Codable, Sendable {
    case protocolIncompatible = "PROTOCOL_INCOMPATIBLE"
    case invalidRequest = "INVALID_REQUEST"
    case internalError = "INTERNAL_ERROR"
    case projectNotFound = "PROJECT_NOT_FOUND"
    case projectNameAmbiguous = "PROJECT_NAME_AMBIGUOUS"
    case projectNameConflict = "PROJECT_NAME_CONFLICT"
    case pathNotFound = "PATH_NOT_FOUND"
    case pathNotDirectory = "PATH_NOT_DIRECTORY"
    case pathUnreadable = "PATH_UNREADABLE"
    case parkedPathNotFound = "PARKED_PATH_NOT_FOUND"
}

public struct IPCErrorPayload: Codable, Equatable, Sendable, Error {
    public let code: IPCErrorCode
    public let message: String
    public let details: [String: String]?
    public init(code: IPCErrorCode, message: String, details: [String: String]? = nil) { self.code = code; self.message = message; self.details = details }
}

public struct ProjectWire: Codable, Equatable, Sendable {
    public let id: UUID?
    public let name: String
    public let path: String
    public let registration: String
    public let availability: String
    public init(id: UUID?, name: String, path: String, registration: String, availability: String) { self.id = id; self.name = name; self.path = path; self.registration = registration; self.availability = availability }
    public init(_ project: Project) { self.init(id: project.id?.rawValue, name: project.name, path: project.rootPath.string, registration: project.registrationKind.rawValue, availability: project.availability.rawValue) }
}

public struct ParkedPathWire: Codable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let availability: String
    public init(id: UUID, path: String, availability: String) { self.id = id; self.path = path; self.availability = availability }
    public init(_ path: ParkedPath) { self.init(id: path.id.rawValue, path: path.rootPath.string, availability: path.availability.rawValue) }
}

public struct LinkProjectRequest: Codable, Equatable, Sendable {
    public let path: String
    public let workingDirectory: String
    public let name: String?
    public init(path: String? = nil, workingDirectory: String, name: String? = nil) { self.path = path ?? workingDirectory; self.workingDirectory = workingDirectory; self.name = name }
}

public struct UnlinkProjectRequest: Codable, Equatable, Sendable {
    public let path: String?
    public let name: String?
    public let workingDirectory: String
    public init(path: String? = nil, name: String? = nil, workingDirectory: String) { self.path = path; self.name = name; self.workingDirectory = workingDirectory }
}

public struct ListProjectsRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct ParkPathRequest: Codable, Equatable, Sendable {
    public let path: String
    public let workingDirectory: String
    public init(path: String? = nil, workingDirectory: String) { self.path = path ?? workingDirectory; self.workingDirectory = workingDirectory }
}

public struct UnparkPathRequest: Codable, Equatable, Sendable {
    public let path: String
    public let workingDirectory: String
    public init(path: String? = nil, workingDirectory: String) { self.path = path ?? workingDirectory; self.workingDirectory = workingDirectory }
}

public struct ProjectMutationResult: Codable, Equatable, Sendable {
    public let project: ProjectWire?
    public let created: Bool
    public init(project: ProjectWire?, created: Bool) { self.project = project; self.created = created }
    private enum CodingKeys: String, CodingKey { case project, created }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(project, forKey: .project)
        if project == nil { try container.encodeNil(forKey: .project) }
        try container.encode(created, forKey: .created)
    }
}

public struct ParkedPathMutationResult: Codable, Equatable, Sendable {
    public let path: ParkedPathWire?
    public let created: Bool
    public init(path: ParkedPathWire?, created: Bool) { self.path = path; self.created = created }
    private enum CodingKeys: String, CodingKey { case path, created }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(path, forKey: .path)
        if path == nil { try container.encodeNil(forKey: .path) }
        try container.encode(created, forKey: .created)
    }
}

public struct ProjectListResult: Codable, Equatable, Sendable {
    public let projects: [ProjectWire]
    public init(projects: [ProjectWire]) { self.projects = projects }
}

public struct ParkedPathListResult: Codable, Equatable, Sendable {
    public let paths: [ParkedPathWire]
    public init(paths: [ParkedPathWire]) { self.paths = paths }
}

public struct PHPVersionRequest: Codable, Equatable, Sendable { public let version: String; public init(version: String) { self.version = version } }
public struct PHPExecRequest: Codable, Equatable, Sendable { public let version: String?; public let workingDirectory: String; public let arguments: [String]; public init(version: String? = nil, workingDirectory: String, arguments: [String]) { self.version = version; self.workingDirectory = workingDirectory; self.arguments = arguments } }
public struct PHPPackageWire: Codable, Equatable, Sendable { public let version: String; public let architecture: String; public init(_ package: PHPPackage) { version = package.version; architecture = package.architecture } }
public struct PHPVersionsResult: Codable, Equatable, Sendable { public let available: [String]; public let installed: [PHPPackageWire]; public let `default`: String?; public init(available: [String], installed: [PHPPackageWire], default: String?) { self.available = available; self.installed = installed; self.default = `default` } }
public struct PHPStatusResult: Codable, Equatable, Sendable { public let status: PHPStatus; public init(status: PHPStatus) { self.status = status } }
public struct PHPExecResult: Codable, Equatable, Sendable { public let exitStatus: Int32; public let output: String; public init(exitStatus: Int32, output: String) { self.exitStatus = exitStatus; self.output = output } }
public struct RouterStatusResult: Codable, Equatable, Sendable { public let router: RouterStatus; public init(router: RouterStatus) { self.router = router } }
public struct RouteRemoveRequest: Codable, Equatable, Sendable { public let id: RouteID; public init(id: RouteID) { self.id = id } }
public struct RouteListResult: Codable, Equatable, Sendable { public let routes: [RouteIntent]; public init(routes: [RouteIntent]) { self.routes = routes } }

public enum ResponseResult: Codable, Equatable, Sendable {
    case handshake(HandshakeResult)
    case status(CoreStatusResponse)
    case projectMutation(ProjectMutationResult)
    case projectList(ProjectListResult)
    case parkedPathMutation(ParkedPathMutationResult)
    case parkedPathList(ParkedPathListResult)
    case phpVersions(PHPVersionsResult)
    case phpStatus(PHPStatusResult)
    case phpExec(PHPExecResult)
    case routingStatus(RouterStatusResult)
    case routeList(RouteListResult)
    case routeMutation(RouteIntent)
    case raw(JSONValue)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .handshake(let value): try value.encode(to: encoder)
        case .status(let value): try value.encode(to: encoder)
        case .projectMutation(let value): try value.encode(to: encoder)
        case .projectList(let value): try value.encode(to: encoder)
        case .parkedPathMutation(let value): try value.encode(to: encoder)
        case .parkedPathList(let value): try value.encode(to: encoder)
        case .phpVersions(let value): try value.encode(to: encoder)
        case .phpStatus(let value): try value.encode(to: encoder)
        case .phpExec(let value): try value.encode(to: encoder)
        case .routingStatus(let value): try value.encode(to: encoder)
        case .routeList(let value): try value.encode(to: encoder)
        case .routeMutation(let value): try value.encode(to: encoder)
        case .raw(let value): try value.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        let data = try IPCCodec.encode(value)
        guard case .object(let fields) = value else { self = .raw(value); return }
        if fields["core"] != nil, let result = try? IPCCodec.decode(CoreStatusResponse.self, from: data) { self = .status(result) }
        else if fields["coreVersion"] != nil, let result = try? IPCCodec.decode(HandshakeResult.self, from: data) { self = .handshake(result) }
        else if fields["projects"] != nil, let result = try? IPCCodec.decode(ProjectListResult.self, from: data) { self = .projectList(result) }
        else if fields["project"] != nil, let result = try? IPCCodec.decode(ProjectMutationResult.self, from: data) { self = .projectMutation(result) }
        else if fields["paths"] != nil, let result = try? IPCCodec.decode(ParkedPathListResult.self, from: data) { self = .parkedPathList(result) }
        else if fields["path"] != nil, let result = try? IPCCodec.decode(ParkedPathMutationResult.self, from: data) { self = .parkedPathMutation(result) }
        else if fields["available"] != nil, let result = try? IPCCodec.decode(PHPVersionsResult.self, from: data) { self = .phpVersions(result) }
        else if fields["status"] != nil, let result = try? IPCCodec.decode(PHPStatusResult.self, from: data) { self = .phpStatus(result) }
        else if fields["exitStatus"] != nil, let result = try? IPCCodec.decode(PHPExecResult.self, from: data) { self = .phpExec(result) }
        else if fields["router"] != nil, let result = try? IPCCodec.decode(RouterStatusResult.self, from: data) { self = .routingStatus(result) }
        else if fields["routes"] != nil, let result = try? IPCCodec.decode(RouteListResult.self, from: data) { self = .routeList(result) }
        else if fields["route"] != nil, let result = try? IPCCodec.decode(RouteIntent.self, from: data) { self = .routeMutation(result) }
        else { self = .raw(value) }
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public let id: UUID
    public let protocolVersion: Int
    public let result: ResponseResult?
    public let error: IPCErrorPayload?

    public init(id: UUID, result: ResponseResult, protocolVersion: Int = ProtocolVersion.v1.rawValue) { self.id = id; self.protocolVersion = protocolVersion; self.result = result; self.error = nil }
    public init(id: UUID, error: IPCErrorPayload, protocolVersion: Int = ProtocolVersion.v1.rawValue) { self.id = id; self.protocolVersion = protocolVersion; self.result = nil; self.error = error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        result = try container.decodeIfPresent(ResponseResult.self, forKey: .result)
        error = try container.decodeIfPresent(IPCErrorPayload.self, forKey: .error)
        guard (result != nil) != (error != nil) else { throw IPCModelError.invalidResponseShape }
    }
    private enum CodingKeys: String, CodingKey { case id, protocolVersion, result, error }
}

public enum IPCModelError: Error, Equatable, Sendable { case invalidResponseShape }

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .string(let v): try container.encode(v); case .number(let v): try container.encode(v); case .bool(let v): try container.encode(v); case .object(let v): try container.encode(v); case .array(let v): try container.encode(v); case .null: try container.encodeNil() }
    }
}

private struct EmptyParams: Codable {}

public enum IPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
}
