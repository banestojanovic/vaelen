import Foundation
import VaelenCore
import VaelenIPC
import Darwin

/// Passive production observation. Registration and process presence are kept
/// separate from endpoint readiness; no method here mutates ServiceManagement.
public struct ProductionLifecycleObservationProvider: LifecycleObservationProvider, LifecycleDispatchIdentityRevalidator {
    private static let controllerObservationTimeout: TimeInterval = 5
    private let bundleURL: URL?
    private let controllerURL: URL
    private let sessionBinding: UUID

    /// The daemon is embedded in the signed app at runtime.  Bundle.main is
    /// intentionally not used here: for an embedded executable it identifies
    /// the executable's bundle (or its build product), not necessarily the
    /// enclosing Vaelen.app.  Tests and packaged callers may provide the app
    /// URL explicitly, but it is still required to have the canonical layout.
    public init(bundleURL: URL? = nil, controllerURL: URL = LifecycleCanonicalIdentity.installedControllerURL,
                sessionBinding: UUID = UUID()) {
        self.bundleURL = Self.resolvePackagedAppURL(bundleURL: bundleURL)
        self.controllerURL = controllerURL.standardizedFileURL
        self.sessionBinding = sessionBinding
    }

    public func observe(operationID: UUID, generation: Int64, intent: LifecycleIntent,
                        target: LifecycleTargetIdentity) async -> LifecycleObservationVector {
        guard target == LifecycleCanonicalIdentity.target else {
            return .init(source: "production-observer", reason: "Non-canonical lifecycle identity.")
        }
        let layout = validateLayout(target: target)
        let signature = validateSignature()
        // Registration is controller-owned evidence.  The daemon asks the
        // exact signed controller for one fresh, operation-bound read; it never
        // queries ServiceManagement itself.
        let registered = await observeRegistration(operationID: operationID, generation: generation,
                                                    intent: intent, target: target)
        let endpoint = await observeEndpoint(target.endpoint)
        let process = observeProcess(target: target)
        return .init(bundlePresent: layout.bundlePresent, layoutValid: layout.layoutValid,
                     signatureValid: signature.valid,
                      registrationMatch: registered,
                      processMatch: process.value, endpointReachable: endpoint.reachable,
                      protocolCompatible: endpoint.protocolCompatible, coreReady: endpoint.coreReady,
                     supervisorObserved: .unknown,
                      signingTeam: signature.team, designatedRequirement: signature.requirement, artifactHash: signature.hash,
                      processIdentity: process.identity,
                     source: "production-observer",
                     reason: endpoint.reason)
    }

