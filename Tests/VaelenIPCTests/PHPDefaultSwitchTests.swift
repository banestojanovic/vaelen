import XCTest
@testable import VaelenCore
@testable import VaelenIPC
@testable import VaelenDaemonSupport

final class PHPDefaultSwitchTests: XCTestCase {
    func testSingleColdDefaultSelectionProcessRecordLifecycle() async throws {
        try requirePHPAcceptanceOptIn()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/vb-record-\(UUID().uuidString.prefix(8))")
        let layout = VaelenFilesystemLayout(rootURL: root, logsDirectoryURL: root.appendingPathComponent("logs"))
        let live = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vaelen/packages/php/8.3.29")
        guard let data = try? Data(contentsOf: live.appendingPathComponent(".vaelen-package.json")),
              let package = try? JSONDecoder().decode(PHPPackage.self, from: data) else { throw XCTSkip("Read-only PHP 8.3.29 package required") }
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("manifest.json")))
        defer {
            do {
                let observed = try module.status(requestedVersion: "8.3.29")
                if observed.state == .running { _ = try module.stop(requestedVersion: "8.3.29") }
                let confirmed = try module.status(requestedVersion: "8.3.29")
                guard confirmed.state == .stopped else { throw NSError(domain: "PHPDefaultSwitchTests.Cleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: "PHP remained \(confirmed.state)"]) }
                try FileManager.default.removeItem(at: root)
            } catch {
                let ns = error as NSError
                XCTFail("Cleanup failure separate from selection: domain=\(ns.domain) code=\(ns.code) underlying=\(String(describing: ns.userInfo[NSUnderlyingErrorKey])) path=\(ns.userInfo["NSFilePath"] ?? "unknown") error=\(error)")
            }
        }
        let target = layout.phpPackagesDirectoryURL.appendingPathComponent("8.3.29")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["php", "php-fpm"] { try FileManager.default.copyItem(at: live.appendingPathComponent(name), to: target.appendingPathComponent(name)) }
        let isolated = PHPPackage(version: package.version, architecture: package.architecture, packagePath: target.path, cliPath: target.appendingPathComponent("php").path, fpmPath: target.appendingPathComponent("php-fpm").path, source: package.source, cliSHA256: package.cliSHA256, fpmSHA256: package.fpmSHA256, installedAt: package.installedAt)
        try JSONEncoder().encode(isolated).write(to: target.appendingPathComponent(".vaelen-package.json"))
        let registry = ProjectRegistry(store: try SQLiteStateStore(databaseURL: layout.databaseURL))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, php: module)
        let before = layout.phpInstancesDirectoryURL.appendingPathComponent("8.3.29/process.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: before.path))
        let pair = InMemoryTransport.pair()
        let server = Task {
            try await pair.server.connect()
            var decoder = FrameDecoder(); var handshaken = false
            while !Task.isCancelled {
                let data = try await pair.server.read()
                for frame in try decoder.append(data) {
                    let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                    let dispatched = await dispatcher.dispatch(request, handshaken: handshaken)
                    handshaken = dispatched.handshaken
                    try await pair.server.write(FrameEncoder().encode(IPCCodec.encode(dispatched.response)))
                }
            }
        }
        defer { server.cancel() }
        let client = VaelenCoreClient(transport: pair.client, identity: ClientIdentity(name: "legacy-php-default-test", version: VaelenBuildInfo.version))
        do {
            try await client.connect()
            let catalog = try await client.phpDefaultSet("8.3.29")
            XCTAssertEqual(catalog.defaultVersion, "8.3.29")
        } catch {
            let ns = error as NSError
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            print("PROCESS_RECORD_ORIGINAL_FAILURE operation=legacy client cold selection domain=\(ns.domain) code=\(ns.code) underlying=\(underlying.map { "\($0.domain):\($0.code)" } ?? "none") path=\(ns.userInfo["NSFilePath"] ?? underlying?.userInfo["NSFilePath"] ?? "unknown") error=\(error)")
            throw error
        }
        await client.disconnect()
        let recordURL = layout.phpInstancesDirectoryURL.appendingPathComponent("8.3.29/process.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path), "successful cold selection must publish its PHP process record")
        let stableRecord = try Data(contentsOf: recordURL)
        for _ in 0..<5 {
            XCTAssertEqual(try module.status(requestedVersion: "8.3.29").state, .running)
            XCTAssertEqual(try Data(contentsOf: recordURL), stableRecord, "repeated status reads must not lose/replace the live process record")
        }
        let stopped = try module.stop(requestedVersion: "8.3.29")
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path), "stop removes the record only after confirming the owned process stopped")
        XCTAssertEqual(try module.status(requestedVersion: "8.3.29").state, .stopped)
    }

    func testColdAndWarmSwitchWithSixInheritedRoutes() async throws {
        try requirePHPAcceptanceOptIn()
        var installedPackages: [String: PHPPackage] = [:]
        for version in ["8.4.23", "8.3.29"] {
            let live = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vaelen/packages/php/\(version)")
            guard let data = try? Data(contentsOf: live.appendingPathComponent(".vaelen-package.json")),
                  let package = try? JSONDecoder().decode(PHPPackage.self, from: data),
                  FileManager.default.isExecutableFile(atPath: package.cliPath),
                  FileManager.default.isExecutableFile(atPath: package.fpmPath) else {
                throw XCTSkip("Read-only real PHP binaries required")
            }
            installedPackages[version] = package
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/vb-\(UUID().uuidString.prefix(8))")
        let layout = VaelenFilesystemLayout(rootURL: root, logsDirectoryURL: root.appendingPathComponent("logs"))
        var routerStopped = false
        var phpStopped = false
        var copiedCaddyDirectory: URL?
        let module = PHPModule(layout: layout, location: FilePHPManifestLocation(manifestURL: root.appendingPathComponent("manifest.json")))
        defer {
            do {
                for version in ["8.4.23", "8.3.29"] {
                    let status = try module.status(requestedVersion: version)
                    if status.state == .running {
                        _ = try module.stop(requestedVersion: version)
                    }
                    guard try module.status(requestedVersion: version).state == .stopped else { throw NSError(domain: "PHPDefaultSwitchTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "PHP \(version) did not verify stopped"]) }
                }
                phpStopped = true
                if !routerStopped { try stopOwnedCaddy(in: root); routerStopped = true }
                guard phpStopped && routerStopped else { throw NSError(domain: "PHPDefaultSwitchTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Owned PHP/Caddy shutdown was not verified"]) }
                if let copiedCaddyDirectory { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copiedCaddyDirectory.path) }
                try FileManager.default.removeItem(at: root)
            } catch {
                let ns = error as NSError
                let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                XCTFail("Cleanup failure (original test error is reported separately): domain=\(ns.domain) code=\(ns.code) underlying=\(underlying.map { "\($0.domain):\($0.code)" } ?? "none") path=\(ns.userInfo["NSFilePath"] ?? underlying?.userInfo["NSFilePath"] ?? "unknown") error=\(error)")
            }
        }
        for version in ["8.4.23", "8.3.29"] {
            let live = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vaelen/packages/php/\(version)")
            let package = try XCTUnwrap(installedPackages[version])
            let directory = layout.phpPackagesDirectoryURL.appendingPathComponent(version)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["php", "php-fpm"] { try FileManager.default.copyItem(at: live.appendingPathComponent(name), to: directory.appendingPathComponent(name)) }
            let copy = PHPPackage(version: version, architecture: package.architecture, packagePath: directory.path, cliPath: directory.appendingPathComponent("php").path, fpmPath: directory.appendingPathComponent("php-fpm").path, source: package.source, cliSHA256: package.cliSHA256, fpmSHA256: package.fpmSHA256, installedAt: package.installedAt)
            try JSONEncoder().encode(copy).write(to: directory.appendingPathComponent(".vaelen-package.json"))
        }
        try FileManager.default.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
        try Data("8.4.23".utf8).write(to: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"))
        let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
        let registry = ProjectRegistry(store: store)
        let repository = RouteIntentRepository(store: store)
        for index in 0..<6 {
            let directory = root.appendingPathComponent("project-\(index)")
            let documentRoot = directory.appendingPathComponent("public")
            try FileManager.default.createDirectory(at: documentRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("bootstrap"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("config"), withIntermediateDirectories: true)
            try Data("<?php".utf8).write(to: directory.appendingPathComponent("artisan"))
            try Data("{\"require\":{\"laravel/framework\":\"^11.0\",\"php\":\"^8.3\"}}".utf8).write(to: directory.appendingPathComponent("composer.json"))
            try Data("<?php echo PHP_VERSION;".utf8).write(to: documentRoot.appendingPathComponent("index.php"))
            let project = try await registry.link(path: directory)
            let route = Route(hostname: "switch-\(index).test", target: .fastCGI(socketPath: root.appendingPathComponent("runtime/sockets/php/php-8.4.23.sock").path, documentRoot: documentRoot.path), tls: .disabled)
            try repository.upsert(RouteIntent(route: route, projectID: project.id!.rawValue, projectPath: directory.path))
        }
        // A single project has a Laravel public/ root, but its persisted route
        // intentionally still points at the project root. Default selection
        // must not rewrite this user route or fail to converge other projects.
        let needsAttention = root.appendingPathComponent("needs-attention")
        try FileManager.default.createDirectory(at: needsAttention.appendingPathComponent("public"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: needsAttention.appendingPathComponent("bootstrap"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: needsAttention.appendingPathComponent("config"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: needsAttention.appendingPathComponent("artisan"))
        try Data("{\"require\":{\"laravel/framework\":\"^11.0\"}}".utf8).write(to: needsAttention.appendingPathComponent("composer.json"))
        try Data("<?php".utf8).write(to: needsAttention.appendingPathComponent("public/index.php"))
        let attentionProject = try await registry.link(path: needsAttention)
        let attentionRoute = Route(hostname: "needs-attention.test", target: .fastCGI(socketPath: root.appendingPathComponent("runtime/sockets/php/php-8.4.23.sock").path, documentRoot: needsAttention.path), tls: .disabled)
        let attentionIntent = RouteIntent(route: attentionRoute, projectID: attentionProject.id?.rawValue, projectPath: needsAttention.path)
        try repository.upsert(attentionIntent)
        let wordpress = root.appendingPathComponent("wordpress")
        try FileManager.default.createDirectory(at: wordpress.appendingPathComponent("wp-admin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordpress.appendingPathComponent("wp-includes"), withIntermediateDirectories: true)
        try Data("<?php".utf8).write(to: wordpress.appendingPathComponent("wp-config.php"))
        try Data("<?php echo PHP_VERSION;".utf8).write(to: wordpress.appendingPathComponent("index.php"))
        let wpProject = try await registry.link(path: wordpress)
        let wpRoute = Route(hostname: "wordpress-root.test", target: .fastCGI(socketPath: root.appendingPathComponent("runtime/sockets/php/php-8.4.23.sock").path, documentRoot: wordpress.path), tls: .disabled)
        let wpIntent = RouteIntent(route: wpRoute, projectID: wpProject.id?.rawValue, projectPath: wordpress.path)
        try repository.upsert(wpIntent)
        let liveCaddy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vaelen/packages/caddy/2.11.4")
        guard FileManager.default.fileExists(atPath: liveCaddy.appendingPathComponent("caddy").path) else { throw XCTSkip("Read-only real Caddy binary required") }
        let caddyDirectory = layout.caddyPackagesDirectoryURL.appendingPathComponent("2.11.4")
        try FileManager.default.createDirectory(at: caddyDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: liveCaddy, to: caddyDirectory)
        let metadataURL = caddyDirectory.appendingPathComponent(".vaelen-package.json")
        var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        metadata["packagePath"] = caddyDirectory.path
        metadata["executablePath"] = caddyDirectory.appendingPathComponent("caddy").path
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        copiedCaddyDirectory = caddyDirectory
        let router = CaddyRouter(layout: layout, supervisor: CaddyProcessSupervisor(layout: layout, configuration: .init(httpPort: 28781, httpsPort: 28782)))
        do { try await router.start() }
        catch { logStageFailure("Caddy start", error: error); throw error }
        routerStopped = false
        do { try await router.reconcile(routes: repository.all().map(\.route)) }
        catch { logStageFailure("initial Caddy reconciliation", error: error); throw error }
        let intents = ServiceIntentStore(url: root.appendingPathComponent("service-intents.json"))
        let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: "test", pid: 1), registry: registry, php: module, router: router, routeRepository: repository, serviceIntents: intents)
        for (kind, version) in [("cold", "8.3.29"), ("cold", "8.4.23"), ("warm", "8.3.29"), ("warm", "8.4.23")] {
            let started = ContinuousClock.now
            let selectionPair = InMemoryTransport.pair()
            let server = Task {
                try await selectionPair.server.connect()
                var decoder = FrameDecoder(); var handshaken = false
                while !Task.isCancelled {
                    let data = try await selectionPair.server.read()
                    for frame in try decoder.append(data) {
                        let request = try IPCCodec.decode(IPCRequest.self, from: frame)
                        let dispatched = await dispatcher.dispatch(request, handshaken: handshaken)
                        handshaken = dispatched.handshaken
                        try await selectionPair.server.write(FrameEncoder().encode(IPCCodec.encode(dispatched.response)))
                    }
                }
            }
            let selectionClient = VaelenCoreClient(transport: selectionPair.client, identity: ClientIdentity(name: "php-default-test", version: VaelenBuildInfo.version))
            try await selectionClient.connect()
            let selection: PHPDefaultSelectionResult
            do { selection = try await selectionClient.phpDefaultSelect(version) }
            catch {
                let ns = error as NSError
                let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                print("PHP_SWITCH_ORIGINAL_FAILURE operation=client selection version=\(version) domain=\(ns.domain) code=\(ns.code) underlying=\(underlying.map { "\($0.domain):\($0.code)" } ?? "none") path=\(ns.userInfo["NSFilePath"] ?? underlying?.userInfo["NSFilePath"] ?? "unknown") error=\(error)")
                throw error
            }
            await selectionClient.disconnect()
            server.cancel()
            let duration = started.duration(to: .now)
            print("PHP_SWITCH_BENCH \(kind) version=\(version) projects=8 elapsed=\(duration)")
            print("PHP_SWITCH_PHASES \(await dispatcher.lastPHPDefaultSwitchTimings)")
            XCTAssertEqual(selection.catalog.defaultVersion, version)
            XCTAssertEqual(selection.projectIssues.map { $0.projectName }, ["needs-attention"])
            XCTAssertEqual(module.defaultVersion(), version)
            XCTAssertTrue(try intents.enabledServices().contains("php:\(version)"))
            XCTAssertTrue(try repository.all().filter { $0.route.hostname != "needs-attention.test" }.allSatisfy { $0.route.target.fastCGISocket?.hasSuffix("php-\(version).sock") == true })
            XCTAssertEqual(try repository.all().first(where: { $0.route.hostname == "needs-attention.test" })?.route, attentionRoute, "Core must not rewrite the affected project's document root or PHP socket")
            var request = URLRequest(url: URL(string: "http://127.0.0.1:28781/")!)
            request.setValue("switch-0.test", forHTTPHeaderField: "Host")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), version)
        }
        let attentionJSON = await dispatcher.dispatch(IPCRequest(method: .projectInspect, params: .projectEnvironment(.init(selector: "needs-attention", workingDirectory: root.path))), handshaken: true)
        guard case .projectEnvironment(let report) = attentionJSON.response.result else { return XCTFail("targeted project inspection missing") }
        XCTAssertEqual(report.report.routeTargets.first?.reason, "The persisted document root does not match the validated project document root.")
        XCTAssertEqual(try repository.all().first(where: { $0.route.hostname == "needs-attention.test" })?.route, attentionRoute, "blocked mismatch must leave persisted route untouched")
        let retry = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: "needs-attention", workingDirectory: root.path))), handshaken: true)
        guard case .projectActivation(let blockedRetry) = retry.response.result else { return XCTFail("targeted retry must return project activation result, not a generic refresh") }
        _ = blockedRetry // activation's summary may succeed while independent route blockers remain
        let stillBlocked = await dispatcher.dispatch(IPCRequest(method: .projectInspect, params: .projectEnvironment(.init(selector: "needs-attention", workingDirectory: root.path))), handshaken: true)
        guard case .projectEnvironment(let stillBlockedReport) = stillBlocked.response.result else { return XCTFail("post-retry verification is required") }
        XCTAssertTrue(stillBlockedReport.report.routeTargets.contains { $0.disposition == .blocked && $0.reason?.contains("document root") == true })
        XCTAssertEqual(try repository.all().first(where: { $0.route.hostname == "needs-attention.test" })?.route, attentionRoute)
        let correctedRoute = Route(id: attentionRoute.id, hostname: attentionRoute.hostname, target: .fastCGI(socketPath: attentionRoute.target.fastCGISocket ?? "", documentRoot: needsAttention.appendingPathComponent("public").path), tls: .disabled)
        let routeCorrection = await dispatcher.dispatch(IPCRequest(method: .routeAdd, params: .route(.init(route: correctedRoute, projectID: attentionProject.id?.rawValue, projectPath: needsAttention.path))), handshaken: true)
        guard case .routeMutation = routeCorrection.response.result else { return XCTFail("explicit isolated route-root correction must be accepted through Core") }
        let recoveredRetry = await dispatcher.dispatch(IPCRequest(method: .projectActivate, params: .projectEnvironment(.init(selector: "needs-attention", workingDirectory: root.path))), handshaken: true)
        guard case .projectActivation(let recovered) = recoveredRetry.response.result else { return XCTFail("targeted recovery must return project activation") }
        XCTAssertEqual(recovered.execution.state, .succeeded)
        let verified = await dispatcher.dispatch(IPCRequest(method: .projectInspect, params: .projectEnvironment(.init(selector: "needs-attention", workingDirectory: root.path))), handshaken: true)
        guard case .projectEnvironment(let verifiedReport) = verified.response.result else { return XCTFail("recovery verification missing") }
        XCTAssertTrue(verifiedReport.report.routeTargets.allSatisfy { $0.disposition == .satisfied })
        let initialDefault = module.defaultVersion()
        let stoppedResponse = await dispatcher.dispatch(IPCRequest(method: .phpStop, params: .phpVersion(.init(version: "8.3.29"))), handshaken: true)
        guard case .phpStatus(let stoppedStatus) = stoppedResponse.response.result else { return XCTFail("php.stop must return authoritative status") }
        XCTAssertEqual(stoppedStatus.status.state, .stopped)
        XCTAssertEqual(module.defaultVersion(), initialDefault, "Stopping a runtime never changes default selection")
        XCTAssertFalse(try intents.enabledServices().contains("php:8.3.29"))
        let startedResponse = await dispatcher.dispatch(IPCRequest(method: .phpStart, params: .phpVersion(.init(version: "8.3.29"))), handshaken: true)
        guard case .phpStatus(let startedStatus) = startedResponse.response.result else { return XCTFail("php.start must return authoritative status") }
        XCTAssertEqual(startedStatus.status.state, .running)
        XCTAssertEqual(module.defaultVersion(), initialDefault, "Starting a runtime never changes default selection")
        XCTAssertTrue(try intents.enabledServices().contains("php:8.3.29"))
        let removal = await dispatcher.dispatch(IPCRequest(method: .phpRemove, params: .phpVersion(.init(version: "8.3.29"))), handshaken: true)
        XCTAssertNotNil(removal.response.error, "Running runtime removal must fail")
        XCTAssertTrue(try intents.enabledServices().contains("php:8.3.29"), "Rejected removal must not disable the user's saved start choice")
        for version in ["8.4.23", "8.3.29"] {
            let status = try module.status(requestedVersion: version)
            if status.state == .running { _ = try module.stop(requestedVersion: version) }
            XCTAssertEqual(try module.status(requestedVersion: version).state, .stopped, "owned PHP \(version) must be confirmed stopped before cleanup")
        }
        phpStopped = true
        try await router.stop()
        let caddyStatus = await router.status()
        XCTAssertEqual(caddyStatus.state, .stopped, "owned Caddy must be confirmed stopped before cleanup")
        routerStopped = true
    }

    private func stopOwnedCaddy(in root: URL) throws {
        let record = root.appendingPathComponent("instances/caddy/process.json")
        guard FileManager.default.fileExists(atPath: record.path) else { return }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any] ?? [:]
        guard let pid = (value["pid"] as? NSNumber)?.int32Value,
              let socket = (value["adminEndpoint"] as? String)?.replacingOccurrences(of: "unix///", with: "/"),
              let executable = value["executablePath"] as? String,
              executable.hasPrefix(root.path + "/"),
              let config = value["configPath"] as? String, config.hasPrefix(root.path + "/"),
              socket.hasPrefix(root.path + "/") else { throw NSError(domain: "PHPDefaultSwitchTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Caddy process record does not prove fixture ownership"]) }
        if kill(pid, 0) == 0 || errno == EPERM {
            let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-p", String(pid), "-o", "command="]
            let identity = Pipe(); ps.standardOutput = identity; ps.standardError = FileHandle.nullDevice
            try ps.run(); ps.waitUntilExit()
            let commandLine = String(data: identity.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard ps.terminationStatus == 0, commandLine.contains(executable), commandLine.contains(config) else {
                throw NSError(domain: "PHPDefaultSwitchTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Caddy PID does not match its recorded executable/config identity"])
            }
            let curl = Process(); curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = ["--silent", "--show-error", "--unix-socket", socket, "-X", "POST", "http://localhost/stop"]
            let output = Pipe(); curl.standardError = output; curl.standardOutput = output
            try curl.run(); curl.waitUntilExit()
            guard curl.terminationStatus == 0 else { throw NSError(domain: "PHPDefaultSwitchTests", code: Int(curl.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Caddy admin stop failed: \(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown")"]) }
            for _ in 0..<100 {
                if kill(pid, 0) != 0 && errno == ESRCH { return }
                usleep(50_000)
            }
            throw NSError(domain: "PHPDefaultSwitchTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Owned Caddy PID \(pid) remained live after admin stop"])
        }
        guard errno == ESRCH else { throw NSError(domain: "PHPDefaultSwitchTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not verify fixture Caddy process state"]) }
    }

    private func logStageFailure(_ operation: String, error: Error) {
        let ns = error as NSError
        let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        print("PHP_SWITCH_STAGE_FAILURE operation=\(operation) domain=\(ns.domain) code=\(ns.code) underlying=\(underlying.map { "\($0.domain):\($0.code)" } ?? "none") path=\(ns.userInfo["NSFilePath"] ?? underlying?.userInfo["NSFilePath"] ?? "unknown") error=\(error)")
    }

    private func requirePHPAcceptanceOptIn() throws {
        guard ProcessInfo.processInfo.environment["VAELEN_PHP_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set VAELEN_PHP_ACCEPTANCE=1 to run PHP default-switch process acceptance tests (requires installed PHP and, for the route test, Caddy packages).")
        }
    }
}
