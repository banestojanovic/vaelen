import Foundation
import Security
import CryptoKit

/// Evidence produced by the read-only trust-boundary check for a packaged
/// controller.  This type deliberately contains observations only; it has no
/// lifecycle, persistence, or ServiceManagement authority.
public struct ArtifactPreflightEvidence: Equatable, Sendable {
    public let appURL: URL
    public let appIdentifier: String
    public let daemonPath: String
    public let daemonIdentifier: String
    public let teamIdentifier: String
    public let appDesignatedRequirement: String
    public let daemonDesignatedRequirement: String
    public let daemonSHA256: String

    public init(appURL: URL, appIdentifier: String, daemonPath: String,
                daemonIdentifier: String, teamIdentifier: String,
                appDesignatedRequirement: String,
                daemonDesignatedRequirement: String, daemonSHA256: String) {
        self.appURL = appURL
        self.appIdentifier = appIdentifier
        self.daemonPath = daemonPath
        self.daemonIdentifier = daemonIdentifier
        self.teamIdentifier = teamIdentifier
        self.appDesignatedRequirement = appDesignatedRequirement
        self.daemonDesignatedRequirement = daemonDesignatedRequirement
        self.daemonSHA256 = daemonSHA256
    }
}

/// Strictly non-mutating validation of one explicit Vaelen.app artifact.
///
/// This API intentionally does not consult SQLite, receipts, Keychain,
/// locks, processes, sockets, launchd, or ServiceManagement.  It only reads
/// the supplied bundle, its embedded daemon, and its embedded LaunchAgent.
public enum ArtifactPreflight {
    public static func validate(appURL suppliedURL: URL) -> ArtifactPreflightEvidence? {
        guard suppliedURL.isFileURL else { return nil }
        let appURL = suppliedURL.standardizedFileURL
        let target = LifecycleCanonicalIdentity.target
        let manager = FileManager.default
        guard appURL.pathExtension == "app",
              appURL.lastPathComponent == "Vaelen.app",
              manager.fileExists(atPath: appURL.path),
              manager.fileExists(atPath: appURL.appendingPathComponent("Contents").path),
              Bundle(url: appURL)?.bundleIdentifier == target.bundleID else { return nil }

        let daemonRelativePath = target.bundleProgram
        let daemonURL = appURL.appendingPathComponent(daemonRelativePath)
        guard daemonURL.path == appURL.appendingPathComponent("Contents/Resources/vaelend").path,
              manager.isExecutableFile(atPath: daemonURL.path) else { return nil }

        let plistURL = appURL.appendingPathComponent("Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              plist["Label"] as? String == target.agentLabel,
              plist["BundleProgram"] as? String == daemonRelativePath,
              plist["ProgramArguments"] == nil else { return nil }

        guard let appSigning = signedEvidence(at: appURL,
                                               identifier: target.bundleID,
                                               nested: true),
              let daemonSigning = signedEvidence(at: daemonURL,
                                                  identifier: LifecycleCanonicalIdentity.daemonIdentifier,
                                                   nested: false),
               let daemonData = try? Data(contentsOf: daemonURL) else { return nil }

        // Code signing authenticates bytes, but does not prove that dyld can
        // resolve the authenticated bytes from this bundle.  Validate the
        // complete package-owned Mach-O closure before returning evidence.
        guard dependencyClosureIsValid(appURL: appURL,
                                       appExecutable: appURL.appendingPathComponent("Contents/MacOS/Vaelen"),
                                       daemon: daemonURL) else { return nil }

        let hash = SHA256.hash(data: daemonData).map { String(format: "%02x", $0) }.joined()
        return ArtifactPreflightEvidence(
            appURL: appURL,
            appIdentifier: target.bundleID,
            daemonPath: daemonRelativePath,
            daemonIdentifier: LifecycleCanonicalIdentity.daemonIdentifier,
            teamIdentifier: LifecycleCanonicalIdentity.teamIdentifier,
            appDesignatedRequirement: appSigning.designatedRequirement,
            daemonDesignatedRequirement: daemonSigning.designatedRequirement,
            daemonSHA256: hash)
    }

    private struct SigningEvidence {
        let designatedRequirement: String
    }

    private static func dependencyClosureIsValid(appURL: URL, appExecutable: URL,
                                                 daemon: URL) -> Bool {
        let contents = appURL.appendingPathComponent("Contents")
        let frameworkRoot = contents.appendingPathComponent("Frameworks")
        let manager = FileManager.default
        var binaries = [appExecutable, daemon]
        if let enumerator = manager.enumerator(at: frameworkRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                // otool is intentionally used as the platform's Mach-O
                // parser; non-Mach-O framework resources are ignored.
                if manager.isExecutableFile(atPath: url.path),
                   runTool("/usr/bin/otool", arguments: ["-L", url.path]) != nil {
                    binaries.append(url)
                }
            }
        }
        let appRPaths = rpaths(of: appExecutable)
        guard appRPaths.contains("@executable_path/../Frameworks") else { return false }
        guard rpaths(of: daemon).contains("@loader_path/../Frameworks") else { return false }
        guard !binaries.contains(where: { !manager.isExecutableFile(atPath: $0.path) }) else { return false }

        for binary in binaries {
            guard let output = runTool("/usr/bin/otool", arguments: ["-L", binary.path]),
                  let loadOutput = runTool("/usr/bin/otool", arguments: ["-l", binary.path]) else { return false }
            let paths = rpaths(from: loadOutput)
            // Every non-system @rpath load must be resolvable from a declared
            // package rpath.  The app's runpaths are inherited by its nested
            // code, while the daemon also declares its loader-relative path.
            let searchPaths = paths + appRPaths
            for dependency in dylibDependencies(output) {
                if isSystemDependency(dependency) { continue }
                guard dependency.hasPrefix("@rpath/") || dependency.hasPrefix("@loader_path/") || dependency.hasPrefix("@executable_path/") else { return false }
                guard resolve(dependency, binary: binary, appURL: appURL, searchPaths: searchPaths) != nil else { return false }
            }
        }
        return true
    }

