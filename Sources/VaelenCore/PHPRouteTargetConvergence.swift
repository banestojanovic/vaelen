import Foundation

public enum PHPRouteTargetOwnership: String, Codable, Equatable, Sendable {
    case proven
    case external
    case unknown
    case unavailable
}

public enum PHPRouteProviderAgreement: String, Codable, Equatable, Sendable {
    case agreed
    case diverged
    case missing
    case unreadable
}

public enum RouteTargetTransitionState: String, Codable, Equatable, Sendable {
    case providerPending
}

public struct RouteTargetTransition: Codable, Equatable, Sendable {
    public let routeID: RouteID
    public let projectID: UUID
    public let previousRoute: Route
    public let desiredRoute: Route
    public let previousProviderFingerprint: Data
    public let desiredProviderFingerprint: Data
    public let previousSocket: String
    public let desiredSocket: String
    public let state: RouteTargetTransitionState

    public init(routeID: RouteID, projectID: UUID, previousRoute: Route, desiredRoute: Route, previousProviderFingerprint: Data, desiredProviderFingerprint: Data, previousSocket: String, desiredSocket: String, state: RouteTargetTransitionState = .providerPending) {
        self.routeID = routeID; self.projectID = projectID; self.previousRoute = previousRoute; self.desiredRoute = desiredRoute; self.previousProviderFingerprint = previousProviderFingerprint; self.desiredProviderFingerprint = desiredProviderFingerprint; self.previousSocket = previousSocket; self.desiredSocket = desiredSocket; self.state = state
    }
}

public func routeProviderFingerprint(_ route: Route) throws -> Data {
    let target: String
    switch route.target {
    case .fastCGI(let socket, let root): target = "fastcgi\u{1F}\(socket)\u{1F}\(root)"
    case .http(let host, let port): target = "http\u{1F}\(host)\u{1F}\(port)"
    case .staticFiles(let root): target = "static\u{1F}\(root)"
    }
    return Data("\(route.hostname)\u{1E}\(route.tls.rawValue)\u{1E}\(target)".utf8)
}

public struct ProjectPHPRouteTargetObservation: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let routeID: RouteID
    public let hostname: String
    public let persistedDocumentRoot: String
    public let observedDocumentRoot: String?
    public let persistedTLS: TLSMode
    public let observedTLS: TLSMode?
    public let persistedSocket: String
    public let observedSocket: String?
    public let currentPHPVersion: String?
    public let desiredPHPDeclaration: String?
    public let resolvedPHPVersion: String?
    public let desiredSocket: String?
    public let associationAuthority: RouteMutationAuthority
    public let currentTargetOwnership: PHPRouteTargetOwnership
    public let desiredTargetOwnership: PHPRouteTargetOwnership
    public let providerAgreement: PHPRouteProviderAgreement
    public let disposition: ProjectReconciliationDisposition
    public let reason: String?

    public init(projectID: UUID, routeID: RouteID, hostname: String, persistedDocumentRoot: String, observedDocumentRoot: String?, persistedTLS: TLSMode, observedTLS: TLSMode?, persistedSocket: String, observedSocket: String?, currentPHPVersion: String?, desiredPHPDeclaration: String?, resolvedPHPVersion: String?, desiredSocket: String?, associationAuthority: RouteMutationAuthority, currentTargetOwnership: PHPRouteTargetOwnership, desiredTargetOwnership: PHPRouteTargetOwnership, providerAgreement: PHPRouteProviderAgreement, disposition: ProjectReconciliationDisposition, reason: String? = nil) {
        self.projectID = projectID; self.routeID = routeID; self.hostname = hostname; self.persistedDocumentRoot = persistedDocumentRoot; self.observedDocumentRoot = observedDocumentRoot; self.persistedTLS = persistedTLS; self.observedTLS = observedTLS; self.persistedSocket = persistedSocket; self.observedSocket = observedSocket; self.currentPHPVersion = currentPHPVersion; self.desiredPHPDeclaration = desiredPHPDeclaration; self.resolvedPHPVersion = resolvedPHPVersion; self.desiredSocket = desiredSocket; self.associationAuthority = associationAuthority; self.currentTargetOwnership = currentTargetOwnership; self.desiredTargetOwnership = desiredTargetOwnership; self.providerAgreement = providerAgreement; self.disposition = disposition; self.reason = reason
    }
}

public extension RouteTarget {
    var isFastCGI: Bool {
        if case .fastCGI = self { return true }
        return false
    }

    var fastCGISocket: String? {
        if case .fastCGI(let socket, _) = self { return socket }
        return nil
    }
}
