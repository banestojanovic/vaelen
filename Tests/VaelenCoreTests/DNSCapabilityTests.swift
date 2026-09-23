import XCTest
import Darwin
@testable import VaelenCore

final class DNSCapabilityTests: XCTestCase {
    func testQuitRestoresHerdResolverAndRetainsDNSStartChoiceForReacquisition() async throws {
        let herd = Data("# Herd resolver\nnameserver 127.0.0.1\nsearch test\noptions timeout:1\n".utf8)
        let fixture = try makeRealFixture(contents: herd, ignoreTermination: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baseline = try ResolverFileSnapshot.read(fixture.file.path)
        let intents = ServiceIntentStore(url: fixture.root.appendingPathComponent("service-intents.json"))
        try intents.set("dns", enabled: true)
        _ = try await fixture.capability.install(takeover: true)
        let initialResponderStatus = await fixture.responder.status()
        let identity = try XCTUnwrap(initialResponderStatus.identity)

        _ = try await fixture.capability.shutdownForQuit()
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), baseline)
        XCTAssertEqual(try Data(contentsOf: fixture.file), herd)
        XCTAssertProcessGone(identity.pid)
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.phase, .resolverRestored)
        XCTAssertEqual(try intents.enabledServices(), ["dns"])

        let relaunched = DNSCapability(helper: fixture.helper, responder: fixture.makeNewSupervisor(), port: fixture.port, ledger: fixture.ledger)
        let restored = try await relaunched.install()
        XCTAssertEqual(restored.health, "healthy")
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.phase, .owned)
        _ = try await relaunched.shutdownForQuit()
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), baseline)
        XCTAssertEqual(try intents.enabledServices(), ["dns"])
    }

    func testChangedResolverBlocksSavedDNSReacquisitionAndRemainsUntouched() async throws {
        let herd = Data("# Herd resolver\nnameserver 127.0.0.1\nsearch test\n".utf8)
        let fixture = try makeRealFixture(contents: herd, ignoreTermination: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let intents = ServiceIntentStore(url: fixture.root.appendingPathComponent("service-intents.json"))
        try intents.set("dns", enabled: true)
        _ = try await fixture.capability.install(takeover: true)
        _ = try await fixture.capability.shutdownForQuit()
        let external = Data("# changed by Herd\nnameserver 192.0.2.55\nsearch test\n".utf8)
        try external.write(to: fixture.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o604], ofItemAtPath: fixture.file.path)
        let changedSnapshot = try ResolverFileSnapshot.read(fixture.file.path)

        let relaunched = DNSCapability(helper: fixture.helper, responder: fixture.makeNewSupervisor(), port: fixture.port, ledger: fixture.ledger)
        do { _ = try await relaunched.install(); XCTFail("changed external resolver must block saved-on restoration") }
        catch { XCTAssertEqual(error as? DNSCapabilityError, .ownershipMismatch) }
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), changedSnapshot)
        XCTAssertEqual(try Data(contentsOf: fixture.file), external)
        XCTAssertEqual(try intents.enabledServices(), ["dns"])
        _ = try await relaunched.shutdownForQuit()
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), changedSnapshot)
    }

    func testResponderDiscoveryAcceptsVaelenBuildPathDriftButNotUnrelatedExecutable() {
        let expected = "/Users/banes/Code/apps/vaelen/.build/debug/vaelendns"
        XCTAssertTrue(DNSResponderSupervisor.acceptsExecutablePath("/Users/banes/Code/apps/vaelen/.build/out/Products/Debug/vaelendns", expected: expected))
        XCTAssertFalse(DNSResponderSupervisor.acceptsExecutablePath("/tmp/vaelendns", expected: expected))
        XCTAssertFalse(DNSResponderSupervisor.acceptsExecutablePath("/Users/banes/Code/apps/vaelen/.build/out/Products/Debug/other", expected: expected))
    }

    func testRealOwnedResponderAndResolverAreDisabledTogetherOnTemporaryPaths() async throws {
        let fixture = try makeRealFixture(contents: nil, ignoreTermination: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.capability.install()
        let running = await fixture.capability.status()
        let initialResponderStatus = await fixture.responder.status()
        let identity = try XCTUnwrap(initialResponderStatus.identity)
        XCTAssertEqual(running.health, "healthy")
        XCTAssertNotEqual(fixture.port, 53535)
        XCTAssertNotEqual(fixture.port, 53)
        XCTAssertTrue(initialResponderStatus.listenerResponding)

        _ = try await fixture.capability.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertProcessGone(identity.pid)
        let stopped = await fixture.responder.status()
        XCTAssertEqual(stopped.state, .exited)
        XCTAssertFalse(stopped.listenerResponding)
        XCTAssertNil(try fixture.ledger.resolverOwnershipRecord())
        _ = try await fixture.capability.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))

        let herd = Data("# Herd resolver\nnameserver 127.0.0.1\nsearch test\n".utf8)
        let herdFixture = try makeRealFixture(contents: herd, ignoreTermination: false)
        defer { try? FileManager.default.removeItem(at: herdFixture.root) }
        let original = try ResolverFileSnapshot.read(herdFixture.file.path)
        _ = try await herdFixture.capability.install(takeover: true)
        let herdStatus = await herdFixture.responder.status()
        let herdPID = try XCTUnwrap(herdStatus.pid)
        _ = try await herdFixture.capability.remove()
        XCTAssertEqual(try ResolverFileSnapshot.read(herdFixture.file.path), original)
        XCTAssertEqual(try Data(contentsOf: herdFixture.file), herd)
        XCTAssertProcessGone(herdPID)
    }

    func testResponderShutdownTimeoutAfterRestoreIsPartialAndRetryable() async throws {
        let fixture = try makeRealFixture(contents: nil, ignoreTermination: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.capability.install()
        let initialResponderStatus = await fixture.responder.status()
        let identity = try XCTUnwrap(initialResponderStatus.identity)
        do { _ = try await fixture.capability.remove(); XCTFail("fixture ignores SIGTERM") }
        catch { guard case DNSCapabilityError.responderShutdownFailed = error else { return XCTFail("unexpected error: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.phase, .resolverRestored)
        XCTAssertTrue(isProcessLive(identity.pid))
        let listener = await fixture.responder.status()
        XCTAssertTrue(listener.listenerResponding)
        let partial = await fixture.capability.status()
        XCTAssertEqual(partial.health, "resolver-restored-responder-running")
        try FileManager.default.removeItem(at: fixture.ignoreTerminationFile)
        _ = try await fixture.capability.remove()
        XCTAssertProcessGone(identity.pid)
        XCTAssertNil(try fixture.ledger.resolverOwnershipRecord())
        let finalResponderStatus = await fixture.responder.status()
        XCTAssertFalse(finalResponderStatus.listenerResponding)
    }

    func testIndependentResolverEditPreventsResponderShutdown() async throws {
        let fixture = try makeRealFixture(contents: nil, ignoreTermination: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.capability.install()
        let initial = await fixture.responder.status()
        let identity = try XCTUnwrap(initial.identity)
        let edit = Data("nameserver 192.0.2.77\n# independent edit\n".utf8)
        try edit.write(to: fixture.file)
        let editedSnapshot = try ResolverFileSnapshot.read(fixture.file.path)
        do { _ = try await fixture.capability.remove(); XCTFail("independent resolver edit must block disable") }
        catch { XCTAssertEqual(error as? DNSCapabilityError, .ownershipMismatch) }
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), editedSnapshot)
        XCTAssertEqual(try Data(contentsOf: fixture.file), edit)
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.phase, .owned)
        XCTAssertTrue(isProcessLive(identity.pid), "responder may still serve the independently edited resolver")
        let running = await fixture.responder.status()
        XCTAssertEqual(running.state, .ownedRunning)
        XCTAssertTrue(running.listenerResponding)
        // The fixture owns its child handle; stop it explicitly after proving
        // disable did not stop it. The independent file remains untouched.
        _ = try await fixture.responder.stop(expected: identity, timeout: 1)
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), editedSnapshot)
    }

    func testCoreRestartHasNoPIDOnlyAuthorityAndUnrelatedListenerIsNotSignaled() async throws {
        let fixture = try makeRealFixture(contents: nil, ignoreTermination: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.capability.install()
        let initialResponderStatus = await fixture.responder.status()
        let identity = try XCTUnwrap(initialResponderStatus.identity)
        let restartedResponder = fixture.makeNewSupervisor()
        let restarted = DNSCapability(helper: fixture.helper, responder: restartedResponder, port: fixture.port, ledger: fixture.ledger, responderShutdownTimeout: 0.2)
        let restartedStatus = await restarted.status()
        XCTAssertEqual(restartedStatus.health, "responder-unverified")
        XCTAssertTrue(isProcessLive(identity.pid))
        do { _ = try await restarted.remove(); XCTFail("new Core instance has no launch handle") }
        catch { guard case DNSCapabilityError.responderShutdownFailed = error else { return XCTFail("unexpected error: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.phase, .resolverRestored)
        XCTAssertTrue(isProcessLive(identity.pid), "persisted PID must not be used as signal authority")

        XCTAssertEqual(kill(identity.pid, SIGTERM), 0)
        XCTAssertProcessGone(identity.pid)
        let exited = await fixture.responder.status()
        XCTAssertEqual(exited.state, .exited)
        XCTAssertFalse(exited.listenerResponding)
        let exitedResolverStatus = await fixture.capability.status()
        XCTAssertEqual(exitedResolverStatus.health, "responder-shutdown-pending")
        let unrelated = try fixture.launchUnrelatedResponder()
        let endpointProbe = fixture.makeNewSupervisor()
        let endpointReady = await waitForListener(endpointProbe)
        XCTAssertTrue(endpointReady)
        let observed = await fixture.responder.status()
        XCTAssertEqual(observed.state, .unverified)
        do { _ = try await fixture.capability.remove(); XCTFail("unrelated listener prevents success") }
        catch { guard case DNSCapabilityError.responderShutdownFailed = error else { return XCTFail("unexpected error: \(error)") } }
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.phase, .resolverRestored)
        unrelated.terminate(); unrelated.waitUntilExit()
        _ = try await fixture.capability.remove()
        XCTAssertNil(try fixture.ledger.resolverOwnershipRecord())
    }

    func testExternalResolverConflictsWithoutMutation() async throws {
        let fixture = try makeFixture(contents: Data("nameserver 192.0.2.2\n".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try ResolverFileSnapshot.read(fixture.file.path)
        do { _ = try await fixture.capability.install(); XCTFail("expected conflict") } catch { XCTAssertEqual(error as? DNSCapabilityError, .externalConflict) }
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), before)
        XCTAssertNil(try fixture.ledger.resolverOwnershipRecord())
    }

    func testAbsentResolverRepeatedEnableDisableAndRestartRestoresExactAbsence() async throws {
        let fixture = try makeFixture(contents: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.capability.install()
        let written = try ResolverFileSnapshot.read(fixture.file.path)
        XCTAssertTrue(written.exists)
        XCTAssertEqual(written.bytes, expectedBytes)
        XCTAssertEqual(written.owner, getuid())
        XCTAssertEqual(written.group, getgid())
        XCTAssertEqual(written.mode, 0o640)
        let originalRecord = try XCTUnwrap(fixture.ledger.resolverOwnershipRecord())
        XCTAssertEqual(originalRecord.phase, .owned)
        XCTAssertFalse(originalRecord.previous.exists)

        _ = try await fixture.capability.install()
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord(), originalRecord, "repeated enable must not replace the original preimage")

        let restarted = makeCapability(fixture)
        let restartedStatus = await restarted.status()
        XCTAssertEqual(restartedStatus.ownership, .vaelen)
        _ = try await restarted.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertNil(try fixture.ledger.resolverOwnershipRecord())
        XCTAssertFalse(try XCTUnwrap(try fixture.ledger.dnsRecord()).active)
        _ = try await restarted.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testHerdLikeFileRestoresBytesOwnerGroupAndPermissions() async throws {
        let priorBytes = Data([0x23, 0x20, 0x48, 0x65, 0x72, 0x64, 0x0a, 0x6e, 0x61, 0x6d, 0x65, 0x73, 0x65, 0x72, 0x76, 0x65, 0x72, 0x20, 0x31, 0x32, 0x37, 0x2e, 0x30, 0x2e, 0x30, 0x2e, 0x31, 0x0a])
        let fixture = try makeFixture(contents: priorBytes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o604], ofItemAtPath: fixture.file.path)
        let before = try ResolverFileSnapshot.read(fixture.file.path)
        _ = try await fixture.capability.install(takeover: true)
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.previous, before)
        _ = try await fixture.capability.remove()
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), before)
        XCTAssertEqual(try Data(contentsOf: fixture.file), priorBytes)
        XCTAssertNil(try fixture.ledger.resolverOwnershipRecord())
    }

    func testIndependentEditIsPreservedAndOwnershipRecordRetained() async throws {
        let fixture = try makeFixture(contents: Data("nameserver 127.0.0.1\n".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.capability.install(takeover: true)
        let externalBytes = Data("nameserver 192.0.2.53\n# external edit\n".utf8)
        try await fixture.helper.externalWrite(externalBytes)
        let external = try ResolverFileSnapshot.read(fixture.file.path)
        do { _ = try await fixture.capability.remove(); XCTFail("expected conflict") } catch { XCTAssertEqual(error as? DNSCapabilityError, .ownershipMismatch) }
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), external)
        XCTAssertEqual(try Data(contentsOf: fixture.file), externalBytes)
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.phase, .owned)
        let status = await fixture.capability.status()
        XCTAssertEqual(status.state, .conflict)
        XCTAssertNotNil(status.conflict)
    }

    func testRepeatedDisableIsIdempotentAfterSuccessfulRestore() async throws {
        let fixture = try makeFixture(contents: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.capability.install()
        _ = try await fixture.capability.remove()
        _ = try await fixture.capability.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertNil(try fixture.ledger.resolverOwnershipRecord())
    }

    func testFixtureResponderTimeoutRetainsPartialRecordUntilRetry() async throws {
        let fixture = try makeFixture(contents: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.capability.install()
        await fixture.responder.setTimeout(true)
        do { _ = try await fixture.capability.remove(); XCTFail("expected responder timeout") }
        catch { guard case DNSCapabilityError.responderShutdownFailed = error else { return XCTFail("unexpected error: \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.phase, .resolverRestored)
        let partialStatus = await awaitStatus(fixture.capability)
        XCTAssertEqual(partialStatus.health, "resolver-restored-responder-running")
        await fixture.responder.setTimeout(false)
        _ = try await fixture.capability.remove()
        XCTAssertNil(try fixture.ledger.resolverOwnershipRecord())
    }

    func testCoreRestartBetweenEnableAndRestoreUsesDurableSnapshot() async throws {
        let prior = Data("nameserver 127.0.0.1\nport 1234\n".utf8)
        let fixture = try makeFixture(contents: prior)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try ResolverFileSnapshot.read(fixture.file.path)
        _ = try await fixture.capability.install(takeover: true)
        let reopenedLedger = try SystemModificationLedger(store: SQLiteStateStore(databaseURL: fixture.database))
        let afterRestart = DNSCapability(helper: fixture.helper, responder: FixtureDNSResponder(isRestarted: true), port: 53535, ledger: reopenedLedger)
        XCTAssertEqual(try reopenedLedger.resolverOwnershipRecord()?.previous, before)
        let restartedStatus = await afterRestart.status()
        XCTAssertEqual(restartedStatus.health, "responder-unverified")
        do { _ = try await afterRestart.remove(); XCTFail("new Core instance must not claim the old responder handle") }
        catch { guard case DNSCapabilityError.responderShutdownFailed = error else { return XCTFail("unexpected error: \(error)") } }
        XCTAssertEqual(try reopenedLedger.resolverOwnershipRecord()?.phase, .resolverRestored)
        XCTAssertEqual(try ResolverFileSnapshot.read(fixture.file.path), before)
        XCTAssertEqual(try Data(contentsOf: fixture.file), prior)
        _ = try await fixture.capability.remove()
        XCTAssertNil(try reopenedLedger.resolverOwnershipRecord())
    }

    func testInterruptedWriteAndRestoreFailureKeepUncertainRecoveryRecord() async throws {
        let fixture = try makeFixture(contents: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.helper.failNextInstall()
        do { _ = try await fixture.capability.install(); XCTFail("expected interrupted write") } catch { XCTAssertEqual(error as? DNSCapabilityError, .processFailed("injected interrupted write")) }
        XCTAssertEqual(try fixture.ledger.resolverOwnershipRecord()?.phase, .uncertain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path), "partial file is retained for diagnosis")
        let interruptedStatus = await awaitStatus(fixture.capability)
        XCTAssertEqual(interruptedStatus.health, "ownership-uncertain")
        do { _ = try await fixture.capability.remove(); XCTFail("uncertain write cannot be auto-restored") } catch { guard case DNSCapabilityError.ownershipUncertain = error else { return XCTFail("unexpected error: \(error)") } }

        let clean = try makeFixture(contents: nil)
        defer { try? FileManager.default.removeItem(at: clean.root) }
        _ = try await clean.capability.install()
        await clean.helper.failNextRestore()
        do { _ = try await clean.capability.remove(); XCTFail("expected restore failure") } catch { XCTAssertEqual(error as? DNSCapabilityError, .processFailed("injected restore failure")) }
        XCTAssertEqual(try clean.ledger.resolverOwnershipRecord()?.phase, .restoring)
        XCTAssertEqual(try ResolverFileSnapshot.read(clean.file.path), try XCTUnwrap(try clean.ledger.resolverOwnershipRecord()?.written))
        let restoreFailureStatus = await awaitStatus(clean.capability)
        XCTAssertEqual(restoreFailureStatus.health, "ownership-uncertain")
        _ = try await clean.capability.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean.file.path))
        XCTAssertNil(try clean.ledger.resolverOwnershipRecord())
    }

    func testReplacementAndSymlinkAreConflictsWithoutFollowingOrOverwritingTarget() async throws {
        let replacementFixture = try makeFixture(contents: nil)
        defer { try? FileManager.default.removeItem(at: replacementFixture.root) }
        _ = try await replacementFixture.capability.install()
        try FileManager.default.removeItem(at: replacementFixture.file)
        let replacement = Data("independent replacement\n".utf8)
        try replacement.write(to: replacementFixture.file)
        let replacementState = try ResolverFileSnapshot.read(replacementFixture.file.path)
        do { _ = try await replacementFixture.capability.remove(); XCTFail("expected replacement conflict") } catch { XCTAssertEqual(error as? DNSCapabilityError, .ownershipMismatch) }
        XCTAssertEqual(try ResolverFileSnapshot.read(replacementFixture.file.path), replacementState)
        XCTAssertEqual(try fixtureRecord(replacementFixture).phase, .owned)

        let symlinkFixture = try makeFixture(contents: nil)
        defer { try? FileManager.default.removeItem(at: symlinkFixture.root) }
        _ = try await symlinkFixture.capability.install()
        let target = symlinkFixture.root.appendingPathComponent("external-target")
        let targetBytes = Data("do not change target\n".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.removeItem(at: symlinkFixture.file)
        try FileManager.default.createSymbolicLink(at: symlinkFixture.file, withDestinationURL: target)
        do { _ = try await symlinkFixture.capability.remove(); XCTFail("expected symlink conflict") } catch { guard case DNSCapabilityError.resolverConflict = error else { return XCTFail("unexpected error: \(error)") } }
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
        XCTAssertTrue((try FileManager.default.attributesOfItem(atPath: symlinkFixture.file.path)[.type] as? FileAttributeType) == .typeSymbolicLink)
        XCTAssertEqual(try fixtureRecord(symlinkFixture).phase, .owned)
        let symlinkStatus = await symlinkFixture.capability.status()
        XCTAssertEqual(symlinkStatus.state, .conflict)
    }

    private let expectedBytes = Data("nameserver 127.0.0.1\nport 53535\n".utf8)

    private struct Fixture {
        let root: URL
        let file: URL
        let database: URL
        let ledger: SystemModificationLedger
        let helper: FileDNSHelper
        let responder: FixtureDNSResponder
        let capability: DNSCapability
    }

    private struct RealFixture {
        let root: URL
        let file: URL
        let ledger: SystemModificationLedger
        let helper: FileDNSHelper
        let responder: DNSResponderSupervisor
        let capability: DNSCapability
        let port: Int
        let ignoreTerminationFile: URL
        let script: URL

        func makeNewSupervisor() -> DNSResponderSupervisor {
            DNSResponderSupervisor(layout: VaelenFilesystemLayout(rootURL: root), port: port, executablePath: "/usr/bin/python3", launchArguments: { ["-u", script.path, "--port", "\($0)", "--ignore-file", ignoreTerminationFile.path] }, startupTimeout: 2)
        }

        func launchUnrelatedResponder() throws -> Process {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", script.path, "--port", "\(port)", "--ignore-file", ignoreTerminationFile.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); return process
        }
    }

    private func makeFixture(contents: Data?) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dns-resolver-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("resolver/test")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let contents {
            try contents.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o604], ofItemAtPath: file.path)
        }
        let database = root.appendingPathComponent("state.sqlite")
        let ledger = try SystemModificationLedger(store: SQLiteStateStore(databaseURL: database))
        let helper = FileDNSHelper(path: file.path)
        let responder = FixtureDNSResponder()
        return Fixture(root: root, file: file, database: database, ledger: ledger, helper: helper, responder: responder, capability: DNSCapability(helper: helper, responder: responder, port: 53535, ledger: ledger))
    }

    private func makeRealFixture(contents: Data?, ignoreTermination: Bool) throws -> RealFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dns-owned-process-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("resolver/test")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let contents { try contents.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o604], ofItemAtPath: file.path) }
        let database = root.appendingPathComponent("state.sqlite")
        let ledger = try SystemModificationLedger(store: SQLiteStateStore(databaseURL: database))
        let helper = FileDNSHelper(path: file.path)
        let port = try availableUDPPort()
        let script = root.appendingPathComponent("harmless-dns-fixture.py")
        let ignoreFile = root.appendingPathComponent("ignore-sigterm")
        let source = "import os, signal, socket, sys\nport=int(sys.argv[sys.argv.index('--port')+1])\nignore=sys.argv[sys.argv.index('--ignore-file')+1]\ns=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('127.0.0.1',port))\ndef stop(sig,frame):\n    if not os.path.exists(ignore): raise SystemExit(0)\nsignal.signal(signal.SIGTERM,stop)\nwhile True:\n    data,peer=s.recvfrom(2048); s.sendto(data,peer)\n"
        try Data(source.utf8).write(to: script)
        if ignoreTermination { try Data("ignore".utf8).write(to: ignoreFile) }
        let responder = DNSResponderSupervisor(layout: VaelenFilesystemLayout(rootURL: root), port: port, executablePath: "/usr/bin/python3", launchArguments: { ["-u", script.path, "--port", "\($0)", "--ignore-file", ignoreFile.path] }, startupTimeout: 2)
        let capability = DNSCapability(helper: helper, responder: responder, port: port, ledger: ledger, responderShutdownTimeout: 0.25)
        return RealFixture(root: root, file: file, ledger: ledger, helper: helper, responder: responder, capability: capability, port: port, ignoreTerminationFile: ignoreFile, script: script)
    }

    private func availableUDPPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { throw DNSCapabilityError.processFailed("Could not create test socket") }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw DNSCapabilityError.processFailed("Could not allocate test UDP port") }
        var result = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &result) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard queried == 0 else { throw DNSCapabilityError.processFailed("Could not inspect test UDP port") }
        let port = Int(UInt16(bigEndian: result.sin_port)); guard port != 53 && port != 53535 else { throw DNSCapabilityError.processFailed("Unsafe test endpoint allocation") }; return port
    }

    private func isProcessLive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
    private func waitForListener(_ responder: DNSResponderSupervisor) async -> Bool {
        for _ in 0..<100 { if (await responder.status()).listenerResponding { return true }; usleep(20_000) }
        return false
    }
    private func XCTAssertProcessGone(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<100 { if !isProcessLive(pid) { return }; usleep(20_000) }
        XCTFail("fixture process \(pid) remained alive", file: file, line: line)
    }
    private func makeCapability(_ fixture: Fixture) -> DNSCapability { DNSCapability(helper: fixture.helper, responder: FixtureDNSResponder(), port: 53535, ledger: fixture.ledger) }
    private func fixtureRecord(_ fixture: Fixture) throws -> DNSResolverOwnershipRecord { try XCTUnwrap(fixture.ledger.resolverOwnershipRecord()) }
    private func awaitStatus(_ capability: DNSCapability) async -> DNSStatus { await capability.status() }
}

