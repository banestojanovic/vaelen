import Foundation
import VaelenCore

public enum NodeCommandAction: String, Codable, Equatable, Sendable {
    case list, install, isolate, useDefault, isolated
}

public struct NodeCommandRequest: Codable, Equatable, Sendable {
    public let action: NodeCommandAction
    public let version: NodeVersion?
    public let selector: String?
    public let workingDirectory: String
    public init(action: NodeCommandAction, version: NodeVersion? = nil, selector: String? = nil, workingDirectory: String) {
        self.action = action; self.version = version; self.selector = selector; self.workingDirectory = workingDirectory
    }
}

public struct NodeCommandParams: Codable, Equatable, Sendable {
    public let nodeRequest: NodeCommandRequest
    public init(_ request: NodeCommandRequest) { nodeRequest = request }
}

public struct NodeCommandSnapshot: Codable, Equatable, Sendable {
    public let releases: [NodeRelease]
    public let selections: [ProjectNodeSelection]
    public let installedPackages: [NodePackageIdentity]
    public let installedPackage: NodePackageIdentity?
    public init(releases: [NodeRelease], selections: [ProjectNodeSelection], installedPackages: [NodePackageIdentity] = [], installedPackage: NodePackageIdentity? = nil) {
        self.releases = releases; self.selections = selections; self.installedPackages = installedPackages; self.installedPackage = installedPackage
    }
}

public struct NodeCommandResult: Codable, Equatable, Sendable {
    public let nodeResult: NodeCommandSnapshot
    public init(_ result: NodeCommandSnapshot) { nodeResult = result }
}
