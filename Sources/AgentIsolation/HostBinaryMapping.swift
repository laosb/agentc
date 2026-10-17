#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A declaration, not authorization. The CLI must separately authorize host execution.
public struct HostBinaryMapping: Codable, Sendable, Equatable {
  public var containerPath: String
  public var hostCommand: String
  public var arguments: [String]?
  public var forwardArguments: Bool?
  /// Exact, case-sensitive names. No wildcard or implicit container inheritance.
  public var forwardEnvironment: [String]?

  public init(
    containerPath: String, hostCommand: String, arguments: [String]? = nil,
    forwardArguments: Bool? = nil, forwardEnvironment: [String]? = nil
  ) {
    self.containerPath = containerPath
    self.hostCommand = hostCommand
    self.arguments = arguments
    self.forwardArguments = forwardArguments
    self.forwardEnvironment = forwardEnvironment
  }
}

/// Prepared by the host broker, scoped to one container lifetime.
public struct HostBridgeAttachment: Sendable {
  public var directory: String
  public var socket: String
  public init(directory: String, socket: String) {
    self.directory = directory
    self.socket = socket
  }
}
