import Foundation
import Security
import Darwin
import VaelenCore

/// Vaelen privileged helper daemon (production: installed via SMAppService).
///
/// Runs as root under launchd. Implements ONLY Vaelen's fixed standard-ports
/// forwarding policy. It accepts no addresses, ports, paths, or PF syntax
/// from callers: every privileged operation is validated against
/// StandardPortsForwardingPolicy constants compiled into this binary.
///
/// The signed executable and its BundleProgram launchd plist are embedded in
/// Vaelen.app and registered through SMAppService.daemon. Both development
/// and distribution builds must carry meaningful Apple code signatures.
final class StandardPortsHelper: NSObject, VaelenStandardPortsHelperProtocol {
    private let pfctl = "/sbin/pfctl"
    private let expectedAnchor = StandardPortsForwardingPolicy.anchorRules()
    private let resolverPath = "/etc/resolver/test"

    func inspectTestResolver(with reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let snapshot = try ResolverFileSnapshot.read(resolverPath)
            reply(try JSONEncoder().encode(snapshot), nil)
        } catch { reply(nil, resolverError(1, "Unable to safely inspect /etc/resolver/test: \(error.localizedDescription)")) }
    }

    func installTestResolver(port: Int, replacing: Data, with reply: @escaping (Data?, NSError?) -> Void) {
        do {
            guard (1024...65535).contains(port) else { throw resolverError(2, "Invalid DNS responder port") }
            let expected = try decodeSnapshot(replacing)
            let actual = try ResolverFileSnapshot.read(resolverPath)
            guard actual == expected else {
                throw resolverError(3, "Resolver changed before acquisition; expected [\(describe(expected))], actual [\(describe(actual))]. No resolver change was made.")
            }
            let bytes = Data("nameserver 127.0.0.1\nport \(port)\n".utf8)
            try writeResolver(bytes, owner: 0, group: 0, mode: 0o644)
            let installed = try ResolverFileSnapshot.read(resolverPath)
            guard installed.bytes == bytes else { throw resolverError(4, "Resolver install verification failed") }
            reply(try JSONEncoder().encode(installed), nil)
        } catch let error as NSError { reply(nil, error) }
        catch { reply(nil, resolverError(1, "Unable to install /etc/resolver/test: \(error.localizedDescription)")) }
    }

    func restoreTestResolver(expected: Data, preimage: Data, with reply: @escaping (NSError?) -> Void) {
        do {
            let installed = try decodeSnapshot(expected)
            let previous = try decodeSnapshot(preimage)
            guard try ResolverFileSnapshot.read(resolverPath) == installed else { throw resolverError(3, "Resolver changed externally; it was not overwritten") }
            if previous.exists {
                guard let bytes = previous.bytes, bytes.count <= 1_048_576 else { throw resolverError(5, "Invalid resolver preimage") }
                try writeResolver(bytes, owner: previous.owner ?? 0, group: previous.group ?? 0, mode: previous.mode ?? 0o644)
            } else {
                try FileManager.default.removeItem(atPath: resolverPath)
            }
            let restored = try ResolverFileSnapshot.read(resolverPath)
            guard restored.exists == previous.exists, restored.bytes == previous.bytes,
                  !previous.exists || (restored.owner == previous.owner && restored.group == previous.group && restored.mode == previous.mode) else {
                throw resolverError(4, "Resolver restore verification failed")
            }
            reply(nil)
        } catch let error as NSError { reply(error) }
        catch { reply(resolverError(1, "Unable to restore /etc/resolver/test: \(error.localizedDescription)")) }
    }

    private func decodeSnapshot(_ data: Data) throws -> ResolverFileSnapshot {
        guard data.count <= 1_100_000, let value = try? JSONDecoder().decode(ResolverFileSnapshot.self, from: data),
              (!value.exists || (value.bytes != nil && (value.bytes?.count ?? 0) <= 1_048_576)) else {
            throw resolverError(5, "Invalid resolver snapshot")
        }
        return value
    }

    private func describe(_ snapshot: ResolverFileSnapshot) -> String {
        let bytes = snapshot.bytes?.base64EncodedString() ?? "nil"
        let owner = snapshot.owner.map { String($0) } ?? "nil"
        let group = snapshot.group.map { String($0) } ?? "nil"
        let mode = snapshot.mode.map { String($0, radix: 8) } ?? "nil"
        let device = snapshot.device.map { String($0) } ?? "nil"
        let inode = snapshot.inode.map { String($0) } ?? "nil"
        let fileType = snapshot.fileType.map { String($0) } ?? "nil"
        return "exists=\(snapshot.exists), bytes.base64=\(bytes), owner=\(owner), group=\(group), mode=\(mode), device=\(device), inode=\(inode), fileType=\(fileType)"
    }

    private func writeResolver(_ bytes: Data, owner: UInt32, group: UInt32, mode: UInt16) throws {
        // Atomic replacement is always confined to the one fixed regular-file
        // target. Verify parent and target shape immediately before writing.
        var parent = stat()
        guard lstat("/etc/resolver", &parent) == 0, (parent.st_mode & S_IFMT) == S_IFDIR else { throw resolverError(1, "Resolver directory is not a real directory") }
        var current = stat()
        if lstat(resolverPath, &current) == 0, (current.st_mode & S_IFMT) != S_IFREG { throw resolverError(1, "Resolver target is not a regular file") }
        try bytes.write(to: URL(fileURLWithPath: resolverPath), options: .atomic)
        guard chown(resolverPath, uid_t(owner), gid_t(group)) == 0,
              chmod(resolverPath, mode_t(mode)) == 0 else { throw resolverError(1, "Unable to restore resolver metadata") }
    }

    private func resolverError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "dev.vaelen.privileged-helper.dns", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

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
    // Privileged requests originate from the bundled Core, not the GUI. The
    // Core identifier is additionally constrained to the helper's signing team
    // by VaelenPrivilegedClientTrust below.
    private let clientRequirement = "anchor apple generic and identifier \"vaelend\""
    private let lock = NSLock()
    private var activeConnections = 0
    private var idleExit: DispatchWorkItem?

    override init() {
        super.init()
        scheduleIdleExit()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard authorizedClient(connection) else { return false }
        lock.lock()
        activeConnections += 1
        idleExit?.cancel()
        idleExit = nil
        lock.unlock()
        connection.exportedInterface = NSXPCInterface(with: VaelenStandardPortsHelperProtocol.self)
        connection.exportedObject = StandardPortsHelper()
        connection.invalidationHandler = { [weak self] in self?.connectionDidClose() }
        connection.resume()
        return true
    }

    private func connectionDidClose() {
        lock.lock()
        activeConnections = max(0, activeConnections - 1)
        let shouldSchedule = activeConnections == 0
        lock.unlock()
        if shouldSchedule { scheduleIdleExit() }
    }

    private func scheduleIdleExit() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let idle = self.activeConnections == 0
            self.lock.unlock()
            if idle { exit(EXIT_SUCCESS) }
        }
        lock.lock()
        idleExit?.cancel()
        idleExit = work
        lock.unlock()
        // LaunchDaemons with MachServices are demand-started. Exit after an
        // idle grace period so approval remains durable without a resident
        // root process when Vaelen/Core is inactive.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3), execute: work)
    }

    private func authorizedClient(_ connection: NSXPCConnection) -> Bool {
        var code: SecCode?
        let attributes: [CFString: Any] = [kSecGuestAttributePid: connection.processIdentifier]
        var requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(clientRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
              let clientIdentity = signingIdentity(code),
              let helperIdentity = ownSigningIdentity() else { return false }
        return VaelenPrivilegedClientTrust.permits(client: clientIdentity, helper: helperIdentity)
    }

    private func ownSigningIdentity() -> VaelenSigningIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "anchor apple generic and identifier \"dev.vaelen.privileged-helper\"" as CFString,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        return signingIdentity(code)
    }

    private func signingIdentity(_ code: SecCode) -> VaelenSigningIdentity? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return VaelenSigningIdentity(identifier: identifier, teamIdentifier: team)
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: "dev.vaelen.privileged-helper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