private actor FileDNSHelper: PrivilegedDNSHelper {
    private let path: String
    private var failInstall = false
    private var failRestore = false
    init(path: String) { self.path = path }
    func failNextInstall() { failInstall = true }
    func failNextRestore() { failRestore = true }
    func externalWrite(_ bytes: Data) throws { try bytes.write(to: URL(fileURLWithPath: path), options: .atomic) }

    func inspectTestResolver() async throws -> ResolverInspection {
        let snapshot = try ResolverFileSnapshot.read(path)
        return ResolverInspection(exists: snapshot.exists, content: snapshot.bytes.map { String(decoding: $0, as: UTF8.self) }, ownership: snapshot.exists ? .unknown : .none, snapshot: snapshot)
    }

    func installTestResolver(port: Int, replacing: ResolverFileSnapshot?) async throws -> ResolverFileSnapshot {
        let before = try ResolverFileSnapshot.read(path)
        guard before == replacing else { throw DNSCapabilityError.ownershipMismatch }
        if failInstall {
            failInstall = false
            try Data("partial".utf8).write(to: URL(fileURLWithPath: path))
            throw DNSCapabilityError.processFailed("injected interrupted write")
        }
        let bytes = Data("nameserver 127.0.0.1\nport \(port)\n".utf8)
        try writeInPlace(bytes)
        return try ResolverFileSnapshot.read(path)
    }

    func removeTestResolver(expected: ResolverFileSnapshot, restore: ResolverFileSnapshot) async throws {
        guard try ResolverFileSnapshot.read(path) == expected else { throw DNSCapabilityError.ownershipMismatch }
        if failRestore { failRestore = false; throw DNSCapabilityError.processFailed("injected restore failure") }
        if restore.exists {
            guard let bytes = restore.bytes else { throw DNSCapabilityError.ownershipUncertain("Missing original bytes") }
            try writeInPlace(bytes)
            if let owner = restore.owner, let group = restore.group { _ = chown(path, owner, group) }
            if let mode = restore.mode { _ = chmod(path, mode_t(mode)) }
        } else {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private func writeInPlace(_ bytes: Data) throws {
        let descriptor: Int32
        if FileManager.default.fileExists(atPath: path) {
            descriptor = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw DNSCapabilityError.resolverConflict("Resolver path changed type") }
            guard ftruncate(descriptor, 0) == 0 else { close(descriptor); throw DNSCapabilityError.processFailed("truncate failed") }
        } else {
            descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o640)
            guard descriptor >= 0 else { throw DNSCapabilityError.resolverConflict("Resolver path appeared during write") }
        }
        defer { close(descriptor) }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let amount = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                guard amount > 0 else { throw DNSCapabilityError.processFailed("resolver write failed") }
                offset += amount
            }
        }
    }
}

