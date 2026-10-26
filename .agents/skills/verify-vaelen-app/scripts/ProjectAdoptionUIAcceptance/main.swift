import Darwin
import CryptoKit
import Foundation
import VaelenCore
import VaelenIPC

private struct ChildIdentity: Codable {
    let role: String
    let pid: Int32
    let start: String
    let executable: String
}

private struct RunManifest: Codable {
    let token: UUID
    let evidence: String
    let root: String
    let support: String
    let project: String
    let projectID: UUID
    let app: String
    let core: String
    let appPID: Int32
    let corePID: Int32
    let appStart: String
    let coreStart: String
    let appExecutable: String
    let coreExecutable: String
    let dotenvHash: String
    var invalidatedDiscovery: Bool
}

private enum HarnessError: Error, CustomStringConvertible {
    case usage
    case refused(String)
    case failed(String)
    var description: String {
        switch self {
        case .usage: "usage: project-adoption-ui-core <prepare --evidence ABSOLUTE_PATH|invalidate-discovery --evidence PATH|inspect --expect unadopted|adopted --evidence PATH|cleanup --evidence PATH>"
        case .refused(let value): "NOT VERIFIED: \(value)"
        case .failed(let value): value
        }
    }
}

@main
private struct ProjectAdoptionUIAcceptance {
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 2 else { throw HarnessError.usage }
            let command = CommandLine.arguments[1]
            let args = try parse(Array(CommandLine.arguments.dropFirst(2)))
            guard let rawEvidence = args["--evidence"] else { throw HarnessError.usage }
            let evidence = URL(fileURLWithPath: lexicalPath(rawEvidence))
            switch command {
            case "prepare": try await prepare(evidence)
            case "invalidate-discovery": try invalidateDiscovery(evidence)
            case "inspect":
                guard let expected = args["--expect"], ["unadopted", "adopted"].contains(expected) else { throw HarnessError.usage }
                try await inspect(expected, evidence: evidence)
            case "cleanup": try await cleanup(evidence)
            default: throw HarnessError.usage
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func parse(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i < args.count {
            guard args[i].hasPrefix("--"), i + 1 < args.count, result[args[i]] == nil else { throw HarnessError.usage }
            result[args[i]] = args[i + 1]
            i += 2
        }
        return result
    }

    private static func prepare(_ evidence: URL) async throws {
        let rootURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = lexicalPath(rootURL.path)
        guard isEvidencePath(evidence, checkoutRoot: root),
              !FileManager.default.fileExists(atPath: evidence.path) else {
            throw HarnessError.refused("evidence must be a new directory under this checkout's artifacts/verification")
        }
        try validateAncestors(evidence)
        guard try processIDs(named: "Vaelen").isEmpty, try processIDs(named: "vaelend").isEmpty else {
            throw HarnessError.refused("a Vaelen app or Core process is already running")
        }
        let runToken = UUID()
        let token = runToken.uuidString.lowercased().prefix(8)
        let scratch = URL(fileURLWithPath: lexicalPath("/private/tmp/vaui-\(token)"), isDirectory: true)
        let support = scratch.appendingPathComponent("s", isDirectory: true)
        let project = scratch.appendingPathComponent("p", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: scratch.path) else { throw HarnessError.refused("unique scratch root already exists") }
        let appBundle = scratch.appendingPathComponent("DerivedData/Build/Products/Debug/Vaelen.app", isDirectory: true)
        let appExecutable = appBundle.appendingPathComponent("Contents/MacOS/Vaelen")
        let coreExecutable = appBundle.appendingPathComponent("Contents/Resources/vaelend")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let manifestURL = evidence.appendingPathComponent("ownership.json")
        var manifest = RunManifest(token: runToken, evidence: evidence.path, root: scratch.path, support: support.path,
            project: project.path, projectID: UUID(), app: appBundle.path, core: coreExecutable.path,
            appPID: 0, corePID: 0, appStart: "", coreStart: "", appExecutable: appExecutable.path,
            coreExecutable: coreExecutable.path, dotenvHash: "", invalidatedDiscovery: false)
        try save(manifest, to: manifestURL)
        try write("building isolated Debug app\n", to: evidence.appendingPathComponent("run.txt"))
        let buildLog = evidence.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: buildLog.path, contents: Data())
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        build.arguments = ["-quiet", "-project", "\(root)/App/Vaelen/Vaelen.xcodeproj", "-scheme", "Vaelen", "-configuration", "Debug", "-derivedDataPath", "\(scratch.path)/DerivedData", "build"]
        build.standardOutput = try FileHandle(forWritingTo: buildLog)
        build.standardError = build.standardOutput
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: appExecutable.path),
              FileManager.default.isExecutableFile(atPath: coreExecutable.path) else {
            try? FileManager.default.removeItem(at: scratch)
            throw HarnessError.failed("isolated Debug app build failed; see \(buildLog.path)")
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: support.path).appendingPathComponent("runtime"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{\n  \"require\": {\"php\": \"^8.3\"}\n}\n".utf8).write(to: project.appendingPathComponent("composer.json"), options: .atomic)
        try Data("{\n  \"engines\": {\"node\": \">=20\"}\n}\n".utf8).write(to: project.appendingPathComponent("package.json"), options: .atomic)
        try Data("DB_CONNECTION=pgsql\nDB_PASSWORD=synthetic-sentinel-do-not-display\n".utf8).write(to: project.appendingPathComponent(".env"), options: .atomic)
        let dotenvHash = try hash(project.appendingPathComponent(".env"))
        let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout(rootURL: support).databaseURL)
        let registry = ProjectRegistry(store: store)
        let linked = try await registry.link(path: project, name: "Adoption-Fixture")
        guard let projectID = linked.id?.rawValue else { throw HarnessError.failed("Core registry did not assign project identity") }
        let catalog = ServiceInstanceRepository(store: store)
        try catalog.saveManuallyClaimedInstance(ServiceInstanceRecord(
            id: ServiceInstanceID(kind: .postgresql, name: try ProjectInstanceName("adoption-db")),
            packageIdentifier: "postgresql-18.6", endpoint: try .postgresql(port: 25432),
            dataDirectory: support.appendingPathComponent("instances/postgresql/adoption-db/data").path))
        try catalog.saveManuallyClaimedInstance(ServiceInstanceRecord(
            id: ServiceInstanceID(kind: .valkey, name: try ProjectInstanceName("adoption-cache")),
            packageIdentifier: "valkey-9.1.2", endpoint: try .valkey(port: 26379),
            dataDirectory: support.appendingPathComponent("instances/valkey/adoption-cache/data").path))
        manifest = RunManifest(token: runToken, evidence: evidence.path, root: scratch.path,
            support: support.path, project: project.path, projectID: projectID, app: appBundle.path,
            core: coreExecutable.path, appPID: 0, corePID: 0, appStart: "", coreStart: "",
            appExecutable: appExecutable.path, coreExecutable: coreExecutable.path,
            dotenvHash: dotenvHash, invalidatedDiscovery: false)
        try save(manifest, to: manifestURL)
        let baseEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(),
                              "VAELEN_TEST_SUPPORT_ROOT_ENABLED": "1", "VAELEN_TEST_SUPPORT_ROOT": support.path]
        let coreLog = evidence.appendingPathComponent("core.log")
        FileManager.default.createFile(atPath: coreLog.path, contents: Data())
        let core = try launch(coreExecutable.path, args: [], env: baseEnvironment, log: coreLog)
        let coreIdentity: (start: String, executable: String)
        do {
            coreIdentity = try identity(core.processIdentifier)
            guard coreIdentity.executable == lexicalPath(coreExecutable.path) else { throw HarnessError.refused("launched Core executable identity changed") }
        } catch {
            core.terminate()
            core.waitUntilExit()
            throw error
        }
        var running = RunManifest(token: manifest.token, evidence: manifest.evidence, root: manifest.root, support: manifest.support,
            project: manifest.project, projectID: manifest.projectID, app: manifest.app, core: manifest.core,
            appPID: 0, corePID: core.processIdentifier, appStart: "", coreStart: coreIdentity.start,
            appExecutable: manifest.appExecutable, coreExecutable: manifest.coreExecutable,
            dotenvHash: manifest.dotenvHash, invalidatedDiscovery: false)
        try save(running, to: manifestURL)
        try await waitForCore(running)
        var appEnvironment = baseEnvironment
        appEnvironment["VAELEN_PHP_MANIFEST"] = support.appendingPathComponent("php-manifest.json").path
        let appLog = evidence.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: appLog.path, contents: Data())
        let app = try launch(appExecutable.path, args: ["--verification-open-settings=projects"], env: appEnvironment, log: appLog)
        let appIdentity: (start: String, executable: String)
        do {
            appIdentity = try identity(app.processIdentifier)
            guard appIdentity.executable == lexicalPath(appExecutable.path) else { throw HarnessError.refused("launched app executable identity changed") }
        } catch {
            app.terminate()
            app.waitUntilExit()
            throw error
        }
        running = RunManifest(token: running.token, evidence: running.evidence, root: running.root, support: running.support,
            project: running.project, projectID: running.projectID, app: running.app, core: running.core,
            appPID: app.processIdentifier, corePID: running.corePID, appStart: appIdentity.start, coreStart: running.coreStart,
            appExecutable: running.appExecutable, coreExecutable: running.coreExecutable,
            dotenvHash: running.dotenvHash, invalidatedDiscovery: false)
        try save(running, to: manifestURL)
        let runText = "token=\(running.token)\nevidence=\(evidence.path)\nscratch=\(scratch.path)\nsupport=\(support.path)\nproject=\(project.path)\nproject_id=\(projectID)\napp=\(appBundle.path)\napp_pid=\(app.processIdentifier)\napp_start=\(appIdentity.start)\ncore=\(coreExecutable.path)\ncore_pid=\(core.processIdentifier)\ncore_start=\(coreIdentity.start)\nproject_seed=linked declaration-free; composer.php=^8.3; package.engines.node=>=20; dotenv=sha256:\(dotenvHash)\nservices=catalog-only postgresql-18.6 adoption-db; valkey-9.1.2 adoption-cache\n"
        try write(runText, to: evidence.appendingPathComponent("run.txt"), append: false)
        try append("prepared token=\(running.token) project_id=\(projectID); no service processes started\n", to: evidence.appendingPathComponent("events.log"))
        print("PREPARED evidence=\(evidence.path) app=\(appBundle.path) app_pid=\(app.processIdentifier) core_pid=\(core.processIdentifier)")
    }

    private static func invalidateDiscovery(_ evidence: URL) throws {
        var manifest = try load(evidence)
        try validate(manifest, evidence: evidence)
        let composer = URL(fileURLWithPath: manifest.project).appendingPathComponent("composer.json")
        let before = try String(contentsOf: composer, encoding: .utf8)
        guard before.contains("^8.3"), !before.contains("^8.4") else { throw HarnessError.refused("synthetic Composer declaration is not at its expected baseline") }
        try write(before.replacingOccurrences(of: "^8.3", with: "^8.4"), to: composer, append: false)
        manifest.invalidatedDiscovery = true
        try save(manifest, to: evidence.appendingPathComponent("ownership.json"))
        try append("invalidate-discovery composer.php ^8.3 -> ^8.4\n", to: evidence.appendingPathComponent("events.log"))
        print("INVALIDATED project=\(manifest.project) composer.php=^8.4")
    }

    private static func inspect(_ expected: String, evidence: URL) async throws {
        let run = try load(evidence)
        try validate(run, evidence: evidence)
        let project = URL(fileURLWithPath: run.project)
        let dotenv = project.appendingPathComponent(".env")
        guard try hash(dotenv) == run.dotenvHash else { throw HarnessError.failed(".env sentinel changed") }
        let store = try SQLiteStateStore(databaseURL: VaelenFilesystemLayout(rootURL: URL(fileURLWithPath: run.support)).databaseURL)
        let linked = try await ProjectRegistry(store: store).linkedProjects()
        let canonicalProjectPath = CanonicalPathService().canonicalize(run.project).string
        guard let registered = linked.first(where: { $0.id?.rawValue == run.projectID }), registered.rootPath.string == canonicalProjectPath else {
            throw HarnessError.failed("prepared linked project identity is missing")
        }
        let catalog = ServiceInstanceRepository(store: store)
        let projectID = ProjectID(rawValue: run.projectID)
        let inventory = try catalog.inventorySnapshot().entries
        let expectedRecords: Set<String> = ["postgresql:adoption-db:postgresql-18.6", "valkey:adoption-cache:valkey-9.1.2"]
        let actualRecords = Set(inventory.map { "\($0.record.id.kind.rawValue):\($0.record.id.name.value):\($0.record.packageIdentifier)" })
        guard actualRecords == expectedRecords else { throw HarnessError.failed("seeded service inventory differs from the two catalog-only records") }
        let declaration = project.appendingPathComponent("vaelen.yml")
        if expected == "unadopted" {
            guard !FileManager.default.fileExists(atPath: declaration.path), try catalog.projectClaims(for: projectID).isEmpty else {
                throw HarnessError.failed("unadopted project has a declaration or project claims")
            }
            guard composerConstraint(project) == (run.invalidatedDiscovery ? "^8.4" : "^8.3") else { throw HarnessError.failed("Composer fixture does not match recorded discovery state") }
        } else {
            guard FileManager.default.fileExists(atPath: declaration.path) else { throw HarnessError.failed("adopted vaelen.yml is missing") }
            let coreClient = try client(run)
            try await coreClient.connect()
            let report: ProjectEnvironmentReport
            do {
                report = try await coreClient.projectStatus(selector: run.projectID.uuidString, workingDirectory: run.project)
                await coreClient.disconnect()
            } catch {
                await coreClient.disconnect()
                throw error
            }
            guard let spec = report.projectSpec else { throw HarnessError.failed("Core did not load the adopted V2 project manifest") }
            let bindings = Set(spec.services.map { "\($0.alias.value):\($0.kind.rawValue):\($0.instance.value):\($0.version ?? "")" })
            let intended: Set<String> = ["database:postgresql:adoption-db:postgresql-18.6", "cache:valkey:adoption-cache:valkey-9.1.2"]
            let claims = Set(try catalog.projectClaims(for: projectID).map {
                "\($0.alias.value):\($0.kind.rawValue):\($0.instance.value):\($0.version ?? "")"
            })
            guard spec.version == 2, spec.php?.value == "8.4", spec.node?.value == "20", spec.web == nil,
                  bindings == intended, claims == intended else {
                throw HarnessError.failed("adoption does not match PHP 8.4, Node 20, no web, and the exact reviewed service bindings")
            }
            for binding in spec.services {
                guard inventory.contains(where: { $0.record.id.kind == binding.kind && $0.record.id.name == binding.instance && $0.record.packageIdentifier == binding.version }) else {
                    throw HarnessError.failed("adopted service binding has no exact catalog record")
                }
            }
        }
        let digest = FileManager.default.fileExists(atPath: declaration.path) ? try hash(declaration) : "absent"
        try append("inspect expect=\(expected) project_id=\(run.projectID) declaration_sha256=\(digest) dotenv_sha256=\(run.dotenvHash) inventory=2\n", to: evidence.appendingPathComponent("events.log"))
        print("INSPECTED expect=\(expected) project_id=\(run.projectID) declaration_sha256=\(digest) dotenv_sha256=\(run.dotenvHash) inventory=2")
    }

    private static func cleanup(_ evidence: URL) async throws {
        let run = try load(evidence)
        try validate(run, evidence: evidence, allowExitedApp: true)
        let ownedPIDs = [run.appPID, run.corePID].filter { $0 != 0 }
        let childProcesses = try descendantPIDs(of: ownedPIDs).map { pid -> ChildIdentity in
            let value = try identity(pid)
            return ChildIdentity(role: "task-child", pid: pid, start: value.start, executable: value.executable)
        }
        let appChild = ChildIdentity(role: "app", pid: run.appPID, start: run.appStart, executable: run.appExecutable)
        if run.appPID != 0, try isLive(appChild) {
            guard kill(run.appPID, SIGTERM) == 0 || errno == ESRCH else { throw HarnessError.failed("could not terminate owned app") }
            try waitForExit(appChild)
        }
        let coreChild = ChildIdentity(role: "core", pid: run.corePID, start: run.coreStart, executable: run.coreExecutable)
        if run.corePID != 0, try isLive(coreChild) {
            let client = try client(run)
            try await client.connect()
            let response = try await client.shutdown()
            await client.disconnect()
            guard response.completed else { throw HarnessError.failed("typed Core shutdown did not complete; preserving scratch root") }
            try waitForExit(coreChild)
        }
        guard !FileManager.default.fileExists(atPath: CoreEndpointPaths(root: URL(fileURLWithPath: run.support).appendingPathComponent("runtime")).socketPath) else {
            throw HarnessError.failed("Core socket remains; preserving scratch root")
        }
        let remainingChildren = try childProcesses.filter { try isLive($0) }
        guard remainingChildren.isEmpty else {
            throw HarnessError.failed("owned task children remain (\(remainingChildren.map(\.pid))); preserving scratch root")
        }
        guard try serviceProcesses(under: run.support).isEmpty else { throw HarnessError.failed("a service process remains under private support; preserving scratch root") }
        let root = URL(fileURLWithPath: lexicalPath(run.root), isDirectory: true)
        guard validScratchRoot(root, token: run.token) else { throw HarnessError.refused("scratch ownership validation failed") }
        try FileManager.default.removeItem(at: root)
        try append("cleanup complete token=\(run.token); evidence retained\n", to: evidence.appendingPathComponent("events.log"))
        print("CLEANED token=\(run.token) evidence=\(evidence.path)")
    }

    private static func client(_ run: RunManifest) throws -> VaelenCoreClient {
        let paths = CoreEndpointPaths(root: URL(fileURLWithPath: run.support).appendingPathComponent("runtime"))
        try paths.validateSocketPathLength()
        return VaelenCoreClient(transport: UnixSocketTransport(path: paths.socketPath), identity: ClientIdentity(name: "ProjectAdoptionUIAcceptance", version: VaelenBuildInfo.version, schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion, buildIdentity: VaelenBuildInfo.buildIdentity))
    }

    private static func waitForCore(_ run: RunManifest) async throws {
        let core = ChildIdentity(role: "core", pid: run.corePID, start: run.coreStart, executable: run.coreExecutable)
        let client = try client(run)
        for _ in 0..<100 {
            guard try isLive(core) else { throw HarnessError.failed("private Core exited during startup") }
            do { try await client.connect(); await client.disconnect(); return }
            catch { await client.disconnect(); usleep(100_000) }
        }
        throw HarnessError.failed("private Core IPC did not become ready")
    }

    private static func launch(_ executable: String, args: [String], env: [String: String], log: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = env
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    private static func identity(_ pid: Int32) throws -> (start: String, executable: String) {
        var process = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, size) == size else { throw HarnessError.failed("could not record process start identity") }
        let started = "\(process.pbi_start_tvsec):\(process.pbi_start_tvusec)"
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw HarnessError.failed("could not record process executable identity") }
        let end = path.firstIndex(of: 0) ?? path.endIndex
        let executable = String(decoding: path[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (started, lexicalPath(executable))
    }

    private static func isLive(_ child: ChildIdentity) throws -> Bool {
        guard kill(child.pid, 0) == 0 else { if errno == ESRCH { return false }; throw HarnessError.failed("cannot verify recorded process") }
        let current = try identity(child.pid)
        guard current.start == child.start, current.executable == child.executable else { throw HarnessError.refused("recorded PID was reused or executable identity changed") }
        return true
    }

    private static func waitForExit(_ child: ChildIdentity) throws {
        for _ in 0..<100 { if kill(child.pid, 0) != 0 && errno == ESRCH { return }; usleep(50_000) }
        throw HarnessError.failed("owned process did not exit; preserving scratch root")
    }

    private static func processIDs(named name: String) throws -> [Int32] {
        try command("/usr/bin/pgrep", ["-x", name], allowFailure: true).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    private static func descendantPIDs(of roots: [Int32]) throws -> [Int32] {
        let rows = try command("/bin/ps", ["-axo", "pid=,ppid="]).split(whereSeparator: \.isNewline).compactMap { row -> (Int32, Int32)? in
            let fields = row.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return (pid, ppid)
        }
        var parents = Set(roots)
        var descendants = Set<Int32>()
        var changed = true
        while changed {
            changed = false
            for (pid, ppid) in rows where parents.contains(ppid) && !parents.contains(pid) {
                parents.insert(pid); descendants.insert(pid); changed = true
            }
        }
        return descendants.sorted()
    }

    private static func serviceProcesses(under support: String) throws -> [String] {
        let listing = try command("/bin/ps", ["-axo", "pid=,command="])
        return listing.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line)
            guard value.contains(support), (value.contains("postgres") || value.contains("valkey") || value.contains("redis-server")) else { return nil }
            return value
        }
    }

    private static func validate(_ run: RunManifest, evidence: URL, allowExitedApp: Bool = false) throws {
        let standardizedEvidence = lexicalPath(evidence.path)
        let checkoutRoot = lexicalPath(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path)
        let root = URL(fileURLWithPath: lexicalPath(run.root), isDirectory: true)
        let expectedApp = root.appendingPathComponent("DerivedData/Build/Products/Debug/Vaelen.app", isDirectory: true)
        let expectedAppExecutable = expectedApp.appendingPathComponent("Contents/MacOS/Vaelen")
        let expectedCoreExecutable = expectedApp.appendingPathComponent("Contents/Resources/vaelend")
        let expectedSupport = root.appendingPathComponent("s", isDirectory: true)
        let expectedProject = root.appendingPathComponent("p", isDirectory: true)
        guard run.evidence == standardizedEvidence, isEvidencePath(evidence, checkoutRoot: checkoutRoot),
              validScratchRoot(root, token: run.token),
              run.support == expectedSupport.path,
              run.project == expectedProject.path,
              run.app == expectedApp.path, run.appExecutable == expectedAppExecutable.path,
              run.core == expectedCoreExecutable.path, run.coreExecutable == expectedCoreExecutable.path,
              !isSymlink(root) else {
            throw HarnessError.refused("ownership manifest paths or token do not validate")
        }
        let support = URL(fileURLWithPath: run.support, isDirectory: true)
        let project = URL(fileURLWithPath: run.project, isDirectory: true)
        let database = VaelenFilesystemLayout(rootURL: support).databaseURL
        let runtime = support.appendingPathComponent("runtime", isDirectory: true)
        let ownedPaths = [
            project.appendingPathComponent("composer.json"),
            project.appendingPathComponent("package.json"),
            project.appendingPathComponent(".env"),
            project.appendingPathComponent("vaelen.yml"),
            support.appendingPathComponent("php-manifest.json"),
            database,
            runtime,
            URL(fileURLWithPath: CoreEndpointPaths(root: runtime).socketPath),
            support.appendingPathComponent("instances/postgresql/adoption-db/data", isDirectory: true),
            support.appendingPathComponent("instances/valkey/adoption-cache/data", isDirectory: true),
            expectedApp.appendingPathComponent("Contents/MacOS/Vaelen"),
            expectedApp.appendingPathComponent("Contents/Resources/vaelend")
        ]
        try validateOwnedPathComponents(ownedPaths, beneath: root)
        try validateAncestors(evidence)
        let app = ChildIdentity(role: "app", pid: run.appPID, start: run.appStart, executable: run.appExecutable)
        let core = ChildIdentity(role: "core", pid: run.corePID, start: run.coreStart, executable: run.coreExecutable)
        if run.appPID == 0 {
            guard allowExitedApp else { throw HarnessError.refused("owned app identity has not been recorded") }
        } else if try !isLive(app), !allowExitedApp { throw HarnessError.refused("owned app identity is no longer live") }
        if run.corePID == 0 {
            guard allowExitedApp else { throw HarnessError.refused("owned Core identity has not been recorded") }
        } else if try !isLive(core), !allowExitedApp { throw HarnessError.refused("owned Core identity is no longer live") }
    }

    private static func load(_ evidence: URL) throws -> RunManifest {
        let manifestURL = evidence.appendingPathComponent("ownership.json")
        guard manifestURL.path.hasPrefix(evidence.path + "/"), FileManager.default.fileExists(atPath: manifestURL.path) else { throw HarnessError.refused("ownership manifest is missing") }
        return try JSONDecoder().decode(RunManifest.self, from: Data(contentsOf: manifestURL))
    }

    private static func save(_ manifest: RunManifest, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private static func validateAncestors(_ evidence: URL) throws {
        var current = evidence
        while current.path != "/" {
            guard !isSymlink(current) else { throw HarnessError.refused("evidence path traverses a symlink") }
            current.deleteLastPathComponent()
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType) == .typeSymbolicLink
    }

    private static func validateOwnedPathComponents(_ paths: [URL], beneath root: URL) throws {
        let rootPath = lexicalPath(root.path)
        for path in paths {
            let rawPath = path.path
            let lexicalTarget = lexicalPath(rawPath)
            guard rawPath == lexicalTarget else {
                throw HarnessError.refused("owned path contains a non-canonical spelling")
            }
            let target: String
            let aliasRoot = "/tmp" + rootPath.dropFirst("/private/tmp".count)
            if lexicalTarget.hasPrefix(aliasRoot + "/") {
                let temporaryAlias = URL(fileURLWithPath: "/tmp")
                let aliasDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: temporaryAlias.path)
                guard isSymlink(temporaryAlias), aliasDestination == "private/tmp" || aliasDestination == "/private/tmp" else {
                    throw HarnessError.refused("temporary directory alias does not resolve to the expected scratch parent")
                }
                target = rootPath + lexicalTarget.dropFirst(aliasRoot.count)
            } else {
                target = lexicalTarget
            }
            guard target.hasPrefix(rootPath + "/") else {
                throw HarnessError.refused("owned path escapes the scratch root")
            }
            var current = URL(fileURLWithPath: target)
            while current.path != rootPath {
                if isSymlink(current) {
                    throw HarnessError.refused("owned scratch path traverses a symlink")
                }
                current.deleteLastPathComponent()
            }
        }
    }

    private static func lexicalPath(_ path: String) -> String {
        precondition(path.hasPrefix("/"), "expected an absolute path")
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func isEvidencePath(_ evidence: URL, checkoutRoot: String) -> Bool {
        let path = lexicalPath(evidence.path)
        let allowedRoot = checkoutRoot + "/artifacts/verification"
        return path.hasPrefix(allowedRoot + "/")
    }

    private static func validScratchRoot(_ root: URL, token: UUID) -> Bool {
        let path = lexicalPath(root.path)
        let expected = "/private/tmp/vaui-\(token.uuidString.lowercased().prefix(8))"
        guard path == expected,
              !isSymlink(URL(fileURLWithPath: "/private")),
              !isSymlink(URL(fileURLWithPath: "/private/tmp")),
              !isSymlink(URL(fileURLWithPath: path)) else { return false }
        return true
    }

    private static func composerConstraint(_ project: URL) -> String? {
        guard let data = try? Data(contentsOf: project.appendingPathComponent("composer.json")), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let require = json["require"] as? [String: String] else { return nil }
        return require["php"]
    }

    private static func hash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var hasher = SHA256Digest(); hasher.update(data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func command(_ executable: String, _ args: [String], allowFailure: Bool = false) throws -> String {
        let process = Process(); let output = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard allowFailure || process.terminationStatus == 0 else { throw HarnessError.failed("command failed: \(executable)") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func write(_ value: String, to url: URL, append: Bool = true) throws {
        let data = Data(value.utf8)
        if append, FileManager.default.fileExists(atPath: url.path) { let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.seekToEnd(); try handle.write(contentsOf: data) }
        else { try data.write(to: url, options: .atomic) }
    }

    private static func append(_ value: String, to url: URL) throws { try write(value, to: url) }
}

private struct SHA256Digest {
    private var digest = [UInt8]()
    mutating func update(_ data: Data) { digest = Array(SHA256.hash(data: data)) }
    func finalize() -> [UInt8] { digest }
}
