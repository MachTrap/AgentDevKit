// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDevKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDevKitCore", targets: ["AgentDevKitCore"]),
        .library(name: "AgentDevKitTransport", targets: ["AgentDevKitTransport"]),
        .library(name: "AgentDevKitHost", targets: ["AgentDevKitHost"]),
        .library(name: "AgentDevKitClient", targets: ["AgentDevKitClient"]),
        .executable(name: "agentdevctl", targets: ["agentdevctl"])
    ],
    targets: [
        .target(name: "AgentDevKitCore"),
        .target(name: "AgentDevKitTransport", dependencies: ["AgentDevKitCore"]),
        .target(name: "AgentDevKitHost", dependencies: ["AgentDevKitCore", "AgentDevKitTransport"]),
        .target(name: "AgentDevKitClient", dependencies: ["AgentDevKitCore", "AgentDevKitTransport"]),
        .executableTarget(name: "agentdevctl", dependencies: ["AgentDevKitClient", "AgentDevKitCore"]),
        .testTarget(
            name: "AgentDevKitTests",
            dependencies: ["AgentDevKitCore", "AgentDevKitTransport", "AgentDevKitHost", "AgentDevKitClient"]
        )
    ],
    swiftLanguageModes: [.v6]
)
