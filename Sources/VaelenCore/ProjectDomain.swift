import Foundation

public struct ProjectID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct ParkedPathID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public enum ProjectRegistrationKind: String, Codable, Sendable { case linked, discovered }
public enum ProjectVisibilitySource: String, Codable, Sendable { case explicitLink, parkedFolder }

public struct Project: Identifiable, Codable, Equatable, Sendable {
    public let id: ProjectID?
    public let name: String
    public let rootPath: CanonicalPath
    public let registrationKind: ProjectRegistrationKind
    public let availability: PathAvailability
    public let detectedFramework: String?
    public let visibilitySources: [ProjectVisibilitySource]?

    public init(id: ProjectID?, name: String, rootPath: CanonicalPath,
                registrationKind: ProjectRegistrationKind, availability: PathAvailability,
                detectedFramework: String? = nil, visibilitySources: [ProjectVisibilitySource]? = nil) {
        self.id = id; self.name = name; self.rootPath = rootPath
        self.registrationKind = registrationKind; self.availability = availability
        self.detectedFramework = detectedFramework; self.visibilitySources = visibilitySources
    }
}

public struct ParkedPath: Identifiable, Codable, Equatable, Sendable {
    public let id: ParkedPathID
    public let rootPath: CanonicalPath
    public let availability: PathAvailability

    public init(id: ParkedPathID, rootPath: CanonicalPath, availability: PathAvailability) {
        self.id = id; self.rootPath = rootPath; self.availability = availability
    }
}

public struct LinkedProjectRecord: Codable, Equatable, Sendable {
    public let id: ProjectID
    public let name: String
    public let canonicalPath: String
    public let customName: String?
    public init(id: ProjectID, name: String, canonicalPath: String, customName: String? = nil) {
        self.id = id; self.name = name; self.canonicalPath = canonicalPath; self.customName = customName
    }
}

public struct ParkedPathRecord: Codable, Equatable, Sendable {
    public let id: ParkedPathID
    public let canonicalPath: String
    public init(id: ParkedPathID, canonicalPath: String) { self.id = id; self.canonicalPath = canonicalPath }
}
