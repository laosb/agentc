import AgentIsolation
import Synchronization

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// A byte-preserving, line-oriented transcript. Each direction buffers incomplete
/// lines independently, including UTF-8 sequences split across runtime reads.
final class StdioLog: Sendable {
  enum Stream: String { case stdin, stdout }

  private struct State {
    var stdin = Data()
    var stdout = Data()
    var finished = false
  }

  private let file: LogFile
  private let state = Mutex(State())
  // Bound memory for terminal output, binary streams, and very long JSON lines.
  static let maximumRecordBytes = 64 * 1024

  init(path: String) throws {
    file = try LogFile(path: path)
  }

  var observer: StdioObserver {
    StdioObserver(
      stdin: { self.record($0, stream: .stdin) },
      stdout: { self.record($0, stream: .stdout) })
  }

  func record(_ data: Data, stream: Stream) {
    guard !data.isEmpty else { return }
    state.withLock { state in
      guard !state.finished else { return }
      do {
        switch stream {
        case .stdin: try append(data, to: &state.stdin, stream: stream)
        case .stdout: try append(data, to: &state.stdout, stream: stream)
        }
      } catch {
        state.finished = true
        logger.error("Stdio logging failed: \(error.localizedDescription)")
      }
    }
  }

  /// Flush unterminated final lines before the CLI exits or a session fails.
  func finish() {
    state.withLock { state in
      guard !state.finished else { return }
      state.finished = true
      do {
        if !state.stdin.isEmpty { try writeRecord(state.stdin, stream: .stdin) }
        if !state.stdout.isEmpty { try writeRecord(state.stdout, stream: .stdout) }
      } catch {
        logger.error("Stdio logging failed: \(error.localizedDescription)")
      }
    }
  }

  private func append(_ data: Data, to pending: inout Data, stream: Stream) throws {
    // Scan only new bytes; repeatedly searching the entire pending line would
    // make heavily fragmented protocol messages quadratic.
    var start = data.startIndex
    for index in data.indices {
      if data[index] == 0x0a || pending.count + index - start + 1 >= Self.maximumRecordBytes {
        pending.append(data[start...index])
        try writeRecord(pending, stream: stream)
        pending.removeAll(keepingCapacity: true)
        start = index + 1
      }
    }
    pending.append(data[start...])
  }

  private func writeRecord(_ data: Data, stream: Stream) throws {
    var record = Data("\(stream.rawValue): ".utf8)
    record.append(data)
    if data.last != 0x0a { record.append(0x0a) }
    try file.append(record)
  }
}
