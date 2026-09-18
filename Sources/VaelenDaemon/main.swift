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
            let registry = ProjectRegistry(store: store)
            let helper: any PrivilegedDNSHelper = ProcessInfo.processInfo.environment["VAELEN_ENABLE_DEVELOPMENT_PRIVILEGED_DNS"] == "1" ? DevelopmentPrivilegedDNSHelper() : UnavailablePrivilegedDNSHelper()
            let tls = TLSCapability(layout: layout, store: store)
            let router = CaddyRouter(layout: layout, tls: tls)
            // Production Core talks to the signed helper over XPC; without an
            // installed helper every mutation reports helperUnavailable and
            // observation stays user-space, so development behavior is safe.
            let ports = StandardPortsCapability(privileged: HelperStandardPortsPrivileged(), ledger: SystemModificationLedger(store: store), backendHealthy: { let status = await router.status(); return status.state == .running && status.health == .healthy })
            let dispatcher = CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version), registry: registry, php: PHPModule.development(layout: layout), mysql: MySQLModule(layout: layout), mailpit: MailpitModule(layout: layout), router: router, routeRepository: RouteIntentRepository(store: store), dns: DNSCapability(layout: layout, helper: helper, ledger: SystemModificationLedger(store: store)), tls: tls, ports: ports)
            try await dispatcher.reconcilePersistedRoutesOnStartup()
            try DaemonServer(paths: paths, dispatcher: dispatcher).run()
        } catch {
            FileHandle.standardError.write(Data("vaelend failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
