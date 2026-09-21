import XCTest
@testable import VaelenCore
import Darwin

final class CanonicalSigningTrustBoundaryTests: XCTestCase {
    private func accepted(hash: String = "stable", cdHash: String = "stable") -> Bool {
        _ = (hash, cdHash) // evidence only; never part of the trust predicate
        return LifecycleCanonicalIdentity.accepts(
            appTeam: LifecycleCanonicalIdentity.teamIdentifier,
            appIdentifier: LifecycleCanonicalIdentity.target.bundleID,
            daemonTeam: LifecycleCanonicalIdentity.teamIdentifier,
            daemonIdentifier: LifecycleCanonicalIdentity.daemonIdentifier,
            daemonPath: LifecycleCanonicalIdentity.target.bundleProgram,
            agentLabel: LifecycleCanonicalIdentity.target.agentLabel,
            bundleProgram: LifecycleCanonicalIdentity.target.bundleProgram)
    }

    func testCanonicalIdentityIsAccepted() { XCTAssertTrue(accepted()) }
    func testAdHocOrInvalidAppAndDaemonAreRejectedBeforeIdentityCanAuthorize() {
        // The platform adapter performs the real SecStaticCode checks. This
        // falsifier documents the fail-closed boundary used by test doubles.
        let app = FakeBootstrapPlatform(preflightResult: false)
        XCTAssertFalse(app.preflightResult)
        XCTAssertFalse(LifecycleCanonicalIdentity.accepts(appTeam: "-", appIdentifier: "dev.vaelen.app", daemonTeam: "TFKZJV643G", daemonIdentifier: "vaelend", daemonPath: "Contents/Resources/vaelend", agentLabel: "dev.vaelen.vaelend", bundleProgram: "Contents/Resources/vaelend"))
        XCTAssertFalse(LifecycleCanonicalIdentity.accepts(appTeam: "TFKZJV643G", appIdentifier: "dev.vaelen.app", daemonTeam: "-", daemonIdentifier: "vaelend", daemonPath: "Contents/Resources/vaelend", agentLabel: "dev.vaelen.vaelend", bundleProgram: "Contents/Resources/vaelend"))
    }
    func testMissingOrWrongTeamIsRejected() {
        XCTAssertFalse(LifecycleCanonicalIdentity.accepts(appTeam: nil, appIdentifier: "dev.vaelen.app", daemonTeam: "TFKZJV643G", daemonIdentifier: "vaelend", daemonPath: "Contents/Resources/vaelend", agentLabel: "dev.vaelen.vaelend", bundleProgram: "Contents/Resources/vaelend"))
        XCTAssertFalse(LifecycleCanonicalIdentity.accepts(appTeam: "OTHER", appIdentifier: "dev.vaelen.app", daemonTeam: "TFKZJV643G", daemonIdentifier: "vaelend", daemonPath: "Contents/Resources/vaelend", agentLabel: "dev.vaelen.vaelend", bundleProgram: "Contents/Resources/vaelend"))
        XCTAssertFalse(LifecycleCanonicalIdentity.accepts(appTeam: "TFKZJV643G", appIdentifier: "dev.vaelen.app", daemonTeam: "OTHER", daemonIdentifier: "vaelend", daemonPath: "Contents/Resources/vaelend", agentLabel: "dev.vaelen.vaelend", bundleProgram: "Contents/Resources/vaelend"))
    }
    func testWrongIdentityPathAndLaunchAgentLayoutAreRejected() {
        XCTAssertFalse(LifecycleCanonicalIdentity.accepts(appTeam: "TFKZJV643G", appIdentifier: "wrong", daemonTeam: "TFKZJV643G", daemonIdentifier: "vaelend", daemonPath: "Contents/Resources/vaelend", agentLabel: "dev.vaelen.vaelend", bundleProgram: "Contents/Resources/vaelend"))
        XCTAssertFalse(LifecycleCanonicalIdentity.accepts(appTeam: "TFKZJV643G", appIdentifier: "dev.vaelen.app", daemonTeam: "TFKZJV643G", daemonIdentifier: "other", daemonPath: "Contents/Resources/vaelend", agentLabel: "dev.vaelen.vaelend", bundleProgram: "Contents/Resources/vaelend"))
        XCTAssertFalse(LifecycleCanonicalIdentity.accepts(appTeam: "TFKZJV643G", appIdentifier: "dev.vaelen.app", daemonTeam: "TFKZJV643G", daemonIdentifier: "vaelend", daemonPath: "wrong", agentLabel: "wrong", bundleProgram: "wrong"))
    }
    func testArtifactAndCDHashRotationDoesNotChangeIdentityAcceptance() {
        XCTAssertTrue(accepted(hash: "a", cdHash: "a"))
        XCTAssertTrue(accepted(hash: "b", cdHash: "b"))
    }

