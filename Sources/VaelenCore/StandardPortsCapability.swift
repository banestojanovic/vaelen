import Foundation
import Darwin
import CryptoKit

/// Desired and observed state of Vaelen's Standard Local Ports capability.
///
/// Standard ports 80/443 are served exclusively through macOS PF redirection
/// to Vaelen's private loopback backends. Caddy itself never binds them.
public enum StandardPortsState: String, Codable, Sendable {
    case absent
    case installed
    case healthy
    case unhealthy
    case conflict
    case ownershipMismatch
    case unavailable
}

public struct StandardPortsStatus: Codable, Equatable, Sendable {
    public let state: StandardPortsState
    public let httpPort: Int
    public let httpsPort: Int
    public let backendHTTPPort: Int
    public let backendHTTPSPort: Int
    public let anchor: String
    public let detail: String?
    public let conflict: String?

    public init(state: StandardPortsState, httpPort: Int = VaelenNetworkPorts.standardHTTP, httpsPort: Int = VaelenNetworkPorts.standardHTTPS, backendHTTPPort: Int = VaelenNetworkPorts.httpBackend, backendHTTPSPort: Int = VaelenNetworkPorts.httpsBackend, anchor: String = StandardPortsForwardingPolicy.anchorName, detail: String? = nil, conflict: String? = nil) {
        self.state = state; self.httpPort = httpPort; self.httpsPort = httpsPort; self.backendHTTPPort = backendHTTPPort; self.backendHTTPSPort = backendHTTPSPort; self.anchor = anchor; self.detail = detail; self.conflict = conflict
    }
}

public enum StandardPortsError: Error, Equatable, Sendable {
    case helperUnavailable
    case authorizationRequired(String)
    case externalConflict(String)
    case ownershipMismatch
    case backendUnavailable
    case unavailable(String)
}

/// Fixed Vaelen-owned PF forwarding policy.
///
/// The privileged helper understands this policy only. Callers never supply
/// addresses, ports, or PF syntax: installation is parameterless and the
/// helper validates everything against these constants.
public enum StandardPortsForwardingPolicy {
    public static let anchorName = "dev.vaelen.standard-ports"
    public static let anchorPath = "/etc/pf.anchors/dev.vaelen.standard-ports"
    public static let pfConfPath = "/etc/pf.conf"

    public static func anchorRules(httpBackend: Int = VaelenNetworkPorts.httpBackend, httpsBackend: Int = VaelenNetworkPorts.httpsBackend) -> String {
        "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port \(httpBackend)\n" +
        "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port \(httpsBackend)\n"
    }

    /// Lines appended to /etc/pf.conf so the Vaelen anchor is reachable.
    /// This is the smallest integration that makes a non-Apple anchor evaluate.
    public static func pfConfReferenceLines(anchorPath: String = anchorPath) -> [String] {
        ["# Vaelen standard local ports (managed by Vaelen; do not edit)", "rdr-anchor \"\(anchorName)\"", "load anchor \"\(anchorName)\" from \"\(anchorPath)\""]
    }

    /// Writes the anchor file. Shared by the privileged helper and fixtures.
    public static func writeAnchor(to anchorPath: String, httpBackend: Int = VaelenNetworkPorts.httpBackend, httpsBackend: Int = VaelenNetworkPorts.httpsBackend) throws {
        try anchorRules(httpBackend: httpBackend, httpsBackend: httpsBackend).write(toFile: anchorPath, atomically: true, encoding: .utf8)
    }

    /// Inserts missing reference lines into pf.conf content. Idempotent and
    /// self-healing: PF requires translation anchors (rdr-anchor) before
    /// filter anchors, so the block goes immediately before the first
    /// `anchor` filter line, never appended after it. Misplaced blocks are
    /// moved, not duplicated.
    public static func addingReference(to pfConf: String, anchorPath: String = anchorPath) -> String {
        let lines = pfConfReferenceLines(anchorPath: anchorPath)
        var body = removingReference(from: pfConf, anchorPath: anchorPath).components(separatedBy: "\n")
        while body.last?.isEmpty == true { body.removeLast() }
        if body.isEmpty { return lines.joined(separator: "\n") + "\n" }
        let index = body.firstIndex(where: isFilterAnchorLine) ?? body.endIndex
        body.insert(contentsOf: lines, at: index)
        return body.joined(separator: "\n") + "\n"
    }

