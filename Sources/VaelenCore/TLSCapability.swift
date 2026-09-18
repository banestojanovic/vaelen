import Foundation
import Security
import CryptoKit

public enum TLSCapabilityState: String, Codable, Sendable { case absent, createdButUntrusted, trusted, unhealthy, ownershipMismatch }
public struct TLSStatus: Codable, Equatable, Sendable {
    public let state: TLSCapabilityState
    public let caFingerprint: String?
    public let caCertificatePath: String?
    public let trustObserved: Bool
    public let tlsPort: Int
    public let detail: String?
    public init(state: TLSCapabilityState, caFingerprint: String? = nil, caCertificatePath: String? = nil, trustObserved: Bool = false, tlsPort: Int = VaelenNetworkPorts.httpsBackend, detail: String? = nil) { self.state = state; self.caFingerprint = caFingerprint; self.caCertificatePath = caCertificatePath; self.trustObserved = trustObserved; self.tlsPort = tlsPort; self.detail = detail }
}

public enum TLSError: Error, Equatable, Sendable { case unsupportedHostname(String), keychain(OSStatus), certificate(String), ownershipMismatch, unavailable }

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
    public func removeCAKey() throws { let status = SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecAttrKeyType: kSecAttrKeyTypeRSA] as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw TLSError.keychain(status) } }
}

public final class LocalCATrustService: @unchecked Sendable {
    public init() {}
    public func isTrusted(certificateData: Data) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else { return false }
        var settings: CFArray?
        return SecTrustSettingsCopyTrustSettings(certificate, .user, &settings) == errSecSuccess
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
    private let trust: LocalCATrustService
    private let store: SQLiteStateStore?
    public init(layout: VaelenFilesystemLayout = .init(), store: SQLiteStateStore? = nil, tlsPort: Int = VaelenNetworkPorts.httpsBackend, keychain: LocalCAKeychain = .init(), trust: LocalCATrustService = .init()) { self.layout = layout; self.store = store; self.tlsPort = tlsPort; self.keychain = keychain; self.trust = trust }
    public func status() -> TLSStatus {
        let path = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        guard let data = try? Data(contentsOf: path), let _ = SecCertificateCreateWithData(nil, data as CFData) else { return TLSStatus(state: .absent, tlsPort: tlsPort) }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let trusted = trust.isTrusted(certificateData: data)
        return TLSStatus(state: trusted ? .trusted : .createdButUntrusted, caFingerprint: fingerprint, caCertificatePath: path.path, trustObserved: trusted, tlsPort: tlsPort)
    }
    public func install() throws -> TLSStatus {
        let key = try keychain.caKey()
        let path = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.path) { try LocalCertificateBuilder.ca(key: key).write(to: path, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }
        return status()
    }
    public func remove() throws -> TLSStatus {
        let path = layout.tlsCertificatesDirectoryURL.appendingPathComponent("ca.der")
        if let data = try? Data(contentsOf: path), trust.isTrusted(certificateData: data) { throw TLSError.ownershipMismatch }
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
