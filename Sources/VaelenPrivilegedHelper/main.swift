import Foundation
import Security
import Darwin
import OSLog
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
    private let portsLogger = Logger(subsystem: "dev.vaelen.privileged-helper", category: "standard-ports")

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
        portsLogger.debug("PF inspection started")
        let inspection = StandardPortsHelperInspection(
            anchorContent: try? String(contentsOfFile: StandardPortsForwardingPolicy.anchorPath, encoding: .utf8),
            pfConfContent: try? String(contentsOfFile: StandardPortsForwardingPolicy.pfConfPath, encoding: .utf8),
            pfEnabled: pfEnabled(),
            forwardingActive: forwardingActive()
        )
        portsLogger.info("PF inspection completed; PF-enabled and forwarding-active observations collected")
        reply(try? JSONEncoder().encode(inspection), nil)
    }

    func installForwarding(with reply: @escaping (Data?, NSError?) -> Void) {
        portsLogger.info("PF install request entered helper")
        do {
            let acquisition = try install()
            portsLogger.info("PF install acquisition produced; persistent file changes: \(acquisition.changedPFConf || acquisition.changedAnchor, privacy: .public)")
            reply(try JSONEncoder().encode(acquisition), nil)
        } catch let error as NSError {
            portsLogger.error("PF install failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func removeForwarding(acquisition: Data, with reply: @escaping (NSError?) -> Void) {
        do {
            guard let record = try? JSONDecoder().decode(StandardPortsAcquisition.self, from: acquisition) else { throw StandardPortsHelperError.ownershipMismatch.nsError }
            try remove(acquisition: record)
            reply(nil)
        } catch let error as NSError {
            reply(error)
        }
    }

    private func install() throws -> StandardPortsAcquisition {
        portsLogger.debug("PF install preflight started")
        let pfPre = try fileSnapshot(StandardPortsForwardingPolicy.pfConfPath)
        let anchorPre = try fileSnapshot(StandardPortsForwardingPolicy.anchorPath)
        guard let confBytes = pfPre.bytes, let pfConf = String(data: confBytes, encoding: .utf8) else { throw StandardPortsHelperError.filesystemFailure.nsError }
        let refLines = StandardPortsForwardingPolicy.pfConfReferenceLines()
        let hasAnyReference = refLines.contains { pfConf.contains($0) } || pfConf.contains(StandardPortsForwardingPolicy.anchorName)
        let exactExisting = anchorPre.exists && anchorPre.bytes == Data(expectedAnchor.utf8) && StandardPortsForwardingPolicy.hasExactReference(in: pfConf)
        let absent = !anchorPre.exists && !hasAnyReference
        guard exactExisting || absent else { throw StandardPortsHelperError.ownershipMismatch.nsError }
        let initiallyEnabled = pfEnabled() == true
        let activeBefore = forwardingActive() == true
        portsLogger.info("PF install preflight completed; exact compatible state: \(exactExisting, privacy: .public), PF initially enabled: \(initiallyEnabled, privacy: .public), forwarding active: \(activeBefore, privacy: .public)")
        var token: String?
        var vaelenPFConf: StandardPortsFileSnapshot?
        var vaelenAnchor: StandardPortsFileSnapshot?
        do {
            if !initiallyEnabled {
                portsLogger.info("PF enable-reference acquisition attempted")
                token = try enablePF()
                portsLogger.info("PF enable-reference acquisition completed; token returned: \(token != nil, privacy: .public)")
            }
            if absent {
                try atomicWrite(Data(expectedAnchor.utf8), to: StandardPortsForwardingPolicy.anchorPath, owner: 0, group: 0, mode: 0o644)
                vaelenAnchor = try fileSnapshot(StandardPortsForwardingPolicy.anchorPath)
                try atomicWrite(Data(StandardPortsForwardingPolicy.addingReference(to: pfConf).utf8), to: StandardPortsForwardingPolicy.pfConfPath, owner: pfPre.owner ?? 0, group: pfPre.group ?? 0, mode: pfPre.mode ?? 0o644)
                vaelenPFConf = try fileSnapshot(StandardPortsForwardingPolicy.pfConfPath)
            }
            if absent || !activeBefore {
                portsLogger.info("PF main configuration reload attempted")
                try runPfctl(["-f", StandardPortsForwardingPolicy.pfConfPath], stage: "reload-main-configuration")
                portsLogger.info("PF main configuration reload completed")
                portsLogger.info("PF fixed anchor load attempted")
                try runPfctl(["-a", StandardPortsForwardingPolicy.anchorName, "-f", StandardPortsForwardingPolicy.anchorPath], stage: "load-fixed-anchor")
                portsLogger.info("PF fixed anchor load completed")
            }
            portsLogger.info("PF forwarding verification attempted")
            let enabledAfter = pfEnabled() == true
            let activeAfter = forwardingActive() == true
            portsLogger.info("PF forwarding verification completed; PF enabled: \(enabledAfter, privacy: .public), forwarding active: \(activeAfter, privacy: .public)")
            guard enabledAfter, activeAfter else { throw StandardPortsHelperError.pfFailure.nsError }
            return StandardPortsAcquisition(
                preimagePFConf: pfPre, preimageAnchor: anchorPre,
                writtenPFConf: try fileSnapshot(StandardPortsForwardingPolicy.pfConfPath),
                writtenAnchor: try fileSnapshot(StandardPortsForwardingPolicy.anchorPath),
                changedPFConf: absent, changedAnchor: absent, forwardingWasActive: activeBefore, pfToken: token
            )
        } catch {
            portsLogger.error("PF install stage failed; attempting best-effort rollback")
            if absent {
                if let vaelenPFConf { try? restoreIfMatches(StandardPortsForwardingPolicy.pfConfPath, expected: vaelenPFConf, preimage: pfPre) }
                if let vaelenAnchor { try? restoreIfMatches(StandardPortsForwardingPolicy.anchorPath, expected: vaelenAnchor, preimage: anchorPre) }
            }
            if let token { _ = try? runPfctl(["-X", token], stage: "rollback-enable-reference") }
            throw error
        }
    }

    private func remove(acquisition: StandardPortsAcquisition) throws {
        let currentConf = try fileSnapshot(StandardPortsForwardingPolicy.pfConfPath)
        let currentAnchor = try fileSnapshot(StandardPortsForwardingPolicy.anchorPath)
        guard acquisition.preimagePFConf.bytes != nil,
              acquisition.changedPFConf ? currentConf == acquisition.writtenPFConf : currentConf == acquisition.preimagePFConf,
              acquisition.changedAnchor ? currentAnchor == acquisition.writtenAnchor : currentAnchor == acquisition.preimageAnchor else {
            throw StandardPortsHelperError.ownershipMismatch.nsError
        }
        if !acquisition.forwardingWasActive, forwardingActive() == true {
            try runPfctl(["-a", StandardPortsForwardingPolicy.anchorName, "-F", "all"], stage: "clear-fixed-anchor")
        }
        if acquisition.changedPFConf { try restoreIfMatches(StandardPortsForwardingPolicy.pfConfPath, expected: acquisition.writtenPFConf, preimage: acquisition.preimagePFConf) }
        if acquisition.changedAnchor { try restoreIfMatches(StandardPortsForwardingPolicy.anchorPath, expected: acquisition.writtenAnchor, preimage: acquisition.preimageAnchor) }
        if acquisition.changedPFConf { try runPfctl(["-f", StandardPortsForwardingPolicy.pfConfPath], stage: "restore-main-configuration") }
        if let token = acquisition.pfToken, Int(token) != nil { try runPfctl(["-X", token], stage: "release-enable-reference") }
    }

    private func fileSnapshot(_ path: String) throws -> StandardPortsFileSnapshot {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return StandardPortsFileSnapshot(exists: false, bytes: nil, owner: nil, group: nil, mode: nil) }
            throw StandardPortsHelperError.filesystemFailure.nsError
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw StandardPortsHelperError.ownershipMismatch.nsError }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw StandardPortsHelperError.ownershipMismatch.nsError }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              let bytes = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() else { throw StandardPortsHelperError.ownershipMismatch.nsError }
        return StandardPortsFileSnapshot(exists: true, bytes: bytes, owner: opened.st_uid, group: opened.st_gid, mode: UInt16(opened.st_mode & 0o7777))
    }

    private func restoreIfMatches(_ path: String, expected: StandardPortsFileSnapshot?, preimage: StandardPortsFileSnapshot) throws {
        guard let expected, try fileSnapshot(path) == expected else { throw StandardPortsHelperError.ownershipMismatch.nsError }
        if preimage.exists {
            guard let bytes = preimage.bytes else { throw StandardPortsHelperError.filesystemFailure.nsError }
            try atomicWrite(bytes, to: path, owner: preimage.owner ?? 0, group: preimage.group ?? 0, mode: preimage.mode ?? 0o644)
        } else { try FileManager.default.removeItem(atPath: path) }
    }

    private func forwardingActive() -> Bool? {
        guard let enabled = pfEnabled() else { return nil }
        guard enabled else { return false }
        guard let rules = try? runPfctl(["-a", StandardPortsForwardingPolicy.anchorName, "-s", "nat"], stage: "inspect-fixed-anchor-rules") else { return nil }
        let normalized = rules.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // pfctl renders well-known source ports as service names (for example
        // `port = http`) rather than decimal numbers. The anchor's on-disk
        // rules are independently required to match Vaelen's exact fixed
        // policy; here require both unique backend ports in the live NAT
        // listing, which avoids treating a successful connection through the
        // redirect as evidence of ownership.
        let active = normalized.contains("port 8787") && normalized.contains("port 8743")
        portsLogger.info("PF fixed anchor inspection completed; both Vaelen backend redirect ports observed: \(active, privacy: .public)")
        return active
    }

    private func enablePF() throws -> String? {
        let output = try runPfctl(["-E"], stage: "enable-reference")
        if let token = StandardPortsPFEnableToken.parse(stdout: output, stderr: "") {
            portsLogger.info("PF enable-reference command succeeded and returned a token")
            return token
        }
        let diagnostic = Self.safePFEnableDiagnostic(output)
        portsLogger.error("pfctl stage parse-enable-reference-token completed with exit 0 but no numeric token was found; output: \(diagnostic, privacy: .public)")
        throw StandardPortsHelperError.pfCommandFailure(stage: "parse-enable-reference-token", terminationStatus: 0, diagnostic: diagnostic)
    }

    private func pfEnabled() -> Bool? {
        guard let output = try? runPfctl(["-s", "info"], stage: "inspect-pf-state") else { return nil }
        return output.contains("Status: Enabled")
    }

    private func pfEnableToken() -> NSString? {
        if (try? runPfctl(["-s", "info"], stage: "inspect-pf-state"))?.contains("Status: Enabled") == true { return nil }
        guard let output = try? runPfctl(["-E"], stage: "enable-reference") else { return nil }
        return StandardPortsPFEnableToken.parse(stdout: output, stderr: "") as NSString?
    }

    @discardableResult
    private func runPfctl(_ arguments: [String], stage: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pfctl)
        process.arguments = arguments
        let output = Pipe(); let error = Pipe()
        process.standardOutput = output; process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            portsLogger.error("pfctl stage \(stage, privacy: .public) could not launch: \(error.localizedDescription, privacy: .public)")
            throw StandardPortsHelperError.pfCommandFailure(stage: stage, terminationStatus: -1, diagnostic: error.localizedDescription)
        }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = Self.safePFDiagnostic(stderr)
        guard process.terminationStatus == 0 else {
            portsLogger.error("pfctl stage \(stage, privacy: .public) exited \(process.terminationStatus, privacy: .public): \(diagnostic, privacy: .public)")
            throw StandardPortsHelperError.pfCommandFailure(stage: stage, terminationStatus: process.terminationStatus, diagnostic: diagnostic)
        }
        portsLogger.debug("pfctl stage \(stage, privacy: .public) completed successfully")
        let standardOutput = String(decoding: stdout, as: UTF8.self)
        let standardError = String(decoding: stderr, as: UTF8.self)
        return [standardOutput, standardError].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func safePFEnableDiagnostic(_ output: String) -> String {
        let redacted = output.replacingOccurrences(of: #"(?im)Token\s*:\s*[^\s]+"#, with: "Token: <redacted>", options: .regularExpression)
        return safePFDiagnostic(Data(redacted.utf8))
    }

    private static func safePFDiagnostic(_ data: Data) -> String {
        let raw = String(decoding: data.prefix(1024), as: UTF8.self)
        let oneLine = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" ? " " : String($0) }.joined()
        return String(oneLine.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func atomicWrite(_ content: String, to path: String) throws {
        try atomicWrite(Data(content.utf8), to: path, owner: 0, group: 0, mode: 0o644)
    }

    private func atomicWrite(_ content: Data, to path: String, owner: UInt32, group: UInt32, mode: UInt16) throws {
        let temporary = path + ".vaelen-tmp"
        do {
            try content.write(to: URL(fileURLWithPath: temporary), options: .atomic)
            guard chown(temporary, uid_t(owner), gid_t(group)) == 0, chmod(temporary, mode_t(mode)) == 0 else { throw StandardPortsHelperError.filesystemFailure.nsError }
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
