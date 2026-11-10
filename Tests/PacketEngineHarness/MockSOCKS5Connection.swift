// Only the standalone packet-engine harness compiles this transport double.
// Production builds use the separately tested SOCKS5Connection implementation.
import AgentIsolation
import Foundation

actor MockConnections {
  static let shared = MockConnections()
  private(set) var destinations: [String] = []
  private(set) var finishedBytes: [Int] = []
  private(set) var slowSends = 0
  func record(_ destination: String) { destinations.append(destination) }
  func finished(_ count: Int) { finishedBytes.append(count) }
  func startingSlowSend() { slowSends += 1 }
}

public actor SOCKS5Connection {
  public enum TransportError: Error { case associateRejected(UInt8) }
  private let dns: Bool
  private let waitForFIN: Bool
  private let earlyEOF: Bool
  private let delayedUpload: Bool
  private var closed = false
  private var finished = false
  private var pending = Data()
  private var sentBytes = 0
  private var slowSendStarted = false

  private init(
    dns: Bool, waitForFIN: Bool = false, earlyEOF: Bool = false,
    delayedUpload: Bool = false
  ) {
    self.dns = dns
    self.waitForFIN = waitForFIN
    self.earlyEOF = earlyEOF
    self.delayedUpload = delayedUpload
  }

  public static func connect(proxy: SOCKS5Proxy, destination: String, port: UInt16) async throws
    -> SOCKS5Connection
  {
    await MockConnections.shared.record("\(destination):\(port)")
    if destination == "203.0.113.9" { throw CancellationError() }
    return SOCKS5Connection(
      dns: destination == proxy.dns.host && port == proxy.dns.port,
      waitForFIN: port == 444, earlyEOF: port == 445,
      delayedUpload: port == 446)
  }

  public static func connectHostMCP(port: UInt16) async throws -> SOCKS5Connection {
    await MockConnections.shared.record("HOST-MCP:\(port)")
    return SOCKS5Connection(dns: false)
  }

  public func send(_ data: Data) async throws {
    guard !closed else { throw CancellationError() }
    if delayedUpload {
      slowSendStarted = true
      await MockConnections.shared.startingSlowSend()
      try await Task.sleep(for: .milliseconds(500))
      guard !closed else { throw CancellationError() }
    }
    if waitForFIN { try await Task.sleep(for: .milliseconds(2)) }
    sentBytes += data.count
    if dns {
      var answer = [UInt8](data)
      answer[4] |= 0x80
      pending.append(contentsOf: answer)
      finished = true
    } else {
      pending.append(data)
    }
  }

  public func receive(maximum: Int) async throws -> Data? {
    if earlyEOF { return nil }
    if delayedUpload {
      while !slowSendStarted { try await Task.sleep(for: .milliseconds(2)) }
      try await Task.sleep(for: .milliseconds(100))
      return nil
    }
    while (pending.isEmpty || (waitForFIN && !finished)) && !closed && !finished {
      try await Task.sleep(for: .milliseconds(2))
    }
    guard !closed else { throw CancellationError() }
    if pending.isEmpty { return nil }
    let data = Data(pending.prefix(maximum))
    pending.removeFirst(data.count)
    return data
  }

  public func finishSending() async throws {
    await MockConnections.shared.finished(sentBytes)
    finished = true
  }
  public func close() { closed = true }
}

actor MockUDPAssociations {
  static let shared = MockUDPAssociations()
  private(set) var destinations: [String] = []
  private(set) var closed = 0
  func record(_ value: String) { destinations.append(value) }
  func didClose() { closed += 1 }
}

public actor SOCKS5UDPAssociation {
  public static let maximumPayloadSize = 1472
  private var pending: [Data] = []
  private var closed = false

  public static func associate(proxy: SOCKS5Proxy, destination: String, port: UInt16) async throws
    -> SOCKS5UDPAssociation
  {
    await MockUDPAssociations.shared.record("\(destination):\(port)")
    if port == 9003 { throw SOCKS5Connection.TransportError.associateRejected(7) }
    return SOCKS5UDPAssociation()
  }

  public func send(_ payload: Data) async throws {
    try Task.checkCancellation()
    guard !closed, payload.count <= Self.maximumPayloadSize else { throw CancellationError() }
    pending.append(payload)
  }

  public func receive() async throws -> Data? {
    while pending.isEmpty && !closed { try await Task.sleep(for: .milliseconds(2)) }
    guard !closed else { return nil }
    return pending.removeFirst()
  }

  public func close() async {
    guard !closed else { return }
    closed = true
    pending.removeAll()
    await MockUDPAssociations.shared.didClose()
  }
}