    private static func isFilterAnchorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("anchor") else { return false }
        let rest = trimmed.dropFirst("anchor".count)
        return rest.first == " " || rest.first == "\t" || rest.first == "\""
    }

    /// Removes exactly Vaelen's reference lines from pf.conf content.
    public static func removingReference(from pfConf: String, anchorPath: String = anchorPath) -> String {
        var updated = pfConf
        for line in pfConfReferenceLines(anchorPath: anchorPath) {
            updated = updated.replacingOccurrences(of: line + "\n", with: "")
            updated = updated.replacingOccurrences(of: line, with: "")
        }
        return updated
    }
}

public struct StandardPortsInspection: Equatable, Sendable {
    public let anchorContent: String?
    public let pfConfContent: String?
    public let pfEnabled: Bool?
    public init(anchorContent: String?, pfConfContent: String?, pfEnabled: Bool? = nil) { self.anchorContent = anchorContent; self.pfConfContent = pfConfContent; self.pfEnabled = pfEnabled }
}

/// Privileged side of the Standard Ports capability. Implementations perform
/// only fixed-policy operations; every request is validated against
/// StandardPortsForwardingPolicy inside the privileged implementation.
public protocol StandardPortsPrivileged: Sendable {
    func inspectForwarding() async throws -> StandardPortsInspection
    /// Installs the fixed Vaelen forwarding policy. Returns the PF enable
    /// token when the implementation enabled PF, nil when PF was already on.
    func installForwarding() async throws -> String?
    /// Removes the fixed policy. pfToken is the opaque token previously
    /// issued; nil/unknown tokens must leave PF enabled (bias to preserving
    /// shared infrastructure).
    func removeForwarding(pfToken: String?) async throws
}

public enum StandardPortsPrivilegeError: Error, Equatable, Sendable { case unavailable }

/// Production placeholder used when the signed helper is not installed.
/// Observation stays user-space; mutation requires Vaelen.app authorization.
public struct UnavailableStandardPortsPrivileged: StandardPortsPrivileged {
    private let paths: StandardPortsPaths
    public init(paths: StandardPortsPaths = .live) { self.paths = paths }
    public func inspectForwarding() async throws -> StandardPortsInspection {
        StandardPortsInspection(anchorContent: try? String(contentsOfFile: paths.anchorPath), pfConfContent: try? String(contentsOfFile: paths.pfConfPath), pfEnabled: nil)
    }
    public func installForwarding() async throws -> String? { throw StandardPortsPrivilegeError.unavailable }
    public func removeForwarding(pfToken: String?) async throws { throw StandardPortsPrivilegeError.unavailable }
}

public struct StandardPortsPaths: Equatable, Sendable {
    public let anchorPath: String
    public let pfConfPath: String
    public static let live = StandardPortsPaths(anchorPath: StandardPortsForwardingPolicy.anchorPath, pfConfPath: StandardPortsForwardingPolicy.pfConfPath)
    public init(anchorPath: String, pfConfPath: String) { self.anchorPath = anchorPath; self.pfConfPath = pfConfPath }
}

