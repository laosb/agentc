// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "claudec",
  platforms: [.macOS("15")],
  products: [
    .library(name: "AgentIsolation", targets: ["AgentIsolation"]),
    .library(
      name: "AgentIsolationAppleContainerRuntime", targets: ["AgentIsolationAppleContainerRuntime"]),
    .library(
      name: "AgentIsolationDockerRuntime", targets: ["AgentIsolationDockerRuntime"]),
    .executable(name: "claudec", targets: ["claudec"]),
  ],
  traits: [
    .default(enabledTraits: ["ContainerRuntimeAppleContainer", "ContainerRuntimeDocker"]),
    .trait(
      name: "ContainerRuntimeAppleContainer",
      description: "Apple Containerization runtime (macOS only)"
    ),
    .trait(
      name: "ContainerRuntimeDocker",
      description: "Docker Engine runtime (macOS & Linux)"
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/containerization.git", from: "0.29.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
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
    .target(
      name: "AgentIsolationDockerRuntime",
      dependencies: [
        "AgentIsolation",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .executableTarget(
      name: "claudec",
      dependencies: [
        "AgentIsolation",
        .target(name: "AgentIsolationAppleContainerRuntime", condition: .when(traits: ["ContainerRuntimeAppleContainer"])),
        .target(name: "AgentIsolationDockerRuntime", condition: .when(traits: ["ContainerRuntimeDocker"])),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .testTarget(
      name: "AgentIsolationTests",
      dependencies: ["AgentIsolation"]
    ),
    .testTarget(
      name: "AgentIsolationDockerRuntimeTests",
      dependencies: [
        "AgentIsolation",
        .target(name: "AgentIsolationDockerRuntime", condition: .when(traits: ["ContainerRuntimeDocker"])),
      ]
    ),
    .testTarget(
      name: "ClaudecIntegrationTests",
      dependencies: []
    ),
  ]
)
