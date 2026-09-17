import Foundation
import VaelenCore

public enum ProtocolVersion: Int, Codable, Sendable {
    case v1 = 1
}

public struct ClientIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct HandshakeParams: Codable, Equatable, Sendable {
    public let client: ClientIdentity

    public init(client: ClientIdentity) {
        self.client = client
    }
}

public struct HandshakeResult: Codable, Equatable, Sendable {
    public let protocolVersion: ProtocolVersion
    public let coreVersion: String

    public init(protocolVersion: ProtocolVersion, coreVersion: String) {
        self.protocolVersion = protocolVersion
        self.coreVersion = coreVersion
    }
}

public struct CoreStatusResponse: Codable, Equatable, Sendable {
    public let core: CoreRuntimeStatus
    public let protocolVersion: ProtocolVersion

    public init(core: CoreRuntimeStatus, protocolVersion: ProtocolVersion) {
        self.core = core
        self.protocolVersion = protocolVersion
    }
}

public enum CoreMethod: String, Codable, Sendable {
    case handshake = "core.handshake"
    case status = "core.status"
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let protocolVersion: ProtocolVersion
    public let method: CoreMethod
    public let params: RequestParams?

    public init(id: UUID = UUID(), method: CoreMethod, params: RequestParams? = nil, protocolVersion: ProtocolVersion = .v1) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.method = method
        self.params = params
    }
}

public enum RequestParams: Codable, Equatable, Sendable {
    case handshake(HandshakeParams)
    case empty

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .handshake(let params): try params.encode(to: encoder)
        case .empty: try EmptyParams().encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        self = .handshake(try HandshakeParams(from: decoder))
    }
}

private struct EmptyParams: Codable {}

public enum IPCErrorCode: String, Codable, Sendable {
    case protocolIncompatible = "PROTOCOL_INCOMPATIBLE"
    case invalidRequest = "INVALID_REQUEST"
    case internalError = "INTERNAL_ERROR"
}

public struct IPCErrorPayload: Codable, Equatable, Sendable, Error {
    public let code: IPCErrorCode
    public let message: String
    public let details: [String: String]?

    public init(code: IPCErrorCode, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public let id: UUID
    public let protocolVersion: ProtocolVersion
    public let result: ResponseResult?
    public let error: IPCErrorPayload?

    public init(id: UUID, result: ResponseResult, protocolVersion: ProtocolVersion = .v1) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.result = result
        self.error = nil
    }

    public init(id: UUID, error: IPCErrorPayload, protocolVersion: ProtocolVersion = .v1) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.result = nil
        self.error = error
    }
}

public enum ResponseResult: Codable, Equatable, Sendable {
    case handshake(HandshakeResult)
    case status(CoreStatusResponse)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .handshake(let result): try result.encode(to: encoder)
        case .status(let result): try result.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let status = try? container.decode(CoreStatusResponse.self) {
            self = .status(status)
        } else {
            self = .handshake(try container.decode(HandshakeResult.self))
        }
    }
}

public enum IPCCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
