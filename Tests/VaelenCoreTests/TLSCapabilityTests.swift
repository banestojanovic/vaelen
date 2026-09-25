import XCTest
import Security
import CryptoKit
@testable import VaelenCore

final class TLSCapabilityTests: XCTestCase {
    private final class FakeTrustBoundary: @unchecked Sendable, TLSTrustBoundary {
        var trusted = false
        var unsupported = false
        var failObservation = false
        var failAfterTrust = false
        var failTrust = false
        var failRemove = false
        var fingerprintOverride: String?
        var trustCalls = 0
        var removeCalls = 0

        func observe(certificateData: Data) throws -> LocalCATrustService.Observation {
            if failObservation || (failAfterTrust && trusted) { throw TLSError.trustObservationFailed("injected") }
            if unsupported { throw TLSError.trustSettingsUnsupported }
            if trusted {
                return .init(trusted: true, canonical: "trust:empty-array", fingerprint: fingerprintOverride ?? "empty-fingerprint")
            }
            return .init(trusted: false, canonical: "trust:nil", fingerprint: nil)
        }

        func trust(certificateData: Data) throws {
            trustCalls += 1
            if failTrust { throw TLSError.keychain(errSecAuthFailed) }
            trusted = true
        }

        func removeTrust(certificateData: Data) throws {
            removeCalls += 1
            if failRemove { throw TLSError.keychain(errSecAuthFailed) }
            trusted = false
        }
    }

    private func makeCapability(fake: FakeTrustBoundary) throws -> (TLSCapability, SQLiteStateStore, LocalCAKeychain, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-m13-") .appendingPathComponent(UUID().uuidString)
        let layout = VaelenFilesystemLayout(rootURL: root)
        let store = try SQLiteStateStore(databaseURL: root.appendingPathComponent("state.sqlite"))
        let keychain = LocalCAKeychain(tag: "dev.vaelen.m13.\(UUID().uuidString)")
        let capability = TLSCapability(layout: layout, store: store, keychain: keychain, trustBoundary: fake)
        return (capability, store, keychain, root)
    }

    private func makeLegacyTLSDatabase(active: Int, withRow: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-m13-migration-").appendingPathComponent(UUID().uuidString)
        let database = root.appendingPathComponent("state.sqlite")
        do {
            let store = try SQLiteStateStore(databaseURL: database)
            try store.execute("DROP TABLE tls_capability")
            try store.execute("CREATE TABLE tls_capability (id INTEGER PRIMARY KEY CHECK (id = 1), ca_fingerprint TEXT NOT NULL, ca_certificate_path TEXT NOT NULL, active INTEGER NOT NULL)")
            if withRow {
                try store.execute("INSERT INTO tls_capability VALUES (1, 'legacy-fingerprint', '/legacy/ca.der', \(active))")
            }
            try store.execute("PRAGMA user_version = 5")
        }
        return database
    }

    func testSchemaFiveTLSMigrationNeverFabricatesTrustOrOwnership() throws {
        for active in [0, 1] {
            let database = try makeLegacyTLSDatabase(active: active, withRow: true)
            defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
            let store = try SQLiteStateStore(databaseURL: database)
            XCTAssertEqual(try store.pragmaVersion(), 6)
            let record = try XCTUnwrap(try store.tlsRecord())
            XCTAssertEqual(record.fingerprint, "legacy-fingerprint")
            XCTAssertEqual(record.certificatePath, "/legacy/ca.der")
            XCTAssertEqual(record.ownership, .unverified)
            XCTAssertEqual(record.trustDomain, "user")
            XCTAssertEqual(record.trustProvenance, .none)
            XCTAssertNil(record.publicKeyFingerprint)
            XCTAssertNil(record.trustSettingsFingerprint)
            let reopened = try SQLiteStateStore(databaseURL: database)
            XCTAssertEqual(try reopened.pragmaVersion(), 6)
            XCTAssertEqual(try reopened.tlsRecord(), record)
        }
    }

