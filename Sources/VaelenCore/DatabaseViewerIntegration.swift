import Foundation

/// A replaceable projection for opening a project's database in an external
/// viewer. Credentials are intentionally not accepted by this boundary.
public struct ProjectDatabaseViewerAction: Equatable, Sendable {
    public let url: URL?
    public let reason: String

    public var isEnabled: Bool { url != nil }

    /// Builds an action from runtime and configured project evidence. Desired
    /// service state is deliberately not an eligibility gate: a project can
    /// already have a healthy, reachable database configured in its .env.
    public static func tablePlus(report: ProjectEnvironmentReport, tablePlusInstalled: Bool) -> Self {
        tablePlus(configured: report.configured, mysql: report.observed.mysql, tablePlusInstalled: tablePlusInstalled)
    }

    public static func tablePlus(
        configured: ProjectConfiguredEnvironment,
        mysql: MySQLStatus?,
        tablePlusInstalled: Bool
    ) -> Self {
        guard tablePlusInstalled else { return disabled("TablePlus is not installed") }
        guard configured.dbConnection?.trimmedLowercase == "mysql" else {
            return disabled("This project does not use MySQL")
        }
        guard ["127.0.0.1", "localhost", "::1"].contains(configured.dbHost?.trimmedLowercase ?? "") else {
            return disabled("This project uses a remote database")
        }
        guard configured.dbUsername?.trimmedLowercase == "root" else {
            return disabled("This project does not use Vaelen’s local root account")
        }
        guard let mysql else { return disabled("Vaelen MySQL status is unavailable") }
        guard mysql.state == .running, mysql.health == "healthy" else {
            return disabled("Start Vaelen MySQL to open this database")
        }
        guard let configuredPort = configured.dbPort?.trimmingCharacters(in: .whitespacesAndNewlines),
              Int(configuredPort) == mysql.port else {
            return disabled("This project does not use Vaelen MySQL port \(mysql.port)")
        }
        guard let rawDatabase = configured.database else { return disabled("No project database is configured") }
        let database = rawDatabase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !database.isEmpty, !database.contains("$") else { return disabled("The project database name is unresolved") }
        guard let databases = mysql.databases else { return disabled("Database inventory is unavailable; refresh Vaelen") }
        guard databases.contains(database) else { return disabled("Database \(database) does not exist in Vaelen MySQL") }

        var components = URLComponents()
        components.scheme = "mysql"
        components.user = "root"
        components.host = "127.0.0.1"
        components.port = mysql.port
        components.path = "/\(database)"
        guard let url = components.url else { return disabled("The project database name cannot be opened") }
        return .init(url: url, reason: "Open \(database) in TablePlus")
    }

    private static func disabled(_ reason: String) -> Self { .init(url: nil, reason: reason) }
}

/// A server-level TablePlus connection that does not select a project
/// database, user, or password. TablePlus obtains authentication interactively.
public struct MySQLDatabaseViewerAction: Equatable, Sendable {
    public let url: URL?
    public let reason: String

    public var isEnabled: Bool { url != nil }

    public static func tablePlus(mysql: MySQLStatus?, tablePlusInstalled: Bool) -> Self {
        guard tablePlusInstalled else { return .init(url: nil, reason: "TablePlus is not installed") }
        guard let mysql else { return .init(url: nil, reason: "Vaelen MySQL status is unavailable") }
        guard mysql.state == .running, mysql.health == "healthy" else {
            return .init(url: nil, reason: "Start Vaelen MySQL to open a connection")
        }
        var components = URLComponents()
        components.scheme = "mysql"
        components.host = "127.0.0.1"
        components.port = mysql.port
        guard let url = components.url else { return .init(url: nil, reason: "Vaelen MySQL connection URL is unavailable") }
        return .init(url: url, reason: "Open Vaelen MySQL in TablePlus")
    }
}

private extension String {
    var trimmedLowercase: String { trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
