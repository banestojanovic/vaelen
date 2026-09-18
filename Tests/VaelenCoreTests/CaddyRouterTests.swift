import XCTest
@testable import VaelenCore

final class CaddyRouterTests: XCTestCase {
    func testOfficialCaddyServesMultipleStaticRoutesAndRemovesOne() async throws {
        let root = URL(fileURLWithPath: "/tmp/vaelen-router-\(UUID().uuidString)", isDirectory: true)
        let alphaRoot = root.appendingPathComponent("alpha", isDirectory: true)
        let betaRoot = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alphaRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: betaRoot, withIntermediateDirectories: true)
        try Data("alpha response".utf8).write(to: alphaRoot.appendingPathComponent("index.html"))
        try Data("beta response".utf8).write(to: betaRoot.appendingPathComponent("index.html"))
        
        let layout = VaelenFilesystemLayout(rootURL: root)
        let package = try resolveCaddyPackage()
        let supervisor = CaddyProcessSupervisor(layout: layout)
        await supervisor.installPackage(package)
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await router.start()

        let alpha = Route(hostname: "alpha.test", target: .staticFiles(documentRoot: alphaRoot.path), tls: .disabled)
        let beta = Route(hostname: "beta.test", target: .staticFiles(documentRoot: betaRoot.path), tls: .disabled)
        try await router.reconcile(routes: [alpha, beta])
        XCTAssertEqual(try runCurl(host: "alpha.test"), "alpha response")
        XCTAssertEqual(try runCurl(host: "beta.test"), "beta response")

        try await router.removeRoute(id: alpha.id)
        XCTAssertNotEqual(try runCurl(host: "alpha.test"), "alpha response")
        XCTAssertEqual(try runCurl(host: "beta.test"), "beta response")
        try await router.stop()
    }

    func testOfficialCaddyServesControlledPHPFixtureThroughM2FPM() async throws {
        guard let php = PHPModule.development(), let phpPackage = php.installedVersions().last else {
            throw XCTSkip("M2 PHP-FPM package is not installed")
        }
        let root = URL(fileURLWithPath: "/tmp/vaelen-fastcgi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<?php echo 'php response';".utf8).write(to: root.appendingPathComponent("index.php"))

        let layout = VaelenFilesystemLayout(rootURL: root)
        let supervisor = CaddyProcessSupervisor(layout: layout)
        let package = try resolveCaddyPackage()
        await supervisor.installPackage(package)
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            _ = try? php.stop(requestedVersion: phpPackage.version)
            try? FileManager.default.removeItem(at: root)
        }

        _ = try php.start(requestedVersion: phpPackage.version)
        try await router.start()
        let socket = try php.status(requestedVersion: phpPackage.version).socket
        let route = Route(hostname: "php.test", target: .fastCGI(socketPath: socket, documentRoot: root.path), tls: .disabled)
        try await router.reconcile(routes: [route])
        XCTAssertEqual(try runCurl(host: "php.test", path: "/index.php"), "php response")
    }

    func testOfficialCaddyReachesSyncproofLaravelFrontController() async throws {
        guard let php = PHPModule.development(), let phpPackage = php.installedVersions().last else {
            throw XCTSkip("M2 PHP-FPM package is not installed")
        }
        let project = URL(fileURLWithPath: "/Users/banes/Code/syncproof", isDirectory: true)
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent("public/index.php").path) else {
            throw XCTSkip("syncproof project is not available")
        }
        let root = URL(fileURLWithPath: "/tmp/vaelen-syncproof-\(UUID().uuidString)", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: root)
        let supervisor = CaddyProcessSupervisor(layout: layout)
        await supervisor.installPackage(try resolveCaddyPackage())
        let router = CaddyRouter(layout: layout, supervisor: supervisor)
        addTeardownBlock {
            try? await router.stop()
            _ = try? php.stop(requestedVersion: phpPackage.version)
            try? FileManager.default.removeItem(at: root)
        }

        _ = try php.start(requestedVersion: phpPackage.version)
        try await router.start()
        let route = Route(hostname: "syncproof.test", target: .fastCGI(socketPath: try php.status(requestedVersion: phpPackage.version).socket, documentRoot: project.appendingPathComponent("public").path), tls: .disabled)
        try await router.reconcile(routes: [route])

        let home = try runHTTP(host: "syncproof.test", path: "/")
        XCTAssertEqual(home.status, 302, home.body)
        XCTAssertTrue(home.headers.contains("/integrations"), home.headers)
        let login = try runHTTP(host: "syncproof.test", path: "/login")
        XCTAssertEqual(login.status, 200, login.body)
        XCTAssertTrue(login.body.contains("auth\\/login"), login.body)
    }

    private func resolveCaddyPackage() throws -> CaddyPackage {
        let module = CaddyModule(layout: VaelenFilesystemLayout())
        do {
            return try module.resolveInstalled(requestedVersion: "2.11.4")
        } catch CaddyModuleError.packageMissing {
            do {
                return try module.install(requestedVersion: "2.11.4")
            } catch {
                throw XCTSkip("Caddy distribution prerequisite unavailable: \(error)")
            }
        }
    }

    private func runCurl(host: String, path: String = "/") throws -> String {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-fsS", "-H", "Host: \(host)", "http://127.0.0.1:8787\(path)"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyRuntimeError.processFailed("curl failed for \(host)") }; return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runHTTP(host: String, path: String) throws -> (status: Int, headers: String, body: String) {
        let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); process.arguments = ["-sS", "-D", "-", "-o", "-", "-H", "Host: \(host)", "http://127.0.0.1:8787\(path)"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; try process.run(); let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; process.waitUntilExit(); guard process.terminationStatus == 0 else { throw CaddyRuntimeError.processFailed("curl failed for \(host)") }; let parts = output.components(separatedBy: "\r\n\r\n"); let header = parts.first ?? ""; let body = parts.dropFirst().joined(separator: "\r\n\r\n"); let status = Int(header.split(separator: "\n").first?.split(separator: " ").dropFirst().first ?? "0") ?? 0; return (status, header, body)
    }
}
