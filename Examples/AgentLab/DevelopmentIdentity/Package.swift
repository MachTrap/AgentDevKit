// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevelopmentIdentity",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DevelopmentIdentity", targets: ["DevelopmentIdentity"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.10.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.6.0")
    ],
    targets: [
        .target(name: "DevelopmentIdentity", dependencies: [
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1")
        ])
    ]
)
