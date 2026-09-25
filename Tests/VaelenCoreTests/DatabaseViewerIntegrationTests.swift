import XCTest
@testable import VaelenCore

final class DatabaseViewerIntegrationTests: XCTestCase {
    private func configured(connection: String = "mysql", host: String = "127.0.0.1", port: String = "3306", database: String? = "callthewaiter", username: String = "root") -> ProjectConfiguredEnvironment {
        .init(envFile: "/project/.env", envFilePresent: true, dbConnection: connection, dbHost: host, dbPort: port, database: database, dbUsername: username, usernameConfigured: true, password: .missing)
    }

    private func mysql(state: MySQLState = .running, health: String = "healthy", databases: [String]? = ["callthewaiter"]) -> MySQLStatus {
        .init(state: state, health: health, installedVersion: "8.4.11", selectedVersion: "8.4.11", pid: state == .running ? 42 : nil, port: 3306, socket: "/vaelen/mysql.sock", datadir: "/vaelen/mysql", executablePath: "/vaelen/mysqld", databases: databases)
    }

    func testTablePlusTargetsTheSpecificImportedDatabaseWithoutCredentials() {
        let action = ProjectDatabaseViewerAction.tablePlus(configured: configured(), mysql: mysql(), tablePlusInstalled: true)
        XCTAssertEqual(action.url?.absoluteString, "mysql://root@127.0.0.1:3306/callthewaiter")
        XCTAssertFalse(action.url?.absoluteString.contains("root:") ?? true)
        XCTAssertFalse(action.url?.absoluteString.contains("password") ?? true)
    }

    func testTablePlusFailsClosedWithClearReasons() {
        let cases: [(ProjectDatabaseViewerAction, String)] = [
            (.tablePlus(configured: configured(), mysql: mysql(), tablePlusInstalled: false), "TablePlus is not installed"),
            (.tablePlus(configured: configured(connection: "pgsql"), mysql: mysql(), tablePlusInstalled: true), "This project does not use MySQL"),
            (.tablePlus(configured: configured(host: "db.example.com"), mysql: mysql(), tablePlusInstalled: true), "This project uses a remote database"),
            (.tablePlus(configured: configured(username: "app"), mysql: mysql(), tablePlusInstalled: true), "This project does not use Vaelen’s local root account"),
            (.tablePlus(configured: configured(), mysql: mysql(state: .stopped, health: "stopped"), tablePlusInstalled: true), "Start Vaelen MySQL to open this database"),
            (.tablePlus(configured: configured(database: "missing"), mysql: mysql(), tablePlusInstalled: true), "Database missing does not exist in Vaelen MySQL"),
            (.tablePlus(configured: configured(), mysql: mysql(databases: nil), tablePlusInstalled: true), "Database inventory is unavailable; refresh Vaelen")
        ]
        for (action, reason) in cases {
            XCTAssertFalse(action.isEnabled)
            XCTAssertEqual(action.reason, reason)
        }
    }
}