    private func observeRegistration(operationID: UUID, generation: Int64,
                                     intent: LifecycleIntent, target: LifecycleTargetIdentity) async -> ObservationValue {
        guard LifecycleCanonicalIdentity.isAllowedControllerURL(controllerURL),
              ArtifactPreflight.validate(appURL: controllerURL) != nil else { return .unknown }
        let request = LifecycleControllerObservationRequest(operationID: operationID, generation: generation,
                                                            intent: intent, target: target,
                                                            sessionBinding: sessionBinding)
        let executable = controllerURL.appendingPathComponent("Contents/MacOS/Vaelen")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .unknown }
        let process = Process(); process.executableURL = executable
        process.arguments = ["--vaelen-observe-registration"]
        let input = Pipe(); let output = Pipe(); process.standardInput = input; process.standardOutput = output
        do {
            try process.run()
            let data = try IPCJSON.encode(request)
            input.fileHandleForWriting.write(data); input.fileHandleForWriting.closeFile()
            // The controller is a one-shot witness.  A malformed or
            // LaunchServices-wedged app must not pin the daemon's observation
            // task forever: both readDataToEndOfFile() and waitUntilExit()
            // are otherwise unbounded blocking calls.
            guard Self.waitForController(process, timeout: Self.controllerObservationTimeout) else {
                return .unknown
            }
            let responseData = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let response = try? IPCJSON.decode(LifecycleControllerObservationResponse.self, from: responseData),
                  LifecycleControllerObservationValidator.validate(response, request: request, controllerPath: controllerURL.path)
            else { return .unknown }
            return response.registrationMatch
        } catch {
            return .unknown
        }
    }

    private static func waitForController(_ process: Process, timeout: TimeInterval) -> Bool {
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            completion.signal()
        }
        guard completion.wait(timeout: .now() + timeout) == .success else {
            // This only terminates the short-lived observation witness, never
            // the canonical daemon or any ServiceManagement job.
            process.terminate()
            _ = completion.wait(timeout: .now() + 1)
            return false
        }
        return true
    }

    /// Recheck the exact ephemeral process identity immediately before the
    /// ServiceManagement call. Missing, unreadable, or changed identity fails
    /// closed; this evidence is never durable ownership.
    public func revalidateProcessIdentity(expected: LifecycleProcessIdentity,
                                          target: LifecycleTargetIdentity) async -> ObservationValue {
        guard target == LifecycleCanonicalIdentity.target else { return .unknown }
        let process = observeProcess(target: target)
        guard process.value == .true, let actual = process.identity else { return .unknown }
        return actual == expected ? .true : .unknown
    }

    /// `.on` is intentionally not gated on a running daemon: a normal first
    /// registration has no process identity yet.  Revalidate only the fixed
    /// artifact and platform-registration boundary here; ownership and any
    /// existing registration remain Core decisions and are never adopted by
    /// this observation.
    public func revalidateOnRegistrationPreconditions(target: LifecycleTargetIdentity,
                                                      allowExistingRegistration: Bool) async -> ObservationValue {
        guard target == LifecycleCanonicalIdentity.target else { return .unknown }
        let layout = validateLayout(target: target)
        let signature = validateSignature()
        guard layout.layoutValid == .true, signature.valid == .true else { return .unknown }
        // No daemon-side ServiceManagement query is permitted here.  Core's
        // operation-bound receipt is validated at the admission boundary.
        _ = allowExistingRegistration
        return .true
    }

    private struct SignatureObservation { let valid: ObservationValue; let team: String?; let requirement: String?; let hash: String? }
    private func validateSignature() -> SignatureObservation {
        guard let bundleURL else { return .init(valid: .false, team: nil, requirement: nil, hash: nil) }
        guard let evidence = ArtifactPreflight.validate(appURL: bundleURL) else {
            return .init(valid: .false, team: nil, requirement: nil, hash: nil)
        }
        return .init(valid: .true, team: evidence.teamIdentifier,
                     requirement: evidence.appDesignatedRequirement,
                     hash: evidence.daemonSHA256)
    }

    private struct ProcessObservation { let value: ObservationValue; let identity: LifecycleProcessIdentity? }
    private func observeProcess(target: LifecycleTargetIdentity) -> ProcessObservation {
        guard let bundleURL else { return .init(value: .false, identity: nil) }
        let expected = bundleURL.appendingPathComponent(target.bundleProgram).path
        var pids = [pid_t](repeating: 0, count: 1024)
        let bytes = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard bytes > 0 else { return .init(value: .unknown, identity: nil) }
        var inspected = false
        // proc_listallpids returns a PID count (not a byte count).
        for pid in pids.prefix(Int(bytes)) where pid > 0 {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            inspected = true
            let actual = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard actual == expected else { continue }
            guard let first = readProcessIdentity(pid) else { return .init(value: .unknown, identity: nil) }
            guard let second = readProcessIdentity(pid) else { return .init(value: .unknown, identity: first) }
            let value = LifecycleProcessIdentityValidator.evaluate(first: first, second: second, expectedPath: expected, expectedUID: getuid())
            return .init(value: value, identity: value == .true ? second : nil)
        }
        return .init(value: inspected ? .false : .unknown, identity: nil)
    }

    private func readProcessIdentity(_ pid: pid_t) -> LifecycleProcessIdentity? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return nil }
        let path = String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride)) == MemoryLayout<proc_bsdinfo>.stride else { return nil }
        return .init(pid: pid, startIdentity: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)", uid: info.pbi_uid, executablePath: path)
    }

    private func validateLayout(target: LifecycleTargetIdentity) -> (bundlePresent: ObservationValue, layoutValid: ObservationValue) {
        let manager = FileManager.default
        guard let bundleURL,
              manager.fileExists(atPath: bundleURL.path),
              bundleURL.pathExtension == "app",
              bundleURL.lastPathComponent == "Vaelen.app",
              Bundle(url: bundleURL)?.bundleIdentifier == target.bundleID else { return (.false, .false) }
        let helper = bundleURL.appendingPathComponent("Contents/Resources/vaelend")
        let plist = bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist")
        guard manager.isExecutableFile(atPath: helper.path),
              let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              object["Label"] as? String == target.agentLabel,
              object["BundleProgram"] as? String == target.bundleProgram,
              object["ProgramArguments"] == nil else { return (.true, .false) }
        return (.true, .true)
    }

    private static func resolvePackagedAppURL(bundleURL: URL?) -> URL? {
        let appURL: URL
        if let bundleURL {
            appURL = bundleURL
        } else {
            // Bundle.main.bundleURL is the wrong authority for an embedded
            // daemon.  Use the executable path and derive its enclosing app.
            guard let executableURL = Bundle.main.executableURL else { return nil }
            let executable = executableURL.standardizedFileURL
            guard Array(executable.pathComponents.suffix(3)) == ["Contents", "Resources", "vaelend"] else { return nil }
            appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }

        let standardized = appURL.standardizedFileURL
        guard standardized.pathExtension == "app",
              standardized.lastPathComponent == "Vaelen.app",
              Array(standardized.pathComponents.suffix(1)) == ["Vaelen.app"] else { return nil }
        return standardized
    }

    // These are deliberately three-valued (and, for compatibility, carry an
    // explicit incompatible value).  A socket path that is present is not
    // evidence that Vaelen Core is on the other end of it.  In particular,
    // transport failures after connect and malformed replies must not become a
    // false observation which an Off decision could mistake for a fact.
    internal struct EndpointObservation {
        let reachable: ObservationValue
        let protocolCompatible: ObservationValue
        let coreReady: ObservationValue
        let reason: String?
    }

    internal enum EndpointObservationClassification {
        case absent
        case incompatible(String)
        case ambiguous(String)

        var observation: EndpointObservation {
            switch self {
            case .absent:
                return .init(reachable: .false, protocolCompatible: .unknown,
                             coreReady: .false, reason: "Core endpoint is absent or refused the connection.")
            case .incompatible(let reason):
                return .init(reachable: .true, protocolCompatible: .incompatible,
                             coreReady: .incompatible, reason: reason)
            case .ambiguous(let reason):
                return .init(reachable: .unknown, protocolCompatible: .unknown,
                             coreReady: .unknown, reason: reason)
            }
        }
    }

    internal static func observationValue(for readiness: CoreReadiness) -> ObservationValue {
        switch readiness {
        case .ready: return .true
        case .starting, .unavailable: return .false
        case .incompatible: return .incompatible
        case .unknown: return .unknown
        }
    }

    private func observeEndpoint(_ path: String) async -> EndpointObservation {
        let client = VaelenCoreClient(transport: UnixSocketTransport(path: path),
            identity: ClientIdentity(name: "vaelen-lifecycle-observer", version: VaelenBuildInfo.version,
                                     schemaCompatibilityVersion: VaelenBuildInfo.schemaCompatibilityVersion,
                                     buildIdentity: VaelenBuildInfo.buildIdentity))
        do {
            try await client.connect()
            let readiness = try await client.coreReadiness()
            await client.disconnect()
            let readinessValue = Self.observationValue(for: readiness.readiness)
            return .init(reachable: .true, protocolCompatible: .true, coreReady: readinessValue,
                         reason: readinessValue == .true ? nil : "Core endpoint is reachable but Core has not reported ready.")
        } catch let error as CoreClientError {
            await client.disconnect()
            switch error {
            case .protocolIncompatible, .coreIncompatible:
                return EndpointObservationClassification.incompatible("Core endpoint handshake is incompatible.").observation
            case .invalidResponse:
                return EndpointObservationClassification.incompatible("Core endpoint returned a malformed response.").observation
            case .coreUnavailable:
                return EndpointObservationClassification.absent.observation
            default:
                return EndpointObservationClassification.ambiguous("Core endpoint communication was ambiguous.").observation
            }
        } catch is CoreTransportError {
            await client.disconnect()
            // CoreClientError.coreUnavailable is the connect-phase absence
            // case. A transport error escaping after connect is ambiguous,
            // including an `.unavailable` supplied by another transport.
            return EndpointObservationClassification.ambiguous("Core endpoint transport failed after or during connection.").observation
        } catch {
            await client.disconnect()
            return EndpointObservationClassification.ambiguous("Core endpoint observation failed ambiguously.").observation
        }
    }
}

private enum IPCJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
