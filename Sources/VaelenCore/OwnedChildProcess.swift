import Foundation
import Darwin

/// Holds the Process object for a child launched by Core. Signals are sent only
/// while that exact Process handle still represents the recorded PID.
public final class OwnedChildProcess: @unchecked Sendable {
    public let process: Process
    public let label: String
    private let lock = NSLock()
    private var reaped = false
    private var pendingDescendants: [Int32: String] = [:]
    private var observedDescendants: [Int32: String] = [:]

    public var processIdentifier: Int32 { process.processIdentifier }
    public var executablePath: String? { process.executableURL?.standardizedFileURL.path }
    public var arguments: [String] { process.arguments ?? [] }

    public init(process: Process, label: String) {
        self.process = process
        self.label = label
    }

    public static func launch(executable: URL, arguments: [String], label: String, output: Any? = FileHandle.nullDevice) throws -> OwnedChildProcess {
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardOutput = output
        child.standardError = output
        try child.run()
        return OwnedChildProcess(process: child, label: label)
    }

    /// Returns true while the owned child is live. If it exited, waits for its
    /// termination result to be collected before returning false.
    public func isRunningAndReapedIfExited() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !reaped else { return false }
        if process.isRunning {
            observedDescendants.merge(Self.descendantIdentities(of: process.processIdentifier)) { _, latest in latest }
            return true
        }
        process.waitUntilExit()
        reaped = true
        pendingDescendants.merge(observedDescendants) { _, latest in latest }
        return false
    }

    public var hasLiveOwnedDescendants: Bool {
        lock.lock(); defer { lock.unlock() }
        pendingDescendants.merge(observedDescendants) { _, latest in latest }
        return !Self.descendantsAreGone(pendingDescendants)
    }

    /// Gracefully terminate this child only. Never escalates to SIGKILL; a
    /// caller can therefore report a bounded cleanup failure truthfully.
    public func terminateAndWait(timeout: TimeInterval = 3) -> Bool {
        terminateAndWait(timeout: timeout, signal: SIGTERM, waitForDescendants: false)
    }

    /// Terminates a child with the provider's graceful signal and, when
    /// requested, waits for the descendants that were children of its master
    /// when shutdown began (PHP-FPM workers).
    public func terminateAndWait(timeout: TimeInterval, signal: Int32, waitForDescendants: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if reaped {
            guard waitForDescendants else { return true }
            return Self.waitForDescendantsToExit(pendingDescendants, timeout: timeout)
        }
        guard process.processIdentifier > 0 else { process.waitUntilExit(); reaped = true; return true }
        let descendants = waitForDescendants ? observedDescendants.merging(Self.descendantIdentities(of: process.processIdentifier)) { _, latest in latest } : [:]
        if waitForDescendants { pendingDescendants = descendants }
        if !process.isRunning {
            process.waitUntilExit(); reaped = true
            return !waitForDescendants || Self.waitForDescendantsToExit(descendants, timeout: timeout)
        }
        // Foundation's Process handle proves the launched master identity.
        // SIGQUIT is PHP-FPM's graceful-stop signal (TERM is not equivalent).
        if signal == SIGTERM { process.terminate() }
        else if kill(process.processIdentifier, signal) != 0 && errno != ESRCH { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                process.waitUntilExit(); reaped = true
                if !waitForDescendants || Self.waitForDescendantsToExit(descendants, timeout: max(0, deadline.timeIntervalSinceNow)) { pendingDescendants = [:]; return true }
            }
            usleep(20_000)
        }
        if !process.isRunning {
            process.waitUntilExit(); reaped = true
            let gone = !waitForDescendants || Self.descendantsAreGone(descendants)
            if gone { pendingDescendants = [:] }
            return gone
        }
        return false
    }

    private static func descendantIdentities(of root: Int32) -> [Int32: String] {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,lstart="]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var parents = [Int32: Int32](), identities = [Int32: String]()
        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard columns.count == 3, let pid = Int32(columns[0]), let ppid = Int32(columns[1]) else { continue }
            parents[pid] = ppid; identities[pid] = String(columns[2])
        }
        var descendants = Set<Int32>()
        var changed = true
        while changed {
            changed = false
            for (pid, ppid) in parents where (ppid == root || descendants.contains(ppid)) && !descendants.contains(pid) {
                descendants.insert(pid); changed = true
            }
        }
        return Dictionary(uniqueKeysWithValues: descendants.compactMap { pid in identities[pid].map { (pid, $0) } })
    }

    private static func descendantsAreGone(_ descendants: [Int32: String]) -> Bool {
        descendants.allSatisfy { pid, startedAt in
            let probe = Process(); let output = Pipe()
            probe.executableURL = URL(fileURLWithPath: "/bin/ps")
            probe.arguments = ["-p", "\(pid)", "-o", "lstart="]
            probe.standardOutput = output; probe.standardError = FileHandle.nullDevice
            guard (try? probe.run()) != nil else { return true }
            let data = output.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
            let observed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return observed.isEmpty || observed != startedAt
        }
    }

    private static func waitForDescendantsToExit(_ descendants: [Int32: String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if descendantsAreGone(descendants) { return true }
            usleep(20_000)
        } while Date() < deadline
        return descendantsAreGone(descendants)
    }
}
