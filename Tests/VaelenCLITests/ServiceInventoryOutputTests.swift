import XCTest
import VaelenCore
import VaelenIPC
@testable import VaelenCLI

final class ServiceInventoryOutputTests: XCTestCase {
    func testNamedPostgreSQLLifecycleCommandsParseWithExactPorts() throws {
        guard case .postgresqlInstance(.create, name: "shop-db", port: 55432, json: true) = try VaelenCLIMain.parse(["service", "postgresql", "create", "shop-db", "--port", "55432", "--json"]) else { return XCTFail("PostgreSQL create did not parse") }
        guard case .postgresqlInstance(.status, name: "shop-db", port: nil, json: false) = try VaelenCLIMain.parse(["service", "postgresql", "status", "shop-db"]) else { return XCTFail("PostgreSQL status did not parse") }
        for args in [["service", "postgresql", "create", "bad name"], ["service", "postgresql", "create", "shop-db", "--port", "0"], ["service", "postgresql", "start", "shop-db", "--port", "5000"], ["service", "postgresql", "remove"], ["service", "postgresql", "status", "shop-db", "--json", "--json"]] {
            XCTAssertThrowsError(try VaelenCLIMain.parse(args), "Expected rejection for \(args)")
        }
        XCTAssertTrue(CLIDocumentation.focusedText(for: ["service", "postgresql"]).contains("service postgresql create"))
    }

    func testServiceInstancesParsingAndOutput() throws {
        guard case .serviceInstances(json: false) = try VaelenCLIMain.parse(["service", "instances"]) else { return XCTFail("service instances did not parse") }
        guard case .serviceInstances(json: true) = try VaelenCLIMain.parse(["service", "instances", "--json"]) else { return XCTFail("service instances --json did not parse") }
        for args in [["service", "instances", "extra"], ["service", "instances", "--json", "--json"], ["service", "instances", "--unknown"]] { XCTAssertThrowsError(try VaelenCLIMain.parse(args)) }
        XCTAssertTrue(CLIDocumentation.focusedText(for: ["service", "instances"]).contains("val service instances --json"))

        let empty = ServiceInstanceInventoryResult(.init(entries: []))
        XCTAssertEqual(try ServiceInstanceInventoryFormatter.render(empty, json: false), "No service instances are registered.")
        let name = try ProjectInstanceName("primary")
        let projectID = ProjectID()
        let bindingAlias = try ProjectBindingAlias("database")
        let entry = ServiceInstanceInventoryEntryWire(instance: .init(kind: .mysql, name: name, packageIdentifier: "vendor/mysql@8.4.1", endpoint: .mysql(port: 3307), dataDirectory: "/data/mysql"), owners: [.manual, .project(projectID: projectID, alias: bindingAlias, version: "8.4.1")])
        let laterEntry = ServiceInstanceInventoryEntryWire(instance: .init(kind: .postgresql, name: try ProjectInstanceName("primary"), packageIdentifier: "vendor/postgresql@17", endpoint: .postgresql(port: 5432), dataDirectory: "/data/postgresql"), owners: [])
        let inventory = ServiceInstanceInventoryResult(entries: [laterEntry, entry])
        let human = try ServiceInstanceInventoryFormatter.render(inventory, json: false)
        XCTAssertTrue(human.contains("mysql/primary"))
        XCTAssertLessThan(try XCTUnwrap(human.range(of: "mysql/primary")).lowerBound, try XCTUnwrap(human.range(of: "postgresql/primary")).lowerBound)
        XCTAssertTrue(human.contains("mysql 127.0.0.1:3307"))
        XCTAssertTrue(human.contains("vendor/mysql@8.4.1"))
        XCTAssertTrue(human.contains("/data/mysql"))
        XCTAssertTrue(human.contains("manual, project \(projectID) / database (8.4.1)"))
        let json = try ServiceInstanceInventoryFormatter.render(inventory, json: true)
        XCTAssertFalse(json.contains("health"))
        XCTAssertLessThan(try XCTUnwrap(json.range(of: "mysql")).lowerBound, try XCTUnwrap(json.range(of: "postgresql")).lowerBound)
        XCTAssertEqual(try JSONDecoder().decode(ServiceInstanceInventoryResult.self, from: Data(json.utf8)).entries.map { $0.instance.kind }, [.mysql, .postgresql])
    }