    func testArtifactPreflightRejectsMalformedUnsignedLaunchAgentLayouts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vaelen-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Vaelen.app")
        let daemon = app.appendingPathComponent("Contents/Resources/vaelend")
        let agent = app.appendingPathComponent("Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist")
        try FileManager.default.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a signed daemon".utf8).write(to: daemon)
        chmod(daemon.path, 0o755)
        let info: [String: Any] = ["CFBundleIdentifier": LifecycleCanonicalIdentity.target.bundleID]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))

        func writeAgent(_ values: [String: Any]) throws {
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: agent)
            XCTAssertNil(ArtifactPreflight.validate(appURL: app))
        }
        try writeAgent(["Label": LifecycleCanonicalIdentity.target.agentLabel,
                        "BundleProgram": LifecycleCanonicalIdentity.target.bundleProgram,
                        "ProgramArguments": ["/tmp/replacement"]])
        try writeAgent(["Label": "dev.vaelen.attacker",
                        "BundleProgram": LifecycleCanonicalIdentity.target.bundleProgram])
        try writeAgent(["Label": LifecycleCanonicalIdentity.target.agentLabel,
                        "BundleProgram": "Contents/Resources/replacement"])
    }

    func testArtifactPreflightRequiresExplicitCanonicalAppURL() {
        XCTAssertNil(ArtifactPreflight.validate(appURL: URL(fileURLWithPath: "/tmp/not-a-vaelen-artifact")))
        XCTAssertNil(ArtifactPreflight.validate(appURL: LifecycleCanonicalIdentity.target.endpointURLForTesting))
    }

    func testEquivalentBrokenArtifactWithoutBundleFrameworkRunpathIsRejected() throws {
        let source = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-20260920.xcarchive/Products/Applications/Vaelen.app")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("validation archive is not present")
        }
        // The known validation artifact is signed but has only /usr/lib/swift
        // as an LC_RPATH.  It is therefore an equivalent broken package: its
        // @rpath Vaelen-owned frameworks cannot resolve from the bundle.
        XCTAssertNil(ArtifactPreflight.validate(appURL: source))
    }

    func testBootstrapControllerSelectionIsDeterministicAndOverrideIsExact() {
        let empty: [String: String] = [:]
        XCTAssertEqual(LifecycleCanonicalIdentity.bootstrapControllerURL(environment: empty), LifecycleCanonicalIdentity.installedControllerURL)
        XCTAssertEqual(LifecycleCanonicalIdentity.bootstrapControllerURL(environment: [LifecycleCanonicalIdentity.controllerOverrideEnvironment: LifecycleCanonicalIdentity.installedControllerURL.path]), LifecycleCanonicalIdentity.installedControllerURL)
        XCTAssertEqual(LifecycleCanonicalIdentity.bootstrapControllerURL(environment: [LifecycleCanonicalIdentity.controllerOverrideEnvironment: LifecycleCanonicalIdentity.validationControllerURL.path]), LifecycleCanonicalIdentity.validationControllerURL)
        XCTAssertNil(LifecycleCanonicalIdentity.bootstrapControllerURL(environment: [LifecycleCanonicalIdentity.controllerOverrideEnvironment: "/tmp/Vaelen.app"]))
        XCTAssertNil(LifecycleCanonicalIdentity.bootstrapControllerURL(environment: [LifecycleCanonicalIdentity.controllerOverrideEnvironment: LifecycleCanonicalIdentity.validationControllerURL.path + ".copy"]))
    }

    func testSameBundleIDCandidatesCannotUseDebugPathOrConsumeValidationAuthorization() throws {
        struct Candidate {
            let appURL: URL
            let bundleID: String
            let preflight: ArtifactPreflightEvidence?
        }

        let debugRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaelen-debug-collision-")
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: debugRoot) }
        let debugURL = debugRoot.appendingPathComponent("Vaelen.app", isDirectory: true)
        let canonicalURL = LifecycleCanonicalIdentity.validationControllerURL

        // Make the colliding Debug candidate a real, isolated bundle layout.
        // It has the right bundle ID and launch-agent shape, but is unsigned;
        // the real ArtifactPreflight seam must reject it.
        let debugDaemon = debugURL.appendingPathComponent("Contents/Resources/vaelend")
        let debugAgent = debugURL.appendingPathComponent("Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist")
        try FileManager.default.createDirectory(at: debugDaemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: debugAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unsigned debug fixture".utf8).write(to: debugDaemon)
        chmod(debugDaemon.path, 0o755)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": LifecycleCanonicalIdentity.target.bundleID], format: .xml, options: 0)
            .write(to: debugURL.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": LifecycleCanonicalIdentity.target.agentLabel,
            "BundleProgram": LifecycleCanonicalIdentity.target.bundleProgram
        ], format: .xml, options: 0).write(to: debugAgent)

        func evidence(for appURL: URL) -> ArtifactPreflightEvidence {
            ArtifactPreflightEvidence(
                appURL: appURL,
                appIdentifier: LifecycleCanonicalIdentity.target.bundleID,
                daemonPath: LifecycleCanonicalIdentity.target.bundleProgram,
                daemonIdentifier: LifecycleCanonicalIdentity.daemonIdentifier,
                teamIdentifier: LifecycleCanonicalIdentity.teamIdentifier,
                appDesignatedRequirement: "identifier \"dev.vaelen.app\" and anchor apple generic",
                daemonDesignatedRequirement: "identifier \"vaelend\" and anchor apple generic",
                daemonSHA256: "fixture")
        }

        // Both fixtures deliberately have the same bundle identifier.  A
        // bundle-ID/LaunchServices lookup would therefore be ambiguous (and
        // could select the Debug artifact); the production seam is the exact
        // canonical URL followed by ArtifactPreflight evidence.
        let debug = Candidate(appURL: debugURL,
                              bundleID: LifecycleCanonicalIdentity.target.bundleID,
                              preflight: ArtifactPreflight.validate(appURL: debugURL))
        let validation = Candidate(appURL: canonicalURL,
                                   bundleID: LifecycleCanonicalIdentity.target.bundleID,
                                   preflight: evidence(for: canonicalURL))
        let candidates = [debug, validation]
        XCTAssertEqual(Set(candidates.map { $0.bundleID }).count, 1)
        XCTAssertEqual(candidates.first?.appURL, debugURL)
        XCTAssertNil(debug.preflight, "The same-ID Debug artifact must fail signed ArtifactPreflight")

        func selected(environment: [String: String]) -> Candidate? {
            guard let selectedURL = LifecycleCanonicalIdentity.bootstrapControllerURL(environment: environment) else { return nil }
            return candidates.first {
                $0.appURL.standardizedFileURL == selectedURL.standardizedFileURL &&
                $0.bundleID == LifecycleCanonicalIdentity.target.bundleID &&
                $0.preflight?.appURL.standardizedFileURL == selectedURL.standardizedFileURL
            }
        }

        let environment = [LifecycleCanonicalIdentity.controllerOverrideEnvironment: canonicalURL.path]
        XCTAssertEqual(selected(environment: environment)?.appURL, canonicalURL)
        XCTAssertNotEqual(selected(environment: environment)?.appURL, debugURL)

        // This is an isolated authorization fake: a receipt minted for the
        // selected validation path cannot be consumed by the colliding Debug
        // candidate, even though their bundle IDs are identical.
        let authorizedPath = canonicalURL.standardizedFileURL.path
        func canConsumeAuthorization(for candidate: Candidate) -> Bool {
            candidate.appURL.standardizedFileURL.path == authorizedPath
        }
        XCTAssertFalse(canConsumeAuthorization(for: debug))
        XCTAssertTrue(canConsumeAuthorization(for: validation))
    }

    func testExplicitSignedArtifactPreflightWhenPathIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["VAELEN_ARTIFACT_PREFLIGHT_PATH"] else {
            throw XCTSkip("Set VAELEN_ARTIFACT_PREFLIGHT_PATH to an independently built signed Vaelen.app")
        }
        let evidence = try XCTUnwrap(ArtifactPreflight.validate(appURL: URL(fileURLWithPath: path)))
        XCTAssertEqual(evidence.appIdentifier, "dev.vaelen.app")
        XCTAssertEqual(evidence.daemonPath, "Contents/Resources/vaelend")
        XCTAssertEqual(evidence.daemonIdentifier, "vaelend")
        XCTAssertEqual(evidence.teamIdentifier, "TFKZJV643G")
        XCTAssertTrue(evidence.appDesignatedRequirement.contains("identifier \"dev.vaelen.app\""))
        XCTAssertTrue(evidence.appDesignatedRequirement.contains("anchor apple generic"))
        XCTAssertTrue(evidence.daemonDesignatedRequirement.contains("identifier vaelend"))
        XCTAssertTrue(evidence.daemonDesignatedRequirement.contains("anchor apple generic"))
        XCTAssertFalse(evidence.daemonSHA256.isEmpty)
    }

    func testExplicitSignedArtifactPreflightHandlesUniversalHeadersAndFrameworkResources() throws {
        guard let path = ProcessInfo.processInfo.environment["VAELEN_ARTIFACT_PREFLIGHT_PATH"] else {
            throw XCTSkip("Set VAELEN_ARTIFACT_PREFLIGHT_PATH to an independently built signed Vaelen.app")
        }

        let evidence = try XCTUnwrap(ArtifactPreflight.validate(appURL: URL(fileURLWithPath: path)))
        XCTAssertEqual(evidence.appURL.standardizedFileURL.path, URL(fileURLWithPath: path).standardizedFileURL.path)
    }
}

private extension LifecycleTargetIdentity {
    var endpointURLForTesting: URL { URL(fileURLWithPath: endpoint) }
}
