import Foundation
import Darwin

/// Holds the Process object for a child launched by Core. Signals are sent only
/// while that exact Process handle still represents the recorded PID.
public final class OwnedChildProcess: @unchecked Sendable {
    public let process: Process
    public let label: String
    private let condition = NSCondition()
    private var reaped = false
    private var stopping = false
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

    /// Returns true while the owned child is live. Foundation publishes the
    /// exit state and terminationStatus through Process; do not call
    /// waitUntilExit here. In particular, waitUntilExit can wait on Foundation
    /// bookkeeping even after isRunning has become false.
    public func isRunningAndReapedIfExited() -> Bool {
        condition.lock()
        guard !reaped else { condition.unlock(); return false }
        guard process.isRunning else {
            reaped = true
            pendingDescendants.merge(observedDescendants) { _, latest in latest }
            condition.unlock()
            return false
        }
        let pid = process.processIdentifier
        condition.unlock()

        let descendants = Self.descendantIdentities(of: pid)
        condition.lock()
        if !reaped && process.isRunning {
            observedDescendants.merge(descendants) { _, latest in latest }
        } else if !reaped {
            reaped = true
            pendingDescendants.merge(observedDescendants) { _, latest in latest }
            pendingDescendants.merge(descendants) { _, latest in latest }
        }
        let running = !reaped && process.isRunning
        condition.unlock()
        return running
    }

    public var hasLiveOwnedDescendants: Bool {
        condition.lock()
        pendingDescendants.merge(observedDescendants) { _, latest in latest }
        let descendants = pendingDescendants
        condition.unlock()
        return !Self.descendantsAreGone(descendants)
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
        condition.lock()
        while stopping { condition.wait() }
        if reaped {
            let descendants = pendingDescendants
            condition.unlock()
            guard waitForDescendants else { return true }
            return Self.waitForDescendantsToExit(descendants, timeout: timeout)
        }
        let pid = process.processIdentifier
        guard pid > 0 else { reaped = true; condition.unlock(); return true }
        stopping = true
        let priorDescendants = observedDescendants
        condition.unlock()

        let descendants = waitForDescendants
            ? priorDescendants.merging(Self.descendantIdentities(of: pid)) { _, latest in latest }
            : [:]
        condition.lock()
        if waitForDescendants { pendingDescendants = descendants }
        let wasRunning = process.isRunning
        condition.unlock()
        if !wasRunning {
            finishStop(descendants: descendants)
            return !waitForDescendants || Self.waitForDescendantsToExit(descendants, timeout: timeout)
        }
        // Foundation's Process handle proves the launched master identity.
        // SIGQUIT is PHP-FPM's graceful-stop signal (TERM is not equivalent).
        if signal == SIGTERM { process.terminate() }
        else if process.isRunning, kill(pid, signal) != 0 && errno != ESRCH {
            finishStop(descendants: descendants, markReaped: false)
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        var childExited = false
        while Date() < deadline {
            if !process.isRunning {
                childExited = true
                break
            }
            usleep(20_000)
        }
        if !childExited { childExited = !process.isRunning }
        finishStop(descendants: descendants, markReaped: childExited)
        guard childExited else { return false }
        let descendantsGone = !waitForDescendants || Self.waitForDescendantsToExit(descendants, timeout: max(0, deadline.timeIntervalSinceNow))
        if descendantsGone { condition.lock(); pendingDescendants = [:]; condition.unlock() }
        return descendantsGone
    }

    private func finishStop(descendants: [Int32: String], markReaped: Bool = true) {
        condition.lock()
        if markReaped {
            reaped = true
            pendingDescendants.merge(descendants) { _, latest in latest }
            pendingDescendants.merge(observedDescendants) { _, latest in latest }
        }
        stopping = false
        condition.broadcast()
        condition.unlock()
    }

    private static func descendantIdentities(of root: Int32) -> [Int32: String] {
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,lstart="]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        // EOF is sufficient for this one-shot `ps` probe. Avoid introducing
        // another synchronous Process.waitUntilExit into child lifecycle
        // observation; the kernel closes its pipe when ps exits.
        let data = output.fileHandleForReading.readDataToEndOfFile()
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
            let data = output.fileHandleForReading.readDataToEndOfFile()
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