    func testServiceListParsesAndRejectsUnsupportedArguments() throws {
        guard case .serviceList(json: false) = try VaelenCLIMain.parse(["service", "list"]) else {
            return XCTFail("service list did not parse")
        }
        guard case .serviceList(json: true) = try VaelenCLIMain.parse(["service", "list", "--json"]) else {
            return XCTFail("service list --json did not parse")
        }
        XCTAssertThrowsError(try VaelenCLIMain.parse(["service", "list", "--unknown"]))
        XCTAssertThrowsError(try VaelenCLIMain.parse(["service", "list", "extra"]))
        guard case .serviceAvailable(json: false) = try VaelenCLIMain.parse(["service", "available"]) else {
            return XCTFail("service available did not parse")
        }
        XCTAssertTrue(CLIDocumentation.focusedText(for: ["service", "list"]).contains("val service list --json"))
    }

    func testServiceVersionsAliasesParseStrictlyAndAppearInHelp() throws {
        guard case .mysqlVersions(json: false) = try VaelenCLIMain.parse(["service", "versions", "mysql"]) else {
            return XCTFail("service versions mysql did not map to MySQL versions")
        }
        guard case .mysqlVersions(json: true) = try VaelenCLIMain.parse(["service", "versions", "mysql", "--json"]) else {
            return XCTFail("service versions mysql --json did not map to MySQL versions")
        }
        guard case .mailpitVersions(json: false) = try VaelenCLIMain.parse(["service", "versions", "mailpit"]) else {
            return XCTFail("service versions mailpit did not map to Mailpit versions")
        }
        guard case .mailpitVersions(json: true) = try VaelenCLIMain.parse(["service", "versions", "mailpit", "--json"]) else {
            return XCTFail("service versions mailpit --json did not map to Mailpit versions")
        }

        for args in [
            ["service", "versions"],
            ["service", "versions", "postgres"],
            ["service", "versions", "mysql", "--json", "--json"],
            ["service", "versions", "mailpit", "extra"]
        ] {
            XCTAssertThrowsError(try VaelenCLIMain.parse(args), "Expected rejection for \(args)")
        }

        let help = CLIDocumentation.focusedText(for: ["service", "versions"])
        XCTAssertTrue(help.contains("val service versions <type>"))
        XCTAssertTrue(help.contains("val service versions <type> --json"))
    }

    func testInventoryPreservesBothStatusObservationsInJSONAndHumanOutput() throws {
        let inventory = ServiceInventory(mysql: .available(MySQLStatus(
            state: .running, health: "healthy", installedVersion: "8.4.2", selectedVersion: "8.4.2", pid: 123,
            port: 3307, socket: "/tmp/mysql.sock", datadir: "/data/mysql", executablePath: "/bin/mysqld"
        )), mailpit: .available(MailpitStatus(
            state: .stopped, health: "stopped", installedVersion: "1.31.1", pid: nil,
            smtpPort: 1026, httpPort: 8026, database: "/data/mailpit.db", uiEndpoint: "http://127.0.0.1:8026",
            executablePath: "/bin/mailpit"
        )))

        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.services.map(\.service), [.mysql, .mailpit])
        XCTAssertEqual(inventory.services.map(\.instance), ["default", "default"])
        XCTAssertEqual(inventory.services[0].state, "running")
        XCTAssertEqual(inventory.services[0].health, "healthy")
        XCTAssertEqual(inventory.services[0].installedVersion, "8.4.2")
        XCTAssertEqual(inventory.services[0].selectedVersion, "8.4.2")
        XCTAssertEqual(inventory.services[0].pid, 123)
        XCTAssertEqual(inventory.services[0].endpoints, ["tcp": "127.0.0.1:3307", "socket": "/tmp/mysql.sock"])
        XCTAssertEqual(inventory.services[1].state, "stopped")
        XCTAssertEqual(inventory.services[1].installedVersion, "1.31.1")
        XCTAssertEqual(inventory.services[1].endpoints, ["smtp": "127.0.0.1:1026", "web": "http://127.0.0.1:8026"])

