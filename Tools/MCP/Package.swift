// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AgentDevKitMCP",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "agentdevkit-mcp", targets: ["agentdevkit-mcp"])],
    dependencies: [
        .package(name: "AgentDevKit", path: "../.."),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .executableTarget(
            name: "agentdevkit-mcp",
            dependencies: [
                .product(name: "AgentDevKitCore", package: "AgentDevKit"),
                .product(name: "AgentDevKitClient", package: "AgentDevKit"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
