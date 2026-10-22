import XCTest
import VaelenCore
@testable import VaelenCLI

final class ServiceInventoryOutputTests: XCTestCase {
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
