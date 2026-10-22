import Darwin
import Foundation
import VaelenCore
import VaelenIPC

private struct RuntimeInput: Codable {
    let version: String
    let cli: String
    let fpm: String
    let cliIdentity: String
    let fpmIdentity: String
}

private struct OwnedChild: Codable {
    let role: String
    let pid: Int32
    let startIdentity: String
    let executable: String
}

private struct FPMRecord: Decodable {
    let pid: Int32
    let version: String
    let executable: String
    let arguments: [String]
    let configPath: String
    let socketPath: String
    let startedAt: String?
}

private struct ProjectsPHPUIRun: Codable {
    let token: UUID
    let scratchRoot: String
    let supportRoot: String
    let evidenceRoot: String
    let projectID: UUID
    let projectRoot: String
    let appExecutable: String
    let coreExecutable: String
    let overrideRuntime: RuntimeInput
    let defaultRuntime: RuntimeInput
    let originalDefaultBytes: Data
    var ownershipBaseline: CapabilityOwnershipBaseline?
    var generation: Int
    var children: [OwnedChild]
    var journey: JourneyCheckpoint
    var fpmShutdownProofGeneration: Int?
    var fpmProcessesBeforeShutdown: [OwnedChild]
    var launchAttempted: Bool
}

private struct CapabilityOwnershipBaseline: Codable, Equatable {
    let dns: DNSOwnership
    let pf: StandardPortsOwnership
}

private enum JourneyCheckpoint: String, Codable {
    case preparing
    case preparedBaseline
    case observedOverride
    case restartedOverrideObserved
    case observedDefault
}

private struct SelectionEvidence: Codable {
    let generation: Int
    let projectID: UUID
    let projectPath: String
    let overrideVersion: String?
    let defaultVersion: String
    let effectiveVersion: String
    let observedVersion: String?
    let fpmHealthy: Bool
    let routeCount: Int
    let parkedPathCount: Int
    let dnsOwnership: String
    let pfOwnership: String
    let serviceIntentCount: Int
    let desiredPHP: String?
    let secureWeb: Bool?
    let mysqlDesired: Bool?
    let mailpitDesired: Bool?
}

private enum LaneError: Error, CustomStringConvertible {
    case usage
    case refused(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage: return "usage: projects-php-core <prepare|inspect|restart|cleanup> --evidence PATH [prepare inputs]"
        case .refused(let message): return "NOT VERIFIED: \(message)"
        case .failed(let message): return message
        }
    }
}