public actor StandardPortsCapability {
    private let privileged: any StandardPortsPrivileged
    private let paths: StandardPortsPaths
    private let ledger: SystemModificationLedger?
    private let portOccupied: @Sendable (Int) -> Bool
    private let backendHealthy: @Sendable () async -> Bool

    public init(privileged: any StandardPortsPrivileged = UnavailableStandardPortsPrivileged(), paths: StandardPortsPaths = .live, ledger: SystemModificationLedger? = nil, portOccupied: (@Sendable (Int) -> Bool)? = nil, backendHealthy: (@Sendable () async -> Bool)? = nil) {
        self.privileged = privileged
        self.paths = paths
        self.ledger = ledger
        self.portOccupied = portOccupied ?? StandardPortsCapability.tcpConnectSucceeds(port:)
        self.backendHealthy = backendHealthy ?? { false }
    }

    public func status() async -> StandardPortsStatus {
        let expected = StandardPortsForwardingPolicy.anchorRules()
        let reference = StandardPortsForwardingPolicy.pfConfReferenceLines(anchorPath: paths.anchorPath)
        let inspection: StandardPortsInspection
        do { inspection = try await privileged.inspectForwarding() } catch { return StandardPortsStatus(state: .unavailable, detail: "Standard port observation is unavailable") }
        let anchorContent = inspection.anchorContent
        let pfConf = inspection.pfConfContent
        let anchorMatches = anchorContent == expected
        let referencePresent = pfConf.map { reference.allSatisfy($0.contains) } ?? false
        let record = try? ledger?.standardPortsRecord()
        let active = record?.active ?? false
        let httpOccupied = portOccupied(VaelenNetworkPorts.standardHTTP)
        let httpsOccupied = portOccupied(VaelenNetworkPorts.standardHTTPS)

        if let anchorContent, anchorContent != expected {
            if active { return StandardPortsStatus(state: .ownershipMismatch, detail: "Vaelen PF anchor was modified externally") }
            return StandardPortsStatus(state: .conflict, conflict: "Foreign PF anchor claims \(StandardPortsForwardingPolicy.anchorName)")
        }
        if anchorContent == nil, !referencePresent {
            if httpOccupied || httpsOccupied {
                return StandardPortsStatus(state: .conflict, conflict: StandardPortsCapability.describeOccupied(httpOccupied: httpOccupied, httpsOccupied: httpsOccupied))
            }
            return StandardPortsStatus(state: .absent)
        }
        guard anchorMatches, referencePresent else {
            if active { return StandardPortsStatus(state: .ownershipMismatch, detail: "Vaelen PF integration is partially missing or was modified") }
            return StandardPortsStatus(state: .conflict, conflict: "Partial foreign PF integration for Vaelen anchor")
        }
        let backend = await backendHealthy()
        if (httpOccupied || httpsOccupied), backend {
            return StandardPortsStatus(state: .healthy)
        }
        if backend {
            // Integration present and backend ready, but standard ports refuse:
            // PF rules are not loaded or PF is disabled.
            return StandardPortsStatus(state: .unhealthy, detail: "PF integration is present but standard ports are unreachable")
        }
        return StandardPortsStatus(state: .installed, detail: "PF integration is present; backend router is not running")
    }

    public func install() async throws -> StandardPortsStatus {
        let current = await status()
        switch current.state {
        case .healthy, .installed: return current
        case .conflict: throw StandardPortsError.externalConflict(current.conflict ?? "Standard ports conflict with external state")
        case .ownershipMismatch: throw StandardPortsError.ownershipMismatch
        case .unavailable: throw StandardPortsError.unavailable("Standard port observation is unavailable")
        case .absent, .unhealthy: break
        }
        // Capture the pre-image before mutation: removal must be able to prove
        // what the system looked like before Vaelen touched it.
        let preimage = sha256(ofFile: paths.pfConfPath)
        let token: String?
        do {
            token = try await privileged.installForwarding()
        } catch is StandardPortsPrivilegeError {
            throw StandardPortsError.helperUnavailable
        } catch let error as StandardPortsError {
            throw error
        }
        let anchorRules = StandardPortsForwardingPolicy.anchorRules()
        try ledger?.recordStandardPorts(anchorRules: anchorRules, pfConfPreimageSHA256: preimage, pfToken: token)
        return await status()
    }

    public func remove() async throws -> StandardPortsStatus {
        let record = try ledger?.standardPortsRecord()
        let current = await status()
        if record == nil || record?.active == false, current.state == .absent { return current }
        if current.state == .ownershipMismatch { throw StandardPortsError.ownershipMismatch }
        if current.state == .conflict { throw StandardPortsError.externalConflict(current.conflict ?? "Standard ports conflict with external state") }
        do {
            try await privileged.removeForwarding(pfToken: record?.pfToken)
        } catch is StandardPortsPrivilegeError {
            throw StandardPortsError.helperUnavailable
        } catch let error as StandardPortsError {
            throw error
        }
        try ledger?.deactivateStandardPorts()
        return await status()
    }

    private static func describeOccupied(httpOccupied: Bool, httpsOccupied: Bool) -> String {
        switch (httpOccupied, httpsOccupied) {
        case (true, true): return "External processes own TCP 80 and 443"
        case (true, false): return "External process owns TCP 80"
        case (false, true): return "External process owns TCP 443"
        case (false, false): return "Standard ports are unavailable"
        }
    }

    private static func tcpConnectSucceeds(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }

    private func sha256(ofFile path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
