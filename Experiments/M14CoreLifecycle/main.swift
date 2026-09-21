import Darwin
import Foundation
import ServiceManagement

private enum Experiment {
    static let bundleIdentifier = "dev.vaelen.m14-lifecycle-experiment"
    static let agentLabel = "dev.vaelen.m14-lifecycle-experiment.agent"
    static let plistName = "dev.vaelen.m14-lifecycle-experiment.agent.plist"
    static let rootName = "M14CoreLifecycleExperiment"
    static let appName = "M14CoreLifecycleExperiment.app"
    static let executableName = "M14CoreLifecycleExperiment"
    static let agentExecutableName = "M14CoreLifecycleAgent"
    // proc_pidpath documents PROC_PIDPATHINFO_MAXSIZE as the required
    // upper-bound buffer size, but that C macro is unavailable to Swift in
    // the current macOS SDK importer. This comfortably exceeds macOS's
    // MAXPATHLEN-based process-path limit for this disposable experiment.
    static let processPathCapacity = 4096
    // libproc defines PROC_PIDTBSDINFO as flavor 3. The macro is avoided here
    // for the same Swift-importer portability reason as the path-size macro.
    static let processBSDInfoFlavor: Int32 = 3

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(rootName, isDirectory: true)
    }

    static var app: URL { root.appendingPathComponent("App", isDirectory: true).appendingPathComponent(appName, isDirectory: true) }
    static var executable: URL { app.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executableName) }
    static var agentExecutable: URL { app.appendingPathComponent("Contents/Resources", isDirectory: true).appendingPathComponent(agentExecutableName) }
    static var events: URL { root.appendingPathComponent("events.jsonl") }
    static var pidFile: URL { root.appendingPathComponent("agent.pid") }

    static func rejectUnsafeIdentity() -> Bool {
        let bundle = Bundle.main.bundleIdentifier ?? ""
        guard bundle == bundleIdentifier, !bundle.contains("dev.vaelen.core"), agentLabel != "dev.vaelen.core" else {
            fputs("Refusing unsafe or non-experiment identity.\n", stderr)
            return false
        }
        return true
    }

    static func requirePreparedBundle() -> Bool {
        guard rejectUnsafeIdentity(), Bundle.main.bundleURL.standardizedFileURL == app.standardizedFileURL else {
            fputs("Run this operation only from the prepared experiment app at:\n\(app.path)\n", stderr)
            return false
        }
        return true
    }

    static func service() -> SMAppService { SMAppService.agent(plistName: plistName) }

    @discardableResult
    static func record(_ operation: String, details: [String: Any] = [:], emit: Bool = true) -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            fputs("Unable to create experiment evidence directory: \(error)\n", stderr)
            return false
        }
        var value: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "operation": operation,
            "bundleIdentifier": bundleIdentifier,
            "agentLabel": agentLabel,
            "appBundlePath": app.path,
            "agentExecutablePath": agentExecutable.path,
            "uid": Int(getuid()),
            "euid": Int(geteuid())
        ]
        details.forEach { value[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            fputs("Unable to encode experiment evidence as JSON.\n", stderr)
            return false
        }
        var line = data
        line.append(0x0a)
        do {
            do {
                let handle = try FileHandle(forWritingTo: events)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                try line.write(to: events, options: .atomic)
            }
        } catch {
            fputs("Unable to persist experiment evidence: \(error)\n", stderr)
            return false
        }
        if emit { FileHandle.standardOutput.write(line) }
        return true
    }

    static func status() {
        guard rejectUnsafeIdentity() else { exit(2) }
        let serviceStatus = String(describing: service().status)
        var details: [String: Any] = ["serviceStatus": serviceStatus]
        if FileManager.default.fileExists(atPath: pidFile.path) {
            do {
                let pid = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pid.isEmpty else {
                    fputs("Experiment PID evidence is empty.\n", stderr)
                    exit(1)
                }
                details["recordedPID"] = pid
            } catch {
                fputs("Unable to read experiment PID evidence: \(error)\n", stderr)
                exit(1)
            }
        }
        guard record("status", details: details) else { exit(1) }
    }

    static func mutate(_ operation: String) {
        guard requirePreparedBundle() else { exit(2) }
        do {
            if operation == "register" { try service().register() }
            else { try service().unregister() }
            guard record(operation, details: ["result": "success", "serviceStatus": String(describing: service().status)]) else { exit(1) }
        } catch {
            let persisted = record(operation, details: ["result": "error", "error": String(describing: error), "serviceStatus": String(describing: service().status)])
            if !persisted { fputs("Unable to persist the failed \(operation) evidence.\n", stderr) }
            fputs("\(operation) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func evidence() {
        guard rejectUnsafeIdentity() else { exit(2) }
        guard record("evidence", details: ["serviceStatus": String(describing: service().status)]) else { exit(1) }
        guard let data = try? Data(contentsOf: events), let text = String(data: data, encoding: .utf8) else {
            fputs("Unable to read experiment evidence at \(events.path).\n", stderr)
            exit(1)
        }
        print(text, terminator: "")
    }

    static func agentPID() {
        guard rejectUnsafeIdentity() else { exit(2) }
        guard let pid = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !pid.isEmpty else {
            fputs("No experiment agent PID evidence is available.\n", stderr)
            exit(1)
        }
        guard let numericPID = Int32(pid), numericPID > 1 else {
            fputs("Experiment PID evidence is invalid.\n", stderr)
            exit(1)
        }
        print(numericPID)
    }

    static func terminateAgent(_ rawPID: String) {
        guard requirePreparedBundle() else { exit(2) }
        guard let pid = Int32(rawPID), pid > 1 else {
            fputs("Refusing invalid experiment PID '\(rawPID)'; expected an integer greater than 1.\n", stderr)
            exit(2)
        }
        guard let recordedPID = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), Int32(recordedPID) == pid else {
            fputs("Refusing to terminate a PID different from the current experiment evidence.\n", stderr)
            exit(2)
        }
        var processPath = [CChar](repeating: 0, count: processPathCapacity)
        let pathLength = processPath.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(processPathCapacity))
        }
        guard pathLength > 0, pathLength < Int32(processPathCapacity) else {
            let error = errno
            if pathLength <= 0 {
                fputs("Unable to inspect experiment PID \(pid): \(String(cString: strerror(error)))\n", stderr)
            } else {
                fputs("Refusing experiment PID \(pid): executable path did not fit the bounded inspection buffer.\n", stderr)
            }
            exit(1)
        }
        guard processPath[Int(pathLength)] == 0 else {
            fputs("Refusing experiment PID \(pid): executable path was not NUL-terminated within the inspection buffer.\n", stderr)
            exit(1)
        }
        let observedPath = URL(fileURLWithPath: String(cString: processPath)).standardizedFileURL.path
        var processInfo = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let observedSize = proc_pidinfo(pid, processBSDInfoFlavor, 0, &processInfo, infoSize)
        guard observedSize == infoSize else {
            fputs("Unable to inspect UID for experiment PID \(pid).\n", stderr)
            exit(1)
        }
        guard getuid() == geteuid() else {
            fputs("Refusing termination because the controller is not running as its own user.\n", stderr)
            exit(2)
        }
        guard processInfo.pbi_uid == getuid() else {
            fputs("Refusing PID \(pid): target UID \(processInfo.pbi_uid) is not the current UID \(getuid()).\n", stderr)
            exit(2)
        }
        guard observedPath == agentExecutable.standardizedFileURL.path else {
            fputs("Refusing PID \(pid): executable path is '\(observedPath)', expected '\(agentExecutable.path)'.\n", stderr)
            exit(2)
        }
        guard record("terminate-agent-attempt", details: ["requestedPID": Int(pid), "verifiedPID": Int(pid), "verifiedUID": Int(processInfo.pbi_uid), "verifiedExecutablePath": observedPath], emit: false) else { exit(1) }
        let result = kill(pid, SIGKILL)
        if result == 0 {
            let persisted = record("terminate-agent-signal-issued", details: ["requestedPID": Int(pid), "verifiedPID": Int(pid), "verifiedUID": Int(processInfo.pbi_uid), "verifiedExecutablePath": observedPath], emit: false)
            if persisted {
                print("terminate-agent: success; SIGKILL issued to verified experiment PID \(pid).")
            } else {
                print("terminate-agent: success; SIGKILL issued to verified experiment PID \(pid), but post-signal evidence persistence failed.")
            }
            return
        }
        let error = errno
        fputs("terminate-agent: failure; SIGKILL was not issued to PID \(pid): \(String(cString: strerror(error))) (errno \(error)).\n", stderr)
        exit(1)
    }

}

switch CommandLine.arguments.dropFirst().first {
case "status": Experiment.status()
case "register": Experiment.mutate("register")
case "unregister": Experiment.mutate("unregister")
case "evidence": Experiment.evidence()
case "agent-pid": Experiment.agentPID()
case "terminate-agent":
    guard CommandLine.arguments.count == 3 else {
        fputs("Usage: terminate-agent <exact-pid>\n", stderr)
        exit(2)
    }
    Experiment.terminateAgent(CommandLine.arguments[2])
default: print("Usage: status | register | unregister | evidence | agent-pid | terminate-agent <exact-pid>")
}
