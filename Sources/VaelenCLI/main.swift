import Foundation
import Darwin
import Dispatch
import VaelenIPC

private struct CLIStatusEnvelope: Encodable {
    let core: CoreStatusPayload
}

private struct CoreStatusPayload: Encodable {
    let state: String
    let version: String
    let pid: Int32
    let protocolVersion: Int
}

@main
struct VaelenCLIMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["status"] || arguments == ["status", "--json"] else {
            fail("Usage: val status [--json]", code: 2)
        }

        let json = arguments.contains("--json")
        let paths = CoreEndpointPaths()
        let client = VaelenCoreClient(
            transport: UnixSocketTransport(path: paths.socketPath),
            identity: ClientIdentity(name: "val", version: VaelenBuildInfo.version)
        )

        Task {
            do {
                try await client.connect()
                let status = try await client.status()
                if json {
                    let output = try IPCCodec.encode(CLIStatusEnvelope(core: CoreStatusPayload(
                        state: status.core.state.rawValue,
                        version: status.core.version,
                        pid: status.core.pid,
                        protocolVersion: status.protocolVersion.rawValue
                    )))
                    print(String(decoding: output, as: UTF8.self))
                } else {
                    print("Vaelen")
                    print("Core       \(status.core.state == .running ? "Running" : "Unavailable")")
                    print("Version    \(status.core.version)")
                    print("PID        \(status.core.pid)")
                    print("Protocol   \(status.protocolVersion.rawValue)")
                }
                await client.disconnect()
                Foundation.exit(0)
            } catch let error as CoreClientError {
                switch error {
                case .coreUnavailable:
                    fail("Vaelen Core is not running.", code: 3)
                case .protocolIncompatible(let client, let core):
                    fail("Vaelen Core uses an incompatible protocol version.\n\nClient: \(client)\nCore:   \(core)", code: 4)
                case .remote(let payload):
                    fail(payload.message, code: 1)
                case .invalidResponse:
                    fail("Vaelen Core returned an invalid response.", code: 1)
                }
            } catch {
                fail("val failed: \(error)", code: 1)
            }
        }
        runMainLoop()
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(code)
    }

    private static func runMainLoop() {
        dispatchMain()
    }
}
