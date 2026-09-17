import Foundation
import VaelenCore
import VaelenIPC

@main
struct VaelenDaemonMain {
    static func main() async {
        do {
            let paths = CoreEndpointPaths()
            try DaemonServer(runtime: CoreRuntime(version: VaelenBuildInfo.version), paths: paths).run()
        } catch {
            FileHandle.standardError.write(Data("vaelend failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
