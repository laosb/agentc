import Foundation
import Testing

@testable import agentc

@Suite("Stdio transcripts")
struct StdioLogTests {
  @Test("Fragmented UTF-8, multiline messages, and final partial lines are preserved")
  func fragmentedMessages() throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("stdio.log")
    let log = try StdioLog(path: path.path)
    let input = Data("{\"text\":\"hello 🌍\"}\r\n\n".utf8)
    for byte in input { log.observer.stdin(Data([byte])) }
    log.observer.stdout(Data("{\"ok\":".utf8))
    log.observer.stdout(Data("true}\npartial".utf8))
    // Complete lines are visible while the session is running.
    #expect(try String(contentsOf: path, encoding: .utf8).contains("stdout: {\"ok\":true}\n"))
    log.finish()
    log.finish()
    log.observer.stdout(Data("ignored after finish".utf8))
    #expect(
      try String(contentsOf: path, encoding: .utf8)
        == "stdin: {\"text\":\"hello 🌍\"}\r\nstdin: \nstdout: {\"ok\":true}\nstdout: partial\n")
  }

  @Test("Both directions flush partial lines and preserve arbitrary bytes")
  func partialAndBinary() throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("stdio.log")
    try Data("previous\n".utf8).write(to: path)
    let log = try StdioLog(path: path.path)
    log.record(Data([0x00, 0xff]), stream: .stdin)
    log.record(Data("response".utf8), stream: .stdout)
    log.finish()
    var expected = Data("previous\nstdin: ".utf8)
    expected.append(contentsOf: [0x00, 0xff, 0x0a])
    expected.append(Data("stdout: response\n".utf8))
    #expect(try Data(contentsOf: path) == expected)
  }

  @Test("Concurrent messages do not interleave records")
  func concurrentMessages() async throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("stdio.log")
    let log = try StdioLog(path: path.path)
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<100 {
        group.addTask { log.observer.stdin(Data("request \(i)\n".utf8)) }
        group.addTask { log.observer.stdout(Data("response \(i)\n".utf8)) }
      }
    }
    log.finish()
    let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 200)
    for i in 0..<100 {
      #expect(lines.contains("stdin: request \(i)"))
      #expect(lines.contains("stdout: response \(i)"))
    }
  }

  @Test("Long unterminated streams are recorded with bounded buffering")
  func boundedRecords() throws {
    let directory = try temporaryLogDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("stdio.log")
    let log = try StdioLog(path: path.path)
    let data = Data(repeating: 0x61, count: StdioLog.maximumRecordBytes * 2 + 3)
    log.record(data, stream: .stdout)
    let running = try String(contentsOf: path, encoding: .utf8)
    #expect(running.split(separator: "\n").count == 2)
    log.finish()
    let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines.last == "stdout: aaa")
    #expect(
      lines.map { $0.dropFirst("stdout: ".count) }.joined() == String(decoding: data, as: UTF8.self)
    )
  }
}