@main
private struct ProjectsPHPUIAcceptance {
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 2 else { throw LaneError.usage }
            let command = CommandLine.arguments[1]
            let arguments = try parse(Array(CommandLine.arguments.dropFirst(2)))
            guard let evidence = arguments["--evidence"] else { throw LaneError.usage }
            let evidenceURL = URL(fileURLWithPath: evidence).standardizedFileURL
            switch command {
            case "prepare": try await prepare(arguments, evidence: evidenceURL)
            case "inspect": try await inspect(arguments, evidence: evidenceURL)
            case "restart": try await restart(evidence: evidenceURL)
            case "cleanup": try await cleanup(evidence: evidenceURL)
            default: throw LaneError.usage
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func parse(_ values: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < values.count {
            let key = values[index]
            guard key.hasPrefix("--"), index + 1 < values.count, result[key] == nil else { throw LaneError.usage }
            result[key] = values[index + 1]
            index += 2
        }
        return result
    }

    private static func prepare(_ args: [String: String], evidence: URL) async throws {
        guard let appPath = args["--app"], let overrideCLI = args["--override-cli"],
              let overrideFPM = args["--override-fpm"], let overrideVersion = args["--override-version"],
              let defaultCLI = args["--default-cli"], let defaultFPM = args["--default-fpm"],
              let defaultVersion = args["--default-version"] else { throw LaneError.usage }
        guard overrideVersion != defaultVersion else { throw LaneError.refused("override and shared default must be different exact versions") }
        let manager = FileManager.default
        guard evidence.path.hasPrefix("/"), evidence.path.contains("/artifacts/verification/"), !manager.fileExists(atPath: evidence.path) else {
            throw LaneError.refused("evidence must be a new directory under artifacts/verification")
        }
        try validatePathAncestors(evidence)
        guard appPath.hasPrefix("/") else { throw LaneError.refused("app path must be absolute") }
        let appURL = URL(fileURLWithPath: appPath).standardizedFileURL
        let appExecutable = appURL.appendingPathComponent("Contents/MacOS/Vaelen")
        let coreExecutable = appURL.appendingPathComponent("Contents/Resources/vaelend")
        try validateDebugAppBundle(appURL, appExecutable: appExecutable, coreExecutable: coreExecutable)
        let override = try runtime(version: overrideVersion, cli: overrideCLI, fpm: overrideFPM)
        let sharedDefault = try runtime(version: defaultVersion, cli: defaultCLI, fpm: defaultFPM)
        try requireSafeHost(configuredFPMPaths: [override.fpm, sharedDefault.fpm])
        let token = UUID()
        let scratch = URL(fileURLWithPath: "/private/tmp/vpu-\(token.uuidString.prefix(8))", isDirectory: true)
        try CoreEndpointPaths(root: scratch.appendingPathComponent("support/runtime", isDirectory: true)).validateSocketPathLength()
        let support = scratch.appendingPathComponent("support", isDirectory: true)
        let project = scratch.appendingPathComponent("Storefront", isDirectory: true)
        let layout = VaelenFilesystemLayout(rootURL: support)
        var manifest = ProjectsPHPUIRun(token: token, scratchRoot: scratch.path, supportRoot: support.path, evidenceRoot: evidence.path,
            projectID: UUID(), projectRoot: project.path, appExecutable: appExecutable.path, coreExecutable: coreExecutable.path,
            overrideRuntime: override, defaultRuntime: sharedDefault, originalDefaultBytes: Data("\(defaultVersion)\n".utf8),
            ownershipBaseline: nil, generation: 0, children: [], journey: .preparing, fpmShutdownProofGeneration: nil, fpmProcessesBeforeShutdown: [], launchAttempted: false)
        var evidenceCreated = false
        var scratchCreated = false
        do {
            try manager.createDirectory(at: evidence, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            evidenceCreated = true
            try save(manifest)
            try appendEvidence("allocated token=\(token) scratch=\(scratch.path)\n", to: evidence)
            try mkdirOwned(scratch)
            scratchCreated = true
            for directory in [support, layout.configurationDirectoryURL, layout.routingConfigurationDirectoryURL,
                              layout.stateDirectoryURL, layout.rootURL.appendingPathComponent("runtime", isDirectory: true),
                              layout.routingRuntimeDirectoryURL, layout.packagesDirectoryURL, layout.phpPackagesDirectoryURL,
                              layout.caddyPackagesDirectoryURL, layout.mysqlPackagesDirectoryURL, layout.mailpitPackagesDirectoryURL,
                              layout.instancesDirectoryURL, layout.phpInstancesDirectoryURL, layout.caddyInstancesDirectoryURL,
                              layout.mysqlInstancesDirectoryURL, layout.mailpitInstancesDirectoryURL, layout.dnsInstancesDirectoryURL,
                              layout.cacheDirectoryURL, layout.downloadsDirectoryURL, layout.stagingDirectoryURL,
                              layout.logsDirectoryURL, layout.phpLogsDirectoryURL, layout.caddyLogsDirectoryURL,
                              layout.mysqlLogsDirectoryURL, layout.mailpitLogsDirectoryURL, layout.dnsLogsDirectoryURL,
                              layout.tlsDirectoryURL, layout.tlsCertificatesDirectoryURL, layout.tlsLeafDirectoryURL] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try manager.createDirectory(at: project.appendingPathComponent("public", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("<?php echo 'isolated storefront';\n".utf8).write(to: project.appendingPathComponent("public/index.php"), options: .atomic)
            try Data("version: 1\nweb:\n  secure: false\nservices:\n  mysql: false\n  mailpit: false\n".utf8).write(to: project.appendingPathComponent("vaelen.yml"), options: .atomic)
            let originalDefault = Data("\(defaultVersion)\n".utf8)
            try writeRuntime(override, layout: layout)
            try writeRuntime(sharedDefault, layout: layout)
            try originalDefault.write(to: layout.configurationDirectoryURL.appendingPathComponent("php-default.json"), options: .atomic)
            try writeDevelopmentManifest(version: defaultVersion, to: support.appendingPathComponent("php-manifest.json"))
            try writeDevelopmentConfiguration(manifest: support.appendingPathComponent("php-manifest.json"), to: layout.configurationDirectoryURL.appendingPathComponent("php-distribution.json"))
            setenv("VAELEN_PHP_MANIFEST", support.appendingPathComponent("php-manifest.json").path, 1)
            guard let php = PHPModule.development(layout: layout),
                  try php.resolveEligible(overrideVersion).version == overrideVersion,
                  try php.resolveEligible(defaultVersion).version == defaultVersion else {
                throw LaneError.refused("seeded runtimes did not pass production PHP eligibility")
            }
            let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
            let registry = ProjectRegistry(store: store)
            let linked = try await registry.link(path: project, name: "Storefront")
            guard let projectID = linked.id?.rawValue else { throw LaneError.failed("Core registry did not assign project identity") }
            manifest = ProjectsPHPUIRun(token: token, scratchRoot: scratch.path, supportRoot: support.path, evidenceRoot: evidence.path,
                projectID: projectID, projectRoot: project.path, appExecutable: appExecutable.path, coreExecutable: coreExecutable.path,
                overrideRuntime: override, defaultRuntime: sharedDefault, originalDefaultBytes: originalDefault,
                ownershipBaseline: nil, generation: 0, children: [], journey: .preparing, fpmShutdownProofGeneration: nil, fpmProcessesBeforeShutdown: [], launchAttempted: false)
            try save(manifest)
            try appendEvidence("prepared token=\(manifest.token) project=\(projectID) override=\(override.version) default=\(defaultVersion)\n", to: evidence)
            try await launchCoreAndApp(&manifest)
            let selection = try await observe(manifest)
            guard selection.overrideVersion == nil, selection.defaultVersion == defaultVersion,
                  selection.effectiveVersion == defaultVersion, selection.routeCount == 0, selection.parkedPathCount == 0,
                  selection.serviceIntentCount == 0, selection.desiredPHP == nil, selection.secureWeb == false,
                  selection.mysqlDesired == false, selection.mailpitDesired == false else {
                throw LaneError.failed("private Core baseline did not match the seeded default")
            }
            guard let dnsOwnership = DNSOwnership(rawValue: selection.dnsOwnership),
                  let pfOwnership = StandardPortsOwnership(rawValue: selection.pfOwnership),
                  dnsOwnership != .unknown, pfOwnership != .unknown else {
                throw LaneError.failed("private Core baseline reported unknown or unrecognized capability ownership")
            }
            manifest.ownershipBaseline = CapabilityOwnershipBaseline(dns: dnsOwnership, pf: pfOwnership)
            try appendEvidence("baseline \(try encode(selection))\n", to: evidence)
            manifest.journey = .preparedBaseline
            try save(manifest)
            print("PREPARED token=\(manifest.token) project=\(projectID) default=\(defaultVersion) override=\(override.version)")
        } catch {
            if evidenceCreated { try? appendEvidence("prepare-failed token=\(token) scratch=\(scratch.path) \(error)\n", to: evidence) }
            if scratchCreated, manager.fileExists(atPath: scratch.path), !manifest.launchAttempted, manifest.children.isEmpty, !isSymlink(scratch.path),
               scratch.resolvingSymlinksInPath().standardizedFileURL == scratch.standardizedFileURL {
                try? manager.removeItem(at: scratch)
                if evidenceCreated { try? appendEvidence("prepare-root-removed token=\(token)\n", to: evidence) }
            }
            throw error
        }
    }

    private static func inspect(_ args: [String: String], evidence: URL) async throws {
        guard let expected = args["--expect"], expected == "default" || expected == "override" else { throw LaneError.usage }
        let run = try load(evidence)
        try validateOwnedRun(run)
        if expected == "override" {
            guard run.journey == .preparedBaseline || run.journey == .observedOverride || run.journey == .restartedOverrideObserved else {
                throw LaneError.failed("override observation is out of journey order")
            }
        } else {
            guard run.journey == .restartedOverrideObserved || run.journey == .observedDefault else {
                throw LaneError.failed("Use Default observation requires override and restart checkpoints")
            }
        }
        let value = try await observe(run)
        let wantedOverride = expected == "override" ? run.overrideRuntime.version : nil
        let wantedEffective = expected == "override" ? run.overrideRuntime.version : run.defaultRuntime.version
        guard value.overrideVersion == wantedOverride, value.defaultVersion == run.defaultRuntime.version,
              value.effectiveVersion == wantedEffective, value.routeCount == 0, value.parkedPathCount == 0,
              ownershipMatches(value, baseline: run.ownershipBaseline),
              value.serviceIntentCount == 0, value.desiredPHP == nil, value.secureWeb == false,
              value.mysqlDesired == false, value.mailpitDesired == false else {
            throw LaneError.failed("Core selection mismatch: \(try encode(value))")
        }
        if (expected == "override" && run.generation == 1) || (expected == "default" && run.generation > 1) {
            guard value.fpmHealthy else { throw LaneError.failed("PHP-FPM is not healthy for the selected mutation") }
        }
        guard try currentDefaultBytes(run) == run.originalDefaultBytes else { throw LaneError.failed("private shared-default bytes changed") }
        try appendEvidence("inspect-\(expected) \(try encode(value))\n", to: evidence)
        var updated = run
        if expected == "override" { updated.journey = run.generation > 1 ? .restartedOverrideObserved : .observedOverride }
        else { updated.journey = .observedDefault }
        updated.fpmShutdownProofGeneration = nil
        updated.fpmProcessesBeforeShutdown = []
        try save(updated)
        print(try encode(value))
    }

    private static func restart(evidence: URL) async throws {
        var run = try load(evidence)
        try validateOwnedRun(run)
        guard run.journey == .observedOverride else { throw LaneError.failed("restart requires a prior observed override") }
        try stopOwnedApp(&run)
        try await shutdownOwnedCore(&run)
        try stopRecordedFPM(&run)
        guard !hasOwnedSockets(run) else { throw LaneError.failed("owned sockets remain; preserving private root") }
        let registry = try await readPersistedOverride(run)
        guard registry == run.overrideRuntime.version else { throw LaneError.failed("fresh SQLite registry did not retain the selected override") }
        try await launchCoreAndApp(&run)
        let value = try await observe(run)
        guard value.overrideVersion == run.overrideRuntime.version, value.effectiveVersion == run.overrideRuntime.version,
              value.routeCount == 0, value.parkedPathCount == 0,
              ownershipMatches(value, baseline: run.ownershipBaseline),
              value.serviceIntentCount == 0, value.desiredPHP == nil, value.secureWeb == false,
              value.mysqlDesired == false, value.mailpitDesired == false else {
            throw LaneError.failed("fresh Core did not observe the persisted override")
        }
        try appendEvidence("restart generation=\(run.generation) registryOverride=\(registry ?? "nil") \(try encode(value))\n", to: evidence)
        run.journey = .restartedOverrideObserved
        try save(run)
        print("RESTARTED generation=\(run.generation) override=\(registry ?? "nil")")
    }

    private static func cleanup(evidence: URL) async throws {
        var run = try load(evidence)
        try validateOwnedRun(run, allowExited: true)
        guard run.journey == .observedDefault else { throw LaneError.failed("cleanup requires observed override, restarted override, and Use Default checkpoints; preserving root") }
        guard run.children.contains(where: { $0.role == "core" && processExists($0) }) else {
            let registry = try await readPersistedOverride(run)
            guard registry == nil else { throw LaneError.failed("fresh SQLite registry retains an override; preserving root") }
            throw LaneError.failed("private Core exited before capability baseline could be verified; preserving root")
        }
        do {
            let restored = try await observe(run)
            guard restored.overrideVersion == nil, restored.defaultVersion == run.defaultRuntime.version,
                  restored.effectiveVersion == run.defaultRuntime.version, restored.fpmHealthy,
                  restored.routeCount == 0, restored.parkedPathCount == 0,
                  ownershipMatches(restored, baseline: run.ownershipBaseline),
                  restored.serviceIntentCount == 0, restored.desiredPHP == nil, restored.secureWeb == false,
                  restored.mysqlDesired == false, restored.mailpitDesired == false,
                  try currentDefaultBytes(run) == run.originalDefaultBytes else {
                throw LaneError.failed("native Use Default restoration or private capability baseline is not verified; preserving root")
            }
            try appendEvidence("restore \(try encode(restored))\n", to: evidence)
        } catch { throw error }
        try stopOwnedApp(&run)
        if run.children.contains(where: { $0.role == "core" && processExists($0) }) { try await shutdownOwnedCore(&run) }
        try stopRecordedFPM(&run)
        guard run.fpmShutdownProofGeneration == run.generation, !fpmRecordExists(run) else {
            throw LaneError.failed("typed Core shutdown did not prove the current FPM generation stopped or private FPM records remain; preserving root")
        }
        guard run.children.allSatisfy({ !processExists($0) }), !hasOwnedSockets(run) else {
            throw LaneError.failed("owned process or socket remains; preserving private root")
        }
        let registry = try await readPersistedOverride(run)
        guard registry == nil else { throw LaneError.failed("Use Default was not selected through the native UI; preserving private root") }
        guard try currentDefaultBytes(run) == run.originalDefaultBytes else { throw LaneError.failed("private shared-default bytes changed; preserving private root") }
        let root = try canonicalOwnedRoot(run)
        try FileManager.default.removeItem(at: root)
        try appendEvidence("cleanup complete token=\(run.token) restored=nil\n", to: evidence)
        print("CLEANED token=\(run.token)")
    }

    private static func runtime(version: String, cli: String, fpm: String) throws -> RuntimeInput {
        guard let parsed = PHPVersion(version), parsed.description == version, parsed.isStable else { throw LaneError.refused("runtime version must be an exact stable version") }
        let cliURL = URL(fileURLWithPath: cli).standardizedFileURL
        let fpmURL = URL(fileURLWithPath: fpm).standardizedFileURL
        for (url, label) in [(cliURL, "CLI"), (fpmURL, "FPM")] {
            guard url.isFileURL, !url.path.contains("/../"), FileManager.default.isExecutableFile(atPath: url.path),
                  !url.resolvingSymlinksInPath().path.isEmpty else { throw LaneError.refused("\(label) runtime input is not an executable file") }
            let output = try runCommand(url.path, ["-v"])
            guard output.contains(version) else { throw LaneError.refused("\(label) binary version does not match \(version)") }
            let fileOutput = try runCommand("/usr/bin/file", [url.path])
            guard fileOutput.contains("Mach-O 64-bit executable arm64") else { throw LaneError.refused("\(label) binary is not arm64 Mach-O") }
        }
        return RuntimeInput(version: version, cli: cliURL.path, fpm: fpmURL.path,
                            cliIdentity: try fileIdentity(cliURL), fpmIdentity: try fileIdentity(fpmURL))
    }

    private static func writeRuntime(_ runtime: RuntimeInput, layout: VaelenFilesystemLayout) throws {
        let directory = layout.phpPackagesDirectoryURL.appendingPathComponent(runtime.version, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let package: [String: Any] = ["version": runtime.version, "architecture": "arm64", "packagePath": directory.path,
            "cliPath": runtime.cli, "fpmPath": runtime.fpm, "source": "local-installed-runtime", "cliSHA256": "", "fpmSHA256": "",
            "installedAt": Date().timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys]).write(to: directory.appendingPathComponent(".vaelen-package.json"), options: .atomic)
    }

    private static func writeDevelopmentManifest(version: String, to url: URL) throws {
        let manifest = PHPManifest(schemaVersion: 1, module: "php", phpVersion: version, platform: "macos", architecture: "arm64",
            artifacts: [:], verification: PHPVerification(algorithm: "sha256", authenticity: "isolated-local-runtime"))
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
    }

    private static func writeDevelopmentConfiguration(manifest: URL, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["manifestPath": manifest.path], options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func observe(_ run: ProjectsPHPUIRun) async throws -> SelectionEvidence {
        let client = try client(for: run)
        defer { Task { await client.disconnect() } }
        try await client.connect()
        let selection = try await client.projectPHP(selector: run.projectRoot, workingDirectory: run.projectRoot)
        let report = try await client.projectStatus(selector: run.projectRoot, workingDirectory: run.projectRoot)
        let status = try await client.status()
        let routes = try await client.routeList()
        let parked = try await client.parkedPaths()
        let dns = try await client.dnsStatus()
        let ports = try await client.portsStatus()
        guard let projectID = selection.project.id,
              projectID == run.projectID,
              URL(fileURLWithPath: selection.project.path).standardizedFileURL.path == URL(fileURLWithPath: run.projectRoot).standardizedFileURL.path else {
            throw LaneError.failed("Core selection identity does not match the prepared project")
        }
        return SelectionEvidence(generation: run.generation, projectID: projectID,
            projectPath: selection.project.path, overrideVersion: selection.overrideVersion,
            defaultVersion: selection.defaultVersion ?? "", effectiveVersion: selection.effectiveVersion ?? "",
            observedVersion: selection.observedVersion, fpmHealthy: selection.observedVersion == selection.effectiveVersion,
            routeCount: routes.count, parkedPathCount: parked.count,
            dnsOwnership: dns.ownership.rawValue, pfOwnership: ports.ownership?.rawValue ?? "unknown",
            serviceIntentCount: status.serviceIntents?.count ?? -1,
            desiredPHP: report.desired.php, secureWeb: report.desired.secureWeb,
            mysqlDesired: report.desired.mysql, mailpitDesired: report.desired.mailpit)
    }

    private static func ownershipMatches(_ value: SelectionEvidence, baseline: CapabilityOwnershipBaseline?) -> Bool {
        guard let baseline,
              let dns = DNSOwnership(rawValue: value.dnsOwnership),
              let pf = StandardPortsOwnership(rawValue: value.pfOwnership),
              dns != .unknown, pf != .unknown,
              baseline.dns != .unknown, baseline.pf != .unknown else { return false }
        return baseline == CapabilityOwnershipBaseline(dns: dns, pf: pf)
    }

    private static func client(for run: ProjectsPHPUIRun) throws -> VaelenCoreClient {
        let root = URL(fileURLWithPath: run.supportRoot, isDirectory: true)
        let paths = CoreEndpointPaths(root: root.appendingPathComponent("runtime", isDirectory: true))
        try paths.validateSocketPathLength()
        let identity = ClientIdentity(name: "ProjectsPHPUIAcceptance", version: VaelenBuildInfo.version,
                                      schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity)
        return VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: identity)
    }

    private static func launchCoreAndApp(_ run: inout ProjectsPHPUIRun) async throws {
        var coreEnvironment = isolatedEnvironment(run)
        coreEnvironment.removeValue(forKey: "VAELEN_PARENT_PID")
        let core = try launch(run.coreExecutable, environment: coreEnvironment, role: "core", run: &run)
        guard try await waitForCore(run) else { throw LaneError.failed("private Core did not become ready; preserving root") }
        _ = core
        _ = try launch(run.appExecutable, arguments: ["--verification-open-settings=projects"], environment: isolatedEnvironment(run), role: "app", run: &run)
        run.generation += 1
        run.fpmShutdownProofGeneration = nil
        run.fpmProcessesBeforeShutdown = []
        try save(run)
    }

    private static func launch(_ executable: String, arguments: [String] = [], environment: [String: String], role: String, run: inout ProjectsPHPUIRun) throws -> Process {
        run.launchAttempted = true
        try save(run)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        let identity = try processIdentity(child.processIdentifier)
        run.children.removeAll { $0.role == role }
        run.children.append(OwnedChild(role: role, pid: child.processIdentifier, startIdentity: identity.start, executable: executable))
        try save(run)
        return child
    }

    private static func isolatedEnvironment(_ run: ProjectsPHPUIRun) -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(),
         "VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1", "VAELEN_TEST_SUPPORT_ROOT": run.supportRoot,
         "VAELEN_PHP_MANIFEST": URL(fileURLWithPath: run.supportRoot).appendingPathComponent("php-manifest.json").path]
    }

    private static func waitForCore(_ run: ProjectsPHPUIRun) async throws -> Bool {
        for _ in 0..<100 {
            guard let core = run.children.first(where: { $0.role == "core" }), processExists(core) else { return false }
            try verifyProcess(core)
            if FileManager.default.fileExists(atPath: URL(fileURLWithPath: run.supportRoot).appendingPathComponent("runtime/sockets/core.sock").path) {
                let client = try client(for: run)
                do { try await client.connect(); await client.disconnect(); return true }
                catch { await client.disconnect() }
            }
            usleep(100_000)
        }
        return false
    }

    private static func stopOwnedApp(_ run: inout ProjectsPHPUIRun) throws {
        guard let app = run.children.first(where: { $0.role == "app" }) else { return }
        if processExists(app) {
            try verifyProcess(app)
            guard kill(app.pid, SIGTERM) == 0 || errno == ESRCH else { throw LaneError.failed("could not request quit from the owned app") }
            for _ in 0..<100 {
                if !processExists(app) { break }
                usleep(50_000)
            }
            guard !processExists(app) else { throw LaneError.failed("owned app did not exit; preserving root") }
        }
        run.children.removeAll { $0.role == "app" }
        try save(run)
    }

    private static func shutdownOwnedCore(_ run: inout ProjectsPHPUIRun) async throws {
        guard let core = run.children.first(where: { $0.role == "core" }), processExists(core) else {
            throw LaneError.failed("owned Core identity is missing; preserving root")
        }
        try verifyProcess(core)
        run.fpmProcessesBeforeShutdown = try capturePrivateFPMProcesses(run)
        run.fpmShutdownProofGeneration = nil
        try save(run)
        let client = try client(for: run)
        try await client.connect()
        let result = try await client.shutdown()
        await client.disconnect()
        guard result.completed else { throw LaneError.failed("Core shutdown reported incomplete cleanup: \(result.components.filter { !$0.succeeded }.map(\.component).joined(separator: ", "))") }
        let fpmResults = result.components.filter { $0.component == "php-fpm" || $0.component.hasPrefix("php-fpm ") }
        guard !fpmResults.isEmpty, fpmResults.allSatisfy(\.succeeded) else {
            throw LaneError.failed("typed Core shutdown did not report successful PHP-FPM cleanup; preserving root")
        }
        for _ in 0..<100 {
            if !processExists(core) { break }
            usleep(50_000)
        }
        guard !processExists(core) else { throw LaneError.failed("private Core did not exit after its typed shutdown request") }
        run.children.removeAll { $0.role == "core" }
        try save(run)
    }

    private static func stopRecordedFPM(_ run: inout ProjectsPHPUIRun) throws {
        let layout = VaelenFilesystemLayout(rootURL: URL(fileURLWithPath: run.supportRoot, isDirectory: true))
        let manifestURL = URL(fileURLWithPath: run.supportRoot).appendingPathComponent("php-manifest.json")
        setenv("VAELEN_PHP_MANIFEST", manifestURL.path, 1)
        guard let module = PHPModule.development(layout: layout) else { throw LaneError.failed("private PHP provider could not be reconstructed") }
        for runtime in [run.overrideRuntime, run.defaultRuntime] {
            let record = layout.phpInstancesDirectoryURL.appendingPathComponent(runtime.version).appendingPathComponent("process.json")
            if FileManager.default.fileExists(atPath: record.path) {
                try save(run)
                _ = try module.stop(requestedVersion: runtime.version)
            }
        }
        if FileManager.default.fileExists(atPath: layout.phpInstancesDirectoryURL.path) {
            guard let enumerator = FileManager.default.enumerator(atPath: layout.phpInstancesDirectoryURL.path) else {
                throw LaneError.failed("cannot inspect private PHP process records; preserving root")
            }
            guard !enumerator.allObjects.contains(where: { ($0 as? String)?.hasSuffix("process.json") == true }) else {
                throw LaneError.failed("private PHP process records remain; preserving root")
            }
        }
        try proveCapturedFPMProcessesExited(run)
        guard !hasOwnedSockets(run) else { throw LaneError.failed("private FPM sockets remain; preserving root") }
        run.fpmShutdownProofGeneration = run.generation
        try save(run)
    }

    private static func capturePrivateFPMProcesses(_ run: ProjectsPHPUIRun) throws -> [OwnedChild] {
        let layout = VaelenFilesystemLayout(rootURL: URL(fileURLWithPath: run.supportRoot, isDirectory: true))
        let runtimes = [run.overrideRuntime, run.defaultRuntime]
        let records = try runtimes.compactMap { runtime -> (RuntimeInput, FPMRecord)? in
            let url = layout.phpInstancesDirectoryURL.appendingPathComponent(runtime.version).appendingPathComponent("process.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (runtime, try JSONDecoder().decode(FPMRecord.self, from: Data(contentsOf: url)))
        }
        guard !records.isEmpty else { throw LaneError.failed("no private FPM master record exists before shutdown; preserving root") }
        guard Set(records.map { $0.1.pid }).count == records.count else {
            throw LaneError.failed("private FPM master records identify the same PID; preserving root")
        }
        var captured: [OwnedChild] = []
        var capturedPIDs = Set<Int32>()
        for (runtime, record) in records {
            var masterInfo = proc_bsdinfo()
            guard proc_pidinfo(record.pid, PROC_PIDTBSDINFO, 0, &masterInfo, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else {
                throw LaneError.failed("private FPM master is already dead or unreadable before capture; preserving root")
            }
            let expectedConfig = layout.phpInstancesDirectoryURL.appendingPathComponent(runtime.version).appendingPathComponent("config/php-fpm.conf").standardizedFileURL.path
            let expectedSocket = layout.rootURL.appendingPathComponent("runtime/sockets/php/php-\(runtime.version).sock").standardizedFileURL.path
            let masterIdentity = try processIdentity(record.pid)
            let masterStartedAt = try processStartedAt(record.pid)
            let masterStartFromInfo = "\(masterInfo.pbi_start_tvsec):\(masterInfo.pbi_start_tvusec)"
            let core = run.children.first(where: { $0.role == "core" })
            guard record.version == runtime.version,
                  URL(fileURLWithPath: record.executable).standardizedFileURL.path == runtime.fpm,
                  masterIdentity.executable == runtime.fpm,
                  masterIdentity.start == masterStartFromInfo,
                  record.configPath == expectedConfig, record.socketPath == expectedSocket,
                  record.arguments.contains("-F"), record.arguments.contains(expectedConfig),
                  record.startedAt == masterStartedAt,
                  let core, Int32(masterInfo.pbi_ppid) == core.pid else {
                throw LaneError.failed("private FPM master record or parent identity is ambiguous; preserving root")
            }
            var pending = [record.pid]
            var tree: Set<Int32> = [record.pid]
            var infoByPID: [Int32: proc_bsdinfo] = [record.pid: masterInfo]
            while let parentPID = pending.popLast() {
                for childPID in try childProcessIDs(of: parentPID) {
                    guard childPID > 0 else { throw LaneError.failed("private FPM subtree contains an invalid child PID; preserving root") }
                    guard !tree.contains(childPID) else {
                        throw LaneError.failed("private FPM subtree contains an ambiguous duplicate child PID; preserving root")
                    }
                    var childInfo = proc_bsdinfo()
                    guard proc_pidinfo(childPID, PROC_PIDTBSDINFO, 0, &childInfo, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
                          Int32(childInfo.pbi_ppid) == parentPID else {
                        throw LaneError.failed("private FPM descendant parent identity is ambiguous; preserving root")
                    }
                    tree.insert(childPID)
                    infoByPID[childPID] = childInfo
                    pending.append(childPID)
                }
            }
            for pid in tree.sorted() {
                let identity = try processIdentity(pid)
                guard let processInfo = infoByPID[pid],
                      identity.start == "\(processInfo.pbi_start_tvsec):\(processInfo.pbi_start_tvusec)",
                      identity.executable == runtime.fpm else {
                    throw LaneError.failed("private FPM subtree contains an unclassifiable executable; preserving root")
                }
                guard capturedPIDs.insert(pid).inserted else {
                    throw LaneError.failed("private FPM process trees overlap; preserving root")
                }
                captured.append(OwnedChild(role: "fpm", pid: pid, startIdentity: identity.start, executable: identity.executable))
            }
        }
        guard !captured.isEmpty else { throw LaneError.failed("private FPM process tree could not be captured; preserving root") }
        return captured
    }

    private static func childProcessIDs(of parentPID: Int32) throws -> [Int32] {
        var capacity = 32
        let maximumCapacity = 4096
        while capacity <= maximumCapacity {
            var children = [Int32](repeating: 0, count: capacity)
            let childCount = Int(children.withUnsafeMutableBufferPointer {
                proc_listchildpids(parentPID, $0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
            })
            guard childCount >= 0, childCount <= children.count else {
                throw LaneError.failed("cannot enumerate private FPM descendants; preserving root")
            }
            if childCount < children.count {
                return Array(children.prefix(childCount))
            }
            capacity *= 2
        }
        throw LaneError.failed("private FPM child list exceeded the bounded capture capacity; preserving root")
    }

    private static func allProcessIDs() throws -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { throw LaneError.failed("cannot enumerate process table; preserving root") }
        var pids = [Int32](repeating: 0, count: Int(estimate) * 2)
        let count = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size)) }
        guard count > 0, count < Int32(pids.count) else { throw LaneError.failed("process table changed during enumeration; preserving root") }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    private static func proveCapturedFPMProcessesExited(_ run: ProjectsPHPUIRun) throws {
        guard !run.fpmProcessesBeforeShutdown.isEmpty else { throw LaneError.failed("FPM process identities were not captured before shutdown; preserving root") }
        for captured in run.fpmProcessesBeforeShutdown {
            do {
                let current = try processIdentity(captured.pid)
                guard current.start != captured.startIdentity else {
                    throw LaneError.failed("captured FPM process PID \(captured.pid) is still live; preserving root")
                }
            } catch {
                if case LaneError.failed(let message) = error, message.contains("still live") { throw error }
                if kill(captured.pid, 0) == 0 || errno == EPERM {
                    throw LaneError.failed("captured FPM PID \(captured.pid) is alive but its identity cannot be verified; preserving root")
                }
                guard errno == ESRCH else { throw LaneError.failed("captured FPM PID \(captured.pid) liveness is ambiguous; preserving root") }
            }
        }
        try scanForResidualFPMProcesses(run)
    }

    private static func scanForResidualFPMProcesses(_ run: ProjectsPHPUIRun) throws {
        let pids = try allProcessIDs()
        let configured = Set([run.overrideRuntime, run.defaultRuntime].map(\.fpm))
        let layout = VaelenFilesystemLayout(rootURL: URL(fileURLWithPath: run.supportRoot, isDirectory: true))
        let privateConfigs = Set([run.overrideRuntime, run.defaultRuntime].map {
            layout.phpInstancesDirectoryURL.appendingPathComponent($0.version).appendingPathComponent("config/php-fpm.conf").standardizedFileURL.path
        })
        let privateSockets = Set([run.overrideRuntime, run.defaultRuntime].map {
            layout.rootURL.appendingPathComponent("runtime/sockets/php/php-\($0.version).sock").standardizedFileURL.path
        })
        for pid in pids {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathLength = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if pathLength == 0 {
                if kill(pid, 0) == 0 || errno == EPERM { throw LaneError.failed("cannot inspect live process during residual FPM scan; preserving root") }
                if errno == ESRCH { continue }
                throw LaneError.failed("process liveness is ambiguous during residual FPM scan; preserving root")
            }
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let executable = String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if configured.contains(executable) {
                throw LaneError.failed("configured FPM executable remains live after shutdown; preserving root")
            }
            let command: String
            do { command = try runCommand("/bin/ps", ["-p", "\(pid)", "-o", "command="]) }
            catch {
                if kill(pid, 0) != 0 && errno == ESRCH { continue }
                throw LaneError.failed("cannot inspect live process during residual FPM scan; preserving root")
            }
            if privateConfigs.contains(where: command.contains) || privateSockets.contains(where: command.contains) {
                throw LaneError.failed("private FPM pool signature remains live after shutdown; preserving root")
            }
        }
    }

    private static func processStartedAt(_ pid: Int32) throws -> String {
        let value = try runCommand("/bin/ps", ["-p", "\(pid)", "-o", "lstart="]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw LaneError.failed("cannot identify process start time") }
        return value
    }

    private static func fpmRecordExists(_ run: ProjectsPHPUIRun) -> Bool {
        let layout = VaelenFilesystemLayout(rootURL: URL(fileURLWithPath: run.supportRoot, isDirectory: true))
        let instances = layout.phpInstancesDirectoryURL
        return [run.overrideRuntime, run.defaultRuntime].contains {
            FileManager.default.fileExists(atPath: instances.appendingPathComponent($0.version).appendingPathComponent("process.json").path)
        }
    }

    private static func validateDebugAppBundle(_ app: URL, appExecutable: URL, coreExecutable: URL) throws {
        let manager = FileManager.default
        guard app.path.hasPrefix("/"), app.path == URL(fileURLWithPath: app.path).standardizedFileURL.path,
              app.path.contains("/Build/Products/Debug/"),
              app.pathExtension == "app", !isSymlink(app.path), app.resolvingSymlinksInPath().standardizedFileURL == app,
              !isSymlink(appExecutable.path), !isSymlink(coreExecutable.path),
              appExecutable.resolvingSymlinksInPath().standardizedFileURL == appExecutable.standardizedFileURL,
              coreExecutable.resolvingSymlinksInPath().standardizedFileURL == coreExecutable.standardizedFileURL,
              manager.isExecutableFile(atPath: appExecutable.path), manager.isExecutableFile(atPath: coreExecutable.path) else {
            throw LaneError.refused("app must be a canonical absolute Debug bundle with regular executable paths")
        }
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "dev.vaelen.app",
              info["CFBundleExecutable"] as? String == "Vaelen",
              coreExecutable.standardizedFileURL == app.appendingPathComponent("Contents/Resources/vaelend").standardizedFileURL else {
            throw LaneError.refused("Debug bundle identity or matching bundled Core is invalid")
        }
    }

    private static func readPersistedOverride(_ run: ProjectsPHPUIRun) async throws -> String? {
        let store = try SQLiteStateStore(databaseURL: URL(fileURLWithPath: run.supportRoot).appendingPathComponent("state/vaelen.sqlite"))
        let registry = ProjectRegistry(store: store)
        return try await registry.phpOverride(for: ProjectID(rawValue: run.projectID))
    }

    private static func currentDefaultBytes(_ run: ProjectsPHPUIRun) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: run.supportRoot).appendingPathComponent("config/php-default.json"))
    }

