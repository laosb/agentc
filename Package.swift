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
    .package(url: "https://github.com/apple/containerization.git", from: "0.30.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.0"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.33.1"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.4.0"),
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
        .product(
          name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
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
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(
          name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
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
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(
          name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
      ]
    ),
  ]
)
