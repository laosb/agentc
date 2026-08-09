import AgentIsolation
import ArgumentParser

#if ContainerRuntimeAppleContainer
  import AgentIsolationAppleContainerRuntime
#endif
#if ContainerRuntimeDocker
  import AgentIsolationDockerRuntime
#endif

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct ImagesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "images",
    abstract: "List, inspect, and remove locally stored container images",
    subcommands: [ImagesListCommand.self, ImagesInspectCommand.self, ImagesRemoveCommand.self],
    defaultSubcommand: ImagesListCommand.self
  )
}

struct ImageRuntimeOptions: ParsableArguments {
  @Option(name: .shortAndLong, help: "Container runtime.")
  var runtime: RuntimeChoice?

  @Option(name: .long, help: "Docker Engine API endpoint (socket path or tcp://host:port).")
  var dockerEndpoint: String?

  @Option(
    name: .customLong("storage-path"),
    help: "Container runtime storage path (primarily useful for testing).")
  var storagePath: String?

  func withRuntime<T>(_ operation: (any ManagedImageRuntime) async throws -> T) async throws -> T {
    let resolvedStoragePath =
      storagePath
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first!.appendingPathComponent("sb.lao.agentc").path
    let config = ContainerRuntimeConfiguration(
      storagePath: resolvedStoragePath, endpoint: dockerEndpoint)

    switch RuntimeChoice.resolve(explicit: runtime) {
    case .appleContainer:
      #if ContainerRuntimeAppleContainer
        return try await operation(AppleContainerRuntime(config: config))
      #else
        throw AgentcError.runtimeNotAvailable("apple-container")
      #endif
    case .docker:
      #if ContainerRuntimeDocker
        throw AgentcError.imageManagementNotSupported("docker")
      #else
        throw AgentcError.runtimeNotAvailable("docker")
      #endif
    }
  }
}

struct ImagesListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List images", aliases: ["ls"])
  @OptionGroup var options: ImageRuntimeOptions

  mutating func run() async throws {
    let images = try await options.withRuntime { try await $0.listImages() }
    if images.isEmpty {
      print("No images found.")
      return
    }
    print("NAME\tTAG\tSTORAGE")
    for image in images {
      print("\(image.name)\t\(image.tag)\t\(formatImageSize(image.storageUsage))")
    }
  }
}

struct ImagesInspectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inspect", abstract: "Inspect an image")
  @OptionGroup var options: ImageRuntimeOptions
  @Argument(help: "Image reference to inspect.") var reference: String

  mutating func run() async throws {
    guard
      let image = try await options.withRuntime({ try await $0.inspectManagedImage(ref: reference) }
      )
    else {
      throw AgentcError.imageNotFound(reference)
    }
    print("name:     \(image.name)")
    print("tag:      \(image.tag)")
    print("storage:  \(formatImageSize(image.storageUsage)) (\(image.storageUsage) bytes)")
    if let digest = image.digest { print("digest:   \(digest)") }
    if let mediaType = image.mediaType { print("mediaType: \(mediaType)") }
    if let platforms = image.platforms { print("platforms: \(platforms.joined(separator: ", "))") }
  }
}

struct ImagesRemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove", abstract: "Remove one or more images", aliases: ["rm"])
  @OptionGroup var options: ImageRuntimeOptions
  @Argument(help: "Image reference(s) to remove.") var references: [String]

  mutating func run() async throws {
    guard !references.isEmpty else {
      throw ValidationError("at least one image reference is required")
    }
    try await options.withRuntime { runtime in
      for reference in references {
        try await runtime.removeManagedImage(ref: reference)
        print("agentc: removed image \"\(reference)\"")
      }
    }
  }
}

private func formatImageSize(_ bytes: UInt64) -> String {
  let units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var value = Double(bytes)
  var unit = 0
  while value >= 1024, unit < units.count - 1 {
    value /= 1024
    unit += 1
  }
  return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
}
