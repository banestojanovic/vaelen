import CryptoKit
import Foundation
import XCTest
import VaelenTestSupport
@testable import VaelenCore

/// Acceptance for Vaelen's real PHP package source.
///
/// Vaelen installs provider-published macOS CLI/FPM packages; nothing is built
/// here. Every digest used below is computed from the provider's actual
/// published bytes, and where the shipped catalog pins a version, the test
/// proves that pin matches those bytes. All Vaelen-owned state is isolated
/// beneath a unique temporary root, so a live Vaelen and its projects are
/// never touched.
final class PHPProviderInstallUpdateTests: XCTestCase {
    private var root: URL!
    private var module: PHPModule!
    private var layout: VaelenFilesystemLayout!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["VAELEN_PHP_PROVIDER_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set VAELEN_PHP_PROVIDER_ACCEPTANCE=1 to run tests that consume locally cached real provider PHP artifacts.")
        }
        if (name ?? "").contains("testLatestStableInstallsFromProviderActivatesAndBecomesDefault") {
            guard ProcessInfo.processInfo.environment["VAELEN_PHP_NETWORK_ACCEPTANCE"] == "1" else {
                throw XCTSkip("Set VAELEN_PHP_NETWORK_ACCEPTANCE=1 as well to allow the live provider download acceptance test.")
            }
        }
        root = URL(fileURLWithPath: "/private/var/tmp/vaelen-provider-\(UUID().uuidString.prefix(8))", isDirectory: true)
        layout = VaelenFilesystemLayout(rootURL: root.appendingPathComponent("support", isDirectory: true), logsDirectoryURL: root.appendingPathComponent("logs", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.configurationDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A fixture that still owns a live PHP-FPM must never have its temporary
        // root removed underneath it. Attempt the identity-checked graceful stop,
        // then verify the child is gone before deleting anything. If it is not,
        // preserve the sandbox and report it so no orphan is left behind.
        var liveChildren: [String] = []
        if let module {
            for version in module.installedVersions()
            where FileManager.default.fileExists(atPath: layout.phpInstancesDirectoryURL.appendingPathComponent(version.version).appendingPathComponent("process.json").path) {
                _ = try? module.stop(requestedVersion: version.version)
                let record = layout.phpInstancesDirectoryURL.appendingPathComponent(version.version).appendingPathComponent("process.json")
                if FileManager.default.fileExists(atPath: record.path) { liveChildren.append(version.version) }
            }
        }
        module = nil
        if !liveChildren.isEmpty {
            XCTFail("Isolated PHP-FPM did not shut down for \(liveChildren.joined(separator: ", ")); preserving \(root.path) so no live child is orphaned.")
        } else if let root, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - The shipped catalog's pins describe the provider's real bytes

    /// Every version the signed app advertises must be exactly what the provider
    /// publishes, at a real provider URL, with a digest of the real bytes.
    func testShippedCatalogPinsMatchRealProviderPackages() throws {
        let shipped = try Self.shippedCatalog()
        XCTAssertFalse(shipped.manifests.isEmpty, "The signed app must include PHP.")
        for manifest in shipped.manifests {
            XCTAssertTrue(FilePHPManifestLocation.isProviderBackedManifest(manifest), "\(manifest.phpVersion) is not a verified provider package.")
            if PHPPackageProvider.isLegacyManifest(manifest) {
                for kind in ["cli", "fpm"] {
                    let name = "php-\(manifest.phpVersion)-\(kind)-macos-aarch64.tar.gz"
                    let file = Self.repositoryRoot.appendingPathComponent(".build/php-provider/archive-v2/bulk/\(name)")
                    XCTAssertEqual(try Self.sha256(file), manifest.artifacts[kind]?.sha256, "\(manifest.phpVersion) \(kind) digest does not match the archived provider bytes.")
                }
            } else {
                let cached = try ProviderArtifactCache.shared.artifacts(version: manifest.phpVersion)
                XCTAssertEqual(cached["cli"], manifest.artifacts["cli"]!.sha256, "\(manifest.phpVersion) CLI digest does not match the provider's published bytes.")
                XCTAssertEqual(cached["fpm"], manifest.artifacts["fpm"]!.sha256, "\(manifest.phpVersion) FPM digest does not match the provider's published bytes.")
            }
        }
        // Versions are offered newest first.
        let ordered = try moduleCatalogVersions()
        XCTAssertEqual(ordered, ordered.sorted { (PHPVersion($0) ?? .init(major: 0, minor: 0, patch: 0)) > (PHPVersion($1) ?? .init(major: 0, minor: 0, patch: 0)) })
    }

    /// Exercise the prepared archive source through the production installer in
    /// isolated state: exact CLI, editable configuration, managed FPM startup,
    /// a real FastCGI request, stop, removal, and verified-cache reinstall.
    func testArchivedLegacyPreparedPackagesUseTheFullManagedLifecycle() throws {
        let versions = ["8.0.30", "8.1.34"]
        let all = try Self.shippedCatalog().manifests
        let cache = root.appendingPathComponent("archive-v2-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var manifests: [PHPManifest] = []
        for version in versions {
            let manifest = try XCTUnwrap(all.first { $0.phpVersion == version })
            XCTAssertTrue(PHPPackageProvider.isLegacyManifest(manifest))
            manifests.append(manifest)
            for kind in ["cli", "fpm"] {
                let name = "php-\(version)-\(kind)-macos-aarch64.tar.gz"
                let source = Self.repositoryRoot.appendingPathComponent(".build/php-provider/archive-v2/bulk/\(name)")
                try FileManager.default.copyItem(at: source, to: cache.appendingPathComponent(manifest.artifacts[kind]!.file))
            }
        }
        module = PHPModule(layout: layout, location: Self.fixtureLocation(manifests: manifests, artifactBase: cache))
        XCTAssertEqual(try module.availableVersions(), ["8.0.30", "8.1.34"].sorted(by: { (PHPVersion($0) ?? .init(major: 0, minor: 0, patch: 0)) < (PHPVersion($1) ?? .init(major: 0, minor: 0, patch: 0)) }),
                       "The catalog exposes exactly one verified install patch for each archived family.")

        for version in versions {
            let manifest = try XCTUnwrap(manifests.first { $0.phpVersion == version })
            let installed = try module.install(requestedVersion: version)
            XCTAssertEqual(installed.version, version)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.cliPath))
            let cli = try module.exec(requestedVersion: version, workingDirectory: root.path, arguments: ["-r", "echo PHP_VERSION;"])
            XCTAssertEqual(cli.status, 0)
            XCTAssertEqual(cli.output.trimmingCharacters(in: .whitespacesAndNewlines), version)
            let configuration = PHPManagedSettings(uploadLimitMB: 32, memoryLimitMB: 256, maxExecutionTimeSeconds: 90, maxInputVariables: 2200, postLimitMB: 33)
            _ = try module.updateConfiguration(version: version, settings: configuration)
            let saved = try XCTUnwrap(module.configuration().versions.first { $0.version == version })
            XCTAssertEqual(saved.settings, configuration, "The existing editable settings path must work for archived runtimes.")

            let script = root.appendingPathComponent("fastcgi-\(version).php")
            try "<?php echo \"Content-type: text/plain\\r\\n\\r\\n\" . PHP_VERSION;".write(to: script, atomically: true, encoding: .utf8)
            let running = try module.start(requestedVersion: version)
            XCTAssertEqual(running.state, .running)
            let request = try Self.fastCGIRequest(socket: XCTUnwrap(running.socket), script: script.path)
            XCTAssertTrue(request.contains("\(version)"), "FPM must execute the exact installed runtime: \(request)")
            XCTAssertEqual(try module.stop(requestedVersion: version).state, .stopped)
            let notices = layout.phpPackagesDirectoryURL.appendingPathComponent(version).appendingPathComponent("license/src_php-src_0.txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: notices.path), "The archived PHP license notice must accompany its installed runtime.")
            try module.remove(requestedVersion: version)
            XCTAssertFalse(module.installedVersions().contains { $0.version == version })
            let reinstalled = try module.install(requestedVersion: version)
            XCTAssertEqual(reinstalled.version, version)
            XCTAssertEqual(module.operationState()?.usingVerifiedCachedDownloads, true, "Reinstall must reuse only the verified, generation-scoped download cache.")
            XCTAssertEqual(reinstalled.cliSHA256, manifest.artifacts["cli"]?.sha256)
            XCTAssertEqual(reinstalled.fpmSHA256, manifest.artifacts["fpm"]?.sha256)
            let inventory = try module.runtimeCatalog()
            XCTAssertNil(inventory.installedVersions.first { $0.version == version }?.updateAvailable, "A final archived patch must not create a false update symbol.")
            try module.remove(requestedVersion: version)
        }
    }

    // MARK: - Latest stable installs from the provider and activates

    /// A real provider package downloads over the network, verifies against the
    /// shipped pin, installs, runs, serves, stops, and becomes the default with
    /// no local distribution configuration.
    func testLatestStableInstallsFromProviderActivatesAndBecomesDefault() throws {
        // A non-bundled family, so this exercises a genuine network download
        // rather than the application's own bundled pair.
        let pinned = try Self.pinnedVersion(family: "8.3")
        module = PHPModule(layout: layout, location: Self.fixtureLocation(manifests: [pinned], artifactBase: nil))

        let before = try module.runtimeCatalog()
        XCTAssertEqual(before.installedVersions, [])
        XCTAssertNil(before.defaultVersion)
        XCTAssertTrue(before.availableVersionsKnown)

        let installed = try module.install(requestedVersion: pinned.phpVersion)
        XCTAssertEqual(installed.version, pinned.phpVersion)
        XCTAssertEqual(installed.cliSHA256, pinned.artifacts["cli"]!.sha256)
        XCTAssertEqual(installed.fpmSHA256, pinned.artifacts["fpm"]!.sha256)
        XCTAssertEqual(installed.source, pinned.artifacts["cli"]!.url)

        let reported = try module.exec(requestedVersion: pinned.phpVersion, workingDirectory: root.path, arguments: ["-r", "echo PHP_VERSION;"])
        XCTAssertEqual(reported.status, 0)
        XCTAssertEqual(reported.output.trimmingCharacters(in: .whitespacesAndNewlines), pinned.phpVersion)

        for required in Self.requiredExtensions {
            let modules = try module.exec(requestedVersion: pinned.phpVersion, workingDirectory: root.path, arguments: ["-m"])
            XCTAssertTrue(modules.output.lowercased().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.contains(required), "provider PHP is missing \(required)")
        }

        // Start and stop are real, observable controls.
        let started = try module.start(requestedVersion: pinned.phpVersion)
        XCTAssertEqual(started.state, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.socket))
        let stopped = try module.stop(requestedVersion: pinned.phpVersion)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.socket))

        // Optional activation as the default.
        _ = try module.setDefault(requestedVersion: pinned.phpVersion)
        let after = try module.runtimeCatalog()
        XCTAssertEqual(after.defaultVersion, pinned.phpVersion)
        XCTAssertEqual(after.installedVersions.first?.isDefault, true)

        // Settings are editable immediately for the newly installed version.
        let settings = PHPManagedSettings(uploadLimitMB: 64, memoryLimitMB: 512, maxExecutionTimeSeconds: 120, maxInputVariables: 5_000, postLimitMB: 80)
        let configuration = try module.updateConfiguration(version: pinned.phpVersion, settings: settings)
        let version = try XCTUnwrap(configuration.versions.first { $0.version == pinned.phpVersion })
        XCTAssertEqual(version.settings.memoryLimitMB, 512)
        XCTAssertEqual(version.inheritsDefault, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.cliIniPath))
        XCTAssertEqual(try module.configuration().versions.first { $0.version == pinned.phpVersion }?.settings, settings)
    }

    // MARK: - Update preserves settings and the default relationship

    /// A newer provider patch replaces the default without losing the user's
    /// settings. The superseded patch stays installed and runnable so an update
    /// is reversible; removing it is a separate, explicit action.
    func testUpdateToNewerProviderPatchPreservesSettingsAndDefault() throws {
        let older = try Self.providerVersion(PreferringFamily: "8.4", ImmediatelyBelow: try Self.pinnedVersion(family: "8.4").phpVersion)
        let newer = try Self.pinnedVersion(family: "8.4")
        XCTAssertGreaterThan(newer.phpVersion, older.phpVersion)

        module = PHPModule(layout: layout, location: Self.fixtureLocation(manifests: [older, newer], artifactBase: try ProviderArtifactCache.shared.flatDirectory()))

        _ = try module.install(requestedVersion: older.phpVersion)
        let settings = PHPManagedSettings(uploadLimitMB: 16, memoryLimitMB: 384, maxExecutionTimeSeconds: 90, maxInputVariables: 2_000, postLimitMB: 24)
        _ = try module.updateConfiguration(version: older.phpVersion, settings: settings)
        _ = try module.setDefault(requestedVersion: older.phpVersion)

        // A newer patch of the same series is reported as an available update.
        let installedBefore = try XCTUnwrap(try module.runtimeCatalog().installedVersions.first { $0.version == older.phpVersion })
        XCTAssertEqual(installedBefore.updateAvailable, true)
        XCTAssertEqual(installedBefore.latestVersion, newer.phpVersion)

        let updated = try module.update(requestedVersion: newer.phpVersion)
        XCTAssertEqual(updated.version, newer.phpVersion)

        let reported = try module.exec(requestedVersion: newer.phpVersion, workingDirectory: root.path, arguments: ["-r", "echo PHP_VERSION;"])
        XCTAssertEqual(reported.output.trimmingCharacters(in: .whitespacesAndNewlines), newer.phpVersion)

        let catalog = try module.runtimeCatalog()
        // Both patches are installed: the update replaced the default but left
        // the superseded patch available to fall back to.
        XCTAssertEqual(Set(catalog.installedVersions.map(\.version)), [older.phpVersion, newer.phpVersion])
        XCTAssertEqual(catalog.installedVersions.first { $0.version == older.phpVersion }?.isDefault, false)
        let fallback = try module.exec(requestedVersion: older.phpVersion, workingDirectory: root.path, arguments: ["-r", "echo PHP_VERSION;"])
        XCTAssertEqual(fallback.output.trimmingCharacters(in: .whitespacesAndNewlines), older.phpVersion)

        // Settings survive the update and follow the new patch.
        let configuration = try module.configuration()
        let migrated = try XCTUnwrap(configuration.versions.first { $0.version == newer.phpVersion })
        XCTAssertEqual(migrated.settings, settings, "Settings must be preserved across the update.")
        XCTAssertEqual(migrated.inheritsDefault, false)

        // The default relationship follows the version that replaced it, and no
        // stale update stays advertised for it.
        XCTAssertEqual(catalog.defaultVersion, newer.phpVersion)
        XCTAssertEqual(catalog.installedVersions.first { $0.version == newer.phpVersion }?.isDefault, true)
        XCTAssertNil(catalog.installedVersions.first { $0.version == newer.phpVersion }?.updateAvailable)

        // Removing the superseded patch is then a normal, explicit action.
        try module.remove(requestedVersion: older.phpVersion)
        XCTAssertEqual(module.installedVersions().map(\.version), [newer.phpVersion])
        XCTAssertEqual(try module.runtimeCatalog().defaultVersion, newer.phpVersion)
        let stillConfigured = try XCTUnwrap(try module.configuration().versions.first { $0.version == newer.phpVersion })
        XCTAssertEqual(stillConfigured.settings, settings)
    }

    // MARK: - Recovery from failure needs no restart

    /// A failed install leaves no package, does not damage the catalog, and is
    /// recoverable in the same process.
    func testChecksumFailureLeavesNoPackageAndRecoveryNeedsNoRestart() throws {
        let pinned = try Self.pinnedVersion(family: "8.4")
        let tampered = PHPManifest(
            schemaVersion: 1, module: "php", phpVersion: pinned.phpVersion, platform: "macos", architecture: "arm64",
            build: pinned.build,
            artifacts: [
                "cli": PHPArtifact(file: pinned.artifacts["cli"]!.file, url: pinned.artifacts["cli"]!.url, sha256: String(repeating: "0", count: 64)),
                "fpm": pinned.artifacts["fpm"]!,
            ],
            verification: pinned.verification,
            release: pinned.release
        )
        let location = Self.fixtureLocation(manifests: [tampered], artifactBase: try ProviderArtifactCache.shared.flatDirectory())
        module = PHPModule(layout: layout, location: location)

        XCTAssertThrowsError(try module.install(requestedVersion: pinned.phpVersion)) { error in
            guard case PHPModuleError.verificationFailed = error else { return XCTFail("Expected a checksum verification failure, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.phpPackagesDirectoryURL.appendingPathComponent(pinned.phpVersion).path), "A failed install must not leave a package behind.")
        XCTAssertEqual(module.installedVersions(), [])

        // The catalog is undamaged and still advertises the version.
        let catalog = try module.runtimeCatalog()
        XCTAssertTrue(catalog.availableVersionsKnown)
        XCTAssertTrue(catalog.availableVersions.contains(pinned.phpVersion))

        // The same module instance recovers once the catalog pin is corrected,
        // with no app restart and no leftover partial download.
        location.box.catalog = PHPManifestCatalog(manifests: [pinned])
        let installed = try module.install(requestedVersion: pinned.phpVersion)
        XCTAssertEqual(installed.version, pinned.phpVersion)
        XCTAssertEqual(installed.cliSHA256, pinned.artifacts["cli"]!.sha256)
        XCTAssertEqual(module.installedVersions().map(\.version), [pinned.phpVersion])
        XCTAssertEqual(try module.exec(requestedVersion: pinned.phpVersion, workingDirectory: root.path, arguments: ["-r", "echo PHP_VERSION;"]).output.trimmingCharacters(in: .whitespacesAndNewlines), pinned.phpVersion)
    }

    // MARK: - Removal and reinstallation preserve settings

    /// Removing and reinstalling a version must not lose the user's stored
    /// preferences, and must not disturb which version is the default.
    func testRemovalAndReinstallationPreserveSettingsAndDefault() throws {
        let removable = try Self.pinnedVersion(family: "8.3")
        let defaultVersion = try Self.pinnedVersion(family: "8.4")
        module = PHPModule(layout: layout, location: Self.fixtureLocation(manifests: [removable, defaultVersion], artifactBase: try ProviderArtifactCache.shared.flatDirectory()))

        _ = try module.install(requestedVersion: removable.phpVersion)
        _ = try module.install(requestedVersion: defaultVersion.phpVersion)
        let defaultSettings = PHPManagedSettings(uploadLimitMB: 4, memoryLimitMB: 256, maxExecutionTimeSeconds: 60, maxInputVariables: 1_500, postLimitMB: 8)
        let versionSettings = PHPManagedSettings(uploadLimitMB: 48, memoryLimitMB: 768, maxExecutionTimeSeconds: 180, maxInputVariables: 4_000, postLimitMB: 64)
        _ = try module.updateConfiguration(version: nil, settings: defaultSettings)
        _ = try module.updateConfiguration(version: removable.phpVersion, settings: versionSettings)
        _ = try module.setDefault(requestedVersion: defaultVersion.phpVersion)

        // The default cannot be removed out from under running projects.
        XCTAssertThrowsError(try module.remove(requestedVersion: defaultVersion.phpVersion)) { error in
            guard case PHPModuleError.cannotRemoveDefaultRuntime = error else { return XCTFail("Expected the default runtime to be protected, got \(error)") }
        }

        try module.remove(requestedVersion: removable.phpVersion)
        XCTAssertEqual(module.installedVersions().map(\.version), [defaultVersion.phpVersion])
        XCTAssertEqual(try module.runtimeCatalog().defaultVersion, defaultVersion.phpVersion)

        // Stored preferences survive removal so reinstalling does not lose them.
        _ = try module.install(requestedVersion: removable.phpVersion)
        let configuration = try module.configuration()
        XCTAssertEqual(configuration.defaultSettings, defaultSettings)
        let version = try XCTUnwrap(configuration.versions.first { $0.version == removable.phpVersion })
        XCTAssertEqual(version.settings, versionSettings, "A per-version override must survive removal and reinstallation.")
        XCTAssertEqual(version.inheritsDefault, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: version.cliIniPath), "The reinstated version's settings must be written immediately.")

        // The default relationship is untouched by the other version's removal.
        let catalog = try module.runtimeCatalog()
        XCTAssertEqual(catalog.defaultVersion, defaultVersion.phpVersion)
        XCTAssertEqual(Set(catalog.installedVersions.map(\.version)), [removable.phpVersion, defaultVersion.phpVersion])
        XCTAssertEqual(catalog.installedVersions.first { $0.version == defaultVersion.phpVersion }?.isDefault, true)
        XCTAssertEqual(catalog.installedVersions.first { $0.version == removable.phpVersion }?.isDefault, false)
    }

    // MARK: - Support

    private static let requiredExtensions = [
        "bcmath", "ctype", "curl", "dom", "fileinfo", "filter", "gd", "iconv", "intl",
        "mbstring", "mysqli", "mysqlnd", "openssl", "pcntl", "pdo", "pdo_mysql", "phar",
        "session", "simplexml", "sodium", "tokenizer", "xml", "xmlreader", "xmlwriter", "zip",
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func sha256(_ url: URL) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); process.arguments = ["-a", "256", url.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, let digest = String(data: data, encoding: .utf8)?.split(separator: " ").first else { throw PHPModuleError.verificationFailed(url.lastPathComponent) }
        return String(digest)
    }

    private static func fastCGIRequest(socket: String, script: String) throws -> String {
        let source = #"""
import socket,struct,sys
path,script=sys.argv[1:]
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(8); s.connect(path)
def rec(t,b): s.sendall(struct.pack('!BBHHBB',1,t,1,len(b),0,0)+b)
def length(n): return bytes([n]) if n<128 else struct.pack('!I',n|0x80000000)
def pair(k,v):
 k=k.encode(); v=v.encode(); return length(len(k))+length(len(v))+k+v
rec(1,struct.pack('!HB5s',1,0,b'\0'*5))
params={'GATEWAY_INTERFACE':'CGI/1.1','REQUEST_METHOD':'GET','SCRIPT_FILENAME':script,'SCRIPT_NAME':'/index.php','REQUEST_URI':'/index.php','SERVER_PROTOCOL':'HTTP/1.1','REDIRECT_STATUS':'200','CONTENT_LENGTH':'0'}
rec(4,b''.join(pair(k,v) for k,v in params.items())); rec(4,b''); rec(5,b'')
out=b''
while True:
 h=s.recv(8)
 if len(h)!=8: raise RuntimeError('truncated FastCGI response')
 ver,typ,rid,n,pad,_=struct.unpack('!BBHHBB',h); body=b''
 while len(body)<n:
  part=s.recv(n-len(body))
  if not part: raise RuntimeError('truncated FastCGI body')
  body+=part
 if pad: s.recv(pad)
 if typ==6: out+=body
 if typ==3: break
s.close(); sys.stdout.buffer.write(out)
"""#
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["python3", "-c", source, socket, script]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, let response = String(data: data, encoding: .utf8) else { throw PHPModuleError.processFailed("FastCGI request failed") }
        return response
    }

    private func moduleCatalogVersions() throws -> [String] {
        let module = PHPModule(layout: layout, location: Self.fixtureLocation(manifests: try Self.shippedCatalog().manifests, artifactBase: try ProviderArtifactCache.shared.flatDirectory()))
        return try module.runtimeCatalog().availableVersions
    }

    static func shippedCatalog() throws -> PHPManifestCatalog {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "php-catalog", withExtension: "json"), "The shipped PHP catalog is missing from the test bundle.")
        return try JSONDecoder().decode(PHPManifestCatalog.self, from: Data(contentsOf: url))
    }

    static func pinnedVersion(family: String) throws -> PHPManifest {
        let candidates = try shippedCatalog().manifests.filter { PHPVersion($0.phpVersion)?.family == family }
        guard let match = candidates.compactMap({ PHPVersion($0.phpVersion) }).max().flatMap({ version in candidates.first { $0.phpVersion == version.description } }) else {
            throw XCTSkip("No pinned PHP \(family) is available in the shipped catalog.")
        }
        return match
    }

    /// A real provider manifest for a version Vaelen does not currently pin,
    /// built from the provider's actual published bytes.
    static func providerVersion(PreferringFamily family: String, ImmediatelyBelow pinned: String) throws -> PHPManifest {
        let pinnedVersion = try XCTUnwrap(PHPVersion(pinned))
        let candidates = try ProviderArtifactCache.shared.publishedVersions()
        let older = candidates
            .filter { PHPVersion($0)?.family == family && PHPVersion($0)! < pinnedVersion }
            .compactMap(PHPVersion.init)
            .max()
        guard let chosen = older else { throw XCTSkip("No older provider PHP \(family) is published.") }
        let digests = try ProviderArtifactCache.shared.artifacts(version: chosen.description)
        return PHPManifest(
            schemaVersion: 1, module: "php", phpVersion: chosen.description, platform: "macos", architecture: "arm64",
            build: pinnedVersionBuild,
            artifacts: [
                "cli": PHPArtifact(file: PHPPackageProvider.artifactFile(version: chosen.description, kind: "cli"), url: PHPPackageProvider.artifactURL(version: chosen.description, kind: "cli"), sha256: digests["cli"]!),
                "fpm": PHPArtifact(file: PHPPackageProvider.artifactFile(version: chosen.description, kind: "fpm"), url: PHPPackageProvider.artifactURL(version: chosen.description, kind: "fpm"), sha256: digests["fpm"]!),
            ],
            verification: .init(algorithm: "sha256", authenticity: PHPPackageProvider.authenticity),
            release: .init(tag: PHPPackageProvider.channel, url: PHPPackageProvider.baseURL)
        )
    }

    static let pinnedVersionBuild = PHPBuildConfiguration(
        requiredExtensions: ["bcmath", "ctype", "curl", "dom", "fileinfo", "filter", "gd", "iconv", "intl", "mbstring", "mysqli", "mysqlnd", "openssl", "pcntl", "pdo", "pdo_mysql", "phar", "session", "simplexml", "sodium", "tokenizer", "xml", "xmlreader", "xmlwriter", "zip"],
        optionalExtensions: ["imagick"]
    )

    static func fixtureLocation(manifests: [PHPManifest], artifactBase: URL?) -> PHPProviderManifestLocation {
        PHPProviderManifestLocation(
            box: PHPProviderManifestLocation.CatalogBox(PHPManifestCatalog(manifests: manifests)),
            stateDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vaelen-provider-state-\(UUID().uuidString)", isDirectory: true),
            artifactBase: artifactBase
        )
    }
}
