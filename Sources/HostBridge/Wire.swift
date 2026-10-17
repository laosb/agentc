#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct BridgeError: Error, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// Versioned launch metadata is separate from the byte-stream frames.
/// Executable, cwd and environment policy are deliberately NOT guest-controlled.
public struct BridgeLaunch: Codable, Sendable {
  public var version = 1
  public var token: String
  public var mapping: String
  public var arguments: [String]
  public var environment: [String: String]

  public init(token: String, mapping: String, arguments: [String], environment: [String: String]) {
    self.token = token
    self.mapping = mapping
    self.arguments = arguments
    self.environment = environment
  }
}

public struct BridgeManifest: Codable, Sendable {
  public static let directory = "/agent-isolation/host-bridge"
  public static let socketPath = "\(directory)/socket"
  public static let filePath = "\(directory)/manifest.json"
  public var token: String
  public var entries: [Entry]

  public struct Entry: Codable, Sendable {
    public var id: String
    public var path: String
    public var forwardEnvironment: [String]

    public init(id: String, path: String, forwardEnvironment: [String]) {
      self.id = id
      self.path = path
      self.forwardEnvironment = forwardEnvironment
    }
  }

  public init(token: String, entries: [Entry]) {
    self.token = token
    self.entries = entries
  }
}

public struct BridgeTermination: Codable, Sendable, Equatable {
  public var code: Int32
  public var signal: String?
  public init(code: Int32, signal: String? = nil) {
    self.code = code
    self.signal = signal
  }
}

/// A byte tag and a big-endian UInt32 length followed by uninterpreted bytes.
/// Stream chunks are capped separately from launch metadata.
public struct BridgeFrame: Sendable {
  public enum Kind: UInt8, Sendable {
    case launch = 1
    case stdin, stdout, stderr, stdinEOF, stdinReady, signal, exit, failure
  }
  public let kind: Kind
  public let data: Data
  public init(_ kind: Kind, _ data: Data = Data()) {
    self.kind = kind
    self.data = data
  }
  public static let chunkSize = 16 * 1024
  public static let launchLimit = 1024 * 1024

  public func encoded() throws -> Data {
    guard data.count <= (kind == .launch ? Self.launchLimit : Self.chunkSize) else {
      throw BridgeError("Host bridge frame is too large")
    }
    var result = Data([kind.rawValue])
    var count = UInt32(data.count).bigEndian
    withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
    result.append(data)
    return result
  }
}

public struct BridgeDecoder {
  private var buffer = Data()
  public init() {}

  public mutating func append(_ bytes: Data) throws -> [BridgeFrame] {
    buffer.append(bytes)
    var result: [BridgeFrame] = []
    while buffer.count >= 5 {
      let start = buffer.startIndex
      guard let kind = BridgeFrame.Kind(rawValue: buffer[start]) else {
        throw BridgeError("Unknown host bridge frame")
      }
      let count = buffer[(start + 1)..<(start + 5)].reduce(0) { ($0 << 8) | Int($1) }
      guard count <= (kind == .launch ? BridgeFrame.launchLimit : BridgeFrame.chunkSize) else {
        throw BridgeError("Host bridge frame is too large")
      }
      guard buffer.count >= 5 + count else { break }
      result.append(.init(kind, Data(buffer[(start + 5)..<(start + 5 + count)])))
      buffer.removeFirst(5 + count)
    }
    return result
  }

  public func finish() throws {
    guard buffer.isEmpty else { throw BridgeError("Truncated host bridge frame") }
  }
}
