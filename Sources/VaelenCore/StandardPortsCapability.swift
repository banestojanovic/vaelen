import Foundation
import Darwin
import CryptoKit
import OSLog

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

public enum StandardPortsOwnership: String, Codable, Sendable {
    case none
    case vaelen
    case external
    case unknown
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
    /// Whether the helper verified that the fixed forwarding rule is active.
    /// Nil means the helper could not provide an authoritative observation.
    public let forwardingActive: Bool?
    /// Ownership is reported by Core only when the active ledger and the
    /// currently observed fixed-policy integration agree. Nil is an
    /// unrecognized older Core response, never proof of ownership.
    public let ownership: StandardPortsOwnership?

    public init(state: StandardPortsState, httpPort: Int = VaelenNetworkPorts.standardHTTP, httpsPort: Int = VaelenNetworkPorts.standardHTTPS, backendHTTPPort: Int = VaelenNetworkPorts.httpBackend, backendHTTPSPort: Int = VaelenNetworkPorts.httpsBackend, anchor: String = StandardPortsForwardingPolicy.anchorName, detail: String? = nil, conflict: String? = nil, ownership: StandardPortsOwnership? = nil, forwardingActive: Bool? = nil) {
        self.state = state; self.httpPort = httpPort; self.httpsPort = httpsPort; self.backendHTTPPort = backendHTTPPort; self.backendHTTPSPort = backendHTTPSPort; self.anchor = anchor; self.detail = detail; self.conflict = conflict; self.ownership = ownership; self.forwardingActive = forwardingActive
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

    /// Strictly recognizes the fixed three-line integration block and rejects
    /// any additional active PF anchor directive that targets this Vaelen
    /// anchor. Comments and unrelated text are not counted as directives.
    public static func hasExactReference(in content: String, anchorPath: String = anchorPath) -> Bool {
        let expected = pfConfReferenceLines(anchorPath: anchorPath)
        let lines = content.components(separatedBy: "\n")
        guard expected.allSatisfy({ expectedLine in lines.filter { $0 == expectedLine }.count == 1 }),
              let first = lines.firstIndex(of: expected[0]), first + expected.count <= lines.count,
              Array(lines[first..<(first + expected.count)]) == expected else { return false }

        let expectedDirectives = Array(expected.dropFirst())
        let targetedDirectives = lines.compactMap { line -> String? in
            let withoutComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let directive = withoutComment.trimmingCharacters(in: .whitespaces)
            guard containsPFAnchorDirective(directive), directive.contains(anchorName) else { return nil }
            return directive
        }
        return targetedDirectives == expectedDirectives
    }

    private static func containsPFAnchorDirective(_ line: String) -> Bool {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = words.first else { return false }
        if ["anchor", "rdr-anchor", "nat-anchor", "binat-anchor"].contains(String(first)) { return true }
        return first == "load" && words.dropFirst().first == "anchor"
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
    public let forwardingActive: Bool?
    public init(anchorContent: String?, pfConfContent: String?, pfEnabled: Bool? = nil, forwardingActive: Bool? = nil) { self.anchorContent = anchorContent; self.pfConfContent = pfConfContent; self.pfEnabled = pfEnabled; self.forwardingActive = forwardingActive }
}

/// Exact fixed-path file state used to distinguish pre-existing PF files from
/// files written by this acquisition. Inode identity is intentionally omitted:
/// restoration verifies bytes and metadata while atomic replacement naturally
/// changes inode numbers.
public struct StandardPortsFileSnapshot: Codable, Equatable, Sendable {
    public let exists: Bool
    public let bytes: Data?
    public let owner: UInt32?
    public let group: UInt32?
    public let mode: UInt16?
    public init(exists: Bool, bytes: Data?, owner: UInt32?, group: UInt32?, mode: UInt16?) { self.exists = exists; self.bytes = bytes; self.owner = owner; self.group = group; self.mode = mode }
}

public struct StandardPortsAcquisition: Codable, Equatable, Sendable {
    public let preimagePFConf: StandardPortsFileSnapshot
    public let preimageAnchor: StandardPortsFileSnapshot
    public let writtenPFConf: StandardPortsFileSnapshot
    public let writtenAnchor: StandardPortsFileSnapshot
    public let changedPFConf: Bool
    public let changedAnchor: Bool
    public let forwardingWasActive: Bool
    public let pfToken: String?
    public init(preimagePFConf: StandardPortsFileSnapshot, preimageAnchor: StandardPortsFileSnapshot, writtenPFConf: StandardPortsFileSnapshot, writtenAnchor: StandardPortsFileSnapshot, changedPFConf: Bool, changedAnchor: Bool, forwardingWasActive: Bool, pfToken: String?) { self.preimagePFConf = preimagePFConf; self.preimageAnchor = preimageAnchor; self.writtenPFConf = writtenPFConf; self.writtenAnchor = writtenAnchor; self.changedPFConf = changedPFConf; self.changedAnchor = changedAnchor; self.forwardingWasActive = forwardingWasActive; self.pfToken = pfToken }
}

/// Privileged side of the Standard Ports capability. Implementations perform
/// only fixed-policy operations; every request is validated against
/// StandardPortsForwardingPolicy inside the privileged implementation.
public protocol StandardPortsPrivileged: Sendable {
    func inspectForwarding() async throws -> StandardPortsInspection
    /// Installs the fixed Vaelen forwarding policy. Returns the PF enable
    /// token when the implementation enabled PF, nil when PF was already on.
    func installForwarding() async throws -> StandardPortsAcquisition
    /// Removes the fixed policy. pfToken is the opaque token previously
    /// issued; nil/unknown tokens must leave PF enabled (bias to preserving
    /// shared infrastructure).
    func removeForwarding(acquisition: StandardPortsAcquisition) async throws
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
    public func installForwarding() async throws -> StandardPortsAcquisition { throw StandardPortsPrivilegeError.unavailable }
    public func removeForwarding(acquisition: StandardPortsAcquisition) async throws { throw StandardPortsPrivilegeError.unavailable }
}

public struct StandardPortsPaths: Equatable, Sendable {
    public let anchorPath: String
    public let pfConfPath: String
    public static let live = StandardPortsPaths(anchorPath: StandardPortsForwardingPolicy.anchorPath, pfConfPath: StandardPortsForwardingPolicy.pfConfPath)
    public init(anchorPath: String, pfConfPath: String) { self.anchorPath = anchorPath; self.pfConfPath = pfConfPath }
}

public actor StandardPortsCapability {
    private let logger = Logger(subsystem: "dev.vaelen.daemon", category: "standard-ports")
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
        logger.debug("Standard Ports status inspection started")
        let expected = StandardPortsForwardingPolicy.anchorRules()
        let inspection: StandardPortsInspection
        do { inspection = try await privileged.inspectForwarding() } catch {
            logger.error("Standard Ports helper inspection failed: \(String(describing: error), privacy: .public)")
            return StandardPortsStatus(state: .unavailable, detail: "Standard port observation is unavailable", ownership: .unknown)
        }
        let anchorContent = inspection.anchorContent
        let pfConf = inspection.pfConfContent
        let anchorMatches = anchorContent == expected
        let referencePresent = pfConf.map { StandardPortsForwardingPolicy.hasExactReference(in: $0, anchorPath: paths.anchorPath) } ?? false
        let record: StandardPortsLedgerRecord?
        do { record = try ledger?.standardPortsRecord() }
        catch { return StandardPortsStatus(state: .unavailable, detail: "PF ownership record could not be read; existing rules were left unchanged", ownership: .unknown, forwardingActive: inspection.forwardingActive) }
        let active = record?.active ?? false
        let hasIntegration = anchorContent != nil || referencePresent
        let ownership: StandardPortsOwnership = ledger == nil
            ? .unknown
            : active
                ? (anchorMatches && referencePresent ? .vaelen : .unknown)
                : (hasIntegration ? .external : .none)
        let httpOccupied = portOccupied(VaelenNetworkPorts.standardHTTP)
        let httpsOccupied = portOccupied(VaelenNetworkPorts.standardHTTPS)

        if let anchorContent, anchorContent != expected {
            if active { return StandardPortsStatus(state: .ownershipMismatch, detail: "Vaelen PF anchor was modified externally", ownership: .unknown, forwardingActive: inspection.forwardingActive) }
            return StandardPortsStatus(state: .conflict, conflict: "Foreign PF anchor claims \(StandardPortsForwardingPolicy.anchorName)", ownership: .external, forwardingActive: inspection.forwardingActive)
        }
        if anchorContent == nil, !referencePresent {
            if httpOccupied || httpsOccupied {
                return StandardPortsStatus(state: .unavailable, detail: "\(StandardPortsCapability.describeOccupied(httpOccupied: httpOccupied, httpsOccupied: httpsOccupied)); no fixed Vaelen PF integration is present, so ownership cannot be established", ownership: .unknown, forwardingActive: inspection.forwardingActive)
            }
            return StandardPortsStatus(state: .absent, ownership: StandardPortsOwnership.none, forwardingActive: inspection.forwardingActive)
        }
        guard anchorMatches, referencePresent else {
            if active { return StandardPortsStatus(state: .ownershipMismatch, detail: "Vaelen PF integration is partially missing or was modified", ownership: .unknown, forwardingActive: inspection.forwardingActive) }
            return StandardPortsStatus(state: .conflict, conflict: "Partial foreign PF integration for Vaelen anchor", ownership: .external, forwardingActive: inspection.forwardingActive)
        }
        let backend = await backendHealthy()
        if inspection.forwardingActive == true, httpOccupied, httpsOccupied, backend {
            return StandardPortsStatus(state: .healthy, ownership: ownership, forwardingActive: inspection.forwardingActive)
        }
        if backend {
            // A successful TCP connect is not proof that an external process
            // owns a port: active PF redirection makes Vaelen's backends
            // reachable through 80/443 too. The helper's PF observation is
            // authoritative for forwarding health.
            logger.info("Standard Ports preflight completed; exact integration exists but helper has not verified active forwarding")
            return StandardPortsStatus(state: .unhealthy, detail: "PF integration is present but active forwarding has not been verified", ownership: ownership, forwardingActive: inspection.forwardingActive)
        }
        return StandardPortsStatus(state: .installed, detail: "PF integration is present; backend router is not running", ownership: ownership, forwardingActive: inspection.forwardingActive)
    }

    public func install() async throws -> StandardPortsStatus {
        logger.info("Standard Ports install operation entered")
        guard ledger != nil else { throw StandardPortsError.unavailable("Standard Ports require durable Core ownership state; no PF change was made") }
        let current = await status()
        logger.info("Standard Ports preflight completed: state=\(current.state.rawValue, privacy: .public), ownership=\(current.ownership?.rawValue ?? "unknown", privacy: .public)")
        switch current.state {
        case .healthy:
            if current.ownership == .vaelen { return current }
            fallthrough
        case .installed:
            if current.ownership == .vaelen { return current }
        case .conflict: throw StandardPortsError.externalConflict(current.conflict ?? "Standard ports conflict with external state")
        case .ownershipMismatch: throw StandardPortsError.ownershipMismatch
        case .unavailable: throw StandardPortsError.unavailable("Standard port observation is unavailable")
        case .unhealthy:
            // With an exact compatible unowned pre-existing config, the helper
            // may take a session PF reference and verify/load that fixed policy.
            // It will reject partial or different on-disk state itself.
            break
        case .absent: break
        }
        // Capture the pre-image before mutation: removal must be able to prove
        // what the system looked like before Vaelen touched it.
        let acquisition: StandardPortsAcquisition
        logger.info("Standard Ports helper install request beginning")
        do {
            acquisition = try await privileged.installForwarding()
            logger.info("Standard Ports helper acquisition returned")
        } catch is StandardPortsPrivilegeError {
            logger.error("Standard Ports helper install request failed because helper was unavailable")
            throw StandardPortsError.helperUnavailable
        } catch let error as StandardPortsError {
            logger.error("Standard Ports helper install request failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        do {
            logger.info("Standard Ports acquisition ledger persistence attempted")
            try ledger?.recordStandardPorts(anchorRules: StandardPortsForwardingPolicy.anchorRules(), acquisition: acquisition)
            logger.info("Standard Ports acquisition ledger persistence completed")
        } catch {
            logger.error("Standard Ports acquisition ledger persistence failed; best-effort helper rollback started: \(String(describing: error), privacy: .public)")
            try? await privileged.removeForwarding(acquisition: acquisition)
            throw error
        }
        return await status()
    }

    public func remove() async throws -> StandardPortsStatus {
        let record = try ledger?.standardPortsRecord()
        let current = await status()
        if record == nil || record?.active == false, current.state == .absent { return current }
        guard record?.active == true else {
            throw StandardPortsError.externalConflict("No active Vaelen PF ownership record; existing rules were left unchanged")
        }
        if current.state == .ownershipMismatch { throw StandardPortsError.ownershipMismatch }
        if current.state == .conflict { throw StandardPortsError.externalConflict(current.conflict ?? "Standard ports conflict with external state") }
        guard current.ownership == .vaelen, let acquisition = record?.acquisition else { throw StandardPortsError.ownershipMismatch }
        do {
            try await privileged.removeForwarding(acquisition: acquisition)
        } catch is StandardPortsPrivilegeError {
            throw StandardPortsError.helperUnavailable
        } catch let error as StandardPortsError {
            throw error
        }
        try ledger?.deactivateStandardPorts()
        return await status()
    }

    /// Quit-time cleanup removes PF integration only when the durable ledger
    /// proves that Vaelen installed this exact fixed anchor. Without active
    /// provenance it returns a successful no-op and leaves PF untouched.
    public func shutdownCleanup() async throws -> StandardPortsStatus {
        let record: StandardPortsLedgerRecord?
        do { record = try ledger?.standardPortsRecord() }
        catch { throw StandardPortsError.unavailable("PF provenance could not be read; forwarding was left untouched") }
        let observed = await status()
        guard let record, record.active else {
            // Old installs may leave the policy files in place without an
            // ownership record. They are not authorization to mutate PF and
            // must not prevent an otherwise clean Quit.
            return StandardPortsStatus(state: observed.state, detail: "No active Vaelen PF ownership record; existing PF state was left unchanged.")
        }
        guard record.anchorRules == StandardPortsForwardingPolicy.anchorRules() else {
            throw StandardPortsError.ownershipMismatch
        }
        guard observed.state == .healthy || observed.state == .installed || observed.state == .unhealthy else {
            throw StandardPortsError.unavailable("Active Vaelen PF provenance exists, but current forwarding state is \(observed.state.rawValue); it was left untouched")
        }
        let removed = try await remove()
        let keptPreexisting = record.acquisition.map { !$0.changedPFConf && !$0.changedAnchor } == true
        guard removed.state == .absent || (keptPreexisting && removed.ownership == .external) else { throw StandardPortsError.unavailable("Vaelen PF removal was requested but state remains \(removed.state.rawValue)") }
        return removed
    }

    private static func describeOccupied(httpOccupied: Bool, httpsOccupied: Bool) -> String {
        switch (httpOccupied, httpsOccupied) {
        case (true, true): return "TCP connections to 80 and 443 succeed"
        case (true, false): return "A TCP connection to 80 succeeds"
        case (false, true): return "A TCP connection to 443 succeeds"
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

}
