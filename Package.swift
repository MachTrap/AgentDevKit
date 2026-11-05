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
        /// Declarative file-tree fixtures for Testing targets of file-based apps. Never link it into a shipping target.
        .library(name: "AgentDevKitFixtures", targets: ["AgentDevKitFixtures"]),
        .executable(name: "agentdevctl", targets: ["agentdevctl"]),
        /// The opt-in desktop runner: real pointer and keyboard input through CGEvent. Never linked into apps.
        .executable(name: "agentdevkit-desktop", targets: ["agentdevkit-desktop"])
    ],
    targets: [
        .target(name: "AgentDevKitCore"),
        .target(name: "AgentDevKitTransport", dependencies: ["AgentDevKitCore"]),
        .target(name: "AgentDevKitHost", dependencies: ["AgentDevKitCore", "AgentDevKitTransport"]),
        .target(name: "AgentDevKitClient", dependencies: ["AgentDevKitCore", "AgentDevKitTransport"]),
        .target(name: "AgentDevKitFixtures"),
        .executableTarget(name: "agentdevctl", dependencies: ["AgentDevKitClient", "AgentDevKitCore"]),
        .executableTarget(name: "agentdevkit-desktop", dependencies: ["AgentDevKitClient", "AgentDevKitCore"]),
        .testTarget(
            name: "AgentDevKitTests",
            dependencies: ["AgentDevKitCore", "AgentDevKitTransport", "AgentDevKitHost", "AgentDevKitClient", "AgentDevKitFixtures"]
        )
    ],
    swiftLanguageModes: [.v6]
)
