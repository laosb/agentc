// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "agentc",
  platforms: [.macOS("15")],
  products: [
    .library(name: "AgentIsolation", targets: ["AgentIsolation"]),
    .library(
      name: "AgentIsolationAppleContainerRuntime", targets: ["AgentIsolationAppleContainerRuntime"]),
    .library(
      name: "AgentIsolationDockerRuntime", targets: ["AgentIsolationDockerRuntime"]),
    .executable(name: "agentc", targets: ["agentc"]),
    .executable(name: "agentc-bootstrap", targets: ["agentc-bootstrap"]),
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
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
  ],
  targets: [
    .target(
      name: "AgentIsolation",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(
      name: "AgentIsolationAppleContainerRuntime",
      dependencies: [
        "AgentIsolation",
        .product(
          name: "Containerization", package: "containerization",
          condition: .when(platforms: [.macOS])),
        .product(
          name: "ContainerizationOCI", package: "containerization",
          condition: .when(platforms: [.macOS])),
        .product(
          name: "ContainerizationOS", package: "containerization",
          condition: .when(platforms: [.macOS])),
        .product(
          name: "ContainerizationArchive", package: "containerization",
          condition: .when(platforms: [.macOS])),
        .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.macOS])),
      ]
    ),
    .target(
      name: "AgentIsolationDockerRuntime",
      dependencies: [
        "AgentIsolation",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOFoundationCompat", package: "swift-nio"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .executableTarget(
      name: "agentc",
      dependencies: [
        "AgentIsolation",
        .target(
          name: "AgentIsolationAppleContainerRuntime",
          condition: .when(traits: ["ContainerRuntimeAppleContainer"])),
        .target(
          name: "AgentIsolationDockerRuntime", condition: .when(traits: ["ContainerRuntimeDocker"])),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .executableTarget(
      name: "agentc-bootstrap",
      dependencies: []
    ),
    .testTarget(
      name: "AgentIsolationTests",
      dependencies: [
        "AgentIsolation",
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .testTarget(
      name: "AgentIsolationDockerRuntimeTests",
      dependencies: [
        "AgentIsolation",
        .target(
          name: "AgentIsolationDockerRuntime", condition: .when(traits: ["ContainerRuntimeDocker"])),
      ]
    ),
    .testTarget(
      name: "AgentIsolationAppleContainerRuntimeTests",
      dependencies: [
        "AgentIsolation",
        .target(
          name: "AgentIsolationAppleContainerRuntime",
          condition: .when(traits: ["ContainerRuntimeAppleContainer"])),
      ]
    ),
    .testTarget(
      name: "AgentcIntegrationTests",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
  ]
)
