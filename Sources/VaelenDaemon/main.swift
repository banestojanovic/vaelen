import Foundation
import VaelenCore
import VaelenDaemonSupport
import VaelenIPC

@main
struct VaelenDaemonMain {
    static func main() async {
        do {
            let paths = CoreEndpointPaths()
            let layout = VaelenFilesystemLayout()
            let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
            if CommandLine.arguments.contains("--vaelen-authorized-off-recovery") {
                // This mode is entered only by the signed controller after a
                // daemon was terminated by successful unregister. It performs
                // fresh observation and durable recovery; it never calls
                // ServiceManagement and never retries unregister.
                guard let preflight = ArtifactPreflight.validate(appURL: LifecycleCanonicalIdentity.installedControllerURL) else { throw BootstrapError.refused("Canonical signed artifact failed recovery preflight.") }
                let platform = SMAppServiceBootstrapPlatform(controllerBundleURL: LifecycleCanonicalIdentity.installedControllerURL)
                let registration = await platform.registrationObservationSnapshot()
                let observation = LifecycleObservationVector(bundlePresent: .true, layoutValid: .true,
                    signatureValid: .true, registrationMatch: (registration.status == .notRegistered || registration.status == .notFound) ? .false : registration.value,
                    processMatch: .false, endpointReachable: .false,
                    protocolCompatible: .false, coreReady: .unknown,
                    signingTeam: preflight.teamIdentifier,
                    designatedRequirement: preflight.appDesignatedRequirement,
                    artifactHash: preflight.daemonSHA256,
                    source: "production-observer", reason: registration.detail)
                guard try LifecycleStateRepository(store: store, receiptAuthenticator: nil).recoverOffAfterFreshAbsence(observation) else {
                    throw BootstrapError.recoveryRequired("Exact Off recovery requires fresh canonical absence evidence.")
                }
                if let receipt = try store.bootstrapReceiptEvidence() {
                    try store.archivePromotedReceiptAfterRecoveredOffWithRejectedMAC(receipt)
                }
                return
            }
            let registry = ProjectRegistry(store: store)
            let helper: any PrivilegedDNSHelper = ProcessInfo.processInfo.environment["VAELEN_ENABLE_DEVELOPMENT_PRIVILEGED_DNS"] == "1" ? DevelopmentPrivilegedDNSHelper() : UnavailablePrivilegedDNSHelper()
            let tls = TLSCapability(layout: layout, store: store)
            let router = CaddyRouter(layout: layout, tls: tls)
            // Production Core talks to the signed helper over XPC; without an
            // installed helper every mutation reports helperUnavailable and
            // observation stays user-space, so development behavior is safe.
            let ports = StandardPortsCapability(privileged: HelperStandardPortsPrivileged(), ledger: SystemModificationLedger(store: store), backendHealthy: { let status = await router.status(); return status.state == .running && status.health == .healthy })
            // The supported app bundle path supplies the only production
            // ServiceManagement executor and observer. Tests retain the safe
            // unavailable defaults through the dispatcher initializer.
            let lifecycleSession = UUID()
             let lifecycleObservation = ProductionLifecycleObservationProvider(sessionBinding: lifecycleSession)
            let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version), registry: registry, php: PHPModule.development(layout: layout), mysql: MySQLModule(layout: layout), mailpit: MailpitModule(layout: layout), router: router, routeRepository: RouteIntentRepository(store: store), dns: DNSCapability(layout: layout, helper: helper, ledger: SystemModificationLedger(store: store)), tls: tls, ports: ports, lifecycleStore: store, lifecycleExecutor: SMAppServiceLifecycleExecutor(sessionBinding: lifecycleSession, identityRevalidator: lifecycleObservation), lifecycleObservationProvider: lifecycleObservation, lifecycleSessionBinding: lifecycleSession)
            try await DaemonServer(paths: paths, dispatcher: dispatcher, lifecycleStore: store,
                                   lifecycleObservationProvider: lifecycleObservation,
                                   startupReconciliation: { try await dispatcher.reconcilePersistedRoutesOnStartup() }).run()
        } catch {
            FileHandle.standardError.write(Data("vaelend failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