private actor FixtureDNSResponder: DNSResponderControlling {
    private var running = false
    private var shouldTimeout = false
    private let isRestarted: Bool
    private let identity = DNSResponderIdentity(pid: 42, executablePath: "/fixture/vaelendns", arguments: ["--port", "53535"], startedAt: "fixture")
    init(isRestarted: Bool = false) { self.isRestarted = isRestarted }
    func setTimeout(_ value: Bool) { shouldTimeout = value }
    func status() async -> DNSResponderStatus {
        if running { return .init(state: .ownedRunning, pid: identity.pid, listenerResponding: true, identity: identity) }
        if isRestarted { return .init(state: .unverified, listenerResponding: true) }
        return .init(state: .exited, pid: identity.pid, listenerResponding: false, identity: identity)
    }
    func start() async throws -> DNSResponderIdentity { running = true; return identity }
    func stop(expected: DNSResponderIdentity, timeout: TimeInterval) async throws -> DNSResponderStatus {
        if isRestarted { throw DNSCapabilityError.responderUnverified("fixture has no retained launch handle") }
        guard expected == identity else { throw DNSCapabilityError.responderUnverified("fixture identity mismatch") }
        if shouldTimeout { throw DNSCapabilityError.responderShutdownFailed("injected fixture stop timeout") }
        running = false
        return .init(state: .exited, pid: identity.pid, listenerResponding: false, identity: identity)
    }
}
