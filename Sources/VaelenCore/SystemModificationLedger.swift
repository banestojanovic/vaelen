import Foundation
import SQLite3

public struct DNSLedgerRecord: Equatable, Sendable {
    public let installedContent: String
    public let previousContent: String?
    public let active: Bool
    public init(installedContent: String, previousContent: String?, active: Bool) { self.installedContent = installedContent; self.previousContent = previousContent; self.active = active }
}

/// Provenance for the Standard Local Ports capability (capability key
/// 'standard-ports'). installedContent holds the Vaelen PF anchor rules.
/// previousContent encodes pre-install system state as
/// "pfconf-sha256:<hex>|pftoken:<token|none>".
public struct StandardPortsLedgerRecord: Equatable, Sendable {
    public let anchorRules: String
    public let pfConfPreimageSHA256: String?
    public let pfToken: String?
    public let active: Bool
    public init(anchorRules: String, pfConfPreimageSHA256: String?, pfToken: String?, active: Bool) { self.anchorRules = anchorRules; self.pfConfPreimageSHA256 = pfConfPreimageSHA256; self.pfToken = pfToken; self.active = active }
}

public final class SystemModificationLedger: @unchecked Sendable {
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store }
    public func dnsRecord() throws -> DNSLedgerRecord? {
        var result: DNSLedgerRecord?
        try store.query("SELECT installed_content, previous_content, active FROM system_modifications WHERE capability = 'test-resolver'") { statement in
            result = DNSLedgerRecord(installedContent: store.columnString(statement, 0) ?? "", previousContent: store.columnString(statement, 1), active: sqlite3_column_int(statement, 2) != 0)
        }
        return result
    }
    public func recordDNS(installedContent: String, previousContent: String?) throws {
        let installed = sql(installedContent)
        let savedPrevious = try dnsRecord()?.previousContent ?? previousContent
        let previous = savedPrevious.map(sql).map { "'\($0)'" } ?? "NULL"
        try store.execute("INSERT OR REPLACE INTO system_modifications(capability, installed_content, previous_content, active) VALUES('test-resolver', '\(installed)', \(previous), 1)")
    }
    public func deactivateDNS() throws { try store.execute("UPDATE system_modifications SET active = 0 WHERE capability = 'test-resolver'") }
    public func standardPortsRecord() throws -> StandardPortsLedgerRecord? {
        var result: StandardPortsLedgerRecord?
        try store.query("SELECT installed_content, previous_content, active FROM system_modifications WHERE capability = 'standard-ports'") { statement in
            guard let anchorRules = store.columnString(statement, 0) else { return }
            let previous = store.columnString(statement, 1)
            var preimage: String?; var token: String?
            for part in (previous ?? "").split(separator: "|") {
                if part.hasPrefix("pfconf-sha256:") { preimage = String(part.dropFirst("pfconf-sha256:".count)) }
                if part.hasPrefix("pftoken:") { let value = String(part.dropFirst("pftoken:".count)); token = value == "none" ? nil : value }
            }
            result = StandardPortsLedgerRecord(anchorRules: anchorRules, pfConfPreimageSHA256: preimage?.isEmpty == true ? nil : preimage, pfToken: token, active: sqlite3_column_int(statement, 2) != 0)
        }
        return result
    }
    public func recordStandardPorts(anchorRules: String, pfConfPreimageSHA256: String?, pfToken: String?) throws {
        let previous = "pfconf-sha256:\(pfConfPreimageSHA256 ?? "")|pftoken:\(pfToken ?? "none")"
        try store.execute("INSERT OR REPLACE INTO system_modifications(capability, installed_content, previous_content, active) VALUES('standard-ports', '\(sql(anchorRules))', '\(sql(previous))', 1)")
    }
    public func deactivateStandardPorts() throws { try store.execute("UPDATE system_modifications SET active = 0 WHERE capability = 'standard-ports'") }
    private func sql(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
}
