import AppKit
import Foundation
import VaelenIPC

@MainActor
final class CoreProcessManager {
    static let shared = CoreProcessManager()

    private var process: Process?
    private var executablePath: String?

    func start() throws {
        if let process, process.isRunning { return }
        process?.waitUntilExit()
        process = nil
        executablePath = nil
        guard let executable = Bundle.main.url(forResource: "vaelend", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CoreProcessError.missingBundledCore
        }

        let child = Process()
        child.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["VAELEN_PARENT_PID"] = String(getpid())
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        executablePath = executable.standardizedFileURL.path
    }

    func ownsCore(pid: Int32) -> Bool {
        guard let process, process.isRunning, process.processIdentifier == pid,
              let executablePath, process.executableURL?.standardizedFileURL.path == executablePath else { return false }
        return true
    }

    func confirmCleanExit(pid: Int32, socketPath: String, timeout: TimeInterval = 5) async -> Bool {
        guard ownsCore(pid: pid), let process else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                process.waitUntilExit()
                while FileManager.default.fileExists(atPath: socketPath), Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !FileManager.default.fileExists(atPath: socketPath) else { return false }
                self.process = nil; executablePath = nil
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

private enum CoreProcessError: LocalizedError {
    case missingBundledCore

    var errorDescription: String? {
        switch self {
        case .missingBundledCore:
            return "The Vaelen app bundle does not contain its Core executable. Reinstall Vaelen and try again."
        }
    }
}

@MainActor
final class VaelenAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: VaelenAppDelegate?
    var requestQuit: (() -> Void)?
    private var approvedTermination = false

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard approvedTermination else {
            requestQuit?()
            return .terminateCancel
        }
        return .terminateNow
    }

    func terminateAfterCleanQuit() {
        approvedTermination = true
        NSApplication.shared.terminate(nil)
    }

    // Core is stopped through typed IPC before the app asks AppKit to quit.
    // Forced termination intentionally does not clear the shell activity flag.
}

enum VaelenActivitySignal {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vaelen/state/activity")
    }

    @discardableResult static func markActive() -> Bool { write("active\n") }
    @discardableResult static func markInactive() -> Bool { write("inactive\n") }

    private static func write(_ value: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Vaelen could not update its shell activity signal: %@", error.localizedDescription)
            return false
        }
    }
}
