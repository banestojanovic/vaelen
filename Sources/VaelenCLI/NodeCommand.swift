import Foundation
import Darwin
import VaelenCore
import VaelenIPC

struct NodeExecPlan: Equatable {
    let arguments: [String]
    let path: String?
}

enum NodeExecCommand {
    static func plan(arguments: [String], workingDirectory: String, environment: [String: String], layout: VaelenFilesystemLayout) throws -> NodeExecPlan {
        guard let command = arguments.first, !command.isEmpty, arguments.allSatisfy({ !$0.utf8.contains(0) }) else { throw CLIError.message("Usage: val node exec -- COMMAND [ARGUMENT...]") }
        let records = try NodeSelectionReader(databaseURL: layout.databaseURL).records()
        let resolution = try NodePackageManager(layout: layout).resolution(records: records, workingDirectory: workingDirectory)
        switch resolution {
        case .invocationPATH: return .init(arguments: arguments, path: environment["PATH"])
        case .managed(_, let executable):
            let bin = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            guard !bin.contains(":") else { throw CLIError.message("Managed Node executable path contains ':' and cannot be added safely to PATH.") }
            return .init(arguments: arguments, path: bin + ":" + (environment["PATH"] ?? "/usr/bin:/bin"))
        }
    }

    static func replaceProcess(with plan: NodeExecPlan) throws -> Never {
        if let path = plan.path { setenv("PATH", path, 1) }
        var pointers = plan.arguments.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        _ = pointers.withUnsafeMutableBufferPointer { execvp($0[0], $0.baseAddress) }
        throw CLIError.message("Unable to execute \(plan.arguments[0]). \(String(cString: strerror(errno)))")
    }
}

func nodeCommandOutput(_ result: NodeCommandSnapshot, json: Bool) throws -> String {
    if json { return String(decoding: try IPCCodec.encode(NodeCommandResult(result)), as: UTF8.self) }
    if let installed = result.installedPackage { return HumanOutput.success("Installed Node \(installed.version) for \(installed.platform)-\(installed.architecture).") }
    let releases = result.releases.map { release in
        [release.version.description, release.architecture, result.installedPackages.contains(where: { $0.version == release.version }) ? "Installed" : "Not installed"]
    }
    let projects = result.selections.map { selection in
        [selection.name, selection.path, selection.pinnedVersion?.description ?? "Invocation PATH", selection.availability.rawValue, selection.runtimeAvailable ? "Available" : (selection.detail ?? "Unavailable")]
    }
    return [
        HumanOutput.heading("Reviewed Node releases"),
        HumanOutput.table(releases, headers: ["Exact version", "Architecture", "Package"]),
        HumanOutput.heading("Project Node selections"),
        projects.isEmpty ? "No linked project selections." : HumanOutput.table(projects, headers: ["Project", "Path", "Selection", "Project state", "Runtime"]),
        "Run commands with val node exec -- COMMAND, or install shell integration for ordinary node and npm commands."
    ].joined(separator: "\n")
}
