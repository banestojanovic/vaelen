import Darwin
import Foundation

private enum ExperimentAgent {
    static let bundleIdentifier = "dev.vaelen.m14-lifecycle-experiment"
    static let agentLabel = "dev.vaelen.m14-lifecycle-experiment.agent"
    static let rootName = "M14CoreLifecycleExperiment"
    static let agentExecutableName = "M14CoreLifecycleAgent"
    static let processPathCapacity = 4096
    static let processBSDInfoFlavor: Int32 = 3

    static var experimentRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(rootName, isDirectory: true)
    }

    static var expectedExecutable: URL {
        experimentRoot
            .appendingPathComponent("App", isDirectory: true)
            .appendingPathComponent("M14CoreLifecycleExperiment.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(agentExecutableName)
    }

    static var events: URL { experimentRoot.appendingPathComponent("events.jsonl") }
    static var pidFile: URL { experimentRoot.appendingPathComponent("agent.pid") }

    static func record(_ operation: String, details: [String: Any] = [:]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: experimentRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var value: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "operation": operation,
                "bundleIdentifier": bundleIdentifier,
                "agentLabel": agentLabel,
                "agentExecutablePath": expectedExecutable.path,
                "uid": Int(getuid()),
                "euid": Int(geteuid())
            ]
            details.forEach { value[$0.key] = $0.value }
            var line = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            line.append(0x0a)
            do {
                let handle = try FileHandle(forWritingTo: events)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                try line.write(to: events, options: .atomic)
            }
            return true
        } catch {
            fputs("Unable to persist experiment agent evidence: \(error)\n", stderr)
            return false
        }
    }

    static func argvDerivedPath() -> URL {
        URL(fileURLWithPath: CommandLine.arguments.first ?? "").standardizedFileURL
    }

    static func argvDerivedRoot(from path: URL) -> URL {
        path.deletingLastPathComponent() // Resources
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // App
    }

    static func observedProcessPath() -> URL? {
        var buffer = [CChar](repeating: 0, count: processPathCapacity)
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(getpid(), bytes.baseAddress, UInt32(processPathCapacity))
        }
        guard length > 0, length < Int32(processPathCapacity), buffer[Int(length)] == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
    }

    static func processIdentity() -> (uid: Int, euid: Int)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), processBSDInfoFlavor, 0, &info, size) == size else { return nil }
        return (Int(info.pbi_uid), Int(geteuid()))
    }

    static func run() -> Never {
        let argv0 = CommandLine.arguments.first ?? ""
        let argvPath = argvDerivedPath()
        let argvRoot = argvDerivedRoot(from: argvPath)
        let observedPath = observedProcessPath()
        let identity = processIdentity()
        let observedPathString = observedPath?.path
        let expectedPathString = expectedExecutable.standardizedFileURL.path
        let pathValidationPassed = observedPathString == expectedPathString
        let diagnosticPersisted = record("agent-path-validation", details: [
            "argv0": argv0,
            "argv0StandardizedPath": argvPath.path,
            "argvDerivedRoot": argvRoot.path,
            "expectedHelperFilename": agentExecutableName,
            "expectedExecutablePath": expectedPathString,
            "observedExecutablePath": observedPathString ?? NSNull(),
            "observedPathAvailable": observedPath != nil,
            "uid": identity.map { $0.uid } ?? NSNull(),
            "euid": identity.map { $0.euid } ?? NSNull(),
            "pathValidationPassed": pathValidationPassed,
            "validationPredicate": "proc_pidpath(getpid()) == expectedExperimentHelperPath"
        ])
        guard diagnosticPersisted, pathValidationPassed else {
            fputs("Refusing unexpected experiment agent path.\n", stderr)
            exit(2)
        }
        do {
            try FileManager.default.createDirectory(at: experimentRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try "\(getpid())\n".write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            fputs("Unable to persist experiment agent identity: \(error)\n", stderr)
            exit(1)
        }
        var generation = 0
        if let data = try? Data(contentsOf: events), let text = String(data: data, encoding: .utf8) {
            generation = text.components(separatedBy: "\"operation\":\"agent-launch\"").count - 1
        }
        guard record("agent-launch", details: ["pid": Int(getpid()), "generation": generation + 1]) else { exit(1) }
        while true {
            guard record("heartbeat", details: ["pid": Int(getpid()), "generation": generation + 1]) else { exit(1) }
            sleep(1)
        }
    }
}

ExperimentAgent.run()
