// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "claudec",
    platforms: [.macOS("15")],
    products: [
        .library(name: "AgentIsolation", targets: ["AgentIsolation"]),
        .library(name: "AgentIsolationAppleContainerRuntime", targets: ["AgentIsolationAppleContainerRuntime"]),
        .executable(name: "claudec", targets: ["claudec"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", from: "0.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AgentIsolation",
            dependencies: []
        ),
        .target(
            name: "AgentIsolationAppleContainerRuntime",
            dependencies: [
                "AgentIsolation",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "claudec",
            dependencies: [
                "AgentIsolation",
                "AgentIsolationAppleContainerRuntime",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
