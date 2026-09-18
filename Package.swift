// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Vaelen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VaelenCore", targets: ["VaelenCore"]),
        .library(name: "VaelenIPC", targets: ["VaelenIPC"]),
        .library(name: "VaelenDaemonSupport", targets: ["VaelenDaemonSupport"]),
        .executable(name: "vaelend", targets: ["VaelenDaemon"]),
        .executable(name: "val", targets: ["VaelenCLI"])
    ],
    targets: [
        .target(name: "VaelenCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "VaelenIPC", dependencies: ["VaelenCore"]),
        .target(name: "VaelenDaemonSupport", dependencies: ["VaelenCore", "VaelenIPC"]),
        .executableTarget(name: "VaelenDaemon", dependencies: ["VaelenDaemonSupport"]),
        .executableTarget(name: "VaelenCLI", dependencies: ["VaelenIPC"]),
        .testTarget(name: "VaelenCoreTests", dependencies: ["VaelenCore"]),
        .testTarget(name: "VaelenIPCTests", dependencies: ["VaelenCore", "VaelenIPC", "VaelenDaemonSupport"])
    ]
)
