import Foundation
import VaelenIPC

enum ServiceInstanceInventoryFormatter {
    static func render(_ inventory: ServiceInstanceInventoryResult, json: Bool) throws -> String {
        let entries = inventory.entries.sorted {
            ($0.instance.kind.rawValue, $0.instance.name.value) < ($1.instance.kind.rawValue, $1.instance.name.value)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(ServiceInstanceInventoryResult(entries: entries)), as: UTF8.self)
        }
        guard !entries.isEmpty else { return "No service instances are registered." }
        return entries.map { entry in
            let endpoints = entry.instance.endpoint.displayEndpoints.joined(separator: ", ")
            let owners = entry.owners.map { owner -> String in
                switch owner {
                case .manual: "manual"
                case .project(let projectID, let alias, let version):
                    "project \(projectID) / \(alias.value)" + (version.map { " (\($0))" } ?? "")
                }
            }.joined(separator: ", ")
            let health = entry.assessedHealth ?? "unassessed"
            let eligibility = entry.eligibleForProjectBinding.map { $0 ? "eligible" : "blocked" } ?? "unassessed"
            return "\(entry.instance.kind.rawValue)/\(entry.instance.name.value)\n  Endpoint: \(endpoints)\n  Package: \(entry.instance.packageIdentifier)\n  Data: \(entry.instance.dataDirectory)\n  State: \(health) · project binding \(eligibility)\n  Owners: \(owners.isEmpty ? "none" : owners)"
        }.joined(separator: "\n")
    }
}
