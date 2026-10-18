// ACP fixture interpreted by the Swift test image. Uses Codable so the actual
// rewritten command and argument array are executed, not a test-only relay.
import Foundation

struct Request: Decodable {
  var id: String
  var method: String
  var params: Params?
}
struct Params: Decodable {
  var mcpServers: [Server]?
}
struct Server: Decodable {
  var command: String?
  var args: [String]?
}
struct Empty: Codable {}
struct HostReply: Codable {
  struct Result: Codable {
    var cwd: String
    var value: String
    var argument: String
    var pid: Int32
    var echoedMethod: String
  }
  var result: Result
}
struct Reply: Encodable {
  var jsonrpc = "2.0"
  var id: String
  var result: Result
  struct Result: Encodable {
    var protocolVersion: Int?
    var agentCapabilities: Empty?
    var authMethods: [String]?
    var sessionId: String?
    var bridged: Bool?
    var host: HostReply.Result?
  }
}

var children: [(Process, Pipe, Pipe)] = []
while let line = readLine() {
  let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
  var result = Reply.Result()
  if request.method == "initialize" {
    result.protocolVersion = 1
    result.agentCapabilities = Empty()
    result.authMethods = []
  } else if request.method == "session/new" {
    result.sessionId = "test-session"
    result.bridged = false
    if let server = request.params?.mcpServers?.first,
      server.command == "/entrypoint-bootstrap/bootstrap"
    {
      // Opening for writing is non-destructive, but must fail even though this
      // fixture runs as guest root. The relay reuses the bootstrap mount.
      if let writable = try? FileHandle(forWritingTo: URL(fileURLWithPath: server.command!)) {
        try writable.close()
        FileHandle.standardError.write(Data("Host bootstrap relay mount is writable\n".utf8))
        exit(1)
      }
      let process = Process()
      let input = Pipe()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: server.command!)
      process.arguments = server.args
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.standardError
      try process.run()
      children.append((process, input, output))
      input.fileHandleForWriting.write(
        Data(
          #"{"jsonrpc":"2.0","id":"mcp-test","method":"_unknown/initialize","params":{"opaque":[true,null,"🌍"]}}"#
            .utf8) + Data([10]))
      var bytes = Data()
      while let next = try output.fileHandleForReading.read(upToCount: 1), !next.isEmpty {
        if next == Data([10]) { break }
        bytes.append(next)
      }
      guard !bytes.isEmpty else {
        process.waitUntilExit()
        FileHandle.standardError.write(
          Data("MCP relay exited without a response: \(process.terminationStatus)\n".utf8))
        exit(1)
      }
      let reply = try JSONDecoder().decode(HostReply.self, from: bytes)
      result.host = reply.result
      result.bridged = true
    }
  }
  let encoded = try JSONEncoder().encode(Reply(id: request.id, result: result))
  FileHandle.standardOutput.write(encoded + Data([10]))
}
