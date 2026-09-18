import XCTest
@testable import VaelenCore

final class RouteAssociationTests: XCTestCase {
    func testExactProjectIDIsDurableAndBeatsWeakerEvidenceRegardlessOfOrder() {
        let project = project(id: UUID(), path: "/tmp/association-project")
        let durable = RouteIntent(route: route("durable.test", "/tmp/association-project/public"), projectID: project.id?.rawValue)
        let weaker = RouteIntent(route: route("legacy.test", "/tmp/association-project/public"))
        let classifier = RouteAssociationClassifier()

        let first = classifier.classify(project: project, framework: framework(.high), routes: [weaker, durable])
        let second = classifier.classify(project: project, framework: framework(.high), routes: [durable, weaker])

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.state, .durable)
        XCTAssertEqual(first.mutationAuthority, .allowed)
        XCTAssertEqual(first.selectedRouteID, durable.route.id)
    }

    func testProjectPathOnlyIsInferredAndNotMutationAuthorized() {
        let project = project(id: UUID(), path: "/tmp/path-project")
        let result = classify(project: project, framework: framework(.medium), routes: [RouteIntent(route: route("path.test", "/tmp/other/public"), projectPath: "/tmp/path-project")])

        XCTAssertEqual(result.state, .inferred)
        XCTAssertEqual(result.mutationAuthority, .blocked)
        XCTAssertTrue(result.evidence.projectPath)
    }

    func testDocumentRootOnlyIsInferredUnlessIndependentlyCorroborated() {
        let project = project(id: UUID(), path: "/tmp/root-project")
        let routeIntent = RouteIntent(route: route("root.test", "/tmp/root-project/public"))

        let inferred = classify(project: project, framework: framework(.medium), routes: [routeIntent])
        let corroborated = classify(project: project, framework: framework(.high), routes: [routeIntent])

        XCTAssertEqual(inferred.state, .inferred)
        XCTAssertEqual(corroborated.state, .safelyAssociable)
        XCTAssertEqual(corroborated.mutationAuthority, .blocked)
    }

    func testCompetingCandidatesAreAmbiguous() {
        let project = project(id: UUID(), path: "/tmp/ambiguous-project")
        let pathRoute = RouteIntent(route: route("path.test", "/tmp/other/public"), projectPath: "/tmp/ambiguous-project")
        let rootRoute = RouteIntent(route: route("root.test", "/tmp/ambiguous-project/public"))
        let result = classify(project: project, framework: framework(.high), routes: [rootRoute, pathRoute])

        XCTAssertEqual(result.state, .ambiguous)
        XCTAssertEqual(result.mutationAuthority, .blocked)
    }

    func testMissingProjectIDIsOrphanedAndPreserved() {
        let project = project(id: UUID(), path: "/tmp/orphan-project")
        let orphanID = UUID()
        let routeIntent = RouteIntent(route: route("orphan.test", "/tmp/orphan-project/public"), projectID: orphanID, projectPath: "/tmp/orphan-project")
        let result = classify(project: project, framework: framework(.high), routes: [routeIntent])

        XCTAssertEqual(result.state, .orphaned)
        XCTAssertEqual(result.mutationAuthority, .blocked)
    }

    func testProjectIDPathContradictionIsConflicted() {
        let currentProject = project(id: UUID(), path: "/tmp/current-project")
        let other = project(id: UUID(), path: "/tmp/other-project")
        let routeIntent = RouteIntent(route: route("conflict.test", "/tmp/current-project/public"), projectID: currentProject.id?.rawValue, projectPath: other.rootPath.string)
        let result = classify(project: currentProject, framework: framework(.high), routes: [routeIntent], registered: [currentProject, other])

        XCTAssertEqual(result.state, .conflicted)
        XCTAssertEqual(result.mutationAuthority, .blocked)
    }

    func testProjectIDDocumentRootContradictionIsConflicted() {
        let currentProject = project(id: UUID(), path: "/tmp/current-project")
        let other = project(id: UUID(), path: "/tmp/other-project")
        let routeIntent = RouteIntent(route: route("conflict.test", "/tmp/other-project/public"), projectID: currentProject.id?.rawValue)
        let result = classify(project: currentProject, framework: framework(.high), routes: [routeIntent], registered: [currentProject, other])

        XCTAssertEqual(result.state, .conflicted)
        XCTAssertEqual(result.mutationAuthority, .blocked)
    }

    func testDuplicateHostnameIsConflicted() {
        let project = project(id: UUID(), path: "/tmp/duplicate-project")
        let first = RouteIntent(route: route("duplicate.test", "/tmp/duplicate-project/public"))
        let second = RouteIntent(route: route("duplicate.test", "/tmp/duplicate-project/public-2"))
        let result = classify(project: project, framework: framework(.high), routes: [second, first])

        XCTAssertEqual(result.state, .conflicted)
        XCTAssertEqual(result.mutationAuthority, .blocked)
    }

    func testOneProjectMayOwnMultipleDurableRoutes() {
        let project = project(id: UUID(), path: "/tmp/multi-project")
        let first = RouteIntent(route: route("app.test", "/tmp/multi-project/public"), projectID: project.id?.rawValue)
        let second = RouteIntent(route: route("api.test", "/tmp/multi-project/public"), projectID: project.id?.rawValue)
        let result = classify(project: project, framework: framework(.high), routes: [second, first])

        XCTAssertEqual(result.state, .durable)
        XCTAssertEqual(Set(result.routeIDs), Set([first.route.id, second.route.id]))
        XCTAssertNil(result.selectedRouteID)
    }

    private func classify(project: Project, framework: ProjectFrameworkInspection, routes: [RouteIntent], registered: [Project]? = nil) -> RouteAssociationResult {
        RouteAssociationClassifier().classify(project: project, framework: framework, routes: routes, registeredProjects: registered ?? [project])
    }

    private func project(id: UUID, path: String) -> Project {
        Project(id: ProjectID(rawValue: id), name: URL(fileURLWithPath: path).lastPathComponent, rootPath: CanonicalPath(url: URL(fileURLWithPath: path)), registrationKind: .linked, availability: .available)
    }

    private func route(_ hostname: String, _ documentRoot: String) -> Route {
        Route(hostname: hostname, target: .fastCGI(socketPath: "/tmp/php.sock", documentRoot: documentRoot), tls: .disabled)
    }

    private func framework(_ confidence: ProjectEnvironmentConfidence) -> ProjectFrameworkInspection {
        ProjectFrameworkInspection(framework: "Laravel", confidence: confidence, evidence: ["artisan", "public/index.php"], suggestedDocumentRoot: "public/")
    }
}