    private static func runTool(_ path: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private static func dylibDependencies(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            // Universal-binary headers also begin with the file path, but do
            // not contain a compatibility-version clause.  Only dependency
            // records are part of the closure.
            guard (value.hasPrefix("/") || value.hasPrefix("@")),
                  value.contains(" (compatibility version") else { return nil }
            return value.components(separatedBy: " (compatibility version").first
        }
    }

    private static func rpaths(of binary: URL) -> [String] {
        guard let output = runTool("/usr/bin/otool", arguments: ["-l", binary.path]) else { return [] }
        return rpaths(from: output)
    }

    private static func rpaths(from output: String) -> [String] {
        return output.split(separator: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("path ") else { return nil }
            return value.dropFirst(5).components(separatedBy: " (offset").first
        }
    }

    private static func isSystemDependency(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/lib/")
    }

    private static func resolve(_ dependency: String, binary: URL, appURL: URL,
                                searchPaths: [String]) -> URL? {
        let candidates: [String]
        if dependency.hasPrefix("@rpath/") {
            let suffix = String(dependency.dropFirst("@rpath/".count))
            candidates = searchPaths.map { $0 + "/" + suffix }
        } else if dependency.hasPrefix("@loader_path/") {
            candidates = ["@loader_path" + String(dependency.dropFirst("@loader_path".count))]
        } else {
            candidates = ["@executable_path" + String(dependency.dropFirst("@executable_path".count))]
        }
        let binaryDirectory = binary.deletingLastPathComponent()
        for candidate in candidates {
            let path: URL
            if candidate.hasPrefix("@loader_path") {
                path = binaryDirectory.appendingPathComponent(String(candidate.dropFirst("@loader_path".count)))
            } else if candidate.hasPrefix("@executable_path") {
                path = appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(String(candidate.dropFirst("@executable_path".count)))
            } else {
                continue
            }
            let resolved = path.standardizedFileURL
            let boundary = appURL.standardizedFileURL.path.hasSuffix("/") ? appURL.standardizedFileURL.path : appURL.standardizedFileURL.path + "/"
            guard resolved.path.hasPrefix(boundary), FileManager.default.fileExists(atPath: resolved.path) else { continue }
            return resolved
        }
        return nil
    }

    private static func signedEvidence(at url: URL, identifier: String,
                                       nested: Bool) -> SigningEvidence? {
        // Bind the platform requirement to the canonical product identity.
        // TeamIdentifier is checked independently from signing information;
        // Apple's designated requirement for Apple Development identities does
        // not encode the team ID (it encodes the certificate identity), and
        // pinning that certificate would violate the rotation boundary.
        let expected = "identifier \"\(identifier)\" and anchor apple generic"
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(expected as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }

        // Strict validation plus nested validation is intentional: a valid
        // outer app signature is not sufficient if its embedded daemon is
        // replaced or otherwise invalid.
        var flags = SecCSFlags(rawValue: kSecCSStrictValidate)
        if nested { flags.insert(.init(rawValue: kSecCSCheckNestedCode)) }
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              values[kSecCodeInfoIdentifier as String] as? String == identifier,
              values[kSecCodeInfoTeamIdentifier as String] as? String == LifecycleCanonicalIdentity.teamIdentifier else { return nil }

        var designated: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &designated) == errSecSuccess,
              let designated else { return nil }
        var actualCF: CFString?
        guard SecRequirementCopyString(designated, [], &actualCF) == errSecSuccess,
              let actual = actualCF as String?,
               !actual.isEmpty,
               actual.contains(identifier) else { return nil }
        return SigningEvidence(designatedRequirement: actual)
    }
}
