import Foundation

struct ServiceAvailableCatalog: Codable, Equatable {
    enum Name: String, Codable {
        case mysql
        case mailpit
    }

    enum Scope: String, Codable {
        case defaultOnly = "default-only"
    }

    enum Action: String, Codable {
        case versions, install, use, initialize, start, stop, status, open
    }

    struct Service: Codable, Equatable {
        let name: Name
        let scope: Scope
        let actions: [Action]
    }

    let services: [Service]

    static let supported = ServiceAvailableCatalog(services: [
        Service(name: .mysql, scope: .defaultOnly, actions: [.versions, .install, .use, .initialize, .start, .stop, .status]),
        Service(name: .mailpit, scope: .defaultOnly, actions: [.versions, .install, .start, .stop, .status, .open])
    ])
}

enum ServiceAvailableFormatter {
    static func json(_ catalog: ServiceAvailableCatalog) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(catalog), as: UTF8.self)
    }

    static func human(_ catalog: ServiceAvailableCatalog) -> String {
        let rows = catalog.services.map { service in
            [service.name == .mysql ? "MySQL" : "Mailpit", service.scope.rawValue, service.actions.map(\.rawValue).joined(separator: ", ")]
        }
        return HumanOutput.heading("Available services") + "\n" +
            HumanOutput.table(rows, headers: ["Service", "Scope", "Supported actions"]) +
            "\nSupport describes CLI capabilities. Service instances are default-only."
    }

    static func render(_ catalog: ServiceAvailableCatalog, json: Bool) throws -> String {
        json ? try self.json(catalog) : human(catalog)
    }
}
