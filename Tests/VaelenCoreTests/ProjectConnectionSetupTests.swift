import XCTest
@testable import VaelenCore

final class ProjectConnectionSetupTests: XCTestCase {
    private let values = ConnectionValues(driver: "mysql", host: "127.0.0.1", port: "3306", database: "shop", username: "shop_user", password: "secret-canary")

    func testLosslessPatchPreservesMixedBytesAndRedactsPasswordEdit() throws {
        let input = Data([0xef, 0xbb, 0xbf] + Array("# keep\r\nDB_CONNECTION=sqlite\nDB_HOST = old # keep comment\rDB_PASSWORD='old'".utf8))
        let result = try LosslessDotenvDocument.parse(input).patch(values)
        let output = String(decoding: result.bytes, as: UTF8.self)
        XCTAssertTrue(output.hasPrefix("\u{feff}# keep\r\nDB_CONNECTION=mysql\nDB_HOST = 127.0.0.1 # keep comment\r"))
        XCTAssertTrue(output.hasSuffix("DB_PASSWORD=secret-canary\r\nDB_PORT=3306\r\nDB_DATABASE=shop\r\nDB_USERNAME=shop_user\r\n"), output.replacingOccurrences(of: "\r", with: "<CR>").replacingOccurrences(of: "\n", with: "<LF>"))
        XCTAssertFalse(result.edits.first(where: { $0.key == .password })?.displayedValue.contains("secret-canary") ?? true)
        XCTAssertEqual(result.edits.first(where: { $0.key == .password })?.displayedValue, "managed password (hidden)")
    }

    func testAddKeysAndQuoteUnsafeValuesWithoutAddingAnExtraBlankLine() throws {
        let result = try LosslessDotenvDocument.parse(Data("# comment".utf8)).patch(values)
        XCTAssertTrue(String(decoding: result.bytes, as: UTF8.self).hasPrefix("# comment\nDB_CONNECTION=mysql\nDB_HOST=127.0.0.1\n"))
        XCTAssertEqual(try LosslessDotenvDocument.parse(Data("".utf8)).patch(ConnectionValues(driver: "mysql", host: "host #1", port: "3306", database: "a'b", username: "u", password: "p\\q")).bytes,
                       Data("DB_CONNECTION=mysql\nDB_HOST='host #1'\nDB_PORT=3306\nDB_DATABASE='a\\'b'\nDB_USERNAME=u\nDB_PASSWORD='p\\\\q'\n".utf8))
    }

    func testRejectsAmbiguousOrMalformedInputs() {
        for input in ["DB_HOST=a\nDB_HOST=b\n", "DB_HOST broken\n", "DB_PASSWORD=\"unclosed\n", "DB_NAME=x\n", "DB_HOST=a\0b"] {
            XCTAssertThrowsError(try LosslessDotenvDocument.parse(Data(input.utf8)))
        }
        XCTAssertThrowsError(try LosslessDotenvDocument.parse(Data([0xff])))
    }

    func testConfirmationLedgerExpiresConsumesOnceAndRejectsChangedBinding() throws {
        let origin = Date(timeIntervalSince1970: 10_000)
        var ledger = ConnectionConfirmationLedger<String>()
        let expired = ledger.issue("project|receipt|service|file", now: origin)
        XCTAssertThrowsError(try ledger.consume(expired, now: origin.addingTimeInterval(30)))
        let replay = ledger.issue("project|receipt|service|file", now: origin)
        XCTAssertEqual(try ledger.consume(replay, now: origin.addingTimeInterval(29.9)), "project|receipt|service|file")
        XCTAssertThrowsError(try ledger.consume(replay, now: origin.addingTimeInterval(29.9)))
        let changed = ledger.issue("project|receipt|service|file", now: origin)
        XCTAssertThrowsError(try ledger.consume(changed, expected: "changed-project|receipt|service|file", now: origin.addingTimeInterval(1)))
        XCTAssertThrowsError(try ledger.consume(changed, now: origin.addingTimeInterval(1)))
    }

