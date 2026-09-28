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

    func testServerLevelTablePlusConnectionIsHealthyLocalAndCredentialFree() {
        let action = MySQLDatabaseViewerAction.tablePlus(mysql: mysql(), tablePlusInstalled: true)
        XCTAssertEqual(action.url?.absoluteString, "mysql://127.0.0.1:3306")
        XCTAssertNil(action.url?.user)
        XCTAssertNil(action.url?.password)
        XCTAssertEqual(action.url?.path, "")
        XCTAssertEqual(action.reason, "Open Vaelen MySQL in TablePlus")
    }

    func testServerLevelTablePlusConnectionFailsClosedWithHelpfulReasons() {
        XCTAssertEqual(MySQLDatabaseViewerAction.tablePlus(mysql: nil, tablePlusInstalled: true).reason, "Vaelen MySQL status is unavailable")
        XCTAssertEqual(MySQLDatabaseViewerAction.tablePlus(mysql: mysql(state: .stopped, health: "stopped"), tablePlusInstalled: true).reason, "Start Vaelen MySQL to open a connection")
        XCTAssertEqual(MySQLDatabaseViewerAction.tablePlus(mysql: mysql(), tablePlusInstalled: false).reason, "TablePlus is not installed")
        XCTAssertFalse(MySQLDatabaseViewerAction.tablePlus(mysql: mysql(state: .stopped, health: "stopped"), tablePlusInstalled: true).isEnabled)
    }

    func testProjectTablePlusEligibilityDoesNotRequireDesiredMySQLFlag() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("DB_CONNECTION=mysql\nDB_HOST=127.0.0.1\nDB_PORT=3306\nDB_DATABASE=callthewaiter\nDB_USERNAME=root\n".utf8)
            .write(to: root.appendingPathComponent(".env"))
        try Data("version: 1\nservices:\n  mailpit: true\n".utf8)
            .write(to: root.appendingPathComponent("vaelen.yml"))

        let phpPackage = PHPPackage(version: "8.4.23", architecture: "arm64", packagePath: "/php/8.4.23", cliPath: "/php/8.4.23/php", fpmPath: "/php/8.4.23/php-fpm", source: "test", cliSHA256: "", fpmSHA256: "", installedAt: Date())
        let phpStatus = PHPStatus(version: "8.4.23", package: phpPackage, state: .running, pid: 7, socket: "/php.sock", health: "healthy", isDefault: true)
        let mysql = MySQLStatus(state: .running, health: "healthy", installedVersion: "8.4.11", selectedVersion: "8.4.11", pid: 8, port: 3306, socket: "/mysql.sock", datadir: "/mysql", executablePath: "/mysqld", databases: ["callthewaiter"])
        let stoppedMailpit = MailpitStatus(state: .stopped, health: "stopped", installedVersion: "1.31.1", pid: nil, smtpPort: 1025, httpPort: 8025, database: "", uiEndpoint: "", executablePath: "")
        let report = ProjectEnvironmentInspector().inspect(
            project: Project(id: ProjectID(), name: "callthewaiter", rootPath: CanonicalPath(url: root), registrationKind: .linked, availability: .available),
            routes: [], phpPackages: [phpPackage], phpStatuses: [phpStatus], phpDefault: "8.4", mysql: mysql, mailpit: stoppedMailpit,
            router: RouterStatus(provider: "test", state: .stopped, health: .unknown, routeCount: 0),
            dns: DNSStatus(state: .installed, ownership: .vaelen, health: "healthy"),
            tls: TLSStatus(state: .absent), standardPorts: StandardPortsStatus(state: .absent)
        )

        XCTAssertNil(report.desired.mysql)
        XCTAssertEqual(report.observed.php.fpmHealth, "healthy")
        XCTAssertTrue(report.diagnostics.contains { $0.code == "MAILPIT_NOT_HEALTHY" && $0.severity == .warning })
        XCTAssertFalse(report.diagnostics.contains { $0.code == "PHP_FPM_NOT_HEALTHY" })
        let action = ProjectDatabaseViewerAction.tablePlus(report: report, tablePlusInstalled: true)
        XCTAssertTrue(action.isEnabled, action.reason)
        XCTAssertEqual(action.url?.absoluteString, "mysql://root@127.0.0.1:3306/callthewaiter")
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
