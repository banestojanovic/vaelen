import XCTest
import VaelenCore
import VaelenIPC
@testable import VaelenCLI

final class RuntimeCatalogOutputTests: XCTestCase {
    func testPHPMySQLAndMailpitCatalogsUseSimpleWideAndNarrowLayouts() {
        let php = PHPRuntimeCatalog(
            availableVersions: ["8.4.23", "8.3.29"],
            installedVersions: [PHPRuntimeVersion(version: "8.4.23", running: true, isDefault: true, updateAvailable: false)],
            defaultVersion: "8.4.23",
            runningVersions: ["8.4.23"]
        )
        let mysql = MySQLVersionsPayload(available: ["8.4.11", "8.0.42"], installed: [], default: nil)
        let mailpit = MailpitVersionsPayload(available: ["1.31.1", "1.30.0"], installed: [])

        for (wide, narrow) in [
            (phpCatalogHumanOutput(php, width: 100, color: false), phpCatalogHumanOutput(php, width: 40, color: false)),
            (mysqlCatalogHumanOutput(mysql, width: 100, color: false), mysqlCatalogHumanOutput(mysql, width: 40, color: false)),
            (mailpitCatalogHumanOutput(mailpit, width: 100, color: false), mailpitCatalogHumanOutput(mailpit, width: 40, color: false))
        ] {
            XCTAssertFalse(wide.contains("+---"))
            XCTAssertFalse(wide.contains("\u{001B}["))
            XCTAssertFalse(narrow.contains("+---"))
            XCTAssertFalse(narrow.contains("\u{001B}["))
            XCTAssertLessThanOrEqual(narrow.components(separatedBy: "\n").map { $0.count }.max() ?? 0, 40)
        }

        let phpText = phpCatalogHumanOutput(php, width: 100, color: false)
        XCTAssertTrue(phpText.contains("8.4.23"))
        XCTAssertTrue(phpText.contains("8.3.29"))
        XCTAssertTrue(phpText.contains("Default"))
        XCTAssertTrue(phpText.contains("Running"))
        XCTAssertTrue(phpText.contains("Not installed"))
    }
}