    func testFileBoundaryRequiresOwnerOnlyRegularSingleLinkFile() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        try Data("DB_HOST=localhost\n".utf8).write(to: env)
        XCTAssertEqual(chmod(env.path, 0o600), 0)
        let (_, snapshot) = try ConnectionFileBoundary().inspect(env)
        XCTAssertEqual(snapshot.mode, 0o600)
        XCTAssertEqual(chmod(env.path, 0o644), 0)
        XCTAssertThrowsError(try ConnectionFileBoundary().inspect(env))
        XCTAssertEqual(chmod(env.path, 0o600), 0)
        let symbolicLink = root.appendingPathComponent("linked.env")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: env)
        XCTAssertThrowsError(try ConnectionFileBoundary().inspect(symbolicLink))
        let hardLink = root.appendingPathComponent("hardlink.env")
        XCTAssertEqual(link(env.path, hardLink.path), 0)
        XCTAssertThrowsError(try ConnectionFileBoundary().inspect(env))
    }

    func testRenameSwapKeepsDestinationAndRetainsDisplacedBytes() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let staged = root.appendingPathComponent("staged")
        try Data("approved".utf8).write(to: env)
        try Data("original".utf8).write(to: staged)
        XCTAssertEqual(chmod(env.path, 0o600), 0)
        XCTAssertEqual(chmod(staged.path, 0o600), 0)
        try ConnectionFileBoundary().swap(staged, with: env)
        XCTAssertEqual(try Data(contentsOf: env), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: staged), Data("approved".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.path))
    }

    func testTransactionCreatesPrivateSiblingRecoveryRootAndProjectDirectory() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let env = project.appendingPathComponent(".env")
        try write("reviewed", to: env)
        let recovery = root.appendingPathComponent(".vaelen-connection-recovery").appendingPathComponent(UUID().uuidString)
        let outcome = try ConnectionFileTransaction().apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: UUID())
        guard case .applied = outcome else { return XCTFail("expected apply") }
        var rootInfo = stat(); var leafInfo = stat()
        XCTAssertEqual(lstat(recovery.deletingLastPathComponent().path, &rootInfo), 0)
        XCTAssertEqual(lstat(recovery.path, &leafInfo), 0)
        XCTAssertEqual(rootInfo.st_mode & 0o777, 0o700)
        XCTAssertEqual(leafInfo.st_mode & 0o777, 0o700)
    }

    func testTransactionRejectsPathReplacementAtFinalCheckAndRetainsBothVersions() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let displaced = root.appendingPathComponent("original.saved")
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        try write("reviewed", to: env)
        XCTAssertThrowsError(try ConnectionFileTransaction().apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: UUID(), beforeFinalCheck: {
            try FileManager.default.moveItem(at: env, to: displaced)
            try self.write("external edit", to: env)
        }))
        XCTAssertEqual(try Data(contentsOf: displaced), Data("reviewed".utf8))
        XCTAssertEqual(try Data(contentsOf: env), Data("external edit".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil).contains(where: { $0.pathExtension == "stage" }))
    }

    func testTransactionCapturesLastSyscallRaceAndReconcilesCrashByBytes() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        let raced = root.appendingPathComponent("raced.saved")
        let projectID = UUID()
        try write("reviewed", to: env)
        let outcome = try ConnectionFileTransaction().apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: projectID, afterFinalCheckBeforeSwap: {
            try FileManager.default.moveItem(at: env, to: raced)
            try self.write("late external edit", to: env)
        })
        guard case .conflict(let recoveryID) = outcome else { return XCTFail("expected retained conflict") }
        XCTAssertEqual(try Data(contentsOf: env), Data("approved".utf8))
        let staged = recovery.appendingPathComponent("\(recoveryID.uuidString).stage")
        XCTAssertEqual(try Data(contentsOf: staged), Data("late external edit".utf8))
        XCTAssertEqual(try Data(contentsOf: raced), Data("reviewed".utf8))
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("\(recoveryID.uuidString).before")), Data("reviewed".utf8))
    }

    func testCrashAfterSwapReconcilesFromFileBytes() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        let projectID = UUID()
        try write("reviewed", to: env)
        XCTAssertThrowsError(try ConnectionFileTransaction().apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: projectID, afterSwap: { throw ConnectionFileError.transactionConflict }))
        let journal = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "json" }))
        XCTAssertEqual(try ConnectionFileTransaction().reconcile(destination: env, journalURL: journal), .applied(UUID(uuidString: journal.deletingPathExtension().lastPathComponent)!))
    }

    func testExplicitRestorePreservesAppliedBytesAndRetainsBeforeImage() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        let projectID = UUID()
        try write("reviewed", to: env)
        let applied = try ConnectionFileTransaction().apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: projectID)
        guard case .applied(let recoveryID) = applied else { return XCTFail("expected apply") }
        let transaction = ConnectionFileTransaction()
        XCTAssertEqual(try transaction.recoveryStatus(destination: env, recoveryDirectory: recovery).first?.state, "applied")
        XCTAssertEqual(try transaction.restore(destination: env, recoveryDirectory: recovery, recoveryID: recoveryID), .restored(recoveryID))
        XCTAssertEqual(try Data(contentsOf: env), Data("reviewed".utf8))
        XCTAssertEqual(try transaction.recoveryStatus(destination: env, recoveryDirectory: recovery).first?.state, "restored")
        XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("\(recoveryID.uuidString).before")), Data("reviewed".utf8))
    }

    func testConflictReconciliationDoesNotOverwriteCapturedNewerBytes() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        try write("reviewed", to: env)
        let outcome = try ConnectionFileTransaction().apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: UUID(), afterFinalCheckBeforeSwap: {
            try FileManager.default.moveItem(at: env, to: root.appendingPathComponent("saved"))
            try self.write("newer", to: env)
        })
        guard case .conflict = outcome else { return XCTFail("expected conflict") }
        XCTAssertEqual(try ConnectionFileTransaction().recoveryStatus(destination: env, recoveryDirectory: recovery).first?.state, "conflict")
        XCTAssertEqual(try Data(contentsOf: env), Data("approved".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil).contains(where: { $0.pathExtension == "stage" }))
    }

    func testCrashAfterRestoreSwapReconcilesAsRestored() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        let recoveryID = UUID()
        try write("reviewed", to: env)
        _ = try ConnectionFileTransaction().apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: UUID())
        let transaction = ConnectionFileTransaction()
        let applyID = try XCTUnwrap(try transaction.recoveryStatus(destination: env, recoveryDirectory: recovery).first?.id)
        XCTAssertNotEqual(applyID, recoveryID)
        XCTAssertThrowsError(try transaction.restore(destination: env, recoveryDirectory: recovery, recoveryID: applyID, afterSwap: { throw ConnectionFileError.transactionConflict }))
        XCTAssertEqual(try transaction.recoveryStatus(destination: env, recoveryDirectory: recovery).first(where: { $0.id == applyID })?.state, "restored")
        XCTAssertEqual(try Data(contentsOf: env), Data("reviewed".utf8))
    }

    func testExplicitDiscardRemovesOnlyValidatedRecoveryArtifacts() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        try write("reviewed", to: env)
        let applied = try ConnectionFileTransaction().apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: UUID())
        guard case .applied(let id) = applied else { return XCTFail("expected apply") }
        try ConnectionFileTransaction().discard(destination: env, recoveryDirectory: recovery, recoveryID: id)
        XCTAssertEqual(try Data(contentsOf: env), Data("approved".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil).isEmpty)
    }

    func testKnownRootOwnedSystemAliasRetainsTheSameFileIdentity() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        try write("secret", to: env)
        let systemAlias = URL(fileURLWithPath: String(env.path.dropFirst("/private".count)))
        XCTAssertEqual(try ConnectionFileBoundary().inspect(env).1, try ConnectionFileBoundary().inspect(systemAlias).1)
    }

    func testBoundaryRejectsAncestorSymlinkWritableParentAndFileMetadata() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let env = project.appendingPathComponent(".env")
        try write("secret", to: env)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        XCTAssertThrowsError(try ConnectionFileBoundary().inspect(alias.appendingPathComponent(".env")))
        XCTAssertEqual(chmod(project.path, 0o777), 0)
        XCTAssertThrowsError(try ConnectionFileBoundary().inspect(env))
        XCTAssertEqual(chmod(project.path, 0o700), 0)
        let payload = [UInt8](repeating: 1, count: 32)
        XCTAssertEqual(payload.withUnsafeBytes { setxattr(env.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0) }, 0)
        XCTAssertThrowsError(try ConnectionFileBoundary().inspect(env))
    }

    func testBoundaryAllowsDenyOnlyAncestorACLAndPreservesKnownDirectoryMetadata() throws {
        let root = try privateDirectory()
        let chmodTool = Process()
        chmodTool.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodTool.arguments = ["+a", "everyone deny delete", root.path]
        try chmodTool.run(); chmodTool.waitUntilExit()
        XCTAssertEqual(chmodTool.terminationStatus, 0)
        defer {
            let cleanup = Process(); cleanup.executableURL = URL(fileURLWithPath: "/bin/chmod"); cleanup.arguments = ["-N", root.path]
            try? cleanup.run(); cleanup.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        let payload = [UInt8](repeating: 1, count: 32)
        XCTAssertEqual(payload.withUnsafeBytes { setxattr(root.path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0) }, 0)
        let env = root.appendingPathComponent(".env")
        try write("secret", to: env)
        let originalEvidence = try ConnectionFileBoundary().inspect(env).1
        let transaction = ConnectionFileTransaction()
        let recovery = root.appendingPathComponent("recovery")
        _ = try transaction.apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("secret".utf8), proposedBytes: Data("new".utf8), projectID: UUID())
        XCTAssertEqual(try ConnectionFileBoundary().inspect(env).1.provenance, originalEvidence.provenance)
        var after = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(getxattr(root.path, "com.apple.FinderInfo", &after, after.count, 0, 0), 32)
        XCTAssertEqual(after, payload)
        let allow = Process(); allow.executableURL = URL(fileURLWithPath: "/bin/chmod"); allow.arguments = ["+a", "everyone allow write", root.path]
        try allow.run(); allow.waitUntilExit()
        XCTAssertEqual(allow.terminationStatus, 0)
        XCTAssertThrowsError(try ConnectionFileBoundary().inspect(env))
    }

    func testManagedDriversMapToLaravelNames() throws {
        XCTAssertEqual(try ConnectionValues.laravelDriver(managedDriver: "mysql"), "mysql")
        XCTAssertEqual(try ConnectionValues.laravelDriver(managedDriver: "postgresql"), "pgsql")
        XCTAssertThrowsError(try ConnectionValues.laravelDriver(managedDriver: "sqlite"))
    }

    func testDiscardRejectsArtifactDriftAndResumesDurableIntent() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery")
        try write("reviewed", to: env)
        let transaction = ConnectionFileTransaction()
        guard case .applied(let id) = try transaction.apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: UUID()) else { return XCTFail("apply") }
        let snapshot = try transaction.recoveryEvidence(destination: env, recoveryDirectory: recovery, recoveryID: id)
        let stage = recovery.appendingPathComponent("\(id.uuidString).stage")
        try write("new external version", to: stage)
        XCTAssertThrowsError(try transaction.discard(destination: env, recoveryDirectory: recovery, recoveryID: id, expectedEvidence: snapshot))
        XCTAssertEqual(try Data(contentsOf: stage), Data("new external version".utf8))
        let newReview = try transaction.recoveryEvidence(destination: env, recoveryDirectory: recovery, recoveryID: id)
        XCTAssertThrowsError(try transaction.discard(destination: env, recoveryDirectory: recovery, recoveryID: id, expectedEvidence: newReview, afterRemoval: { throw ConnectionFileError.transactionConflict }))
        let restarted = ConnectionFileTransaction()
        XCTAssertEqual(try restarted.recoveryStatus(destination: env, recoveryDirectory: recovery).first?.state, "discarding")
        let resumedReview = try restarted.recoveryEvidence(destination: env, recoveryDirectory: recovery, recoveryID: id)
        try restarted.discard(destination: env, recoveryDirectory: recovery, recoveryID: id, expectedEvidence: resumedReview)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
    }

    func testDiscardRetainsAnArtifactChangedAfterCapture() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery")
        try write("reviewed", to: env)
        let transaction = ConnectionFileTransaction()
        guard case .applied(let id) = try transaction.apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: UUID()) else { return XCTFail("apply") }
        let evidence = try transaction.recoveryEvidence(destination: env, recoveryDirectory: recovery, recoveryID: id)
        var captured: URL?
        XCTAssertThrowsError(try transaction.discard(destination: env, recoveryDirectory: recovery, recoveryID: id, expectedEvidence: evidence, afterCapture: { url in
            captured = url
            try self.write("new captured external edit", to: url)
        }))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(captured)), Data("new captured external edit".utf8))
    }

    func testOrphanPreparationIsVisibleAndCanBeExplicitlyDiscarded() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try write("current", to: env)
        let id = UUID()
        try write("orphan secret", to: recovery.appendingPathComponent("\(id.uuidString).before"))
        let transaction = ConnectionFileTransaction()
        XCTAssertEqual(try transaction.recoveryStatus(destination: env, recoveryDirectory: recovery).first?.state, "interruptedPreparation")
        let evidence = try transaction.recoveryEvidence(destination: env, recoveryDirectory: recovery, recoveryID: id)
        try transaction.discard(destination: env, recoveryDirectory: recovery, recoveryID: id, expectedEvidence: evidence)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recovery.path).isEmpty)
    }

    func testFIFOIsRefusedWithoutWaitingForAWriter() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent(".env")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let finished = expectation(description: "FIFO inspection returns")
        DispatchQueue.global().async {
            do { _ = try ConnectionFileBoundary().inspect(fifo); XCTFail("FIFO accepted") } catch {}
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
    }

    func testSecondTransactionIsRefusedUntilRecoveryIsDiscarded() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery")
        try write("reviewed", to: env)
        let transaction = ConnectionFileTransaction()
        _ = try transaction.apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: UUID())
        XCTAssertThrowsError(try transaction.apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("approved".utf8), proposedBytes: Data("second".utf8), projectID: UUID()))
        XCTAssertEqual(try Data(contentsOf: env), Data("approved".utf8))
    }

    func testRestoreRejectsChangedBeforeImageAndDetectsPostSwapWrite() throws {
        let root = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        let recovery = root.appendingPathComponent("recovery")
        try write("reviewed", to: env)
        let transaction = ConnectionFileTransaction()
        guard case .applied(let id) = try transaction.apply(destination: env, recoveryDirectory: recovery, reviewedBytes: Data("reviewed".utf8), proposedBytes: Data("approved".utf8), projectID: UUID()) else { return XCTFail("apply") }
        let before = recovery.appendingPathComponent("\(id.uuidString).before")
        try write("tampered", to: before)
        XCTAssertThrowsError(try transaction.restore(destination: env, recoveryDirectory: recovery, recoveryID: id))
        XCTAssertEqual(try Data(contentsOf: env), Data("approved".utf8))
        try write("reviewed", to: before)
        XCTAssertEqual(try transaction.restore(destination: env, recoveryDirectory: recovery, recoveryID: id, afterSwap: { try self.write("external", to: env) }), .conflict(id))
    }

    private func privateDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
}
