import ArgumentParser
import Foundation

/// Determine which container runtime to use.
enum RuntimeChoice: String, ExpressibleByArgument, CaseIterable, Sendable {
  case docker
  case appleContainer = "apple-container"

  /// Resolve the runtime: use an explicit choice if provided, otherwise auto-detect.
  static func resolve(explicit: RuntimeChoice?) -> RuntimeChoice {
    if let explicit {
      return explicit
    }

    #if os(macOS)
      #if ContainerRuntimeAppleContainer
        return .appleContainer
      #elseif ContainerRuntimeDocker
        return .docker
      #else
        fatalError("agentc: no container runtime available. Build with a ContainerRuntime* trait.")
      #endif
    #else
      #if ContainerRuntimeDocker
        return .docker
      #else
        fatalError("agentc: no container runtime available. Build with a ContainerRuntime* trait.")
      #endif
    #endif
  }
}
