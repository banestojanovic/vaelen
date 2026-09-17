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
            let dispatcher = CoreRequestDispatcher(runtime: CoreRuntime(version: VaelenBuildInfo.version), registry: registry)
            try DaemonServer(paths: paths, dispatcher: dispatcher).run()
        } catch {
            FileHandle.standardError.write(Data("vaelend failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
