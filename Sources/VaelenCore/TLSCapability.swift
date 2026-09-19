import Foundation
import Security
import CryptoKit

public enum TLSCapabilityState: String, Codable, Sendable { case absent, createdButUntrusted, trusted, unhealthy, ownershipMismatch }
public enum TLSOwnershipState: String, Codable, Sendable { case unverified, owned, mismatch }
public enum TLSTrustProvenance: String, Codable, Sendable { case none, confirmedByVaelen }
public enum TLSTrustOperationState: String, Codable, Sendable { case trusted, alreadyTrustedUnknownProvenance, confirmed, untrusted, removed }
public struct TLSStatus: Codable, Equatable, Sendable {
    public let state: TLSCapabilityState
    public let caFingerprint: String?
    public let caCertificatePath: String?
    public let trustObserved: Bool
    public let tlsPort: Int
    public let detail: String?
    public let ownership: TLSOwnershipState
    public let trustProvenance: TLSTrustProvenance
    public let trustSettingsFingerprint: String?
    public init(state: TLSCapabilityState, caFingerprint: String? = nil, caCertificatePath: String? = nil, trustObserved: Bool = false, tlsPort: Int = VaelenNetworkPorts.httpsBackend, detail: String? = nil, ownership: TLSOwnershipState = .unverified, trustProvenance: TLSTrustProvenance = .none, trustSettingsFingerprint: String? = nil) { self.state = state; self.caFingerprint = caFingerprint; self.caCertificatePath = caCertificatePath; self.trustObserved = trustObserved; self.tlsPort = tlsPort; self.detail = detail; self.ownership = ownership; self.trustProvenance = trustProvenance; self.trustSettingsFingerprint = trustSettingsFingerprint }
}
public struct TLSTrustResult: Codable, Equatable, Sendable {
    public let status: TLSStatus
    public let operation: TLSTrustOperationState
    public let message: String
    public init(status: TLSStatus, operation: TLSTrustOperationState, message: String) { self.status = status; self.operation = operation; self.message = message }
}

public enum TLSError: Error, Equatable, Sendable { case unsupportedHostname(String), keychain(OSStatus), certificate(String), ownershipMismatch, unavailable, keyCertificateMismatch, trustProvenanceUnavailable, trustSettingsMismatch, trustObservationFailed(String), trustSettingsUnsupported, trustRemovalUnverified }

extension TLSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedHostname(let hostname): return "Unsupported TLS hostname: \(hostname)"
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "Keychain error \(status): \(message)"
        case .certificate(let detail): return "Certificate error: \(detail)"
        case .ownershipMismatch: return "Vaelen TLS ownership mismatch"
        case .unavailable: return "Vaelen TLS is unavailable"
        case .keyCertificateMismatch: return "Vaelen TLS certificate and private-key identities do not match"
        case .trustProvenanceUnavailable: return "Vaelen TLS trust provenance is unavailable"
        case .trustSettingsMismatch: return "Vaelen TLS trust settings do not match recorded Vaelen state"
        case .trustObservationFailed(let detail): return "Unable to observe Vaelen TLS trust: \(detail)"
        case .trustSettingsUnsupported: return "Vaelen TLS trust settings are unsupported or ambiguous"
        case .trustRemovalUnverified: return "Vaelen TLS trust removal was not verified"
        }
    }
}

public enum LocalTLSNamespace {
    public static func validate(_ hostname: String) throws -> String {
        let value = hostname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !value.isEmpty, value.count <= 253, value.hasSuffix(".test"), !value.contains(".."), value.split(separator: ".").allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { throw TLSError.unsupportedHostname(hostname) }
        return value
    }
}

public struct TLSCertificateMaterial: Sendable {
    public let certificate: Data
    public let privateKey: Data
    public init(certificate: Data, privateKey: Data) { self.certificate = certificate; self.privateKey = privateKey }
}
public struct TLSLeafMaterial: Sendable { public let certificateURL: URL; public let keyURL: URL; public init(certificateURL: URL, keyURL: URL) { self.certificateURL = certificateURL; self.keyURL = keyURL } }

public final class LocalCAKeychain: @unchecked Sendable {
    private let tag: Data
    public init(tag: String = "dev.vaelen.local-ca") { self.tag = Data(tag.utf8) }
    internal var applicationTag: String { String(decoding: tag, as: UTF8.self) }

