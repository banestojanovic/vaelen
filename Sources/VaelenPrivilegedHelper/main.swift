import Foundation
import Security
import VaelenCore

/// Vaelen privileged helper daemon (production: installed via SMAppService).
///
/// Runs as root under launchd. Implements ONLY Vaelen's fixed standard-ports
/// forwarding policy. It accepts no addresses, ports, paths, or PF syntax
/// from callers: every privileged operation is validated against
/// StandardPortsForwardingPolicy constants compiled into this binary.
///
/// Production requirements (NOT satisfied by ad-hoc development builds):
/// - Developer ID signature on both Vaelen.app and this tool
/// - SMPrivilegedExecutables entry in Vaelen.app's Info.plist
/// - SMAuthorizedClients in this tool's embedded Info.plist
/// - Embedded launchd plist with MachServices dev.vaelen.privileged-helper
/// - Placement in Vaelen.app/Contents/Library/LaunchServices
/// - Registration through SMAppService.daemon by Vaelen.app
final class StandardPortsHelper: NSObject, VaelenStandardPortsHelperProtocol {
    private let pfctl = "/sbin/pfctl"
    private let expectedAnchor = StandardPortsForwardingPolicy.anchorRules()

    func inspectionData(with reply: @escaping (Data?, NSError?) -> Void) {
        let inspection = StandardPortsHelperInspection(
            anchorContent: try? String(contentsOfFile: StandardPortsForwardingPolicy.anchorPath, encoding: .utf8),
            pfConfContent: try? String(contentsOfFile: StandardPortsForwardingPolicy.pfConfPath, encoding: .utf8),
            pfEnabled: pfEnabled()
        )
        reply(try? JSONEncoder().encode(inspection), nil)
    }

    func installForwarding(with reply: @escaping (NSString?, NSError?) -> Void) {
        do {
            try install()
            reply(pfEnableToken(), nil)
        } catch let error as NSError {
            reply(nil, error)
        }
    }

    func removeForwarding(pfToken: NSString?, with reply: @escaping (NSError?) -> Void) {
        do {
            try remove(pfToken: pfToken as String?)
            reply(nil)
        } catch let error as NSError {
            reply(error)
        }
    }

    private func install() throws {
        if FileManager.default.fileExists(atPath: StandardPortsForwardingPolicy.anchorPath) {
            guard let existing = try? String(contentsOfFile: StandardPortsForwardingPolicy.anchorPath, encoding: .utf8) else {
                throw StandardPortsHelperError.filesystemFailure.nsError
            }
            guard existing == expectedAnchor else { throw StandardPortsHelperError.ownershipMismatch.nsError }
        }
        guard let pfConf = try? String(contentsOfFile: StandardPortsForwardingPolicy.pfConfPath, encoding: .utf8) else {
            throw StandardPortsHelperError.filesystemFailure.nsError
        }
        if pfConf.contains(StandardPortsForwardingPolicy.anchorName),
           !StandardPortsForwardingPolicy.pfConfReferenceLines().allSatisfy(pfConf.contains) {
            // Foreign use of our anchor name: never overwrite, never adopt.
            throw StandardPortsHelperError.ownershipMismatch.nsError
        }
        // Fixed policy: the only anchor this helper will ever create.
        try StandardPortsForwardingPolicy.writeAnchor(to: StandardPortsForwardingPolicy.anchorPath)
        let updated = StandardPortsForwardingPolicy.addingReference(to: pfConf)
        if updated != pfConf { try atomicWrite(updated, to: StandardPortsForwardingPolicy.pfConfPath) }
        // The kernel only evaluates anchors referenced by its ACTIVE main
        // ruleset. Editing pf.conf on disk is not enough: reload the main
        // ruleset from disk (Apple anchors included) so the Vaelen
        // rdr-anchor reference becomes live, then load the anchor itself.
        try runPfctl(["-f", StandardPortsForwardingPolicy.pfConfPath])
        try runPfctl(["-a", StandardPortsForwardingPolicy.anchorName, "-f", StandardPortsForwardingPolicy.anchorPath])
    }

    private func remove(pfToken: String?) throws {
        if FileManager.default.fileExists(atPath: StandardPortsForwardingPolicy.anchorPath) {
            guard let existing = try? String(contentsOfFile: StandardPortsForwardingPolicy.anchorPath, encoding: .utf8) else {
                throw StandardPortsHelperError.filesystemFailure.nsError
            }
            guard existing == expectedAnchor else { throw StandardPortsHelperError.ownershipMismatch.nsError }
        }
        guard let pfConf = try? String(contentsOfFile: StandardPortsForwardingPolicy.pfConfPath, encoding: .utf8) else {
            throw StandardPortsHelperError.filesystemFailure.nsError
        }
        if FileManager.default.fileExists(atPath: StandardPortsForwardingPolicy.anchorPath) {
            do { try FileManager.default.removeItem(atPath: StandardPortsForwardingPolicy.anchorPath) }
            catch { throw StandardPortsHelperError.filesystemFailure.nsError }
        }
        let updated = StandardPortsForwardingPolicy.removingReference(from: pfConf)
        if updated != pfConf { try atomicWrite(updated, to: StandardPortsForwardingPolicy.pfConfPath) }
        // Reload the main ruleset so the removed reference leaves the
        // active kernel state, then flush any residual anchor rules.
        try runPfctl(["-f", StandardPortsForwardingPolicy.pfConfPath])
        try runPfctl(["-a", StandardPortsForwardingPolicy.anchorName, "-F", "all"])
        // Release our PF enable reference only with a token we issued.
        // Unknown/nil tokens bias to leaving shared PF infrastructure enabled.
        if let pfToken, Int(pfToken) != nil {
            _ = try? runPfctl(["-X", pfToken])
        }
    }

    private func pfEnabled() -> Bool? {
        guard let output = try? runPfctl(["-s", "info"]) else { return nil }
        return output.contains("Status: Enabled")
    }

    private func pfEnableToken() -> NSString? {
        if (try? runPfctl(["-s", "info"]))?.contains("Status: Enabled") == true { return nil }
        guard let output = try? runPfctl(["-E"]) else { return nil }
        for line in output.components(separatedBy: .newlines) {
            // pfctl -E prints "Token : <number>".
            let parts = line.components(separatedBy: "Token :")
            if parts.count == 2, let token = parts[1].trimmingCharacters(in: .whitespaces).nilIfEmpty, Int(token) != nil {
                return token as NSString
            }
        }
        return nil
    }

    @discardableResult
    private func runPfctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pfctl)
        process.arguments = arguments
        let output = Pipe(); let error = Pipe()
        process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StandardPortsHelperError.pfFailure.nsError }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func atomicWrite(_ content: String, to path: String) throws {
        let temporary = path + ".vaelen-tmp"
        do {
            try content.write(toFile: temporary, atomically: true, encoding: .utf8)
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temporary))
            } else {
                try FileManager.default.moveItem(atPath: temporary, toPath: path)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw StandardPortsHelperError.filesystemFailure.nsError
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let clientRequirement = "anchor apple generic and identifier \"dev.vaelen.app\""

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard authorizedClient(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: VaelenStandardPortsHelperProtocol.self)
        connection.exportedObject = StandardPortsHelper()
        connection.resume()
        return true
    }

    private func authorizedClient(_ connection: NSXPCConnection) -> Bool {
        var code: SecCode?
        let attributes: [CFString: Any] = [kSecGuestAttributePid: connection.processIdentifier]
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(clientRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: "dev.vaelen.privileged-helper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