        let json = try ServiceInventoryFormatter.json(inventory)
        let decoded = try JSONDecoder().decode(ServiceInventory.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, inventory)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["complete", "services"])
        let rows = try XCTUnwrap(object["services"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows[0].keys), ["service", "instance", "state", "health", "installedVersion", "selectedVersion", "pid", "endpoints", "observationError"])
        XCTAssertTrue(json.contains("\"complete\" : true"))
        XCTAssertTrue(json.contains("mysql.sock"))
        XCTAssertTrue(json.contains("127.0.0.1:8026"))

        let human = ServiceInventoryFormatter.human(inventory)
        XCTAssertTrue(human.contains("MySQL"))
        XCTAssertTrue(human.contains("Mailpit"))
        XCTAssertTrue(human.contains("running"))
        XCTAssertTrue(human.contains("127.0.0.1:3307"))
        XCTAssertTrue(human.contains("http://127.0.0.1:8026"))
        XCTAssertTrue(human.contains("Snapshot is sequential"))
        XCTAssertTrue(human.contains("legacy service"))
    }

    func testInventoryKeepsUnavailableServiceRowAndMarksIncomplete() throws {
        let inventory = ServiceInventory(mysql: .available(MySQLStatus(
            state: .notInstalled, health: "not installed", installedVersion: nil, selectedVersion: nil, pid: nil,
            port: 3306, socket: "/tmp/mysql.sock", datadir: "/data/mysql", executablePath: ""
        )), mailpit: .unavailable("Core could not observe Mailpit"))

        XCTAssertFalse(inventory.complete)
        XCTAssertEqual(inventory.services.count, 2)
        let unavailable = try XCTUnwrap(inventory.services.first { $0.service == .mailpit })
        XCTAssertEqual(unavailable.state, "unavailable")
        XCTAssertNil(unavailable.health)
        XCTAssertNil(unavailable.installedVersion)
        XCTAssertNil(unavailable.selectedVersion)
        XCTAssertNil(unavailable.pid)
        XCTAssertTrue(unavailable.endpoints.isEmpty)
        XCTAssertEqual(unavailable.observationError, "Core could not observe Mailpit")

        let json = try ServiceInventoryFormatter.json(inventory)
        XCTAssertTrue(json.contains("\"complete\" : false"))
        XCTAssertTrue(json.contains("\"state\" : \"unavailable\""))
        let human = ServiceInventoryFormatter.human(inventory)
        XCTAssertTrue(human.contains("Core could not observe Mailpit"))
        XCTAssertTrue(human.localizedCaseInsensitiveContains("incomplete"))
    }

    func testUnavailableCoreProjectsBothServicesAsUnavailable() throws {
        let inventory = ServiceInventory.unavailableCore("Core handshake failed")

        XCTAssertFalse(inventory.complete)
        XCTAssertEqual(inventory.services.map(\.service), [.mysql, .mailpit])
        XCTAssertTrue(inventory.services.allSatisfy { $0.state == "unavailable" })
        XCTAssertTrue(inventory.services.allSatisfy { $0.observationError == "Core handshake failed" })
        let decoded = try JSONDecoder().decode(ServiceInventory.self, from: Data(ServiceInventoryFormatter.json(inventory).utf8))
        XCTAssertEqual(decoded, inventory)
    }
}