    private static func requireSafeHost(configuredFPMPaths: [String]) throws {
        let patterns = ["vaelend", "vaelendns", "php-fpm: master process", "/packages/mysql/", "caddy run --config"]
        let configured = Set(configuredFPMPaths)
        for pid in try allProcessIDs() {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if length == 0 {
                if kill(pid, 0) == 0 || errno == EPERM { throw LaneError.refused("cannot inspect a live process during PHP preflight") }
                if errno == ESRCH { continue }
                throw LaneError.refused("process liveness is ambiguous during PHP preflight")
            }
            let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let executable = String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if configured.contains(executable) { throw LaneError.refused("configured PHP-FPM executable is already active") }
            if isVaelenAppExecutable(executable) {
                throw LaneError.refused("a Vaelen app process is already active")
            }
            let command: String
            do { command = try runCommand("/bin/ps", ["-p", "\(pid)", "-o", "command="]) }
            catch {
                if kill(pid, 0) != 0 && errno == ESRCH { continue }
                throw LaneError.refused("cannot inspect a live process during PHP preflight")
            }
            if patterns.contains(where: command.contains) {
                throw LaneError.refused("active Vaelen-related process prevents isolation: \(command.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    private static func isVaelenAppExecutable(_ path: String) -> Bool {
        let executable = URL(fileURLWithPath: path).standardizedFileURL
        guard executable.lastPathComponent == "Vaelen",
              executable.deletingLastPathComponent().lastPathComponent == "MacOS",
              executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else {
            return false
        }
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app" else {
            return false
        }
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String else {
            return true
        }
        return bundleIdentifier == "dev.vaelen.app"
    }

    private static func validateOwnedRun(_ run: ProjectsPHPUIRun, allowExited: Bool = false) throws {
        let root = try canonicalOwnedRoot(run)
        let support = root.appendingPathComponent("support", isDirectory: true).standardizedFileURL
        let project = root.appendingPathComponent("Storefront", isDirectory: true).standardizedFileURL
        guard URL(fileURLWithPath: run.supportRoot).standardizedFileURL == support,
              URL(fileURLWithPath: run.projectRoot).standardizedFileURL == project,
              !isSymlink(support.path), !isSymlink(project.path),
              !isSymlink(run.appExecutable), !isSymlink(run.coreExecutable) else {
            throw LaneError.refused("manifest paths do not match the private run layout")
        }
        let appBundle = URL(fileURLWithPath: run.appExecutable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appBundle.path.contains("/Build/Products/Debug/"),
              URL(fileURLWithPath: run.coreExecutable).standardizedFileURL == appBundle.appendingPathComponent("Contents/Resources/vaelend").standardizedFileURL,
              URL(fileURLWithPath: run.appExecutable).resolvingSymlinksInPath().standardizedFileURL == URL(fileURLWithPath: run.appExecutable).standardizedFileURL,
              URL(fileURLWithPath: run.coreExecutable).resolvingSymlinksInPath().standardizedFileURL == URL(fileURLWithPath: run.coreExecutable).standardizedFileURL,
              FileManager.default.isExecutableFile(atPath: run.appExecutable), FileManager.default.isExecutableFile(atPath: run.coreExecutable) else {
            throw LaneError.refused("manifest app/Core executable pairing is invalid")
        }
        guard try fileIdentity(URL(fileURLWithPath: run.overrideRuntime.cli)) == run.overrideRuntime.cliIdentity,
              try fileIdentity(URL(fileURLWithPath: run.overrideRuntime.fpm)) == run.overrideRuntime.fpmIdentity,
              try fileIdentity(URL(fileURLWithPath: run.defaultRuntime.cli)) == run.defaultRuntime.cliIdentity,
              try fileIdentity(URL(fileURLWithPath: run.defaultRuntime.fpm)) == run.defaultRuntime.fpmIdentity else {
            throw LaneError.refused("an installed PHP executable changed since prepare; preserving root")
        }
        for child in run.children where processExists(child) { try verifyProcess(child) }
        if !allowExited && !run.children.contains(where: { $0.role == "core" && processExists($0) }) {
            throw LaneError.failed("owned private Core is not running")
        }
    }

    private static func canonicalOwnedRoot(_ run: ProjectsPHPUIRun) throws -> URL {
        let root = URL(fileURLWithPath: run.scratchRoot, isDirectory: true).standardizedFileURL
        let tokenRoot = "vpu-\(String(run.token.uuidString.prefix(8)))"
        guard run.scratchRoot == "/private/tmp/\(tokenRoot)" || run.scratchRoot == "/tmp/\(tokenRoot)",
              root.path == "/tmp/\(tokenRoot)", !isSymlink(root.path),
              root.resolvingSymlinksInPath().standardizedFileURL == root else {
            throw LaneError.refused("run root is not a canonical token-owned private directory")
        }
        return root
    }

    private static func hasOwnedSockets(_ run: ProjectsPHPUIRun) -> Bool {
        let root = URL(fileURLWithPath: run.supportRoot)
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/sockets/core.sock").path)
            || [run.overrideRuntime, run.defaultRuntime].contains { runtime in
                FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime/sockets/php/php-\(runtime.version).sock").path)
            }
    }

    private static func mkdirOwned(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path), !isSymlink(url.path) else { throw LaneError.refused("scratch path already exists or is a symlink") }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    private static func validatePathAncestors(_ url: URL) throws {
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            guard !isSymlink(parent.path), parent.resolvingSymlinksInPath().standardizedFileURL == parent.standardizedFileURL else {
                throw LaneError.refused("evidence path contains a symlink or ambiguous parent")
            }
            parent.deleteLastPathComponent()
        }
    }

    private static func save(_ run: ProjectsPHPUIRun) throws {
        let url = URL(fileURLWithPath: run.evidenceRoot).appendingPathComponent("ProjectsPHPUIRun.json")
        try JSONEncoder().encode(run).write(to: url, options: .atomic)
    }

    private static func load(_ evidence: URL) throws -> ProjectsPHPUIRun {
        let url = evidence.appendingPathComponent("ProjectsPHPUIRun.json")
        guard !isSymlink(url.path) else { throw LaneError.refused("manifest is a symlink") }
        let run = try JSONDecoder().decode(ProjectsPHPUIRun.self, from: Data(contentsOf: url))
        guard URL(fileURLWithPath: run.evidenceRoot).standardizedFileURL == evidence.standardizedFileURL,
              !isSymlink(evidence.path), evidence.resolvingSymlinksInPath() == evidence else {
            throw LaneError.refused("evidence directory identity is ambiguous")
        }
        return run
    }

    private static func appendEvidence(_ text: String, to evidence: URL) throws {
        let url = evidence.appendingPathComponent("result.txt")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private static func fileIdentity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw LaneError.refused("runtime input is not a regular file") }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func processIdentity(_ pid: Int32) throws -> (start: String, executable: String) {
        var processInfo = proc_bsdinfo()
        let infoLength = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &processInfo, infoLength) == infoLength else {
            throw LaneError.failed("cannot identify launched process start time")
        }
        let start = "\(processInfo.pbi_start_tvsec):\(processInfo.pbi_start_tvusec)"
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { throw LaneError.failed("cannot identify launched process executable") }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let executable = String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (start, URL(fileURLWithPath: executable).standardizedFileURL.path)
    }

    private static func verifyProcess(_ child: OwnedChild) throws {
        let identity = try processIdentity(child.pid)
        guard identity.start == child.startIdentity, identity.executable == child.executable else { throw LaneError.refused("PID ownership is ambiguous; preserving root") }
    }

    private static func processExists(_ child: OwnedChild) -> Bool {
        kill(child.pid, 0) == 0 || errno == EPERM
    }

    private static func runCommand(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LaneError.refused("command failed: \(path) \(arguments.joined(separator: " "))") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