    func testSchemaFiveTLSMigrationWithNoRowRemainsEmptyAndIdempotent() throws {
        let database = try makeLegacyTLSDatabase(active: 1, withRow: false)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }
        let store = try SQLiteStateStore(databaseURL: database)
        XCTAssertEqual(try store.pragmaVersion(), 6)
        XCTAssertNil(try store.tlsRecord())
        let reopened = try SQLiteStateStore(databaseURL: database)
        XCTAssertEqual(try reopened.pragmaVersion(), 6)
        XCTAssertNil(try reopened.tlsRecord())
    }

    func testMalformedSchemaFiveTLSMigrationRollsBackAndDoesNotFabricateState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-m13-malformed-migration-").appendingPathComponent(UUID().uuidString)
        let database = root.appendingPathComponent("state.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let store = try SQLiteStateStore(databaseURL: database)
            try store.execute("DROP TABLE tls_capability")
            try store.execute("PRAGMA user_version = 5")
        }
        XCTAssertThrowsError(try SQLiteStateStore(databaseURL: database))
        XCTAssertThrowsError(try SQLiteStateStore(databaseURL: database))
    }

    func testTrustSuccessPersistsConfirmationUsingInjectedBoundary() async throws {
        let fake = FakeTrustBoundary()
        let (capability, store, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        let result = try await capability.trustLocalCA()
        XCTAssertEqual(result.operation, .confirmed)
        XCTAssertEqual(try store.tlsRecord()?.trustProvenance, .confirmedByVaelen)
        XCTAssertEqual(fake.trustCalls, 1)
    }

    func testTrustCannotReportSuccessWithoutDurableStore() async throws {
        let fake = FakeTrustBoundary()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-m13-no-store-").appendingPathComponent(UUID().uuidString)
        let keychain = LocalCAKeychain(tag: "dev.vaelen.m13.\(UUID().uuidString)")
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        let capability = TLSCapability(layout: VaelenFilesystemLayout(rootURL: root), store: nil, keychain: keychain, trustBoundary: fake)
        _ = try await capability.install()
        do { _ = try await capability.trustLocalCA(); XCTFail("trust succeeded without durable provenance storage") } catch { }
        XCTAssertEqual(fake.trustCalls, 0)
    }

    func testExactDERFingerprintAndBindingAreRequired() async throws {
        let fake = FakeTrustBoundary()
        let (capability, store, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        let caURL = root.appendingPathComponent("tls/certificates/ca.der")
        let data = try Data(contentsOf: caURL)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let initialStatus = await capability.status()
        XCTAssertEqual(initialStatus.caFingerprint, expected)

        var error: Unmanaged<CFError>?
        let foreignKey = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error))
        try LocalCertificateBuilder.ca(key: foreignKey).write(to: caURL, options: .atomic)
        do { _ = try await capability.trustLocalCA(); XCTFail("foreign certificate unexpectedly trusted") } catch let error as TLSError { XCTAssertEqual(error, .keyCertificateMismatch) }
        XCTAssertEqual(fake.trustCalls, 0)
        let foreignStatus = await capability.status()
        XCTAssertEqual(foreignStatus.state, .ownershipMismatch)
        XCTAssertNotNil(try store.tlsRecord())
    }

    func testPersistedOwnershipMismatchCannotBeAdopted() async throws {
        let fake = FakeTrustBoundary()
        let (capability, store, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        let record = try XCTUnwrap(try store.tlsRecord())
        try store.saveTLSRecord(.init(fingerprint: record.fingerprint, certificatePath: record.certificatePath, keyApplicationTag: record.keyApplicationTag, publicKeyFingerprint: record.publicKeyFingerprint, ownership: .mismatch, trustDomain: record.trustDomain, trustProvenance: .none, trustSettingsFingerprint: nil))
        let mismatchStatus = await capability.status()
        XCTAssertEqual(mismatchStatus.state, .ownershipMismatch)
        do { _ = try await capability.trustLocalCA(); XCTFail("persisted mismatch was adopted") } catch let error as TLSError { XCTAssertEqual(error, .ownershipMismatch) }
        XCTAssertEqual(fake.trustCalls, 0)
    }

    func testMalformedOrMissingManagedIdentityFailsClosed() async throws {
        let fake = FakeTrustBoundary()
        let (capability, _, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        let caURL = root.appendingPathComponent("tls/certificates/ca.der")
        let original = try Data(contentsOf: caURL)
        try Data("not-a-certificate".utf8).write(to: caURL, options: .atomic)
        do { _ = try await capability.trustLocalCA(); XCTFail("malformed certificate unexpectedly trusted") } catch { }
        XCTAssertEqual(fake.trustCalls, 0)

        try original.write(to: caURL, options: .atomic)
        try keychain.removeCAKey()
        do { _ = try await capability.trustLocalCA(); XCTFail("missing key unexpectedly trusted") } catch { }
        XCTAssertEqual(fake.trustCalls, 0)
    }

    func testTrustFailuresNeverPersistProvenance() async throws {
        for failure in [0, 1] {
            let fake = FakeTrustBoundary()
            fake.failTrust = failure == 0
            fake.failAfterTrust = failure == 1
            let (capability, store, keychain, root) = try makeCapability(fake: fake)
            defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
            _ = try await capability.install()
            do { _ = try await capability.trustLocalCA(); XCTFail("trust unexpectedly succeeded") } catch { }
            XCTAssertEqual(try store.tlsRecord()?.trustProvenance, TLSDurableTrustProvenance.none)
        }
    }

    func testAlreadyTrustedIsNotAdopted() async throws {
        let fake = FakeTrustBoundary(); fake.trusted = true
        let (capability, store, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        let result = try await capability.trustLocalCA()
        XCTAssertEqual(result.operation, .alreadyTrustedUnknownProvenance)
        XCTAssertEqual(try store.tlsRecord()?.trustProvenance, TLSDurableTrustProvenance.none)
        XCTAssertEqual(fake.trustCalls, 0)
    }

    func testRemovalRequiresExactRecordedSettingsAndPreservesMaterial() async throws {
        let fake = FakeTrustBoundary()
        let (capability, store, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        _ = try await capability.trustLocalCA()
        fake.unsupported = true
        do { _ = try await capability.removeLocalCATrust(); XCTFail("removal unexpectedly succeeded") } catch { }
        XCTAssertEqual(fake.removeCalls, 0)
        XCTAssertNotNil(try keychain.existingCAKey())
        XCTAssertNotNil(try store.tlsRecord())
    }

    func testRemovalSettingsMismatchAndProviderFailureRetainAuthority() async throws {
        let fake = FakeTrustBoundary()
        let (capability, store, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        _ = try await capability.trustLocalCA()
        fake.fingerprintOverride = "different-settings"
        do { _ = try await capability.removeLocalCATrust(); XCTFail("settings mismatch unexpectedly removed trust") } catch let error as TLSError { XCTAssertEqual(error, .trustSettingsMismatch) }
        XCTAssertEqual(fake.removeCalls, 0)
        fake.fingerprintOverride = nil
        fake.failRemove = true
        do { _ = try await capability.removeLocalCATrust(); XCTFail("failed removal unexpectedly succeeded") } catch { }
        XCTAssertEqual(try store.tlsRecord()?.trustProvenance, TLSDurableTrustProvenance.confirmedByVaelen)
        XCTAssertEqual(fake.removeCalls, 1)
    }

    func testPersistenceFailureAfterTrustOrRemovalDoesNotFabricateCompletion() async throws {
        let fake = FakeTrustBoundary()
        let (capability, store, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        try store.execute("PRAGMA query_only = 1")
        do { _ = try await capability.trustLocalCA(); XCTFail("trust unexpectedly persisted on read-only store") } catch { }
        XCTAssertEqual(fake.trustCalls, 1)
        XCTAssertEqual(try store.tlsRecord()?.trustProvenance, TLSDurableTrustProvenance.none)

        let fakeRemoval = FakeTrustBoundary()
        let (removalCapability, removalStore, removalKeychain, removalRoot) = try makeCapability(fake: fakeRemoval)
        defer { try? removalKeychain.removeCAKey(); try? FileManager.default.removeItem(at: removalRoot) }
        _ = try await removalCapability.install()
        _ = try await removalCapability.trustLocalCA()
        try removalStore.execute("PRAGMA query_only = 1")
        do { _ = try await removalCapability.removeLocalCATrust(); XCTFail("removal unexpectedly persisted on read-only store") } catch { }
        XCTAssertEqual(fakeRemoval.removeCalls, 1)
        XCTAssertEqual(try removalStore.tlsRecord()?.trustProvenance, TLSDurableTrustProvenance.confirmedByVaelen)
    }

    func testRemovalSuccessClearsProvenanceWithoutDeletingMaterial() async throws {
        let fake = FakeTrustBoundary()
        let (capability, store, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        let path = root.appendingPathComponent("tls/certificates/ca.der")
        _ = try await capability.trustLocalCA()
        _ = try await capability.removeLocalCATrust()
        XCTAssertEqual(try store.tlsRecord()?.trustProvenance, TLSDurableTrustProvenance.none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertNotNil(try keychain.existingCAKey())
        XCTAssertEqual(fake.removeCalls, 1)
    }

    func testRestartCrashWindowsDoNotAdoptOrRepeatTrustMutation() async throws {
        let fake = FakeTrustBoundary()
        let (capability, store, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        fake.trusted = true // external success, before provenance persistence
        let restarted = TLSCapability(layout: VaelenFilesystemLayout(rootURL: root), store: store, keychain: keychain, trustBoundary: fake)
        let restartedStatus = await restarted.status()
        XCTAssertEqual(restartedStatus.trustProvenance, TLSTrustProvenance.none)
        do { _ = try await restarted.removeLocalCATrust(); XCTFail("removal unexpectedly succeeded") } catch { }
        XCTAssertEqual(fake.removeCalls, 0)

        fake.trusted = false
        _ = try await capability.trustLocalCA()
        fake.trusted = false // removal success, before provenance clear
        let restartedAfterRemoval = TLSCapability(layout: VaelenFilesystemLayout(rootURL: root), store: store, keychain: keychain, trustBoundary: fake)
        _ = try await restartedAfterRemoval.removeLocalCATrust()
        XCTAssertEqual(try store.tlsRecord()?.trustProvenance, TLSDurableTrustProvenance.none)
        XCTAssertEqual(fake.removeCalls, 0)
    }

    func testActorSerializesConcurrentTrustRequests() async throws {
        let fake = FakeTrustBoundary()
        let (capability, _, keychain, root) = try makeCapability(fake: fake)
        defer { try? keychain.removeCAKey(); try? FileManager.default.removeItem(at: root) }
        _ = try await capability.install()
        async let first = capability.trustLocalCA()
        async let second = capability.trustLocalCA()
        let results = try await [first, second]
        XCTAssertEqual(results.filter { $0.operation == .confirmed }.count, 2)
        XCTAssertEqual(fake.trustCalls, 1)
    }
    func testLocalNamespaceRejectsPublicNames() throws {
        XCTAssertEqual(try LocalTLSNamespace.validate("api.SyncProof.TEST"), "api.syncproof.test")
        XCTAssertEqual(try LocalTLSNamespace.validate("*.CallTheWaiter.TEST"), "*.callthewaiter.test")
        for name in ["*.*.test", "api.*.test", "*.com"] { XCTAssertThrowsError(try LocalTLSNamespace.validate(name)) }
        for name in ["google.com", "github.com", "apple.com", "example.com"] { XCTAssertThrowsError(try LocalTLSNamespace.validate(name)) }
    }

    func testGeneratedCAAndLeafAreParseableCertificates() throws {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let caKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let leafKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let ca = try LocalCertificateBuilder.ca(key: caKey)
        let leaf = try LocalCertificateBuilder.leaf(hostname: "syncproof.test", key: leafKey, issuer: "Vaelen Local CA", issuerKey: caKey)
        XCTAssertNotNil(SecCertificateCreateWithData(nil, ca as CFData))
        XCTAssertNotNil(SecCertificateCreateWithData(nil, leaf as CFData))
    }

    func testInstalledLeafUsesNativeHostnameTrustEvaluation() throws {
        let layout = VaelenFilesystemLayout()
        let leafURL = layout.tlsLeafDirectoryURL.appendingPathComponent("syncproof_test.crt")
        let caURL = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        guard FileManager.default.fileExists(atPath: leafURL.path), FileManager.default.fileExists(atPath: caURL.path) else {
            throw XCTSkip("installed TLS acceptance material is unavailable")
        }
        let leaf = try Data(contentsOf: leafURL)
        let ca = try Data(contentsOf: caURL)
        let (trusted, error) = LocalCATrustService().evaluateServerTrustResult(leafData: leaf, caData: ca, hostname: "syncproof.test")
        XCTAssertTrue(trusted, "native trust failed: \(error ?? "unknown")")
    }

    func testIssueLeafReusesExistingMaterial() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VaelenFilesystemLayout(rootURL: root)
        let keychain = LocalCAKeychain(tag: "dev.vaelen.test.\(UUID().uuidString)")
        defer { try? keychain.removeCAKey() }
        let capability = TLSCapability(layout: layout, keychain: keychain)
        _ = try await capability.install()
        let first = try await capability.issueLeaf(hostname: "syncproof.test")
        let certificate = try Data(contentsOf: first.certificateURL)
        let privateKey = try Data(contentsOf: first.keyURL)
        let second = try await capability.issueLeaf(hostname: "syncproof.test")
        XCTAssertEqual(second.certificateURL, first.certificateURL)
        XCTAssertEqual(second.keyURL, first.keyURL)
        XCTAssertEqual(try Data(contentsOf: second.certificateURL), certificate)
        XCTAssertEqual(try Data(contentsOf: second.keyURL), privateKey)
    }
}