    public func caKey() throws -> SecKey {
        let query: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecReturnRef: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let key = item as! SecKey? { return key }
        guard status == errSecItemNotFound else { throw TLSError.keychain(status) }
        var error: Unmanaged<CFError>?
        let parameters: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsExtractable: false, kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: tag, kSecAttrIsExtractable: false]]
        guard let key = SecKeyCreateRandomKey(parameters as CFDictionary, &error) else { throw TLSError.certificate((error?.takeRetainedValue() as Error?)?.localizedDescription ?? "CA key generation failed") }
        return key
    }
    public func existingCAKey() throws -> SecKey {
        let query: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecReturnRef: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let key = item as! SecKey? else { throw TLSError.keychain(status) }
        return key
    }
    public func removeCAKey() throws { let status = SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecAttrKeyType: kSecAttrKeyTypeRSA] as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw TLSError.keychain(status) } }
}

internal protocol TLSTrustBoundary: Sendable {
    func observe(certificateData: Data) throws -> LocalCATrustService.Observation
    func trust(certificateData: Data) throws
    func removeTrust(certificateData: Data) throws
}

public final class LocalCATrustService: @unchecked Sendable, TLSTrustBoundary {
    public init() {}
    internal struct Observation: Equatable, Sendable {
        let trusted: Bool
        let canonical: String
        let fingerprint: String?
    }
    public func isTrusted(certificateData: Data) -> Bool {
        (try? observe(certificateData: certificateData).trusted) == true
    }
    internal func observe(certificateData: Data) throws -> Observation {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else { throw TLSError.certificate("invalid CA certificate") }
        var settings: CFArray?
        let status = SecTrustSettingsCopyTrustSettings(certificate, .user, &settings)
        if status == errSecItemNotFound { return Observation(trusted: false, canonical: "trust:nil", fingerprint: nil) }
        guard status == errSecSuccess else { throw TLSError.trustObservationFailed("OSStatus \(status)") }
        guard let settings else { throw TLSError.trustSettingsUnsupported }
        guard CFArrayGetCount(settings) == 0 else { throw TLSError.trustSettingsUnsupported }
        let canonical = "trust:empty-array"
        return Observation(trusted: true, canonical: canonical, fingerprint: Self.digest(canonical))
    }
    public func evaluateServerTrust(leafData: Data, caData: Data, hostname: String) -> Bool {
        evaluateServerTrustResult(leafData: leafData, caData: caData, hostname: hostname).trusted
    }
    public func evaluateServerTrustResult(leafData: Data, caData: Data, hostname: String) -> (trusted: Bool, error: String?) {
        guard let leaf = SecCertificateCreateWithData(nil, der(leafData) as CFData),
              let ca = SecCertificateCreateWithData(nil, der(caData) as CFData) else { return (false, "invalid certificate data") }
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, ca] as CFArray, policy, &trust) == errSecSuccess,
              let trust else { return (false, "unable to create trust object") }
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        let detail = error.map { CFErrorCopyDescription($0) as String? ?? "unknown" }
        return (trusted, trusted ? nil : detail)
    }
    public func trust(certificateData: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else { throw TLSError.certificate("invalid CA certificate") }
        let addStatus = SecCertificateAddToKeychain(certificate, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else { throw TLSError.keychain(addStatus) }
        let settings = [] as CFArray
        let status = SecTrustSettingsSetTrustSettings(certificate, .user, settings)
        guard status == errSecSuccess else { throw TLSError.keychain(status) }
    }
    public func removeTrust(certificateData: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else { throw TLSError.certificate("invalid CA certificate") }
        let status = SecTrustSettingsRemoveTrustSettings(certificate, .user)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TLSError.keychain(status) }
    }

    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func keychainCertificate(_ certificateData: Data) -> SecCertificate? {
        var item: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecValueData: certificateData, kSecReturnRef: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecCertificate)
    }
    private func der(_ data: Data) -> Data {
        if SecCertificateCreateWithData(nil, data as CFData) != nil { return data }
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let lines = text.components(separatedBy: .newlines).filter { !$0.contains("BEGIN") && !$0.contains("END") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty, let decoded = Data(base64Encoded: lines.joined()) else { return data }
        return decoded
    }
}

