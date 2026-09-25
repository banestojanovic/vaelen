import Foundation

/// Selects routes that a project view may present as belonging to a project.
/// A missing route project ID is never a wildcard. The only legacy fallback is
/// an exact, independently verified document-root match for a linked project.
public enum ProjectRouteAttribution {
    public static func routes(
        for projectID: UUID?,
        verifiedDocumentRoot: String?,
        from routes: [RouteIntent]
    ) -> [RouteIntent] {
        guard let projectID else { return [] }
        let expectedRoot = verifiedDocumentRoot.map(canonicalPath)

        return routes.filter { intent in
            if let associatedID = intent.projectID {
                return associatedID == projectID
            }
            guard let expectedRoot,
                  let documentRoot = documentRoot(of: intent.route.target) else { return false }
            return canonicalPath(documentRoot) == expectedRoot
        }
    }

    private static func documentRoot(of target: RouteTarget) -> String? {
        switch target {
        case .fastCGI(_, let documentRoot), .staticFiles(let documentRoot): documentRoot
        case .http: nil
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
