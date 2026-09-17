// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vaelen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VaelenCore", targets: ["VaelenCore"]),
        .library(name: "VaelenIPC", targets: ["VaelenIPC"]),
        .executable(name: "vaelend", targets: ["VaelenDaemon"]),
        .executable(name: "val", targets: ["VaelenCLI"])
    ],
    targets: [
        .target(name: "VaelenCore"),
        .target(name: "VaelenIPC", dependencies: ["VaelenCore"]),
        .executableTarget(name: "VaelenDaemon", dependencies: ["VaelenCore", "VaelenIPC"]),
        .executableTarget(name: "VaelenCLI", dependencies: ["VaelenIPC"]),
        .testTarget(name: "VaelenCoreTests", dependencies: ["VaelenCore"]),
        .testTarget(name: "VaelenIPCTests", dependencies: ["VaelenCore", "VaelenIPC"])
    ]
)