public actor TLSCapability {
    public let layout: VaelenFilesystemLayout
    public let tlsPort: Int
    private let keychain: LocalCAKeychain
    private let trust: any TLSTrustBoundary
    private let store: SQLiteStateStore?
    public init(layout: VaelenFilesystemLayout = .init(), store: SQLiteStateStore? = nil, tlsPort: Int = VaelenNetworkPorts.httpsBackend, keychain: LocalCAKeychain = .init(), trust: LocalCATrustService = .init()) { self.layout = layout; self.store = store; self.tlsPort = tlsPort; self.keychain = keychain; self.trust = trust }
    internal init(layout: VaelenFilesystemLayout, store: SQLiteStateStore?, tlsPort: Int = VaelenNetworkPorts.httpsBackend, keychain: LocalCAKeychain, trustBoundary: any TLSTrustBoundary) { self.layout = layout; self.store = store; self.tlsPort = tlsPort; self.keychain = keychain; self.trust = trustBoundary }
    public func status() -> TLSStatus {
        let path = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        guard FileManager.default.fileExists(atPath: path.path) else { return TLSStatus(state: .absent, tlsPort: tlsPort) }
        let context: ManagedContext
        do {
            context = try managedContext(path: path)
        } catch let error as TLSError {
            let state: TLSCapabilityState = (error == .ownershipMismatch || error == .keyCertificateMismatch) ? .ownershipMismatch : .unhealthy
            return TLSStatus(state: state, caCertificatePath: path.path, tlsPort: tlsPort, detail: error.localizedDescription, ownership: state == .ownershipMismatch ? .mismatch : .unverified)
        } catch {
            return TLSStatus(state: .unhealthy, caCertificatePath: path.path, tlsPort: tlsPort, detail: error.localizedDescription)
        }
        let ownership: TLSOwnershipState = context.record.ownership == .owned ? .owned : .mismatch
        let provenance: TLSTrustProvenance = context.record.trustProvenance == .confirmedByVaelen ? .confirmedByVaelen : .none
        guard let observation = try? trust.observe(certificateData: context.certificateData) else { return TLSStatus(state: .unhealthy, caFingerprint: context.fingerprint, caCertificatePath: path.path, tlsPort: tlsPort, detail: "TLS trust settings are unavailable or unsupported", ownership: ownership, trustProvenance: provenance) }
        return TLSStatus(state: observation.trusted ? .trusted : .createdButUntrusted, caFingerprint: context.fingerprint, caCertificatePath: path.path, trustObserved: observation.trusted, tlsPort: tlsPort, ownership: ownership, trustProvenance: provenance, trustSettingsFingerprint: observation.fingerprint)
    }
    public func install() throws -> TLSStatus {
        let key = try keychain.caKey()
        let path = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.path) { try LocalCertificateBuilder.ca(key: key).write(to: path, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }
        return status()
    }

    public func trustLocalCA() throws -> TLSTrustResult {
        guard store != nil else { throw TLSError.unavailable }
        let path = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        let context = try managedContext(path: path)
        let before = try trust.observe(certificateData: context.certificateData)
        if before.trusted {
            let provenance: TLSTrustProvenance = context.record.trustProvenance == .confirmedByVaelen ? .confirmedByVaelen : .none
            let status = TLSStatus(state: .trusted, caFingerprint: context.fingerprint, caCertificatePath: path.path, trustObserved: true, tlsPort: tlsPort, ownership: .owned, trustProvenance: provenance, trustSettingsFingerprint: before.fingerprint)
            return TLSTrustResult(status: status, operation: context.record.trustProvenance == .confirmedByVaelen ? .confirmed : .alreadyTrustedUnknownProvenance, message: context.record.trustProvenance == .confirmedByVaelen ? "Vaelen Local CA is already trusted." : "Vaelen Local CA is already trusted, but trust provenance is unknown.")
        }
        try trust.trust(certificateData: context.certificateData)
        let after = try trust.observe(certificateData: context.certificateData)
        guard after.trusted, let settingsFingerprint = after.fingerprint else { throw TLSError.trustObservationFailed("trust did not produce the expected user trust settings") }
        let confirmed = TLSDurableRecord(fingerprint: context.fingerprint, certificatePath: path.path, keyApplicationTag: keychain.applicationTag, publicKeyFingerprint: context.publicKeyFingerprint, ownership: .owned, trustDomain: "user", trustProvenance: .confirmedByVaelen, trustSettingsFingerprint: settingsFingerprint)
        try store?.saveTLSRecord(confirmed)
        let status = TLSStatus(state: .trusted, caFingerprint: context.fingerprint, caCertificatePath: path.path, trustObserved: true, tlsPort: tlsPort, ownership: .owned, trustProvenance: .confirmedByVaelen, trustSettingsFingerprint: settingsFingerprint)
        return TLSTrustResult(status: status, operation: .confirmed, message: "Vaelen Local CA trust was confirmed through Core.")
    }

    public func removeLocalCATrust() throws -> TLSTrustResult {
        guard store != nil else { throw TLSError.unavailable }
        let path = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        let context = try managedContext(path: path)
        guard context.record.trustProvenance == .confirmedByVaelen else { throw TLSError.trustProvenanceUnavailable }
        let before = try trust.observe(certificateData: context.certificateData)
        guard before.trusted else {
            let cleared = TLSDurableRecord(fingerprint: context.fingerprint, certificatePath: path.path, keyApplicationTag: keychain.applicationTag, publicKeyFingerprint: context.publicKeyFingerprint, ownership: .owned, trustDomain: "user", trustProvenance: .none, trustSettingsFingerprint: nil)
            try store?.saveTLSRecord(cleared)
            let status = TLSStatus(state: .createdButUntrusted, caFingerprint: context.fingerprint, caCertificatePath: path.path, trustObserved: false, tlsPort: tlsPort, ownership: .owned, trustProvenance: .none)
            return TLSTrustResult(status: status, operation: .untrusted, message: "Vaelen Local CA was already untrusted; stale provenance was cleared.")
        }
        guard before.fingerprint == context.record.trustSettingsFingerprint else { throw TLSError.trustSettingsMismatch }
        try trust.removeTrust(certificateData: context.certificateData)
        let after = try trust.observe(certificateData: context.certificateData)
        guard !after.trusted else { throw TLSError.trustRemovalUnverified }
        let cleared = TLSDurableRecord(fingerprint: context.fingerprint, certificatePath: path.path, keyApplicationTag: keychain.applicationTag, publicKeyFingerprint: context.publicKeyFingerprint, ownership: .owned, trustDomain: "user", trustProvenance: .none, trustSettingsFingerprint: nil)
        try store?.saveTLSRecord(cleared)
        let status = TLSStatus(state: .createdButUntrusted, caFingerprint: context.fingerprint, caCertificatePath: path.path, trustObserved: false, tlsPort: tlsPort, ownership: .owned, trustProvenance: .none)
        return TLSTrustResult(status: status, operation: .removed, message: "Vaelen Local CA trust was removed through Core.")
    }
    public func remove() throws -> TLSStatus {
        let path = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        if let data = try? Data(contentsOf: path), (try? trust.observe(certificateData: data).trusted) == true { throw TLSError.ownershipMismatch }
        try? FileManager.default.removeItem(at: path); try keychain.removeCAKey()
        return status()
    }
    public func issueLeaf(hostname: String) throws -> TLSLeafMaterial {
        let hostname = try LocalTLSNamespace.validate(hostname)
        let base = layout.tlsLeafDirectoryURL.appendingPathComponent(hostname.replacingOccurrences(of: ".", with: "_"))
        let certURL = base.appendingPathExtension("crt")
        let keyURL = base.appendingPathExtension("key")
        if let certificateData = try? Data(contentsOf: certURL),
           SecCertificateCreateWithData(nil, Self.derCertificateData(certificateData) as CFData) != nil,
           let privateKeyData = try? Data(contentsOf: keyURL), !privateKeyData.isEmpty {
            return TLSLeafMaterial(certificateURL: certURL, keyURL: keyURL)
        }
        let caPath = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        guard let caData = try? Data(contentsOf: caPath), SecCertificateCreateWithData(nil, caData as CFData) != nil else { throw TLSError.unavailable }
        let caKey = try keychain.caKey(); var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let leafKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw TLSError.certificate("leaf key generation failed") }
        let certificate = try LocalCertificateBuilder.leaf(hostname: hostname, key: leafKey, issuer: "Vaelen Local CA", issuerKey: caKey)
        guard let privateData = SecKeyCopyExternalRepresentation(leafKey, nil) as Data? else { throw TLSError.certificate("leaf key export failed") }
        try FileManager.default.createDirectory(at: layout.tlsLeafDirectoryURL, withIntermediateDirectories: true)
        try Data(pem: certificate, label: "CERTIFICATE").write(to: certURL, options: .atomic); try Data(pem: privateData, label: "RSA PRIVATE KEY").write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certURL.path)
        return TLSLeafMaterial(certificateURL: certURL, keyURL: keyURL)
    }

    private struct ManagedContext {
        let certificateData: Data
        let fingerprint: String
        let publicKeyFingerprint: String
        let record: TLSDurableRecord
    }

    private func managedContext(path: URL) throws -> ManagedContext {
        guard let certificateData = try? Data(contentsOf: path), let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else { throw TLSError.unavailable }
        let fingerprint = Self.digest(certificateData)
        let key = try keychain.existingCAKey()
        guard let certificateKey = SecCertificateCopyKey(certificate), let publicKey = SecKeyCopyPublicKey(key), let certificatePublic = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?, let managedPublic = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, certificatePublic == managedPublic else { throw TLSError.keyCertificateMismatch }
        let publicKeyFingerprint = Self.digest(managedPublic)
        let existing = try store?.tlsRecord()
        if let existing {
            guard existing.trustDomain == "user", existing.fingerprint == fingerprint, existing.certificatePath == path.path, existing.keyApplicationTag == keychain.applicationTag, existing.publicKeyFingerprint == nil || existing.publicKeyFingerprint == publicKeyFingerprint else { throw TLSError.ownershipMismatch }
            guard existing.ownership != .mismatch else { throw TLSError.ownershipMismatch }
            let owned = existing.ownership == .owned ? existing : TLSDurableRecord(fingerprint: fingerprint, certificatePath: path.path, keyApplicationTag: keychain.applicationTag, publicKeyFingerprint: publicKeyFingerprint, ownership: .owned, trustDomain: "user", trustProvenance: existing.trustProvenance, trustSettingsFingerprint: existing.trustSettingsFingerprint)
            if owned != existing { try store?.saveTLSRecord(owned) }
            return ManagedContext(certificateData: certificateData, fingerprint: fingerprint, publicKeyFingerprint: publicKeyFingerprint, record: owned)
        }
        let record = TLSDurableRecord(fingerprint: fingerprint, certificatePath: path.path, keyApplicationTag: keychain.applicationTag, publicKeyFingerprint: publicKeyFingerprint, ownership: .owned, trustDomain: "user", trustProvenance: .none, trustSettingsFingerprint: nil)
        try store?.saveTLSRecord(record)
        return ManagedContext(certificateData: certificateData, fingerprint: fingerprint, publicKeyFingerprint: publicKeyFingerprint, record: record)
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func derCertificateData(_ data: Data) -> Data {
        guard SecCertificateCreateWithData(nil, data as CFData) == nil,
              let text = String(data: data, encoding: .utf8) else { return data }
        let lines = text.components(separatedBy: .newlines).filter { !$0.contains("BEGIN") && !$0.contains("END") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Data(base64Encoded: lines.joined()) ?? data
    }
}

private extension Data {
    init(pem der: Data, label: String) { self = Data("-----BEGIN \(label)-----\n".utf8) + der.base64EncodedString(options: [.lineLength64Characters]).data(using: .utf8)! + Data("\n-----END \(label)-----\n".utf8) }
}

public enum LocalCertificateBuilder {
    public static func ca(key: SecKey, commonName: String = "Vaelen Local CA") throws -> Data { try certificate(key: key, issuer: commonName, subject: commonName, isCA: true, san: nil, issuerKey: key) }
    public static func leaf(hostname: String, key: SecKey, issuer: String, issuerKey: SecKey) throws -> Data { try certificate(key: key, issuer: issuer, subject: hostname, isCA: false, san: hostname, issuerKey: issuerKey) }

    private static func certificate(key: SecKey, issuer: String, subject: String, isCA: Bool, san: String?, issuerKey: SecKey) throws -> Data {
        let publicKey = try external(SecKeyCopyPublicKey(key))
        let spki = DER.sequence(DER.sequence(DER.oid([1, 2, 840, 113549, 1, 1, 1]) + DER.null) + DER.bitString(Array(publicKey)))
        let nameIssuer = DER.name(issuer); let nameSubject = DER.name(subject)
        let extensions: [UInt8]
        if isCA {
            extensions = DER.x509Extension([2, 5, 29, 19], critical: true, value: DER.sequence(DER.boolean(true)))
                + DER.x509Extension([2, 5, 29, 15], critical: true, value: DER.tlv(3, [1, 0x06]))
        } else {
            extensions = DER.x509Extension([2, 5, 29, 19], critical: true, value: DER.sequence(DER.boolean(false)))
                + DER.x509Extension([2, 5, 29, 15], critical: true, value: DER.tlv(3, [5, 0xA0]))
                + DER.x509Extension([2, 5, 29, 17], critical: false, value: DER.sequence(DER.ia5(san ?? "")))
                + DER.x509Extension([2, 5, 29, 37], critical: false, value: DER.sequence(DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])))
        }
        let extensionsSequence = DER.sequence(extensions)
        let validity = isCA ? DER.validity : DER.leafValidity
        let tbs = DER.sequence(DER.explicit(0, DER.integer(2)) + DER.integer(1) + DER.algorithm + nameIssuer + validity + nameSubject + spki + DER.explicit(3, extensionsSequence))
        let signature = try sign(Data(tbs), with: issuerKey)
        return Data(DER.sequence(tbs + DER.algorithm + DER.bitString(Array(signature))))
    }

    private static func external(_ key: SecKey?) throws -> Data { guard let key, let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { throw TLSError.certificate("key export failed") }; return data }
    private static func sign(_ data: Data, with key: SecKey) throws -> Data { var error: Unmanaged<CFError>?; guard let result = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) as Data? else { throw TLSError.certificate((error?.takeRetainedValue() as Error?)?.localizedDescription ?? "certificate signing failed") }; return result }
}

