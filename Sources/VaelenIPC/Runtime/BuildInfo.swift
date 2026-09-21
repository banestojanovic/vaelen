import Foundation
import CryptoKit

public enum VaelenBuildInfo {
    public static let productVersion = "0.0.14-dev"
    public static let version = productVersion
    public static let buildIdentity = "m14-core-daemon-lifecycle-schema-7"
    /// A stable product/build label carried by every client handshake.  The
    /// executable digest is intentionally computed only when requested; it is
    /// evidence, never a lifecycle authority.
    public static var executableSHA256: String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments.first ?? "")) else { return nil }
        return data.sha256Hex
    }
    public static var cliBuildIdentity: String { "val/\(productVersion)/\(buildIdentity)" + (executableSHA256.map { "/sha256:\($0)" } ?? "") }
    public static let protocolVersion = ProtocolVersion.v1
    public static let schemaCompatibilityVersion = IPCCompatibility.schemaVersion
}

private extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}
