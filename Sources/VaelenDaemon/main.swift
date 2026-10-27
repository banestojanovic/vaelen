import Foundation
import VaelenCore
import VaelenDaemonSupport
import VaelenIPC

@main
struct VaelenDaemonMain {
    static func main() async {
        do {
            if ProcessInfo.processInfo.environment["VAELEN_TEST_ALLOW_CORE_START"] == "1",
               VaelenTestRuntimePaths.isolatedSupportRoot() == nil {
                throw NSError(domain: "VaelenDaemon", code: 1, userInfo: [NSLocalizedDescriptionKey: "test Core start requires an isolated support root"])
            }
            let paths = CoreEndpointPaths()
            let layout = VaelenFilesystemLayout()
            let store = try SQLiteStateStore(databaseURL: layout.databaseURL)
            let registry = ProjectRegistry(store: store)
            let helper: any PrivilegedDNSHelper
            let privilegedPorts: any StandardPortsPrivileged
            if VaelenTestRuntimePaths.isolatedSupportRoot() != nil {
                helper = UnavailablePrivilegedDNSHelper()
                privilegedPorts = UnavailableStandardPortsPrivileged()
            } else {
                helper = ProcessInfo.processInfo.environment["VAELEN_ENABLE_DEVELOPMENT_PRIVILEGED_DNS"] == "1" ? DevelopmentPrivilegedDNSHelper() : HelperPrivilegedDNS()
                privilegedPorts = HelperStandardPortsPrivileged()
            }
            let tls = TLSCapability(layout: layout, store: store)
            let router = CaddyRouter(layout: layout, tls: tls)
            let ports = StandardPortsCapability(privileged: privilegedPorts, ledger: SystemModificationLedger(store: store), backendHealthy: { let status = await router.status(); return status.state == .running && status.health == .healthy })
            // The shipped catalog is the production PHP source. A development
            // manifest, when present, still takes precedence so local work can
            // pin its own packages.
            let php = PHPModule.development(layout: layout) ?? PHPModule.bundled(layout: layout)
            let serviceInstances = ServiceInstanceRepository(store: store)
            let postgresql = PostgreSQLServiceModule(layout: layout, repository: serviceInstances)
            let valkey = ValkeyServiceModule(layout: layout, repository: serviceInstances)
            let dispatcher = try CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version), registry: registry, php: php, mysql: MySQLModule(layout: layout), mailpit: MailpitModule(layout: layout), postgresql: postgresql, valkey: valkey, router: router, routeRepository: RouteIntentRepository(store: store), localProxyRepository: try LocalProxyRepository(databaseURL: layout.localProxyDatabaseURL), dns: DNSCapability(layout: layout, helper: helper, ledger: SystemModificationLedger(store: store)), tls: tls, ports: ports, serviceIntents: ServiceIntentStore(url: layout.stateDirectoryURL.appendingPathComponent("service-intents.json")), serviceInstances: serviceInstances, logs: CoreLogCatalog(layout: layout, phpModule: php))
            try await dispatcher.reconcilePersistedRoutesOnStartup()
            await dispatcher.restoreServicesOnStartup()
            let parentPID = ProcessInfo.processInfo.environment["VAELEN_PARENT_PID"].flatMap(Int32.init)
            try DaemonServer(paths: paths, dispatcher: dispatcher, parentPID: parentPID).run()
        } catch {
            FileHandle.standardError.write(Data("vaelend failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
