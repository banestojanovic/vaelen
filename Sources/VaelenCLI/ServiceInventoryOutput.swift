import Foundation
import VaelenCore

enum ServiceObservation<Value> {
    case available(Value)
    case unavailable(String)
}

struct ServiceInventory: Codable, Equatable {
    struct Service: Codable, Equatable {
        enum Kind: String, Codable {
            case mysql
            case mailpit
        }

        let service: Kind
        let instance: String
        let state: String
        let health: String?
        let installedVersion: String?
        let selectedVersion: String?
        let pid: Int32?
        let endpoints: [String: String]
        let observationError: String?

        private enum CodingKeys: String, CodingKey {
            case service, instance, state, health, installedVersion, selectedVersion, pid, endpoints, observationError
        }

        init(
            service: Kind,
            state: String,
            health: String?,
            installedVersion: String?,
            selectedVersion: String? = nil,
            pid: Int32?,
            endpoints: [String: String],
            observationError: String? = nil
        ) {
            self.service = service
            self.instance = "default"
            self.state = state
            self.health = health
            self.installedVersion = installedVersion
            self.selectedVersion = selectedVersion
            self.pid = pid
            self.endpoints = endpoints
            self.observationError = observationError
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(service, forKey: .service)
            try container.encode(instance, forKey: .instance)
            try container.encode(state, forKey: .state)
            try container.encode(health, forKey: .health)
            try container.encode(installedVersion, forKey: .installedVersion)
            try container.encode(selectedVersion, forKey: .selectedVersion)
            try container.encode(pid, forKey: .pid)
            try container.encode(endpoints, forKey: .endpoints)
            try container.encode(observationError, forKey: .observationError)
        }
    }

    let complete: Bool
    let services: [Service]

    init(mysql: ServiceObservation<MySQLStatus>, mailpit: ServiceObservation<MailpitStatus>) {
        let mysqlService: Service
        switch mysql {
        case .available(let status):
            mysqlService = Service(
                service: .mysql,
                state: status.state.rawValue,
                health: status.health,
                installedVersion: status.installedVersion,
                selectedVersion: status.selectedVersion,
                pid: status.pid,
                endpoints: ["tcp": "127.0.0.1:\(status.port)", "socket": status.socket]
            )
        case .unavailable(let error):
            mysqlService = Service(service: .mysql, state: "unavailable", health: nil, installedVersion: nil, pid: nil, endpoints: [:], observationError: error)
        }

        let mailpitService: Service
        switch mailpit {
        case .available(let status):
            mailpitService = Service(
                service: .mailpit,
                state: status.state.rawValue,
                health: status.health,
                installedVersion: status.installedVersion,
                pid: status.pid,
                endpoints: ["smtp": "127.0.0.1:\(status.smtpPort)", "web": status.uiEndpoint]
            )
        case .unavailable(let error):
            mailpitService = Service(service: .mailpit, state: "unavailable", health: nil, installedVersion: nil, pid: nil, endpoints: [:], observationError: error)
        }

        complete = mysqlService.observationError == nil && mailpitService.observationError == nil
        services = [mysqlService, mailpitService]
    }

    static func unavailableCore(_ error: String) -> ServiceInventory {
        ServiceInventory(mysql: .unavailable(error), mailpit: .unavailable(error))
    }
}

enum ServiceInventoryFormatter {
    static func json(_ inventory: ServiceInventory) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(inventory), as: UTF8.self)
    }

    static func human(_ inventory: ServiceInventory) -> String {
        let rows = inventory.services.map { service in
            let endpointSummary = service.endpoints.keys.sorted().map { key in
                "\(key)=\(service.endpoints[key] ?? "")"
            }.joined(separator: ", ")
            return [
                service.service.rawValue.capitalized,
                service.instance,
                service.state,
                service.health ?? "none",
                service.installedVersion ?? "none",
                endpointSummary.isEmpty ? "none" : endpointSummary,
                service.observationError ?? ""
            ]
        }
        let summary = inventory.complete ? "Complete" : "Incomplete"
        return HumanOutput.heading("Services · \(summary)") + "\n" +
            HumanOutput.list(rows, headers: ["Service", "Instance", "State", "Health", "Installed", "Endpoints", "Observation error"], empty: "No services.") +
            "\n\nInstance default labels each legacy service. Snapshot is sequential. MySQL and Mailpit status are observed independently."
    }

    static func render(_ inventory: ServiceInventory, json: Bool) throws -> String {
        json ? try self.json(inventory) : human(inventory)
    }
}