private enum DER {
    static let algorithm = sequence(oid([1, 2, 840, 113549, 1, 1, 11]) + null)
    static let validity = sequence(utc("260101000000Z") + utc("360101000000Z"))
    static let leafValidity = sequence(utc("260101000000Z") + utc("270101000000Z"))
    static func tlv(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] { [tag] + length(value.count) + value }
    static func sequence(_ value: [UInt8]) -> [UInt8] { tlv(0x30, value) }
    static func set(_ value: [UInt8]) -> [UInt8] { tlv(0x31, value) }
    static func explicit(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] { tlv(0xa0 | tag, value) }
    static func integer(_ value: Int) -> [UInt8] { tlv(2, [UInt8(value)]) }
    static func boolean(_ value: Bool) -> [UInt8] { tlv(1, [value ? 0xff : 0]) }
    static let null = [UInt8](arrayLiteral: 5, 0)
    static func oid(_ values: [Int]) -> [UInt8] { var body = base128(40 * values[0] + values[1]); for value in values.dropFirst(2) { body += base128(value) }; return tlv(6, body) }
    static func base128(_ value: Int) -> [UInt8] { var bytes = [UInt8(value & 0x7f)]; var rest = value >> 7; while rest > 0 { bytes.insert(UInt8(rest & 0x7f) | 0x80, at: 0); rest >>= 7 }; return bytes }
    static func utf8(_ value: String) -> [UInt8] { tlv(0x0c, Array(value.utf8)) }
    static func ia5(_ value: String) -> [UInt8] { tlv(0x82, Array(value.utf8)) }
    static func utc(_ value: String) -> [UInt8] { tlv(0x17, Array(value.utf8)) }
    static func bitString(_ value: [UInt8]) -> [UInt8] { tlv(3, [0] + value) }
    static func name(_ value: String) -> [UInt8] { sequence(set(sequence(oid([2, 5, 4, 3]) + utf8(value)))) }
    static func x509Extension(_ oidValues: [Int], critical: Bool, value: [UInt8]) -> [UInt8] { sequence(oid(oidValues) + (critical ? boolean(true) : []) + tlv(4, value)) }
    static func length(_ value: Int) -> [UInt8] {
        guard value >= 128 else { return [UInt8(value)] }
        var bytes = [UInt8(value & 0xff)]; var rest = value >> 8
        while rest > 0 { bytes.insert(UInt8(rest & 0xff), at: 0); rest >>= 8 }
        return [UInt8(0x80 | bytes.count)] + bytes
    }
}
