import XCTest
import Security
@testable import VaelenCore

final class TLSCapabilityTests: XCTestCase {
    func testLocalNamespaceRejectsPublicNames() throws {
        XCTAssertEqual(try LocalTLSNamespace.validate("api.SyncProof.TEST"), "api.syncproof.test")
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
