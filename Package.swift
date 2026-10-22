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
        .executable(name: "projects-php-core", targets: ["ProjectsPHPUIAcceptance"]),
        .executable(name: "vaelendns", targets: ["VaelenDNS"]),
        .executable(name: "val", targets: ["VaelenCLI"]),
        .executable(name: "vaelen-privileged-helper", targets: ["VaelenPrivilegedHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.6")
    ],
    targets: [
        .target(name: "VaelenCore", dependencies: [.product(name: "Yams", package: "Yams")], resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "VaelenIPC", dependencies: ["VaelenCore"]),
        .target(name: "VaelenDaemonSupport", dependencies: ["VaelenCore", "VaelenIPC"]),
        .executableTarget(name: "VaelenDaemon", dependencies: ["VaelenDaemonSupport"]),
        .executableTarget(name: "ProjectsPHPUIAcceptance", dependencies: ["VaelenCore", "VaelenIPC"], path: ".agents/skills/verify-vaelen-app/scripts/ProjectsPHPUIAcceptance"),
        .target(name: "VaelenDNSCore"),
        .executableTarget(name: "VaelenDNS", dependencies: ["VaelenDNSCore"]),
        .executableTarget(name: "VaelenCLI", dependencies: ["VaelenIPC"]),
        .executableTarget(name: "VaelenPrivilegedHelper", dependencies: ["VaelenCore"]),
        .target(name: "VaelenTestSupport", dependencies: ["VaelenCore"], path: "Tests/Support"),
        .testTarget(name: "VaelenCoreTests", dependencies: ["VaelenCore", "VaelenTestSupport"]),
        .testTarget(name: "VaelenIPCTests", dependencies: ["VaelenCore", "VaelenIPC", "VaelenDaemonSupport", "VaelenTestSupport", "VaelenCLI"]),
        .testTarget(name: "VaelenCLITests", dependencies: ["VaelenCLI", "VaelenCore", "VaelenIPC"]),
        .testTarget(name: "VaelenDNSTests", dependencies: ["VaelenDNSCore"])
    ]
)
