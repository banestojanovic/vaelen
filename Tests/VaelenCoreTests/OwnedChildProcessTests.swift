import XCTest
import Darwin
@testable import VaelenCore

final class OwnedChildProcessTests: XCTestCase {
    func testOwnedLiveChildStopsAndSimilarUnrelatedChildSurvives() throws {
        let owned = try launchSleep()
        let unrelated = try launchSleep()
        defer { _ = kill(unrelated.processIdentifier, SIGKILL) }
        XCTAssertTrue(owned.isRunningAndReapedIfExited())
        XCTAssertTrue(unrelated.process.isRunning)

        XCTAssertTrue(owned.terminateAndWait(timeout: 2))
        XCTAssertFalse(owned.isRunningAndReapedIfExited())
        XCTAssertFalse(owned.process.isRunning)
        XCTAssertTrue(unrelated.process.isRunning, "same-executable unrelated child must not be signaled")
    }

    func testAlreadyExitedChildIsReapedAndReportedStopped() throws {
        let child = try OwnedChildProcess.launch(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], label: "test exited child")
        for _ in 0..<100 where child.process.isRunning { usleep(10_000) }
        XCTAssertFalse(child.isRunningAndReapedIfExited())
        XCTAssertEqual(child.process.terminationStatus, 0)
        XCTAssertFalse(child.isRunningAndReapedIfExited())
    }

    func testUnresponsiveOwnedChildReturnsBoundedFailureAndRemainsObservable() throws {
        let child = try OwnedChildProcess.launch(
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "$SIG{TERM} = 'IGNORE'; $|=1; print \"ready\\n\"; sleep 30"],
            label: "test stubborn child",
            output: FileHandle.nullDevice
        )
        defer { _ = kill(child.processIdentifier, SIGKILL) }
        usleep(200_000) // let Perl install its SIGTERM handler before signaling
        XCTAssertTrue(child.isRunningAndReapedIfExited())
        let began = Date()
        XCTAssertFalse(child.terminateAndWait(timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.5)
        XCTAssertTrue(child.isRunningAndReapedIfExited(), "timeout must not be reported as stopped")
    }

    func testForegroundFPMFixtureStopsWorkerAndReleasesUnixSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vln-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("php-fpm.sock").path
        let workerFile = root.appendingPathComponent("worker.pid").path
        let script = #"""
import os, signal, socket, subprocess, sys, time
sockpath, workerfile = sys.argv[1], sys.argv[2]
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(sockpath); listener.listen(1)
worker = subprocess.Popen(['/bin/sleep', '30'])
open(workerfile, 'w').write(str(worker.pid))
def shutdown(signum, frame):
    worker.terminate(); worker.wait(timeout=2)
    listener.close(); os.unlink(sockpath); sys.exit(0)
signal.signal(signal.SIGQUIT, shutdown)
while True: time.sleep(1)
"""#
        let master = try OwnedChildProcess.launch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", script, socketPath, workerFile], label: "PHP-FPM foreground fixture")
        defer { _ = master.terminateAndWait(timeout: 2, signal: SIGKILL, waitForDescendants: true) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: workerFile) { usleep(20_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "foreground master must own its Unix listening socket")
        let workerPID = try XCTUnwrap(Int32(String(contentsOfFile: workerFile, encoding: .utf8)))
        XCTAssertEqual(kill(workerPID, 0), 0, "master-created worker must be live before shutdown")

        XCTAssertTrue(master.terminateAndWait(timeout: 3, signal: SIGQUIT, waitForDescendants: true))
        XCTAssertFalse(master.process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "master must release its Unix socket on graceful shutdown")
        XCTAssertEqual(kill(workerPID, 0), -1, "master-created worker must be gone after successful shutdown")
    }

    private func launchSleep() throws -> OwnedChildProcess {
        try OwnedChildProcess.launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], label: "test sleep")
    }
}
